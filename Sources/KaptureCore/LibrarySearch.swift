// Library search: FTS5 over the fts_source table (external content; the schema's triggers keep
// captures_fts in step). Name/app text works today; OCR, tags and summaries fill in with M4's
// ingest pipeline through updateSearchText.
import Foundation
import GRDB

extension Library {
    /// Upsert searchable text for a capture. Fields left nil keep their stored value, so ingest
    /// can add ocr/summary/tags later without clobbering the name.
    static func indexText(_ db: GRDB.Database, id: String, name: String? = nil, summary: String? = nil,
                          tags: String? = nil, ocr: String? = nil) throws {
        try db.execute(sql: """
            INSERT INTO fts_source (captureId, name, summary, tags, ocr) VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(captureId) DO UPDATE SET
              name = COALESCE(?, name), summary = COALESCE(?, summary),
              tags = COALESCE(?, tags), ocr = COALESCE(?, ocr)
            """, arguments: [id, name ?? "", summary ?? "", tags ?? "", ocr ?? "",
                             name, summary, tags, ocr])
    }

    public func updateSearchText(_ id: String, name: String? = nil, summary: String? = nil,
                                 tags: String? = nil, ocr: String? = nil) throws {
        try db.queue.write { d in
            try Library.indexText(d, id: id, name: name, summary: summary, tags: tags, ocr: ocr)
        }
    }

    public enum SearchScope: String, CaseIterable, Sendable {
        case all, screenshots, recordings, trash

        public var title: String {
            switch self {
            case .all: "All"
            case .screenshots: "Screenshots"
            case .recordings: "Recordings"
            case .trash: "Trash"
            }
        }
    }

    /// Optional full-text match plus a scope filter, newest first. Ranking weights name over
    /// tags over summary over OCR.
    public func sourceApps() -> [String] {
        (try? db.queue.read { d in
            try String.fetchAll(d, sql: """
                SELECT DISTINCT sourceApp FROM captures
                WHERE sourceApp IS NOT NULL AND status IN ('staged','kept') ORDER BY sourceApp
                """)
        }) ?? []
    }

    public func search(_ query: String = "", scope: SearchScope = .all, app: String? = nil,
                       limit: Int = 500) -> [CaptureRecord] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let statusClause = scope == .trash ? "c.status = 'trashed'" : "c.status IN ('staged', 'kept')"
        var kindClause = ""
        if scope == .screenshots { kindClause = " AND c.kind IN ('screenshot', 'gif')" }
        if scope == .recordings { kindClause = " AND c.kind = 'recording'" }
        var appClause = ""
        if let app { appClause = " AND c.sourceApp = '\(app.replacingOccurrences(of: "'", with: "''"))'" }

        return (try? db.queue.read { d -> [CaptureRecord] in
            guard !trimmed.isEmpty else {
                return try CaptureRecord.fetchAll(d, sql: """
                    SELECT c.* FROM captures c WHERE \(statusClause)\(kindClause)\(appClause)
                    ORDER BY c.createdAt DESC LIMIT ?
                    """, arguments: [limit])
            }
            // Prefix-match every term so partial words match as you type. Punctuation is FTS5
            // syntax, so a query like "scripts/build.mjs" or "v1.2" must be split into bare
            // tokens first — passing it through raw throws and silently returns nothing.
            let pattern = Library.ftsPattern(trimmed)
            guard !pattern.isEmpty else {
                return try CaptureRecord.fetchAll(d, sql: """
                    SELECT c.* FROM captures c WHERE \(statusClause)\(kindClause)\(appClause)
                    ORDER BY c.createdAt DESC LIMIT ?
                    """, arguments: [limit])
            }
            return try CaptureRecord.fetchAll(d, sql: """
                SELECT c.* FROM captures c
                JOIN fts_source s ON s.captureId = c.id
                JOIN captures_fts f ON f.rowid = s.rowid
                WHERE captures_fts MATCH ? AND \(statusClause)\(kindClause)\(appClause)
                ORDER BY bm25(captures_fts, 8.0, 2.0, 4.0, 1.0), c.createdAt DESC LIMIT ?
                """, arguments: [pattern, limit])
        }) ?? []
    }

    /// Files the shell is actively using — a drag in flight, an open save panel, a running
    /// upload. An AI rename must not move a file out from under one of those (the pasteboard
    /// holds a concrete URL), so applyName refuses and the ingest job retries later.
    private static let inUseLock = NSLock()
    nonisolated(unsafe) private static var inUseIDs: Set<String> = []

    public static func markInUse(_ id: String) {
        inUseLock.lock(); defer { inUseLock.unlock() }
        inUseIDs.insert(id)
    }
    public static func clearInUse(_ id: String) {
        inUseLock.lock(); defer { inUseLock.unlock() }
        inUseIDs.remove(id)
    }
    public static func isInUse(_ id: String) -> Bool {
        inUseLock.lock(); defer { inUseLock.unlock() }
        return inUseIDs.contains(id)
    }

    /// Rename a capture's file to an AI-suggested base name (extension preserved), journaled and
    /// compare-and-swapped: the rename is skipped if the row changed underneath (a manual rename
    /// pins aiState) or the target already exists. Sidecar, search index and identity follow.
    @discardableResult
    public func applyName(_ id: String, baseName: String, tags: [String], summary: String,
                          engine: String) -> Bool {
        guard !Library.isInUse(id) else { return false }   // drag/upload/save panel holds the path
        guard let record = try? db.queue.read({ try CaptureRecord.fetchOne($0, key: id) }),
              record.aiState == "ocr" || record.aiState == "none",   // never overwrite a named/manual row
              record.status != .trashed, record.status != .sweeping else { return false }

        let fm = FileManager.default
        let current = url(for: record)
        let ext = current.pathExtension
        let dir = current.deletingLastPathComponent()
        let target = Library.uniqueURL(in: dir, base: baseName, ext: ext)
        guard target.lastPathComponent != current.lastPathComponent else { return false }
        let newRel = rel(target)

        do {
            _ = try OpJournal.run(db, op: "rename", captureId: id, src: record.relPath, dst: newRel,
                fileOp: {
                    guard fm.fileExists(atPath: current.path), !fm.fileExists(atPath: target.path) else {
                        throw CocoaError(.fileNoSuchFile)
                    }
                    try moveWithSidecar(from: current, to: target)
                },
                stateUpdate: { d, _ in
                    // CAS: only rewrite the row if nothing moved it while we worked
                    try d.execute(sql: """
                        UPDATE captures SET relPath = ?, fastID = ?, aiState = ?, summary = ?
                        WHERE id = ? AND relPath = ?
                        """, arguments: [newRel, Library.fastID(of: target), "named:" + engine,
                                         summary, id, record.relPath])
                    try Library.indexText(d, id: id, name: target.lastPathComponent,
                                          summary: summary, tags: tags.joined(separator: " "))
                })
            Log.store.info("named \(record.relPath, privacy: .public) → \(newRel, privacy: .public)")
            return true
        } catch {
            Log.store.error("rename failed for \(id): \(error)")
            return false
        }
    }

    /// Query text → an FTS5 prefix pattern. Splits on anything the unicode61 tokenizer treats
    /// as a separator so punctuation in the query can't become MATCH syntax.
    static func ftsPattern(_ query: String) -> String {
        query.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map { $0.lowercased() + "*" }
            .joined(separator: " ")
    }

    /// Recognized text for a capture, if ingest has read it.
    public func ocrText(_ id: String) -> String? {
        try? db.queue.read {
            try String.fetchOne($0, sql: "SELECT ocr FROM fts_source WHERE captureId = ?", arguments: [id])
        } ?? nil
    }

    /// How many captures carry recognized text (ingest progress).
    public func indexedCount() -> Int {
        (try? db.queue.read {
            try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM fts_source WHERE length(ocr) > 0") ?? 0
        }) ?? 0
    }

    public func sampleIndexedText(limit: Int = 140) -> String? {
        try? db.queue.read {
            try String.fetchOne($0, sql: """
                SELECT substr(replace(ocr, char(10), ' '), 1, ?) FROM fts_source
                WHERE length(ocr) > 0 ORDER BY rowid DESC LIMIT 1
                """, arguments: [limit])
        } ?? nil
    }

    /// Absolute URL for a capture's file.
    public func url(for record: CaptureRecord) -> URL {
        root.appendingPathComponent(record.relPath)
    }
}

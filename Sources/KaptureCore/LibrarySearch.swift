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
    public func search(_ query: String = "", scope: SearchScope = .all, limit: Int = 500) -> [CaptureRecord] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let statusClause = scope == .trash ? "c.status = 'trashed'" : "c.status IN ('staged', 'kept')"
        var kindClause = ""
        if scope == .screenshots { kindClause = " AND c.kind IN ('screenshot', 'gif')" }
        if scope == .recordings { kindClause = " AND c.kind = 'recording'" }

        return (try? db.queue.read { d -> [CaptureRecord] in
            guard !trimmed.isEmpty else {
                return try CaptureRecord.fetchAll(d, sql: """
                    SELECT c.* FROM captures c WHERE \(statusClause)\(kindClause)
                    ORDER BY c.createdAt DESC LIMIT ?
                    """, arguments: [limit])
            }
            // prefix-match every term so partial words match as you type
            let pattern = trimmed.split(separator: " ")
                .map { $0.replacingOccurrences(of: "\"", with: "").appending("*") }
                .joined(separator: " ")
            return try CaptureRecord.fetchAll(d, sql: """
                SELECT c.* FROM captures c
                JOIN fts_source s ON s.captureId = c.id
                JOIN captures_fts f ON f.rowid = s.rowid
                WHERE captures_fts MATCH ? AND \(statusClause)\(kindClause)
                ORDER BY bm25(captures_fts, 8.0, 2.0, 4.0, 1.0), c.createdAt DESC LIMIT ?
                """, arguments: [pattern, limit])
        }) ?? []
    }

    /// Absolute URL for a capture's file.
    public func url(for record: CaptureRecord) -> URL {
        root.appendingPathComponent(record.relPath)
    }
}

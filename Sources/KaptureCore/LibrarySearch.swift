// Library search: FTS5 over the fts_source table (external content; the schema's triggers keep
// captures_fts in step). Name/app text works today; OCR, tags and summaries fill in with M4's
// ingest pipeline through updateSearchText.
import Foundation
import GRDB

/// A running observation of the library. Cancelled explicitly, or when it is let go.
///
/// A wrapper so a caller can hold one without importing GRDB: the app target depends on this
/// module, not on the database library underneath it, and a live subscription should not be the
/// one thing that changes that.
public final class LibraryObservation {
    private let cancellable: AnyDatabaseCancellable

    init(_ cancellable: AnyDatabaseCancellable) { self.cancellable = cancellable }
    deinit { cancellable.cancel() }

    public func cancel() { cancellable.cancel() }
}

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
        case all, screenshots, recordings, shared, trash

        public var title: String {
            switch self {
            case .all: "All"
            case .screenshots: "Screenshots"
            case .recordings: "Recordings"
            case .shared: "Shared"
            case .trash: "Trash"
            }
        }
    }

    /// Calls back whenever anything in the captures table changes, whoever changed it.
    ///
    /// The library window was told to reload by hand, and only `ShareCoordinator` ever remembered
    /// — so a capture taken while the window was open never appeared in it, and neither did a
    /// discard, a restore, an edit, or a name arriving late from the ingest queue. Every one of
    /// those is a separate writer that has to remember a call it gets no reminder about, which is
    /// a bug per writer waiting to happen and had already happened five times over.
    ///
    /// Watching the table is the version that cannot be forgotten: a writer added tomorrow shows
    /// up in an open window without knowing this exists. The callback arrives on the database's
    /// own queue after the transaction commits — hop to wherever you need to be.
    public func observeCaptures(onChange: @escaping @Sendable () -> Void) -> LibraryObservation {
        LibraryObservation(DatabaseRegionObservation(tracking: Table("captures"))
            .start(in: db.queue,
                   onError: { Log.store.error("captures observation failed: \($0)") },
                   onChange: { _ in onChange() }))
    }

    private static let sourceAppsSQL = """
        SELECT DISTINCT sourceApp FROM captures
        WHERE sourceApp IS NOT NULL AND status IN ('staged','kept') ORDER BY sourceApp
        """

    /// Every app the library holds a capture from, for the window's app filter.
    public func sourceApps() -> [String] {
        (try? db.queue.read { try String.fetchAll($0, sql: Self.sourceAppsSQL) }) ?? []
    }

    /// The same list off the main thread, for the same reason `searchAsync` exists: an open
    /// library re-reads this on every write to the table now that it observes them, and the one
    /// serialized connection means a main-thread read waits on whatever ingest is writing.
    public func sourceAppsAsync() async -> [String] {
        (try? await db.queue.read { try String.fetchAll($0, sql: Self.sourceAppsSQL) }) ?? []
    }

    public enum DateRange: String, CaseIterable, Sendable {
        case any, today, week, month

        public var title: String {
            switch self {
            case .any: "Any time"
            case .today: "Today"
            case .week: "Last 7 days"
            case .month: "Last 30 days"
            }
        }

        var since: Date? {
            let cal = Calendar.current
            switch self {
            case .any: return nil
            case .today: return cal.startOfDay(for: Date())
            case .week: return cal.date(byAdding: .day, value: -7, to: Date())
            case .month: return cal.date(byAdding: .day, value: -30, to: Date())
            }
        }
    }

    /// One query in two shapes: SQL text plus its bound arguments. Only the scope's literal
    /// status/kind sets are interpolated (fixed strings this file owns); everything derived from
    /// user input — the app id, the date cutoff, the FTS pattern — is bound as `?`.
    private struct SearchQuery {
        let sql: String
        let arguments: StatementArguments
    }

    private func searchQuery(_ query: String, scope: SearchScope, app: String?,
                             range: DateRange, limit: Int) -> SearchQuery {
        var clauses = [scope == .trash ? "c.status = 'trashed'" : "c.status IN ('staged', 'kept')"]
        var args: [(any DatabaseValueConvertible)?] = []
        switch scope {
        case .screenshots: clauses.append("c.kind IN ('screenshot', 'gif')")
        case .recordings: clauses.append("c.kind = 'recording'")
        case .shared: clauses.append("c.shareURL IS NOT NULL")
        case .all, .trash: break
        }
        if let app {
            clauses.append("c.sourceApp = ?")
            args.append(app)
        }
        // bound as a Date: GRDB encodes it the same way it stored the column, so the comparison
        // matches. An epoch number here would silently match nothing.
        if let since = range.since {
            clauses.append("c.createdAt >= ?")
            args.append(since)
        }
        let filter = clauses.joined(separator: " AND ")

        // Prefix-match every term so partial words match as you type. Punctuation is FTS5
        // syntax, so a query like "scripts/build.mjs" or "v1.2" must be split into bare tokens
        // first — passing it through raw throws and silently returns nothing.
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let pattern = trimmed.isEmpty ? "" : Library.ftsPattern(trimmed)
        guard !pattern.isEmpty else {
            return SearchQuery(sql: """
                SELECT c.* FROM captures c WHERE \(filter)
                ORDER BY c.createdAt DESC LIMIT ?
                """, arguments: StatementArguments(args + [limit]))
        }
        return SearchQuery(sql: """
            SELECT c.* FROM captures c
            JOIN fts_source s ON s.captureId = c.id
            JOIN captures_fts f ON f.rowid = s.rowid
            WHERE captures_fts MATCH ? AND \(filter)
            ORDER BY bm25(captures_fts, 8.0, 2.0, 4.0, 1.0), c.createdAt DESC LIMIT ?
            """, arguments: StatementArguments([pattern] + args + [limit]))
    }

    /// Optional full-text match plus a scope filter, newest first. Ranking weights name over
    /// tags over summary over OCR. (This is what that comment was describing; it had drifted up
    /// the file onto `sourceApps`, which does none of it.)
    public func search(_ query: String = "", scope: SearchScope = .all, app: String? = nil,
                       range: DateRange = .any, limit: Int = 500) -> [CaptureRecord] {
        let q = searchQuery(query, scope: scope, app: app, range: range, limit: limit)
        return (try? db.queue.read { try CaptureRecord.fetchAll($0, sql: q.sql, arguments: q.arguments) }) ?? []
    }

    /// The same query off the main thread. The app has one serialized DB connection, so a
    /// keystroke's search can queue behind an ingest write of 20k characters of OCR text —
    /// blocking the main thread for it stutters typing in the search field.
    public func searchAsync(_ query: String = "", scope: SearchScope = .all, app: String? = nil,
                            range: DateRange = .any, limit: Int = 500) async -> [CaptureRecord] {
        let q = searchQuery(query, scope: scope, app: app, range: range, limit: limit)
        return (try? await db.queue.read { try CaptureRecord.fetchAll($0, sql: q.sql, arguments: q.arguments) }) ?? []
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
}

import Foundation
import SQLite3

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Phase 2 local memory: hotword terms with learned weights, fed by the
/// correction journal. All data stays in the app-support sandbox; entries
/// carry their source and can be disabled — 防污染 rules from the design doc
/// (§10.3) are enforced here: rejections decay a term, three consecutive
/// rejections auto-disable it.
public final class SQLiteMemoryStore: MemoryStore, @unchecked Sendable {
    public struct IngestSummary: Sendable, Equatable {
        public var acceptedPairs = 0
        public var negativeSignals = 0
        public var skippedEntries = 0
    }

    private let queue = DispatchQueue(label: "app.velora.memory.sqlite")
    private var db: OpaquePointer?

    public init(path: String) throws {
        var handle: OpaquePointer?
        guard sqlite3_open(path, &handle) == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "open_failed"
            sqlite3_close(handle)
            throw PipelineError.localModelUnavailable("memory_store_open_failed:\(message)")
        }
        db = handle
        try execute("""
        CREATE TABLE IF NOT EXISTS terms (
            term TEXT NOT NULL,
            replacement TEXT NOT NULL,
            language TEXT NOT NULL DEFAULT 'zh',
            source TEXT NOT NULL DEFAULT 'manual',
            edit_count INTEGER NOT NULL DEFAULT 0,
            reject_streak INTEGER NOT NULL DEFAULT 0,
            base_score REAL NOT NULL DEFAULT 6.0,
            disabled INTEGER NOT NULL DEFAULT 0,
            last_seen_at REAL NOT NULL DEFAULT 0,
            PRIMARY KEY (term, replacement)
        );
        CREATE TABLE IF NOT EXISTS meta (
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL
        );
        """)
    }

    deinit {
        sqlite3_close(db)
    }

    public static func defaultStore() -> SQLiteMemoryStore? {
        guard let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        let folder = directory.appendingPathComponent("Velora", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return try? SQLiteMemoryStore(path: folder.appendingPathComponent("memory.sqlite").path)
    }

    // MARK: - MemoryStore

    /// Ported POC ranking (context_hotword_poc.py), minus per-app/domain data
    /// which no caller records yet:
    /// score = base + nearby_match*4 + min(3, ln(1+edit_count)) + recency + mode_bonus
    public func rankHotwords(for snapshot: ContextSnapshot, limit: Int) async throws -> [HotwordCandidate] {
        let nearby = snapshot.nearbyText.lowercased()
        let modeBonus = snapshot.mode == .translate ? 1.2 : 0.0
        let now = Date().timeIntervalSince1970

        return queue.sync {
            var candidates: [HotwordCandidate] = []
            let sql = "SELECT term, replacement, edit_count, base_score, last_seen_at FROM terms WHERE disabled = 0"
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
                return []
            }
            defer { sqlite3_finalize(statement) }

            while sqlite3_step(statement) == SQLITE_ROW {
                let term = String(cString: sqlite3_column_text(statement, 0))
                let replacement = String(cString: sqlite3_column_text(statement, 1))
                let editCount = Double(sqlite3_column_int(statement, 2))
                let baseScore = sqlite3_column_double(statement, 3)
                let lastSeen = sqlite3_column_double(statement, 4)

                var score = baseScore
                var reasons: [String] = ["memory_term"]
                if nearby.contains(term.lowercased()) || nearby.contains(replacement.lowercased()) {
                    score += 4.0
                    reasons.append("nearby_text_match")
                }
                if editCount > 0 {
                    score += Swift.min(3.0, log(1.0 + editCount))
                    reasons.append("edit_count")
                }
                if lastSeen > 0 {
                    let days = Swift.max(0, (now - lastSeen) / 86_400)
                    let recency = 2.0 * exp(-days / 30.0)
                    if recency > 0.1 {
                        score += recency
                        reasons.append("recency")
                    }
                }
                if modeBonus > 0 {
                    score += modeBonus
                    reasons.append("translation_mode_bonus")
                }
                candidates.append(HotwordCandidate(term: term, replacement: replacement, score: score, reasons: reasons))
            }

            return Array(
                candidates
                    .sorted { lhs, rhs in
                        lhs.score == rhs.score ? lhs.term < rhs.term : lhs.score > rhs.score
                    }
                    .prefix(limit)
            )
        }
    }

    // MARK: - Learning

    public func seedIfEmpty(_ terms: [HotwordCandidate], language: String = "zh") {
        queue.sync {
            guard scalarInt("SELECT COUNT(*) FROM terms") == 0 else {
                return
            }
            for term in terms {
                upsertLocked(
                    term: term.term,
                    replacement: term.replacement,
                    language: language,
                    source: term.reasons.first ?? "seed",
                    baseScore: term.score
                )
            }
        }
    }

    public func recordAcceptedCorrection(term: String, replacement: String, language: String = "zh") {
        let term = term.trimmingCharacters(in: .whitespacesAndNewlines)
        let replacement = replacement.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isReasonableTermPair(term: term, replacement: replacement) else {
            return
        }
        queue.sync {
            upsertLocked(term: term, replacement: replacement, language: language, source: "accepted_correction", baseScore: 6.5)
            run(
                "UPDATE terms SET edit_count = edit_count + 1, reject_streak = 0, last_seen_at = ? WHERE term = ? AND replacement = ?",
                binds: [.double(Date().timeIntervalSince1970), .text(term), .text(replacement)]
            )
        }
    }

    /// Negative feedback (retry/undo). Three consecutive rejections disable
    /// the term automatically (design §10.3).
    public func recordRejection(term: String, replacement: String) {
        queue.sync {
            run(
                """
                UPDATE terms SET reject_streak = reject_streak + 1,
                                 base_score = MAX(1.0, base_score - 0.8),
                                 disabled = CASE WHEN reject_streak + 1 >= 3 THEN 1 ELSE disabled END
                WHERE term = ? AND replacement = ?
                """,
                binds: [.text(term), .text(replacement)]
            )
        }
    }

    public func termCount(includeDisabled: Bool = false) -> Int {
        queue.sync {
            scalarInt(includeDisabled ? "SELECT COUNT(*) FROM terms" : "SELECT COUNT(*) FROM terms WHERE disabled = 0")
        }
    }

    public func isDisabled(term: String, replacement: String) -> Bool {
        queue.sync {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT disabled FROM terms WHERE term = ? AND replacement = ?", -1, &statement, nil) == SQLITE_OK else {
                return false
            }
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_text(statement, 1, term, -1, sqliteTransient)
            sqlite3_bind_text(statement, 2, replacement, -1, sqliteTransient)
            guard sqlite3_step(statement) == SQLITE_ROW else {
                return false
            }
            return sqlite3_column_int(statement, 0) == 1
        }
    }

    // MARK: - Journal ingestion

    /// Incrementally consumes the correction journal (offset tracked in meta),
    /// mining accepted term pairs from source edits and negative feedback from
    /// retry/undo events. Deterministic single-span diffing only — ambiguous
    /// multi-span edits are skipped rather than guessed.
    @discardableResult
    public func ingestCorrectionJournal(at url: URL) -> IngestSummary {
        var summary = IngestSummary()
        guard let data = try? Data(contentsOf: url) else {
            return summary
        }
        let offset = queue.sync { Int(scalarText("SELECT value FROM meta WHERE key = 'journal_offset'").flatMap(Int.init) ?? 0) }
        guard data.count > offset else {
            return summary
        }
        let newData = data.subdata(in: offset..<data.count)
        guard let text = String(data: newData, encoding: .utf8) else {
            return summary
        }

        for line in text.split(separator: "\n") {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let kind = object["kind"] as? String else {
                summary.skippedEntries += 1
                continue
            }
            switch kind {
            case "translate_review_edit":
                if let before = object["source_before"] as? String,
                   let after = object["source_after"] as? String,
                   let pair = Self.singleSpanDiff(before: before, after: after) {
                    recordAcceptedCorrection(term: pair.before, replacement: pair.after)
                    summary.acceptedPairs += 1
                } else {
                    summary.skippedEntries += 1
                }
            case "retry_redictation", "undo_after_insert":
                let edits = object["applied_edits"] as? [[String: Any]] ?? []
                for edit in edits {
                    if let from = edit["from"] as? String, let to = edit["to"] as? String {
                        recordRejection(term: from, replacement: to)
                        summary.negativeSignals += 1
                    }
                }
            default:
                summary.skippedEntries += 1
            }
        }

        queue.sync {
            run(
                "INSERT INTO meta (key, value) VALUES ('journal_offset', ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                binds: [.text(String(data.count))]
            )
        }
        return summary
    }

    /// Mines a term pair only from a SHORT contiguous change (both sides
    /// 1...6 chars). Prefix/suffix trimming collapses any edit into one span,
    /// so the length cap is what actually rejects multi-edit / rewrite cases —
    /// real term corrections (疑程→议程, 超市→超时) are 1–4 chars.
    static func singleSpanDiff(before: String, after: String) -> (before: String, after: String)? {
        guard before != after else {
            return nil
        }
        let b = Array(before)
        let a = Array(after)
        var prefix = 0
        while prefix < b.count && prefix < a.count && b[prefix] == a[prefix] {
            prefix += 1
        }
        var suffix = 0
        while suffix < b.count - prefix && suffix < a.count - prefix
            && b[b.count - 1 - suffix] == a[a.count - 1 - suffix] {
            suffix += 1
        }
        let beforeSpan = String(b[prefix..<(b.count - suffix)])
        let afterSpan = String(a[prefix..<(a.count - suffix)])
        guard (1...6).contains(beforeSpan.count), (1...6).contains(afterSpan.count),
              Self.isReasonableTermPair(term: beforeSpan, replacement: afterSpan) else {
            return nil
        }
        return (beforeSpan, afterSpan)
    }

    static func isReasonableTermPair(term: String, replacement: String) -> Bool {
        (1...12).contains(term.count)
            && (1...12).contains(replacement.count)
            && term != replacement
            && !term.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !replacement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - SQLite plumbing

    private enum Bind {
        case text(String)
        case double(Double)
    }

    private func upsertLocked(term: String, replacement: String, language: String, source: String, baseScore: Double) {
        run(
            """
            INSERT INTO terms (term, replacement, language, source, base_score, last_seen_at)
            VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT(term, replacement) DO NOTHING
            """,
            binds: [.text(term), .text(replacement), .text(language), .text(source), .double(baseScore), .double(Date().timeIntervalSince1970)]
        )
    }

    private func run(_ sql: String, binds: [Bind]) {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            return
        }
        defer { sqlite3_finalize(statement) }
        for (index, bind) in binds.enumerated() {
            switch bind {
            case .text(let value):
                sqlite3_bind_text(statement, Int32(index + 1), value, -1, sqliteTransient)
            case .double(let value):
                sqlite3_bind_double(statement, Int32(index + 1), value)
            }
        }
        sqlite3_step(statement)
    }

    private func execute(_ sql: String) throws {
        var errorMessage: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &errorMessage) == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) } ?? "exec_failed"
            sqlite3_free(errorMessage)
            throw PipelineError.localModelUnavailable("memory_store_exec_failed:\(message)")
        }
    }

    private func scalarInt(_ sql: String) -> Int {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            return 0
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            return 0
        }
        return Int(sqlite3_column_int(statement, 0))
    }

    private func scalarText(_ sql: String) -> String? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            return nil
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW, let text = sqlite3_column_text(statement, 0) else {
            return nil
        }
        return String(cString: text)
    }
}

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
        // Contend gracefully with the settings-panel connection on the same
        // file instead of failing writes with SQLITE_BUSY.
        sqlite3_busy_timeout(handle, 2_000)
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
            promoted INTEGER NOT NULL DEFAULT 1,
            session_count INTEGER NOT NULL DEFAULT 0,
            last_session_id TEXT NOT NULL DEFAULT '',
            PRIMARY KEY (term, replacement)
        );
        CREATE TABLE IF NOT EXISTS meta (
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS correction_examples (
            before_span TEXT NOT NULL,
            after_span TEXT NOT NULL,
            before_text TEXT NOT NULL,
            after_text TEXT NOT NULL,
            pinyin_key TEXT NOT NULL,
            created_at REAL NOT NULL DEFAULT 0,
            PRIMARY KEY (before_span, after_span, before_text)
        );
        """)
        // Additive migrations for stores created before the candidate-pool
        // columns existed. Check the actual schema first so a real failure
        // (disk/lock/corruption) surfaces instead of being swallowed as an
        // "already exists" no-op — otherwise later promoted/session_count
        // reads would silently return wrong data. Pre-existing learned terms
        // default to promoted so an upgrade never turns off hotwords in use.
        let existing = try columnNames(of: "terms")
        let additions: [(name: String, ddl: String)] = [
            ("promoted", "ALTER TABLE terms ADD COLUMN promoted INTEGER NOT NULL DEFAULT 1"),
            ("session_count", "ALTER TABLE terms ADD COLUMN session_count INTEGER NOT NULL DEFAULT 0"),
            ("last_session_id", "ALTER TABLE terms ADD COLUMN last_session_id TEXT NOT NULL DEFAULT ''"),
            // 'contextual' terms only inform the polish LLM; unconditional
            // replacement is reserved for pairs the user marked 'hard'.
            // Existing rows migrate to contextual — blanket replacement of a
            // possibly-legitimate word is the riskier default.
            ("apply_mode", "ALTER TABLE terms ADD COLUMN apply_mode TEXT NOT NULL DEFAULT 'contextual'"),
        ]
        for addition in additions where !existing.contains(addition.name) {
            try execute(addition.ddl)
        }
    }

    private func columnNames(of table: String) throws -> Set<String> {
        var names: Set<String> = []
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA table_info(\(table))", -1, &statement, nil) == SQLITE_OK else {
            throw PipelineError.localModelUnavailable("memory_store_pragma_failed")
        }
        defer { sqlite3_finalize(statement) }
        while sqlite3_step(statement) == SQLITE_ROW {
            // table_info columns: cid(0) name(1) type(2) ...
            if let name = sqlite3_column_text(statement, 1) {
                names.insert(String(cString: name))
            }
        }
        return names
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
            // Candidates (promoted = 0) accumulate evidence but never bias
            // live recognition until they clear the promotion gate.
            let sql = "SELECT term, replacement, edit_count, base_score, last_seen_at, apply_mode FROM terms WHERE disabled = 0 AND promoted = 1"
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
                let applyMode = String(cString: sqlite3_column_text(statement, 5))

                var score = baseScore
                var reasons: [String] = ["memory_term"]
                if applyMode == "hard" {
                    // HotwordCorrector applies ONLY terms carrying this marker;
                    // everything else reaches the LLM as context instead.
                    reasons.append(HotwordCorrector.hardReplaceReason)
                }
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

    /// Learned pairs enter as CANDIDATES and only start biasing recognition
    /// after the promotion gate: the same pair confirmed ≥2 times across ≥2
    /// distinct sessions (`sessionKey`). One-off proper nouns therefore stay
    /// in the candidate pool and age out instead of polluting every future
    /// dictation. Passing a nil sessionKey keeps the legacy immediate-promote
    /// behavior for explicit/manual entries.
    public func recordAcceptedCorrection(
        term: String,
        replacement: String,
        language: String = "zh",
        sessionKey: String? = nil
    ) {
        let term = term.trimmingCharacters(in: .whitespacesAndNewlines)
        let replacement = replacement.trimmingCharacters(in: .whitespacesAndNewlines)
        guard VeloraLearnGate.isLearnablePair(term: term, replacement: replacement) else {
            return
        }
        queue.sync {
            upsertLocked(
                term: term,
                replacement: replacement,
                language: language,
                source: "accepted_correction",
                baseScore: 6.5,
                promoted: sessionKey == nil
            )
            run(
                "UPDATE terms SET edit_count = edit_count + 1, reject_streak = 0, last_seen_at = ? WHERE term = ? AND replacement = ?",
                binds: [.double(Date().timeIntervalSince1970), .text(term), .text(replacement)]
            )
            if let sessionKey {
                run(
                    """
                    UPDATE terms SET session_count = session_count + 1, last_session_id = ?
                    WHERE term = ? AND replacement = ? AND last_session_id != ?
                    """,
                    binds: [.text(sessionKey), .text(term), .text(replacement), .text(sessionKey)]
                )
                run(
                    "UPDATE terms SET promoted = 1 WHERE term = ? AND replacement = ? AND edit_count >= 2 AND session_count >= 2",
                    binds: [.text(term), .text(replacement)]
                )
            }
            enforceActiveCapLocked()
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

    // MARK: - Dictionary management (settings UI)

    public struct TermRecord: Sendable, Equatable, Identifiable {
        public var term: String
        public var replacement: String
        public var language: String
        public var source: String
        public var editCount: Int
        public var disabled: Bool
        public var promoted: Bool
        public var lastSeenAt: Date?
        public var hardReplace: Bool

        public var id: String { "\(term)→\(replacement)" }
        public var isAutoLearned: Bool { source == "accepted_correction" }
    }

    public func listTerms(limit: Int = 500) -> [TermRecord] {
        queue.sync {
            var records: [TermRecord] = []
            let sql = """
            SELECT term, replacement, language, source, edit_count, disabled, promoted, last_seen_at, apply_mode
            FROM terms ORDER BY promoted DESC, last_seen_at DESC, edit_count DESC LIMIT ?
            """
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
                return []
            }
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_int(statement, 1, Int32(limit))
            while sqlite3_step(statement) == SQLITE_ROW {
                let lastSeen = sqlite3_column_double(statement, 7)
                records.append(
                    TermRecord(
                        term: String(cString: sqlite3_column_text(statement, 0)),
                        replacement: String(cString: sqlite3_column_text(statement, 1)),
                        language: String(cString: sqlite3_column_text(statement, 2)),
                        source: String(cString: sqlite3_column_text(statement, 3)),
                        editCount: Int(sqlite3_column_int(statement, 4)),
                        disabled: sqlite3_column_int(statement, 5) == 1,
                        promoted: sqlite3_column_int(statement, 6) == 1,
                        lastSeenAt: lastSeen > 0 ? Date(timeIntervalSince1970: lastSeen) : nil,
                        hardReplace: String(cString: sqlite3_column_text(statement, 8)) == "hard"
                    )
                )
            }
            return records
        }
    }

    public func setTermDisabled(term: String, replacement: String, disabled: Bool) {
        queue.sync {
            run(
                "UPDATE terms SET disabled = ?, reject_streak = 0 WHERE term = ? AND replacement = ?",
                binds: [.double(disabled ? 1 : 0), .text(term), .text(replacement)]
            )
        }
    }

    public func removeTerm(term: String, replacement: String) {
        queue.sync {
            run("DELETE FROM terms WHERE term = ? AND replacement = ?", binds: [.text(term), .text(replacement)])
        }
    }

    /// User-typed dictionary entry: active immediately (promoted, no
    /// candidate gate — the pool exists to filter NOISY automatic signals,
    /// not deliberate input). Upserting an existing pair re-enables it.
    public func addManualTerm(term: String, replacement: String, language: String = "zh") {
        let term = term.trimmingCharacters(in: .whitespacesAndNewlines)
        let replacement = replacement.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty, !replacement.isEmpty, term != replacement else {
            return
        }
        queue.sync {
            run(
                """
                INSERT INTO terms (term, replacement, language, source, promoted, disabled, last_seen_at)
                VALUES (?, ?, ?, 'manual', 1, 0, ?)
                ON CONFLICT(term, replacement) DO UPDATE SET disabled = 0, promoted = 1
                """,
                binds: [.text(term), .text(replacement), .text(language), .double(Date().timeIntervalSince1970)]
            )
        }
    }

    /// In-place edit of a pair. The pair IS the primary key, so this is a
    /// keyed move that carries the row's stats along; landing on an existing
    /// pair merges into it (old row removed, target re-enabled). Editing is
    /// deliberate input, so the result is promoted like a manual entry.
    public func updateTerm(
        term: String,
        replacement: String,
        newTerm: String,
        newReplacement: String
    ) {
        let newTerm = newTerm.trimmingCharacters(in: .whitespacesAndNewlines)
        let newReplacement = newReplacement.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !newTerm.isEmpty, !newReplacement.isEmpty, newTerm != newReplacement,
              newTerm != term || newReplacement != replacement else {
            return
        }
        queue.sync {
            // OR IGNORE: when the target pair already exists the move is
            // skipped; the follow-up DELETE then drops the old row and the
            // UPDATE re-enables the merge target. Without a collision the
            // row moves in place and the follow-ups are no-ops.
            run(
                "UPDATE OR IGNORE terms SET term = ?, replacement = ?, promoted = 1, disabled = 0 WHERE term = ? AND replacement = ?",
                binds: [.text(newTerm), .text(newReplacement), .text(term), .text(replacement)]
            )
            run("DELETE FROM terms WHERE term = ? AND replacement = ?", binds: [.text(term), .text(replacement)])
            run(
                "UPDATE terms SET disabled = 0, promoted = 1 WHERE term = ? AND replacement = ?",
                binds: [.text(newTerm), .text(newReplacement)]
            )
        }
    }

    /// Periodic hygiene, run after each journal ingest:
    /// - learned terms unseen for 90 days drop back to the candidate pool;
    /// - the active learned set is capped so ranking stays sharp and a future
    ///   HomophoneReplacer dictionary stays small.
    public static let activeLearnedCap = 200

    public func performMaintenance(now: Date = Date()) {
        queue.sync {
            run(
                "UPDATE terms SET promoted = 0 WHERE promoted = 1 AND source = 'accepted_correction' AND last_seen_at > 0 AND last_seen_at < ?",
                binds: [.double(now.timeIntervalSince1970 - 90 * 86_400)]
            )
            enforceActiveCapLocked()
        }
    }

    private func enforceActiveCapLocked() {
        let active = scalarInt("SELECT COUNT(*) FROM terms WHERE promoted = 1 AND source = 'accepted_correction'")
        let excess = active - Self.activeLearnedCap
        guard excess > 0 else {
            return
        }
        run(
            """
            UPDATE terms SET promoted = 0 WHERE rowid IN (
                SELECT rowid FROM terms
                WHERE promoted = 1 AND source = 'accepted_correction'
                ORDER BY base_score ASC, last_seen_at ASC
                LIMIT ?
            )
            """,
            binds: [.double(Double(excess))]
        )
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
        // Serialize the whole read-offset → process → write-offset cycle. The
        // caller fires this from an untracked Task.detached on every recording
        // start, so two overlapping runs could otherwise read the same offset
        // and double-count the same lines. First writer wins; the loser bails.
        guard beginIngestGuard() else {
            return summary
        }
        defer { endIngestGuard() }

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

        // post_insert_edit for one session can appear twice (live settle, then
        // the next-dictation lazy re-diff). Keep only the LAST one per session
        // so a temporary edit the user reverted doesn't leave a stale asr_fix
        // (docs/LEARNING_PIPELINE.md: "以后到的为准"). Preserve arrival order.
        var latestPostInsert: [String: [String: Any]] = [:]
        var postInsertOrder: [String] = []
        var immediate: [(kind: String, object: [String: Any], sessionKey: String)] = []

        for line in text.split(separator: "\n") {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let kind = object["kind"] as? String else {
                summary.skippedEntries += 1
                continue
            }
            let sessionKey = (object["session_id"] as? String) ?? (object["at"] as? String) ?? "unknown"
            if kind == "post_insert_edit" {
                if latestPostInsert[sessionKey] == nil {
                    postInsertOrder.append(sessionKey)
                }
                latestPostInsert[sessionKey] = object
            } else {
                immediate.append((kind, object, sessionKey))
            }
        }

        for entry in immediate {
            switch entry.kind {
            case "translate_review_edit":
                // Only the SOURCE-language edit is a hotword candidate. Target
                // (translated) edits are terminology preferences in another
                // language; mining them into the shared term pool lets the
                // ASR-side HotwordCorrector rewrite unrelated text. They stay
                // in the journal for fine-tuning, just not in `terms`.
                if let before = entry.object["source_before"] as? String,
                   let after = entry.object["source_after"] as? String,
                   let pair = Self.singleSpanDiff(before: before, after: after) {
                    recordAcceptedCorrection(term: pair.before, replacement: pair.after, sessionKey: entry.sessionKey)
                    recordCorrectionExample(
                        beforeSpan: pair.before,
                        afterSpan: pair.after,
                        beforeText: before,
                        afterText: after
                    )
                    summary.acceptedPairs += 1
                } else {
                    summary.skippedEntries += 1
                }
            case "retry_redictation", "undo_after_insert":
                let edits = entry.object["applied_edits"] as? [[String: Any]] ?? []
                for edit in edits {
                    if let from = edit["from"] as? String, let to = edit["to"] as? String {
                        recordRejection(term: from, replacement: to)
                        summary.negativeSignals += 1
                    }
                }
            case "insertion":
                // Positive baseline for the fine-tune corpus; nothing to mine
                // into the hotword table.
                break
            default:
                summary.skippedEntries += 1
            }
        }

        for sessionKey in postInsertOrder {
            guard let object = latestPostInsert[sessionKey] else {
                continue
            }
            let blocks = object["edit_blocks"] as? [[String: Any]] ?? []
            let language = object["lang"] as? String ?? "zh"
            for block in blocks {
                guard let type = block["type"] as? String,
                      let before = block["before"] as? String,
                      let after = block["after"] as? String else {
                    continue
                }
                switch type {
                case "asr_fix":
                    recordAcceptedCorrection(
                        term: before,
                        replacement: after,
                        language: language,
                        sessionKey: sessionKey
                    )
                    recordCorrectionExample(
                        beforeSpan: before,
                        afterSpan: after,
                        beforeText: object["inserted_text"] as? String ?? "",
                        afterText: object["user_final_span"] as? String ?? ""
                    )
                    summary.acceptedPairs += 1
                case "reverted_hotword":
                    // The user undid OUR replacement: reject the pair as it
                    // exists in the table (term = original, replacement = what
                    // we wrongly put on screen).
                    recordRejection(term: after, replacement: before)
                    summary.negativeSignals += 1
                default:
                    break
                }
            }
        }

        queue.sync {
            run(
                "INSERT INTO meta (key, value) VALUES ('journal_offset', ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                binds: [.text(String(data.count))]
            )
        }
        performMaintenance()
        return summary
    }

    // MARK: - Correction examples (few-shot history for the polish LLM)

    /// Sentence pairs are capped in length (windowed around the span) and the
    /// table is capped by recency: this is prompt material, not an archive —
    /// the journal remains the full record.
    public static let correctionExampleCap = 300
    private static let exampleTextLimit = 120

    func recordCorrectionExample(
        beforeSpan: String,
        afterSpan: String,
        beforeText: String,
        afterText: String
    ) {
        guard !beforeSpan.isEmpty, !afterSpan.isEmpty, beforeSpan != afterSpan,
              !beforeText.isEmpty, !afterText.isEmpty else {
            return
        }
        let before = Self.windowed(beforeText, around: beforeSpan, limit: Self.exampleTextLimit)
        let after = Self.windowed(afterText, around: afterSpan, limit: Self.exampleTextLimit)
        queue.sync {
            run(
                """
                INSERT INTO correction_examples (before_span, after_span, before_text, after_text, pinyin_key, created_at)
                VALUES (?, ?, ?, ?, ?, ?)
                ON CONFLICT(before_span, after_span, before_text) DO UPDATE SET created_at = excluded.created_at
                """,
                binds: [
                    .text(beforeSpan), .text(afterSpan), .text(before), .text(after),
                    .text(VeloraPinyin.latinized(beforeSpan)), .double(Date().timeIntervalSince1970),
                ]
            )
            run(
                """
                DELETE FROM correction_examples WHERE rowid NOT IN (
                    SELECT rowid FROM correction_examples ORDER BY created_at DESC LIMIT \(Self.correctionExampleCap)
                )
                """,
                binds: []
            )
        }
    }

    public func recentCorrectionExamples(limit: Int) -> [VeloraCorrectionExample] {
        queue.sync {
            var examples: [VeloraCorrectionExample] = []
            let sql = """
            SELECT before_span, after_span, before_text, after_text, pinyin_key
            FROM correction_examples ORDER BY created_at DESC LIMIT ?
            """
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
                return []
            }
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_int(statement, 1, Int32(limit))
            while sqlite3_step(statement) == SQLITE_ROW {
                examples.append(
                    VeloraCorrectionExample(
                        beforeSpan: String(cString: sqlite3_column_text(statement, 0)),
                        afterSpan: String(cString: sqlite3_column_text(statement, 1)),
                        beforeText: String(cString: sqlite3_column_text(statement, 2)),
                        afterText: String(cString: sqlite3_column_text(statement, 3)),
                        pinyinKey: String(cString: sqlite3_column_text(statement, 4))
                    )
                )
            }
            return examples
        }
    }

    /// Keeps the span visible with symmetric context when the sentence is
    /// longer than the prompt budget allows.
    static func windowed(_ text: String, around span: String, limit: Int) -> String {
        guard text.count > limit else {
            return text
        }
        let chars = Array(text)
        let spanChars = Array(span)
        var spanStart = 0
        if !spanChars.isEmpty {
            for start in 0...(chars.count - Swift.min(spanChars.count, chars.count)) {
                if Array(chars[start..<Swift.min(start + spanChars.count, chars.count)]) == spanChars {
                    spanStart = start
                    break
                }
            }
        }
        let half = Swift.max(0, (limit - spanChars.count) / 2)
        let lower = Swift.max(0, spanStart - half)
        let upper = Swift.min(chars.count, lower + limit)
        return String(chars[lower..<upper])
    }

    /// Dictionary UI: flip a term between context-only (LLM decides) and
    /// hard replacement (HotwordCorrector + FST).
    public func setTermApplyMode(term: String, replacement: String, hard: Bool) {
        queue.sync {
            run(
                "UPDATE terms SET apply_mode = ? WHERE term = ? AND replacement = ?",
                binds: [.text(hard ? "hard" : "contextual"), .text(term), .text(replacement)]
            )
        }
    }

    private var ingesting = false
    private func beginIngestGuard() -> Bool {
        queue.sync {
            guard !ingesting else {
                return false
            }
            ingesting = true
            return true
        }
    }
    private func endIngestGuard() {
        queue.sync { ingesting = false }
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

    private func upsertLocked(
        term: String,
        replacement: String,
        language: String,
        source: String,
        baseScore: Double,
        promoted: Bool = true
    ) {
        run(
            """
            INSERT INTO terms (term, replacement, language, source, base_score, last_seen_at, promoted)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(term, replacement) DO NOTHING
            """,
            binds: [
                .text(term), .text(replacement), .text(language), .text(source),
                .double(baseScore), .double(Date().timeIntervalSince1970), .double(promoted ? 1 : 0),
            ]
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

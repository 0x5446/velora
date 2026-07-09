import Foundation
import Testing
@testable import Velora

// MARK: - Pinyin domain

@Test func pinyinLatinizationAndDistance() {
    #expect(VeloraPinyin.latinized("超时") == "chaoshi")
    #expect(VeloraPinyin.distance("超市", "超时") == 0)
    #expect(VeloraPinyin.isNearHomophone("文当", "文档"))
    #expect(VeloraPinyin.isNearHomophone("疑程", "议程"))
    // Different sounds must not pass: near-homophone is the asr_fix gate.
    #expect(!VeloraPinyin.isNearHomophone("方案", "预算"))
    // Latin text passes through: their/there are near, apple/window are not.
    #expect(VeloraPinyin.isNearHomophone("their", "there"))
    #expect(!VeloraPinyin.isNearHomophone("apple", "window"))
}

// MARK: - Edit spans

@Test func editSpansFindSingleSubstitution() {
    let spans = VeloraEditAnalyzer.editSpans(before: "接口超市了", after: "接口超时了")
    #expect(spans.count == 1)
    #expect(spans.first?.before == "市")
    #expect(spans.first?.after == "时")
}

@Test func editSpansBridgeSingleUnchangedCharacter() {
    // 反回接果 → 返回结果: two sound-alike misrecognitions separated by an
    // unchanged 回/果 must merge into ONE logical edit, not confetti.
    let spans = VeloraEditAnalyzer.editSpans(before: "反回接果", after: "返回结果")
    #expect(spans.count == 1)
    #expect(spans.first?.before.contains("反") == true)
    #expect(spans.first?.after.contains("返") == true)
}

@Test func editSpansSeparateDistantEdits() {
    let spans = VeloraEditAnalyzer.editSpans(
        before: "把超市参数发给张三看一下",
        after: "把超时参数发给章衫看一下"
    )
    #expect(spans.count == 2)
}

// MARK: - Classification

@Test func analyzeClassifiesHomophoneFixAsASRFix() {
    let analysis = VeloraEditAnalyzer.analyze(
        inserted: "接口超市了需要重试",
        userFinal: "接口超时了需要重试"
    )
    #expect(!analysis.isRewrite)
    #expect(analysis.blocks.count == 1)
    #expect(analysis.blocks.first?.kind == .asrFix)
    #expect(analysis.blocks.first?.before == "市")
    #expect(analysis.blocks.first?.after == "时")
}

@Test func analyzeClassifiesPureInsertionAsContent() {
    let analysis = VeloraEditAnalyzer.analyze(
        inserted: "明天开会",
        userFinal: "明天上午开会"
    )
    #expect(analysis.blocks.count == 1)
    #expect(analysis.blocks.first?.kind == .content)
}

@Test func analyzeClassifiesNumericFormattingAsStyle() {
    let analysis = VeloraEditAnalyzer.analyze(
        inserted: "下午三点碰一下",
        userFinal: "下午3点碰一下"
    )
    #expect(analysis.blocks.allSatisfy { $0.kind == .style })
}

@Test func analyzeDetectsRevertedHotword() {
    let analysis = VeloraEditAnalyzer.analyze(
        inserted: "用户都很支持这个方案",
        userFinal: "拥护都很支持这个方案",
        appliedEdits: [TextEdit(from: "拥护", to: "用户", reason: "selected_hotword", confidence: 0.9)]
    )
    #expect(analysis.blocks.first?.kind == .revertedHotword)
}

@Test func analyzeTreatsHeavyRewriteAsNoSignal() {
    let analysis = VeloraEditAnalyzer.analyze(
        inserted: "今天天气不错我们出去走走吧",
        userFinal: "会议纪要已经发到群里请大家确认"
    )
    #expect(analysis.isRewrite)
    #expect(!analysis.blocks.contains { $0.kind == .asrFix })
}

@Test func analyzeIgnoresPunctuationChurn() {
    let analysis = VeloraEditAnalyzer.analyze(
        inserted: "好的，明天见。",
        userFinal: "好的，明天见！"
    )
    #expect(analysis.blocks.isEmpty)
}

// MARK: - Learn gate

@Test func learnGateBansStopwordsDigitsAndLongSpans() {
    #expect(VeloraLearnGate.isLearnablePair(term: "超市", replacement: "超时"))
    #expect(!VeloraLearnGate.isLearnablePair(term: "的", replacement: "地"))
    #expect(!VeloraLearnGate.isLearnablePair(term: "我们", replacement: "沃门"))
    #expect(!VeloraLearnGate.isLearnablePair(term: "v2版本", replacement: "威二版本"))
    #expect(!VeloraLearnGate.isLearnablePair(term: "这是一个很长的跨度", replacement: "这是一个很长的跨读"))
}

// MARK: - Span anchoring

@Test func spanAnchorExtractsEditedSpanViaContext() {
    let baseline = "会前准备：这里是我们插入的听写内容。会后跟进事项。"
    let inserted = "这里是我们插入的听写内容。"
    let spanStart = 5
    // The user fixed one character inside the span; surrounding text intact.
    let updated = "会前准备：这里是我们插入的听写內容。会后跟进事项。"
    let extraction = VeloraSpanAnchor.extractSpan(
        baseline: baseline,
        spanStart: spanStart,
        spanLength: inserted.count,
        updated: updated
    )
    #expect(extraction?.span == "这里是我们插入的听写內容。")
}

@Test func spanAnchorHandlesInsertionAtDocumentEnd() {
    let baseline = "已有内容。新插入的句子"
    let extraction = VeloraSpanAnchor.extractSpan(
        baseline: baseline,
        spanStart: 5,
        spanLength: 6,
        updated: "已有内容。新插入的句子改了尾巴"
    )
    #expect(extraction?.span == "新插入的句子改了尾巴")
}

@Test func spanAnchorWholeFieldWhenSpanIsEverything() {
    let extraction = VeloraSpanAnchor.extractSpan(
        baseline: "整段就是插入内容",
        spanStart: 0,
        spanLength: 8,
        updated: "整段就是插入內容"
    )
    #expect(extraction?.span == "整段就是插入內容")
}

@Test func spanAnchorPicksCorrectSpanWhenPrefixRepeatsAfterSpan() {
    // The 16-char prefix context before the span also appears AFTER it. Naive
    // last-occurrence anchoring would pick the trailing copy and miss the span;
    // pair-solving by gap length must select the real one.
    let baseline = "请参考下面的说明开始操作插入的正文内容请参考下面的说明结束"
    let inserted = "插入的正文内容"
    let spanStart = baseline.distance(
        from: baseline.startIndex,
        to: baseline.range(of: inserted)!.lowerBound
    )
    let updated = "请参考下面的说明开始操作插入的正文內容请参考下面的说明结束"
    let extraction = VeloraSpanAnchor.extractSpan(
        baseline: baseline,
        spanStart: spanStart,
        spanLength: inserted.count,
        updated: updated
    )
    #expect(extraction?.span == "插入的正文內容")
}

@Test func spanAnchorSurvivesEditsBeforeTheSpan() {
    // Offsets drift when the user edits text ABOVE the span; anchors survive.
    let baseline = "第一段落写了一些别的东西。插入的内容在这里。结尾。"
    let updated = "第一段落被用户大改特改过了，完全不同。插入的内容在这里没变。结尾。"
    let extraction = VeloraSpanAnchor.extractSpan(
        baseline: baseline,
        spanStart: 13,
        spanLength: 9,
        updated: updated
    )
    #expect(extraction?.span.contains("插入的内容在这里") == true)
}

// MARK: - Memory store promotion gate

private func temporaryPromotionStore() throws -> SQLiteMemoryStore {
    let path = NSTemporaryDirectory() + "velora-memory-promo-\(UUID().uuidString).sqlite"
    return try SQLiteMemoryStore(path: path)
}

@Test func learnedPairStaysCandidateUntilSecondSession() async throws {
    let store = try temporaryPromotionStore()
    let snapshot = ContextSnapshot(appBundle: "test", mode: .input)

    store.recordAcceptedCorrection(term: "超市", replacement: "超时", sessionKey: "s1")
    var ranked = try await store.rankHotwords(for: snapshot, limit: 5)
    #expect(ranked.isEmpty)

    // Same session again: still one session — stays a candidate.
    store.recordAcceptedCorrection(term: "超市", replacement: "超时", sessionKey: "s1")
    ranked = try await store.rankHotwords(for: snapshot, limit: 5)
    #expect(ranked.isEmpty)

    // Second distinct session clears the gate.
    store.recordAcceptedCorrection(term: "超市", replacement: "超时", sessionKey: "s2")
    ranked = try await store.rankHotwords(for: snapshot, limit: 5)
    #expect(ranked.first?.term == "超市")
}

@Test func legacyNilSessionKeepsImmediatePromotion() async throws {
    let store = try temporaryPromotionStore()
    store.recordAcceptedCorrection(term: "理点需求", replacement: "理清需求")
    let ranked = try await store.rankHotwords(
        for: ContextSnapshot(appBundle: "test", mode: .input),
        limit: 5
    )
    #expect(ranked.first?.term == "理点需求")
}

@Test func ingestPostInsertEditBlocks() async throws {
    let store = try temporaryPromotionStore()
    let journal = URL(fileURLWithPath: NSTemporaryDirectory() + "velora-journal-pie-\(UUID().uuidString).jsonl")
    defer { try? FileManager.default.removeItem(at: journal) }

    let entries = [
        #"{"kind":"insertion","session_id":"a","asr_text":"x","polished_text":"y","final_text":"y"}"#,
        #"{"kind":"post_insert_edit","session_id":"a","lang":"zh","edit_blocks":[{"type":"asr_fix","before":"超市","after":"超时"},{"type":"reverted_hotword","before":"用户","after":"拥护"},{"type":"style","before":"，","after":"。"}]}"#,
        #"{"kind":"post_insert_edit","session_id":"b","lang":"zh","edit_blocks":[{"type":"asr_fix","before":"超市","after":"超时"}]}"#,
    ]
    try (entries.joined(separator: "\n") + "\n").write(to: journal, atomically: true, encoding: .utf8)

    let summary = store.ingestCorrectionJournal(at: journal)
    #expect(summary.acceptedPairs == 2)
    #expect(summary.negativeSignals == 1)

    // Two distinct sessions → promoted and rankable.
    let ranked = try await store.rankHotwords(
        for: ContextSnapshot(appBundle: "test", mode: .input),
        limit: 5
    )
    #expect(ranked.contains { $0.term == "超市" && $0.replacement == "超时" })
}

@Test func laterPostInsertEditForSameSessionWins() async throws {
    // Session s1: first the user makes an asr_fix, then (lazy re-diff, same
    // session, later in the file) reverts it. Only the LAST event should apply,
    // so no 超市→超时 pair should be learned.
    let store = try temporaryPromotionStore()
    let journal = URL(fileURLWithPath: NSTemporaryDirectory() + "velora-journal-latest-\(UUID().uuidString).jsonl")
    defer { try? FileManager.default.removeItem(at: journal) }
    let entries = [
        #"{"kind":"post_insert_edit","session_id":"s1","lang":"zh","edit_blocks":[{"type":"asr_fix","before":"超市","after":"超时"}]}"#,
        #"{"kind":"post_insert_edit","session_id":"s1","lang":"zh","edit_blocks":[]}"#,
        // A different session confirms the pair once — not enough on its own.
        #"{"kind":"post_insert_edit","session_id":"s2","lang":"zh","edit_blocks":[{"type":"asr_fix","before":"超市","after":"超时"}]}"#,
    ]
    try (entries.joined(separator: "\n") + "\n").write(to: journal, atomically: true, encoding: .utf8)

    store.ingestCorrectionJournal(at: journal)
    // s1's asr_fix was superseded by its empty re-diff, so only s2 contributed:
    // one session, below the 2-session gate → not promoted → not ranked.
    let ranked = try await store.rankHotwords(for: ContextSnapshot(appBundle: "t", mode: .input), limit: 5)
    #expect(!ranked.contains { $0.term == "超市" })
}

@Test func translateTargetEditsDoNotEnterHotwordTable() throws {
    // Target-side (translated) edits must NOT be mined into `terms` — only the
    // source-language edit is a hotword candidate.
    let store = try temporaryPromotionStore()
    let journal = URL(fileURLWithPath: NSTemporaryDirectory() + "velora-journal-tgt-\(UUID().uuidString).jsonl")
    defer { try? FileManager.default.removeItem(at: journal) }
    let entry = #"{"kind":"translate_review_edit","language_pair":"zh-en","source_before":"过一遍疑程","source_after":"过一遍议程","target_before":"reviewthe aganda","target_after":"review the agenda"}"#
    try (entry + "\n").write(to: journal, atomically: true, encoding: .utf8)

    let summary = store.ingestCorrectionJournal(at: journal)
    // Only the source edit counts (singleSpanDiff trims the shared 程 → 疑→议);
    // the target edit is ignored entirely.
    #expect(summary.acceptedPairs == 1)
    let terms = store.listTerms()
    #expect(terms.contains { $0.term == "疑" && $0.replacement == "议" })
    #expect(!terms.contains { $0.replacement.contains("agenda") })
}

@Test func migrationPreservesExistingLearnedTermsAsPromoted() throws {
    // A store created fresh has the new columns; reopening the same file must
    // not fail and must keep terms rankable.
    let path = NSTemporaryDirectory() + "velora-memory-migrate-\(UUID().uuidString).sqlite"
    let first = try SQLiteMemoryStore(path: path)
    first.recordAcceptedCorrection(term: "文当", replacement: "文档")
    let reopened = try SQLiteMemoryStore(path: path)
    #expect(reopened.termCount() == 1)
}

@Test func dictionaryManagementAPIs() throws {
    let store = try temporaryPromotionStore()
    store.recordAcceptedCorrection(term: "超市", replacement: "超时")
    store.recordAcceptedCorrection(term: "文当", replacement: "文档")

    var terms = store.listTerms()
    #expect(terms.count == 2)
    #expect(terms.allSatisfy { $0.isAutoLearned })

    store.setTermDisabled(term: "超市", replacement: "超时", disabled: true)
    terms = store.listTerms()
    #expect(terms.first { $0.term == "超市" }?.disabled == true)

    store.removeTerm(term: "文当", replacement: "文档")
    #expect(store.listTerms().count == 1)
}

// MARK: - Terminal grid hard-wrap handling

/// Re-wraps text into fixed-width rows the way a terminal grid renders it —
/// hard \n injected mid-span, breakpoints shifting as content changes.
private func gridWrapped(_ text: String, width: Int) -> String {
    var rows: [String] = []
    var current = ""
    for ch in text {
        current.append(ch)
        if current.count == width {
            rows.append(current)
            current = ""
        }
    }
    if !current.isEmpty {
        rows.append(current)
    }
    return rows.joined(separator: "\n")
}

@Test func hardWrapStripRemovesNewlinesAndCarriageReturns() {
    #expect(VeloraSpanAnchor.strippingHardWraps("ab\ncd\r\nef") == "abcdef")
    #expect(VeloraSpanAnchor.strippingHardWraps("无换行") == "无换行")
}

@Test func hardWrapStripDropsRowTailPaddingButKeepsContentSpaces() {
    // iTerm2 (probed 2026-07-07): CJK double-width chars leave a one-column
    // gap at the row end, rendered as trailing space(s) before the newline.
    #expect(VeloraSpanAnchor.strippingHardWraps("中文行尾 \n继续") == "中文行尾继续")
    #expect(VeloraSpanAnchor.strippingHardWraps("双空格  \n继续") == "双空格继续")
    // Interior spaces are content and must survive.
    #expect(VeloraSpanAnchor.strippingHardWraps("How old\nare you") == "How oldare you")
    #expect(VeloraSpanAnchor.strippingHardWraps("a b c") == "a b c")
}

@Test func wrappedTerminalSpanLocatesAndDiffsAfterRewrap() {
    // The exact scenario that failed live in iTerm2 (2026-07-07): a dictated
    // sentence longer than one terminal row. The grid injects \n inside the
    // span, so an exact match on the raw value can never hit — capture must
    // fall back to wrap-stripped space, and the whole observation (baseline,
    // updated reads, diff) then runs there.
    let inserted = "所以现在终端这边也可以去记录这个商品文字的修改了呗。"
    let baselineGrid = "prompt> " + gridWrapped(inserted, width: 10)

    // Raw grid: exact match fails (this is what broke the live capture).
    #expect(baselineGrid.range(of: inserted) == nil)

    // Wrap-stripped: match succeeds — mirrors tryCapture's fallback.
    let baseline = VeloraSpanAnchor.strippingHardWraps(baselineGrid)
    let range = baseline.range(of: inserted, options: [.backwards])
    #expect(range != nil)
    guard let range else { return }
    let spanStart = baseline.distance(from: baseline.startIndex, to: range.lowerBound)

    // The user fixes the ASR near-homophone (商品 → 上屏); the grid re-wraps
    // at a different width, moving every break point.
    let edited = inserted.replacingOccurrences(of: "商品", with: "上屏")
    let updatedGrid = "prompt> " + gridWrapped(edited, width: 13)
    let updated = VeloraSpanAnchor.strippingHardWraps(updatedGrid)

    let extraction = VeloraSpanAnchor.extractSpan(
        baseline: baseline,
        spanStart: spanStart,
        spanLength: inserted.count,
        updated: updated
    )
    #expect(extraction?.span == edited)

    // And the diff classifies it as the hotword candidate it is.
    let analysis = VeloraEditAnalyzer.analyze(inserted: inserted, userFinal: edited, appliedEdits: [])
    let fix = analysis.blocks.first { $0.kind == .asrFix }
    #expect(fix?.before == "商品")
    #expect(fix?.after == "上屏")
}

@Test func wrappedSpanSurvivesPhantomNewlineFreeDiff() {
    // Even when nothing was edited, comparing stripped baseline against a
    // re-wrapped-then-stripped read must be a clean no-op — phantom newlines
    // must never surface as content edits.
    let inserted = "测试一段会被终端折行的比较长的中文句子内容。"
    let a = VeloraSpanAnchor.strippingHardWraps(gridWrapped(inserted, width: 7))
    let b = VeloraSpanAnchor.strippingHardWraps(gridWrapped(inserted, width: 11))
    #expect(a == b)
    #expect(a == inserted)
}

/// Renders text the way iTerm2's accessibility buffer does (probed live
/// 2026-07-07): every double-width CJK char is followed by a U+0000 filler
/// for its second cell, rows are hard-wrapped and may carry tail padding.
private func iTermGrid(_ text: String, width: Int) -> String {
    var cells = ""
    for ch in text {
        cells.append(ch)
        if ch.unicodeScalars.first.map({ $0.value > 0x2E7F }) == true {
            cells.append("\0")
        }
    }
    return gridWrapped(cells, width: width)
}

@Test func hardWrapStripRemovesITermDoubleWidthNULFillers() {
    let inserted = "正常听写不用特意配合"
    let grid = iTermGrid("提示> " + inserted, width: 9)
    // Raw and even whitespace-free matching fail on the NUL-riddled grid —
    // this is exactly why iTerm2 Chinese captures never armed.
    #expect(!grid.contains(inserted))
    // Wrap-strip now drops the fillers too, so the span matches again.
    let stripped = VeloraSpanAnchor.strippingHardWraps(grid)
    #expect(stripped.contains(inserted))
}

@Test func iTermNULGridSpanExtractsAndClassifiesAfterEdit() {
    // The live 2026-07-07 iTerm2 failure: a CJK sentence pasted into the
    // Claude Code input box, hand-fixed (near-homophone), then re-rendered
    // by the grid. 会画→会话 share pinyin (huìhuà) — a true asr_fix.
    let inserted = "新开的会画，看看这个问题还存不存在。"
    let baselineGrid = iTermGrid("> " + inserted, width: 11)
    let baseline = VeloraSpanAnchor.strippingHardWraps(baselineGrid)
    guard let range = baseline.range(of: inserted, options: [.backwards]) else {
        Issue.record("span must locate in stripped space")
        return
    }
    let spanStart = baseline.distance(from: baseline.startIndex, to: range.lowerBound)

    let edited = inserted.replacingOccurrences(of: "会画", with: "会话")
    let updated = VeloraSpanAnchor.strippingHardWraps(iTermGrid("> " + edited, width: 13))
    let extraction = VeloraSpanAnchor.extractSpan(
        baseline: baseline,
        spanStart: spanStart,
        spanLength: inserted.count,
        updated: updated
    )
    #expect(extraction?.span == edited)
    let analysis = VeloraEditAnalyzer.analyze(inserted: inserted, userFinal: edited, appliedEdits: [])
    // singleSpanDiff trims the shared 会 — the learned pair is 画→话.
    let fix = analysis.blocks.first { $0.kind == .asrFix }
    #expect(fix?.before == "画")
    #expect(fix?.after == "话")
}

// MARK: - Manual dictionary editing

@Test func manualTermIsActiveImmediatelyAndUpserts() async throws {
    let store = try temporaryPromotionStore()
    store.addManualTerm(term: "薇拉", replacement: "Velora")
    let ranked = try await store.rankHotwords(for: ContextSnapshot(appBundle: "t", mode: .input), limit: 5)
    #expect(ranked.contains { $0.term == "薇拉" })

    // Re-adding a disabled pair re-enables it instead of duplicating.
    store.setTermDisabled(term: "薇拉", replacement: "Velora", disabled: true)
    store.addManualTerm(term: "薇拉", replacement: "Velora")
    let terms = store.listTerms()
    #expect(terms.filter { $0.term == "薇拉" }.count == 1)
    #expect(terms.first { $0.term == "薇拉" }?.disabled == false)
    // Rejected inputs: empty side, identity pair.
    store.addManualTerm(term: " ", replacement: "x")
    store.addManualTerm(term: "same", replacement: "same")
    #expect(store.listTerms().count == 1)
}

@Test func updateTermMovesPairAndMergesOnCollision() throws {
    let store = try temporaryPromotionStore()
    store.recordAcceptedCorrection(term: "会画", replacement: "对话")
    store.updateTerm(term: "会画", replacement: "对话", newTerm: "会画", newReplacement: "会话")

    var terms = store.listTerms()
    #expect(terms.count == 1)
    #expect(terms.first?.replacement == "会话")
    // Editing is deliberate: the pair is active even if it was a candidate.
    #expect(terms.first?.promoted == true)

    // Collision merges: editing another pair onto 会画→会话 keeps one row.
    store.addManualTerm(term: "绘画", replacement: "绘图")
    store.updateTerm(term: "绘画", replacement: "绘图", newTerm: "会画", newReplacement: "会话")
    terms = store.listTerms()
    #expect(terms.count == 1)
    #expect(terms.first?.term == "会画")
}

// MARK: - Contextual-by-default correction channels

@Test func hotwordCorrectorOnlyAppliesHardTerms() {
    let contextual = HotwordCandidate(term: "拥护", replacement: "用户", score: 8, reasons: ["memory_term"])
    let hard = HotwordCandidate(
        term: "薇拉", replacement: "Velora", score: 8,
        reasons: ["memory_term", HotwordCorrector.hardReplaceReason]
    )
    let result = HotwordCorrector.correct(text: "大家都拥护薇拉这个方案", hotwords: [contextual, hard])
    // The legitimate word 拥护 must survive; only the explicit hard pair applies.
    #expect(result.correctedText == "大家都拥护Velora这个方案")
    #expect(result.edits.count == 1)
}

@Test func rankHotwordsMarksHardTermsAndUIRoundTripsApplyMode() async throws {
    let store = try temporaryPromotionStore()
    store.addManualTerm(term: "薇拉", replacement: "Velora")
    var ranked = try await store.rankHotwords(for: ContextSnapshot(appBundle: "t", mode: .input), limit: 5)
    // Default is contextual — no hard marker anywhere.
    #expect(ranked.allSatisfy { !$0.reasons.contains(HotwordCorrector.hardReplaceReason) })

    store.setTermApplyMode(term: "薇拉", replacement: "Velora", hard: true)
    ranked = try await store.rankHotwords(for: ContextSnapshot(appBundle: "t", mode: .input), limit: 5)
    #expect(ranked.first { $0.term == "薇拉" }?.reasons.contains(HotwordCorrector.hardReplaceReason) == true)
    #expect(store.listTerms().first { $0.term == "薇拉" }?.hardReplace == true)
}

@Test func correctionExamplesIngestRetrieveAndSelectByPinyin() throws {
    let store = try temporaryPromotionStore()
    let journal = URL(fileURLWithPath: NSTemporaryDirectory() + "velora-journal-ex-\(UUID().uuidString).jsonl")
    defer { try? FileManager.default.removeItem(at: journal) }
    let entry = #"{"kind":"post_insert_edit","session_id":"s1","lang":"zh","inserted_text":"新开的会画，看看这个问题还存不存在。","user_final_span":"新开的会话，看看这个问题还存不存在。","edit_blocks":[{"type":"asr_fix","before":"会画","after":"会话"}]}"#
    try (entry + "\n").write(to: journal, atomically: true, encoding: .utf8)
    _ = store.ingestCorrectionJournal(at: journal)

    let examples = store.recentCorrectionExamples(limit: 10)
    #expect(examples.count == 1)
    #expect(examples.first?.beforeSpan == "会画")
    #expect(examples.first?.pinyinKey == VeloraPinyin.latinized("会画"))

    // Selection: sound present in the utterance → included; absent → not.
    let hit = OllamaTextIntelligenceEngine.relevantCorrectionExamples(text: "再开一个会画确认一下", examples: examples)
    #expect(hit.contains("会话"))
    let miss = OllamaTextIntelligenceEngine.relevantCorrectionExamples(text: "明天上午发布版本", examples: examples)
    #expect(miss.isEmpty)
}

@Test func correctionExampleWindowKeepsSpanVisible() {
    let long = String(repeating: "前", count: 100) + "目标词" + String(repeating: "后", count: 100)
    let window = SQLiteMemoryStore.windowed(long, around: "目标词", limit: 60)
    #expect(window.count == 60)
    #expect(window.contains("目标词"))
}

/// Not a test of behavior: exports the SHIPPED system prompt into the eval
/// candidate files so pocs/tuning gates always run against the real thing.
/// Inert unless VELORA_EXPORT_PROMPTS=1.
@Test func exportPromptCandidatesWhenRequested() throws {
    guard ProcessInfo.processInfo.environment["VELORA_EXPORT_PROMPTS"] == "1" else {
        return
    }
    let dir = URL(fileURLWithPath: "/tmp/velora-eval")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let candidates: [[String: Any]] = [[
        "id": "shipped",
        "model": ProcessInfo.processInfo.environment["VELORA_OLLAMA_MODEL"] ?? "qwen3:8b",
        "system": OllamaPromptLibrary.inputSystem,
        "options": ["temperature": 0.1, "num_ctx": 4096, "repeat_penalty": 1.0, "num_predict": 400],
    ]]
    let data = try JSONSerialization.data(withJSONObject: candidates)
    for name in ["repair_candidates.json", "format_candidates.json", "homophone_candidates.json", "ambiguity_candidates.json"] {
        try data.write(to: dir.appendingPathComponent(name))
    }
}

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

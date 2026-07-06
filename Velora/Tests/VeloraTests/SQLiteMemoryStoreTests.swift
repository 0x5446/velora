import Foundation
import Testing
@testable import Velora

private func temporaryStore() throws -> SQLiteMemoryStore {
    let path = NSTemporaryDirectory() + "velora-memory-\(UUID().uuidString).sqlite"
    return try SQLiteMemoryStore(path: path)
}

@Test func memoryStoreSeedsOnceAndRanksWithContextBoosts() async throws {
    let store = try temporaryStore()
    store.seedIfEmpty(InMemoryHotwordStore.defaultTerms)
    store.seedIfEmpty(InMemoryHotwordStore.defaultTerms)
    #expect(store.termCount() == InMemoryHotwordStore.defaultTerms.count)

    let snapshot = ContextSnapshot(
        appBundle: "test",
        nearbyText: "we discussed prompt injection today",
        mode: .translate
    )
    let ranked = try await store.rankHotwords(for: snapshot, limit: 5)
    #expect(ranked.count == 5)
    // Nearby match (+4) must lift prompt injection to the top.
    #expect(ranked.first?.replacement == "prompt injection")
    #expect(ranked.first?.reasons.contains("nearby_text_match") == true)
    #expect(ranked.first?.reasons.contains("translation_mode_bonus") == true)
}

@Test func memoryStoreLearnsAcceptedCorrectionsAndDisablesAfterRejections() async throws {
    let store = try temporaryStore()
    store.recordAcceptedCorrection(term: "理点需求", replacement: "理清需求")
    store.recordAcceptedCorrection(term: "理点需求", replacement: "理清需求")
    #expect(store.termCount() == 1)

    let ranked = try await store.rankHotwords(
        for: ContextSnapshot(appBundle: "test", mode: .input),
        limit: 5
    )
    #expect(ranked.first?.reasons.contains("edit_count") == true)

    store.recordRejection(term: "理点需求", replacement: "理清需求")
    store.recordRejection(term: "理点需求", replacement: "理清需求")
    #expect(!store.isDisabled(term: "理点需求", replacement: "理清需求"))
    store.recordRejection(term: "理点需求", replacement: "理清需求")
    #expect(store.isDisabled(term: "理点需求", replacement: "理清需求"))
    #expect(store.termCount() == 0)
}

@Test func memoryStoreIngestsJournalIncrementally() throws {
    let store = try temporaryStore()
    let journal = URL(fileURLWithPath: NSTemporaryDirectory() + "velora-journal-\(UUID().uuidString).jsonl")
    defer { try? FileManager.default.removeItem(at: journal) }

    let entries = [
        // Single-span source edit → accepted pair 疑程→议程.
        #"{"kind":"translate_review_edit","source_before":"下午过一遍疑程","source_after":"下午过一遍议程"}"#,
        // Two separated edits collapse into one 7-char span → over the 6-char
        // mining cap → skipped, never guessed.
        #"{"kind":"translate_review_edit","source_before":"今天开会讨论议程安排","source_after":"明天开会讨论日程安排"}"#,
        // Retry event → negative feedback on the applied edit.
        #"{"kind":"retry_redictation","applied_edits":[{"from":"拥护","to":"用户","reason":"selected_hotword"}]}"#,
    ]
    try (entries.joined(separator: "\n") + "\n").write(to: journal, atomically: true, encoding: .utf8)

    let first = store.ingestCorrectionJournal(at: journal)
    #expect(first.acceptedPairs == 1)
    #expect(first.negativeSignals == 1)
    #expect(first.skippedEntries == 1)
    #expect(store.termCount() == 1)

    // Second pass over unchanged file: offset tracking prevents reprocessing.
    let second = store.ingestCorrectionJournal(at: journal)
    #expect(second == SQLiteMemoryStore.IngestSummary())

    // Appended entries are picked up from the stored offset.
    let handle = try FileHandle(forWritingTo: journal)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data((entries[0] + "\n").utf8))
    try handle.close()
    let third = store.ingestCorrectionJournal(at: journal)
    #expect(third.acceptedPairs == 1)
}

@Test func singleSpanDiffIsConservative() {
    let hit = SQLiteMemoryStore.singleSpanDiff(before: "接口超市了", after: "接口超时了")
    #expect(hit?.before == "市")
    #expect(hit?.after == "时")

    #expect(SQLiteMemoryStore.singleSpanDiff(before: "一样", after: "一样") == nil)
    // Whole-sentence rewrite exceeds the 12-char span cap → skipped.
    #expect(SQLiteMemoryStore.singleSpanDiff(
        before: "这句话被完完全全彻彻底底重写成另一句话了",
        after: "内容和原来那句几乎没有任何一个字相同啦"
    ) == nil)
}

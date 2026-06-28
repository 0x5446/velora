import Foundation
import Testing
@testable import Velora

@Test func keyboardBridgePayloadKeepsTranslationSourceAndTarget() async throws {
    let pipeline = PipelineOrchestrator(
        asrEngine: FakeASREngine(),
        contextProvider: StaticContextProvider(),
        memoryStore: InMemoryHotwordStore(),
        textEngine: RuleBasedTextIntelligenceEngine(),
        translationEngine: StubTranslationEngine(),
        insertionEngine: NoopInsertionEngine()
    )

    let result = try await pipeline.run(
        PipelineRunRequest(
            platform: .iOS,
            mode: .translate,
            sampleText: "明天上午十点我和 Alex 开会，帮我确认一下 agenda",
            sourceLanguage: "zh",
            targetLanguage: "en",
            insertPolicy: .bilingual
        )
    )

    let now = Date(timeIntervalSince1970: 100)
    let payload = KeyboardBridgePayload.from(result, ttl: 60, now: now)

    #expect(payload.isTranslation)
    #expect(payload.sourceText.contains("明天上午十点"))
    #expect(payload.correctedSourceText.contains("Alex"))
    #expect(payload.targetText?.contains("I have a meeting with Alex") == true)
    #expect(payload.displayText.contains("原文:"))
    #expect(payload.displayText.contains("译文:"))
    #expect(payload.insertText == "明天上午十点我和 Alex 开会，帮我确认一下 agenda。")
    #expect(!payload.isExpired(at: Date(timeIntervalSince1970: 159)))
    #expect(payload.isExpired(at: Date(timeIntervalSince1970: 160)))
}

@Test func keyboardBridgePayloadForDictateUsesFinalTextOnly() async throws {
    let pipeline = PipelineOrchestrator(
        asrEngine: FakeASREngine(),
        contextProvider: StaticContextProvider(),
        memoryStore: InMemoryHotwordStore(),
        textEngine: RuleBasedTextIntelligenceEngine(),
        translationEngine: StubTranslationEngine(),
        insertionEngine: NoopInsertionEngine()
    )

    let result = try await pipeline.run(
        PipelineRunRequest(
            platform: .iOS,
            mode: .dictate,
            sampleText: "The biggest risk is prom injection",
            sourceLanguage: "en"
        )
    )

    let payload = KeyboardBridgePayload.from(result)

    #expect(!payload.isTranslation)
    #expect(payload.targetText == nil)
    #expect(payload.insertText.contains("prompt injection"))
    #expect(payload.insertPolicy == .targetOnly)
}

@Test func keyboardBridgeStoreRoundTripsLatestPayload() async throws {
    let suiteName = "app.velora.tests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defaults.removePersistentDomain(forName: suiteName)
    let store = KeyboardBridgeStore(userDefaults: defaults)
    let now = Date(timeIntervalSince1970: 1_000)
    let payload = KeyboardBridgePayload(
        createdAt: now,
        expiresAt: now.addingTimeInterval(60),
        mode: .translate,
        sourceLanguage: "zh",
        targetLanguage: "en",
        sourceText: "你好",
        correctedSourceText: "你好。",
        targetText: "Hello.",
        displayText: "原文:\n你好。\n译文:\nHello.",
        insertText: "原文:\n你好。\n译文:\nHello.",
        insertPolicy: .bilingual
    )

    try store.save(payload)
    let loaded = try store.loadLatestPayload(now: now.addingTimeInterval(1))

    #expect(loaded == payload)

    store.clear()
    #expect(try store.loadLatestPayload(now: now.addingTimeInterval(1)) == nil)
    defaults.removePersistentDomain(forName: suiteName)
}

@Test func keyboardBridgeStoreDropsExpiredPayload() throws {
    let suiteName = "app.velora.tests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defaults.removePersistentDomain(forName: suiteName)
    let store = KeyboardBridgeStore(userDefaults: defaults)
    let now = Date(timeIntervalSince1970: 1_000)
    let payload = KeyboardBridgePayload(
        createdAt: now,
        expiresAt: now.addingTimeInterval(2),
        mode: .dictate,
        sourceLanguage: "en",
        sourceText: "hello",
        correctedSourceText: "hello.",
        displayText: "hello.",
        insertText: "hello.",
        insertPolicy: .targetOnly
    )

    try store.save(payload)

    #expect(try store.loadLatestPayload(now: now.addingTimeInterval(3)) == nil)
    #expect(defaults.data(forKey: KeyboardBridgeStore.latestPayloadKey) == nil)
    defaults.removePersistentDomain(forName: suiteName)
}

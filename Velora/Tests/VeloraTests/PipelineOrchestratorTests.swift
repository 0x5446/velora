import Foundation
import Testing
@testable import Velora

@Test func translatePipelineDisplaysBilingualReviewButDefaultsToChineseInsertText() async throws {
    let pipeline = PipelineOrchestrator.testPipeline()

    let result = try await pipeline.run(
        PipelineRunRequest(
            platform: .macOS,
            mode: .translate,
            sampleText: "明天上午十点我和 Alex 开会，帮我确认一下 agenda",
            sourceLanguage: "zh",
            targetLanguage: "en",
            insertPolicy: .bilingual
        )
    )

    #expect(result.finalText == "明天上午十点我和 Alex 开会，帮我确认一下 agenda。")
    #expect(result.translation?.displayText.contains("原文:") == true)
    #expect(result.translation?.displayText.contains("译文:") == true)
    #expect(result.finalText.contains("明天上午十点"))
    #expect(result.translation?.targetText.contains("I have a meeting with Alex") == true)
    #expect(result.translation?.glossaryHits.contains("Alex") == true)
    #expect(result.trace.stages.map(\.name).contains("asr_finalize"))
    #expect(result.trace.stages.map(\.name).contains("translation_reconcile"))
    #expect(result.trace.releaseToInsertMS >= 0)
}

@Test func hotwordCorrectionRunsBeforeTranslation() async throws {
    let pipeline = PipelineOrchestrator.testPipeline()

    let result = try await pipeline.run(
        PipelineRunRequest(
            platform: .macOS,
            mode: .translate,
            sampleText: "The biggest risk is prom injection in velora when we keep long term context",
            sourceLanguage: "en",
            targetLanguage: "zh",
            insertPolicy: .bilingual
        )
    )

    #expect(result.correction.correctedText.contains("prompt injection"))
    #expect(result.correction.correctedText.contains("Velora"))
    #expect(result.correction.edits.count == 2)
    #expect(result.finalText.contains("提示注入"))
    #expect(result.translation?.displayText.contains("原文:") == true)
    #expect(result.translation?.displayText.contains("译文:") == true)
}

@Test func inputProductHotwordsCorrectReviewFlowTermsBeforeTranslation() async throws {
    let pipeline = PipelineOrchestrator.testPipeline()

    let result = try await pipeline.run(
        PipelineRunRequest(
            platform: .macOS,
            mode: .translate,
            sampleText: "展示给拥护确认之后再上评，终于门对照就是这个价值",
            sourceLanguage: "zh",
            targetLanguage: "en",
            insertPolicy: .bilingual
        )
    )

    #expect(result.correction.correctedText.contains("用户"))
    #expect(result.correction.correctedText.contains("上屏"))
    #expect(result.correction.correctedText.contains("中英文对照"))
    #expect(!result.correction.correctedText.contains("拥护"))
    #expect(!result.correction.correctedText.contains("上评"))
}

@Test func translatePipelineCanDeferInsertionForUserReview() async throws {
    let pipeline = PipelineOrchestrator.testPipeline()

    let result = try await pipeline.run(
        PipelineRunRequest(
            platform: .macOS,
            mode: .translate,
            sampleText: "先展示原文和译文，用户确认以后再上屏",
            sourceLanguage: "zh",
            targetLanguage: "en",
            insertPolicy: .bilingual,
            insertionStrategy: .none
        )
    )

    #expect(result.insertion == nil)
    #expect(result.finalText == "先展示原文和译文，用户确认以后再上屏。")
    #expect(result.translation?.displayText.contains("原文:") == true)
    #expect(result.translation?.displayText.contains("译文:") == true)
}

@Test func preferredOutputLanguageCanChooseEnglishInsertText() async throws {
    let pipeline = PipelineOrchestrator.testPipeline()

    let result = try await pipeline.run(
        PipelineRunRequest(
            platform: .macOS,
            mode: .translate,
            sampleText: "翻译模式要同时上屏原文和译文",
            sourceLanguage: "zh",
            targetLanguage: "en",
            insertPolicy: .targetOnly,
            preferredInsertLanguage: "en"
        )
    )

    #expect(result.finalText == "Translation mode should insert both the source text and the translated text.")
    #expect(result.translation?.displayText.contains("原文:") == true)
    #expect(result.translation?.displayText.contains("译文:") == true)
}

@Test func englishInputWithChineseEnglishPairAutoReversesToChinese() async throws {
    let pipeline = PipelineOrchestrator.testPipeline()

    let result = try await pipeline.run(
        PipelineRunRequest(
            platform: .macOS,
            mode: .translate,
            sampleText: "The biggest risk is prompt injection in Velora when we keep long term context",
            sourceLanguage: "zh",
            targetLanguage: "en",
            insertPolicy: .bilingual,
            preferredInsertLanguage: "zh"
        )
    )

    #expect(result.translation?.mode.sourceLanguage == "en")
    #expect(result.translation?.mode.targetLanguage == "zh")
    #expect(result.finalText.contains("提示注入"))
    #expect(result.translation?.displayText.contains("原文:") == true)
    #expect(result.translation?.displayText.contains("译文:") == true)
}

@Test func polishPipelineReturnsPolishedTextWithoutTranslation() async throws {
    let pipeline = PipelineOrchestrator.testPipeline()

    let result = try await pipeline.run(
        PipelineRunRequest(
            platform: .macOS,
            mode: .polish,
            sampleText: "  please   confirm the agenda  ",
            sourceLanguage: "en"
        )
    )

    #expect(result.finalText == "please confirm the agenda。")
    #expect(result.polish != nil)
    #expect(result.translation == nil)
}

@Test func pipelineAcceptsAudioPathWithoutSampleText() async throws {
    let pipeline = PipelineOrchestrator.testPipeline()

    let result = try await pipeline.run(
        PipelineRunRequest(
            platform: .macOS,
            mode: .dictate,
            sampleText: "",
            audioPath: "/tmp/velora-test.caf",
            sourceLanguage: "en"
        )
    )

    #expect(result.asr.text.contains("velora-test.caf"))
    #expect(result.finalText.lowercased().contains("velora-test.caf"))
}

@Test func pipelineUsesConfiguredInsertionEngine() async throws {
    let pipeline = PipelineOrchestrator(
        asrEngine: FakeASREngine(),
        contextProvider: StaticContextProvider(),
        memoryStore: InMemoryHotwordStore(),
        textEngine: RuleBasedTextIntelligenceEngine(),
        translationEngine: StubTranslationEngine(),
        insertionEngine: RecordingInsertionEngine()
    )

    let result = try await pipeline.run(
        PipelineRunRequest(
            platform: .macOS,
            mode: .dictate,
            sampleText: "please confirm the agenda",
            sourceLanguage: "en",
            insertionStrategy: .pasteboard
        )
    )

    #expect(result.insertion?.strategy == .pasteboard)
    #expect(result.insertion?.inserted == true)
    #expect(result.insertion?.fallbackText == nil)
}

#if canImport(Speech)
@Test func appleSpeechLocaleDefaultsPreferConcreteLocales() {
    #expect(AppleSpeechASREngine.defaultLocaleIdentifier(for: "zh") == "zh-CN")
    #expect(AppleSpeechASREngine.defaultLocaleIdentifier(for: "en") == "en-US")
    #expect(AppleSpeechASREngine.defaultLocaleIdentifier(for: "ja") == "ja-JP")
}

@Test func appleSpeechMapsDictationUnavailableError() {
    #expect(
        AppleSpeechASREngine.recognitionFailureReason(
            domain: "kLSRErrorDomain",
            code: 201
        ) == "apple_speech_disabled_siri_dictation"
    )
}
#endif

@Test func localErrorPresenterTurnsModelFailuresIntoUserFacingText() {
    #expect(
        VeloraErrorPresenter.message(
            for: PipelineError.asrUnavailable("whisper_model_missing:/tmp/nope.bin")
        ).contains("whisper.cpp 模型")
    )
    #expect(
        VeloraErrorPresenter.message(
            for: PipelineError.localModelUnavailable("ollama_unavailable:connection")
        ).contains("Ollama")
    )
}

@Test func ollamaTextCleanerRemovesThinkingAndLabels() {
    let cleaned = OllamaTextIntelligenceEngine.cleanModelText(
        "<think>hidden</think>\n最终文本：明天上午十点开会。"
    )

    #expect(cleaned == "明天上午十点开会。")
}

@Test func ollamaTranslationDetectsWrongOutputLanguageForCommonPairs() {
    #expect(
        OllamaTranslationEngine.translationLooksLikeSourceLanguage(
            "Please confirm the agenda.",
            sourceLanguage: "en",
            targetLanguage: "zh"
        )
    )
    #expect(
        !OllamaTranslationEngine.translationLooksLikeSourceLanguage(
            "请确认议程。",
            sourceLanguage: "en",
            targetLanguage: "zh"
        )
    )
}

#if os(macOS)
@Test func whisperConfigurationIgnoresClearlyIncompleteModelFiles() throws {
    let temp = FileManager.default.temporaryDirectory
        .appendingPathComponent("velora-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temp) }

    let broken = temp.appendingPathComponent("broken.bin")
    let usable = temp.appendingPathComponent("usable.bin")
    FileManager.default.createFile(atPath: broken.path, contents: Data(repeating: 0, count: 8))
    FileManager.default.createFile(atPath: usable.path, contents: Data(repeating: 0, count: 32))

    let config = WhisperCLIConfiguration(
        modelCandidates: [
            WhisperModelCandidate(path: broken.path, minimumBytes: 16),
            WhisperModelCandidate(path: usable.path, minimumBytes: 16),
        ]
    )

    #expect(try config.resolvedModelPath() == usable.path)
}

@Test func whisperConfigurationBuildsDeduplicatedInitialPrompt() {
    let prompt = WhisperCLIConfiguration.default.initialPrompt(
        from: ["Alex", "agenda", "alex", " Velora ", ""]
    )

    #expect(prompt == "Alex, agenda, Velora")
}

@Test func whisperModelModesPreferExpectedPrimaryModels() {
    let fast = Array<WhisperModelCandidate>.candidates(for: .fast)
    let accurate = Array<WhisperModelCandidate>.candidates(for: .accurate)
    let fallback = Array<WhisperModelCandidate>.candidates(for: .fallback)

    #expect(URL(fileURLWithPath: fast[0].path).lastPathComponent == "ggml-base.bin")
    #expect(URL(fileURLWithPath: accurate[0].path).lastPathComponent == "ggml-large-v3-turbo-q5_0.bin")
    #expect(URL(fileURLWithPath: fallback[0].path).lastPathComponent == "ggml-tiny.bin")
}

@Test func whisperModeCanBeReadFromEnvironment() {
    #expect(WhisperModelMode.fromEnvironment(["VELORA_WHISPER_MODE": "accurate"]) == .accurate)
    #expect(WhisperModelMode.fromEnvironment(["VELORA_ASR_MODE": "fallback"]) == .fallback)
    #expect(WhisperModelMode.fromEnvironment(["VELORA_WHISPER_MODE": "unknown"]) == .fast)
}
#endif

extension PipelineOrchestrator {
    fileprivate static func testPipeline() -> PipelineOrchestrator {
        PipelineOrchestrator(
            asrEngine: FakeASREngine(),
            contextProvider: StaticContextProvider(),
            memoryStore: InMemoryHotwordStore(),
            textEngine: RuleBasedTextIntelligenceEngine(),
            translationEngine: StubTranslationEngine(),
            insertionEngine: NoopInsertionEngine()
        )
    }
}

private struct RecordingInsertionEngine: InsertionEngine {
    func insert(_ request: InsertionRequest) async throws -> InsertionResult {
        InsertionResult(
            strategy: request.strategy,
            inserted: true,
            latencyMS: 7
        )
    }
}

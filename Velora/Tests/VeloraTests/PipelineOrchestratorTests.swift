import Foundation
import Testing
@testable import Velora

@Test func translatePipelineInsertsBilingualBlockByDefault() async throws {
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

    // Hard rule: inserted text is single-language (target). The bilingual
    // block exists only in displayText for the review overlay.
    #expect(result.finalText == result.translation?.targetText)
    #expect(result.finalText.contains("I have a meeting with Alex"))
    #expect(!result.finalText.contains("原文:"))
    #expect(result.translation?.displayText.contains("原文:") == true)
    #expect(result.translation?.displayText.contains("明天上午十点") == true)
    #expect(result.translation?.glossaryHits.contains("agenda") == true)
    #expect(result.trace.stages.map(\.name).contains("asr_finalize"))
    #expect(result.trace.stages.map(\.name).contains("compose_bilingual"))
    #expect(result.trace.stages.map(\.name).contains("translation_fallback"))
    #expect(result.trace.releaseToInsertMS >= 0)
}

@Test func composeEmittedTargetSkipsTranslationFallback() async throws {
    let pipeline = PipelineOrchestrator(
        asrEngine: FakeASREngine(),
        contextProvider: StaticContextProvider(),
        memoryStore: InMemoryHotwordStore(),
        textEngine: ScriptedComposeEngine(targetText: "Hello from compose."),
        translationEngine: FailingTranslationEngine(),
        insertionEngine: NoopInsertionEngine()
    )

    let result = try await pipeline.run(
        PipelineRunRequest(
            platform: .macOS,
            mode: .translate,
            sampleText: "你好，来自单次调用",
            sourceLanguage: "zh",
            targetLanguage: "en",
            insertPolicy: .bilingual
        )
    )

    #expect(!result.trace.stages.map(\.name).contains("translation_fallback"))
    #expect(result.translation?.targetText == "Hello from compose.")
    #expect(result.finalText.contains("Hello from compose."))
    #expect(!result.reviewRequired)
}

@Test func translationFallbackFailureDegradesInsteadOfThrowing() async throws {
    let pipeline = PipelineOrchestrator(
        asrEngine: FakeASREngine(),
        contextProvider: StaticContextProvider(),
        memoryStore: InMemoryHotwordStore(),
        textEngine: RuleBasedTextIntelligenceEngine(),
        translationEngine: FailingTranslationEngine(),
        insertionEngine: NoopInsertionEngine()
    )

    let result = try await pipeline.run(
        PipelineRunRequest(
            platform: .macOS,
            mode: .translate,
            sampleText: "翻译引擎完全不可用时也不能丢掉规则结果",
            sourceLanguage: "zh",
            targetLanguage: "en",
            insertPolicy: .bilingual
        )
    )

    #expect(result.translation == nil)
    #expect(result.reviewRequired)
    #expect(result.finalText == "翻译引擎完全不可用时也不能丢掉规则结果。")
    #expect(result.compose.warnings.contains { $0.hasPrefix("translation_fallback_error") })
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
    #expect(result.finalText == result.translation?.targetText)
    #expect(result.translation?.displayText.contains("先展示原文和译文，用户确认以后再上屏。") == true)
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

@Test func inputModeAlwaysRunsTieredPolish() async throws {
    let pipeline = PipelineOrchestrator.testPipeline()

    let result = try await pipeline.run(
        PipelineRunRequest(
            platform: .macOS,
            mode: .input,
            sampleText: "  please   confirm the agenda  ",
            sourceLanguage: "en"
        )
    )

    #expect(result.finalText == "please confirm the agenda.")
    #expect(result.compose.engine == "rules")
    #expect(result.translation == nil)
    #expect(!result.reviewRequired)
    #expect(result.trace.stages.map(\.name).contains("compose"))
}

@Test func inputModeUsesChineseTerminalPunctuationForChineseText() async throws {
    let pipeline = PipelineOrchestrator.testPipeline()

    let result = try await pipeline.run(
        PipelineRunRequest(
            platform: .macOS,
            mode: .input,
            sampleText: "明天上午十点开会",
            sourceLanguage: "zh"
        )
    )

    #expect(result.finalText == "明天上午十点开会。")
}

@Test func pipelineAcceptsAudioPathWithoutSampleText() async throws {
    let pipeline = PipelineOrchestrator.testPipeline()

    let result = try await pipeline.run(
        PipelineRunRequest(
            platform: .macOS,
            mode: .input,
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
            mode: .input,
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

private struct ScriptedComposeEngine: TextIntelligenceEngine {
    var targetText: String?

    func compose(_ request: ComposeRequest) async throws -> ComposeResult {
        ComposeResult(
            polishedText: VeloraTextComposer.cleaned(request.text),
            targetText: request.mode == .translate ? targetText : nil,
            confidence: 0.9,
            reviewRequired: false,
            engine: "scripted"
        )
    }
}

private struct FailingTranslationEngine: TranslationEngine {
    func translate(_ request: LocalTranslationRequest) async throws -> LocalTranslationOutput {
        throw PipelineError.localModelUnavailable("test_translation_engine_down")
    }
}

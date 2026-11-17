import Foundation
import Testing
@testable import Velora

@Test func ollamaResponseMetricsStayNullWhenFieldsAreAbsentOrNegative() throws {
    let partial = try OllamaGenerateOutput.decode(
        responseJSON: Data(#"{"response":"明天开会","prompt_eval_count":11,"load_duration":1807954000}"#.utf8)
    )
    #expect(partial.promptTokens == 11)
    #expect(partial.loadDurationNS == 1_807_954_000)
    #expect(partial.loadDurationMS == 1_807)
    #expect(partial.evalCount == nil)
    #expect(partial.evalDurationNS == nil)

    let rejected = try OllamaGenerateOutput.decode(
        responseJSON: Data(#"{"response":"secret","eval_count":-1,"eval_duration":-5,"load_duration":-1}"#.utf8)
    )
    #expect(rejected.evalCount == nil)
    #expect(rejected.evalDurationNS == nil)
    #expect(rejected.loadDurationNS == nil)
    #expect(rejected.loadDurationMS == nil)

    let measurement = PipelineMeasurement.llmSample(
        output: partial,
        llmWaitMS: 12,
        llmWaitScope: "generate_only",
        guardMS: 1,
        engine: "ollama:qwen3:8b"
    )
    let encoded = String(decoding: try JSONEncoder().encode(measurement), as: UTF8.self)
    #expect(!encoded.contains("明天"))
    #expect(!encoded.contains("secret"))
    #expect(measurement.evalCount == nil)
    #expect(measurement.promptEvalCount == 11)
    #expect(measurement.loadDurationNS == 1_807_954_000)
}

@Test func physicalInsertStaysNullWithoutARealKeyAndInsert() {
    let staged = PipelineMeasurement(
        physicalKeyAndInsertObserved: true,
        hudWallMS: 4539,
        insertMS: 12,
        ruleFloorMS: 4,
        llmWaitMS: 3000,
        llmWaitScope: "generate_only"
    ).atPipelineBoundary(criticalStageSumMS: 4539, translationFallbackMS: nil)
    #expect(staged.observationSource == "cli")
    #expect(staged.physicalKeyAndInsertObserved == false)
    #expect(staged.hudWallMS == nil)
    #expect(staged.insertMS == nil)
    #expect(staged.criticalStageSumMS == 4539)
    #expect(staged.releaseToInsertMeaning == "critical_stage_sum")
    #expect(staged.excludeFromCriticalSum == true)
    #expect(staged.ruleFloorMS == 4)
    #expect(staged.llmWaitMS == 3000)

    let observed = staged.withObservedInsert(
        hudWallMS: 4800,
        insertMS: 20,
        observationSource: "real_key_release"
    )
    #expect(observed.observationSource == "real_key_release")
    #expect(observed.physicalKeyAndInsertObserved == true)
    #expect(observed.hudWallMS == 4800)
    #expect(observed.insertMS == 20)
    let replay = staged.withObservedInsert(
        hudWallMS: 4800,
        insertMS: 20,
        observationSource: "debug_file"
    )
    #expect(replay.observationSource == "debug_file")
    #expect(replay.physicalKeyAndInsertObserved == false)
    #expect(replay.hudWallMS == 4800)
    #expect(replay.insertMS == 20)
    let rejected = staged.withObservedInsert(
        hudWallMS: nil,
        insertMS: 20,
        observationSource: "real_key_release"
    )
    #expect(rejected.hudWallMS == nil)
    #expect(rejected.insertMS == nil)
    #expect(rejected.physicalKeyAndInsertObserved == false)
}

@Test func oldMeasurementJSONWithoutASourceCannotBecomeAPhysicalKey() throws {
    let json = """
    {"schema":"velora.pipeline_measurement.v1","physicalKeyAndInsertObserved":true,"hudWallMS":4800,"insertMS":20}
    """
    let decoded = try JSONDecoder().decode(PipelineMeasurement.self, from: Data(json.utf8)).sanitized()
    #expect(decoded.observationSource == nil)
    #expect(decoded.physicalKeyAndInsertObserved == false)
    #expect(decoded.hudWallMS == nil)
    #expect(decoded.insertMS == nil)
}

@Test func negativeMeasurementsBecomeNullInsteadOfZero() {
    let cleaned = PipelineMeasurement(
        criticalStageSumMS: -1,
        ruleFloorMS: -5,
        llmWaitMS: 0,
        llmWaitScope: "not_a_scope",
        guardMS: nil,
        promptEvalCount: -2,
        evalCount: 0,
        engine: "ollama:qwen3:8b /secret"
    ).sanitized()
    #expect(cleaned.criticalStageSumMS == nil)
    #expect(cleaned.ruleFloorMS == nil)
    #expect(cleaned.llmWaitMS == 0)
    #expect(cleaned.llmWaitScope == nil)
    #expect(cleaned.guardMS == nil)
    #expect(cleaned.promptEvalCount == nil)
    #expect(cleaned.evalCount == 0)
    #expect(cleaned.engine == nil)
}

@Test func composeResultWithoutMeasurementStillDecodes() throws {
    let original = ComposeResult(
        polishedText: "kept",
        confidence: 0.5,
        reviewRequired: false,
        engine: "rules"
    )
    let encoded = try JSONEncoder().encode(original)
    let object = try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
    #expect(object?["measurement"] == nil)
    let decoded = try JSONDecoder().decode(ComposeResult.self, from: encoded)
    #expect(decoded.measurement == nil)
    #expect(decoded.polishedText == "kept")
    #expect(decoded.engine == "rules")
}

@Test func rulePipelineDoesNotClaimAPhysicalInsert() async throws {
    let result = try await PipelineOrchestrator(
        asrEngine: FakeASREngine(),
        contextProvider: StaticContextProvider(),
        memoryStore: InMemoryHotwordStore(),
        textEngine: RuleBasedTextIntelligenceEngine(),
        translationEngine: StubTranslationEngine(),
        insertionEngine: NoopInsertionEngine()
    ).run(
        PipelineRunRequest(
            platform: .macOS,
            mode: .input,
            sampleText: "明天开会",
            sourceLanguage: "zh",
            insertionStrategy: .none
        )
    )
    let measurement = try #require(result.trace.measurement)
    #expect(measurement.physicalKeyAndInsertObserved == false)
    #expect(measurement.hudWallMS == nil)
    #expect(measurement.insertMS == nil)
    #expect(measurement.criticalStageSumMS == result.trace.releaseToInsertMS)
    #expect(measurement.excludeFromCriticalSum == true)
    #expect(measurement.translationFallbackMS == nil)
    #expect(measurement.ruleFloorScope == "compose_stage")
}

@Test func monotonicElapsedIsNonNegative() {
    let start = ContinuousClock.now
    let elapsed = MonotonicMilliseconds.since(start)
    #expect(elapsed != nil)
    #expect((elapsed ?? -1) >= 0)
}

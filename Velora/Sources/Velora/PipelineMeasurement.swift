import Foundation

/// Numeric measurements only. Durations that ran use ContinuousClock milliseconds.
/// A missing, cancelled, or failed interval stays nil. Nil is not stored as zero.
/// These parts sit inside stages that are already in `releaseToInsertMS`;
/// `excludeFromCriticalSum` tells a collector not to add them again.
public struct PipelineMeasurement: Sendable, Equatable {
    public static let schema = "velora.pipeline_measurement.v1"
    public static let durationUnit = "ms"
    public static let nanosecondUnit = "ns"
    public static let countUnit = "tokens"
    public static let clockName = "continuous"
    public static let criticalStageSumMeaning = "critical_stage_sum"

    public var schema: String
    public var durationUnit: String
    public var nanosecondUnit: String
    public var countUnit: String
    public var clock: String
    /// `releaseToInsertMS` is this sum. It is not a physical key or a paste.
    public var releaseToInsertMeaning: String
    public var excludeFromCriticalSum: Bool
    public var criticalStageSumMS: Int?
    /// `real_key_release` is a physical key. `debug_file` is a file replay. `cli` has neither.
    public var observationSource: String?
    /// True only for `real_key_release` when the insert attempt was also timed.
    /// A file-driven paste does not set this.
    public var physicalKeyAndInsertObserved: Bool
    public var hudWallMS: Int?
    public var insertMS: Int?
    public var ruleFloorMS: Int?
    public var ruleFloorScope: String?
    public var llmWaitMS: Int?
    public var llmWaitScope: String?
    public var guardMS: Int?
    public var translationFallbackMS: Int?
    public var promptEvalCount: Int?
    public var loadDurationNS: Int64?
    public var evalCount: Int?
    public var evalDurationNS: Int64?
    public var fallbackLLMWaitMS: Int?
    public var fallbackLLMWaitScope: String?
    public var fallbackGuardMS: Int?
    public var fallbackPromptEvalCount: Int?
    public var fallbackLoadDurationNS: Int64?
    public var fallbackEvalCount: Int?
    public var fallbackEvalDurationNS: Int64?
    public var engine: String?

    public init(
        schema: String = PipelineMeasurement.schema,
        durationUnit: String = PipelineMeasurement.durationUnit,
        nanosecondUnit: String = PipelineMeasurement.nanosecondUnit,
        countUnit: String = PipelineMeasurement.countUnit,
        clock: String = PipelineMeasurement.clockName,
        releaseToInsertMeaning: String = PipelineMeasurement.criticalStageSumMeaning,
        excludeFromCriticalSum: Bool = true,
        criticalStageSumMS: Int? = nil,
        observationSource: String? = nil,
        physicalKeyAndInsertObserved: Bool = false,
        hudWallMS: Int? = nil,
        insertMS: Int? = nil,
        ruleFloorMS: Int? = nil,
        ruleFloorScope: String? = nil,
        llmWaitMS: Int? = nil,
        llmWaitScope: String? = nil,
        guardMS: Int? = nil,
        translationFallbackMS: Int? = nil,
        promptEvalCount: Int? = nil,
        loadDurationNS: Int64? = nil,
        evalCount: Int? = nil,
        evalDurationNS: Int64? = nil,
        fallbackLLMWaitMS: Int? = nil,
        fallbackLLMWaitScope: String? = nil,
        fallbackGuardMS: Int? = nil,
        fallbackPromptEvalCount: Int? = nil,
        fallbackLoadDurationNS: Int64? = nil,
        fallbackEvalCount: Int? = nil,
        fallbackEvalDurationNS: Int64? = nil,
        engine: String? = nil
    ) {
        self.schema = schema
        self.durationUnit = durationUnit
        self.nanosecondUnit = nanosecondUnit
        self.countUnit = countUnit
        self.clock = clock
        self.releaseToInsertMeaning = releaseToInsertMeaning
        self.excludeFromCriticalSum = excludeFromCriticalSum
        self.criticalStageSumMS = criticalStageSumMS
        self.observationSource = observationSource
        self.physicalKeyAndInsertObserved = physicalKeyAndInsertObserved
        self.hudWallMS = hudWallMS
        self.insertMS = insertMS
        self.ruleFloorMS = ruleFloorMS
        self.ruleFloorScope = ruleFloorScope
        self.llmWaitMS = llmWaitMS
        self.llmWaitScope = llmWaitScope
        self.guardMS = guardMS
        self.translationFallbackMS = translationFallbackMS
        self.promptEvalCount = promptEvalCount
        self.loadDurationNS = loadDurationNS
        self.evalCount = evalCount
        self.evalDurationNS = evalDurationNS
        self.fallbackLLMWaitMS = fallbackLLMWaitMS
        self.fallbackLLMWaitScope = fallbackLLMWaitScope
        self.fallbackGuardMS = fallbackGuardMS
        self.fallbackPromptEvalCount = fallbackPromptEvalCount
        self.fallbackLoadDurationNS = fallbackLoadDurationNS
        self.fallbackEvalCount = fallbackEvalCount
        self.fallbackEvalDurationNS = fallbackEvalDurationNS
        self.engine = engine
    }

    public static func llmSample(
        output: OllamaGenerateOutput,
        llmWaitMS: Int?,
        llmWaitScope: String,
        guardMS: Int?,
        engine: String
    ) -> PipelineMeasurement {
        PipelineMeasurement(
            llmWaitMS: llmWaitMS,
            llmWaitScope: llmWaitScope,
            guardMS: guardMS,
            promptEvalCount: output.promptTokens,
            loadDurationNS: output.loadDurationNS,
            evalCount: output.evalCount,
            evalDurationNS: output.evalDurationNS,
            engine: engine
        ).sanitized()
    }

    public static func failureEnvelope(ruleFloorMS: Int?, llmWaitMS: Int?, engine: String) -> PipelineMeasurement {
        PipelineMeasurement(
            ruleFloorMS: ruleFloorMS,
            ruleFloorScope: ruleFloorMS == nil ? nil : "rule_engine_only",
            llmWaitMS: llmWaitMS,
            llmWaitScope: llmWaitMS == nil ? nil : "deadline_or_error_envelope",
            engine: engine
        ).sanitized()
    }

    /// Pipeline JSON is not a key release and not a GUI paste.
    public func atPipelineBoundary(criticalStageSumMS: Int, translationFallbackMS: Int?) -> PipelineMeasurement {
        var copy = self
        copy.criticalStageSumMS = criticalStageSumMS
        copy.translationFallbackMS = translationFallbackMS
        copy.observationSource = "cli"
        copy.physicalKeyAndInsertObserved = false
        copy.hudWallMS = nil
        copy.insertMS = nil
        copy.excludeFromCriticalSum = true
        copy.releaseToInsertMeaning = Self.criticalStageSumMeaning
        return copy.sanitized()
    }

    /// `debug_file` may keep HUD and insert times. It never counts as a physical key release.
    public func withObservedInsert(
        hudWallMS: Int?,
        insertMS: Int?,
        observationSource: String
    ) -> PipelineMeasurement {
        var copy = self
        copy.observationSource = observationSource
        copy.hudWallMS = hudWallMS
        copy.insertMS = insertMS
        copy.physicalKeyAndInsertObserved = observationSource == "real_key_release"
        return copy.sanitized()
    }

    public func adoptingFallback(_ fallback: PipelineMeasurement?) -> PipelineMeasurement {
        guard let fallback else {
            return self
        }
        var copy = self
        copy.fallbackLLMWaitMS = fallback.llmWaitMS
        copy.fallbackLLMWaitScope = fallback.llmWaitScope
        copy.fallbackGuardMS = fallback.guardMS
        copy.fallbackPromptEvalCount = fallback.promptEvalCount
        copy.fallbackLoadDurationNS = fallback.loadDurationNS
        copy.fallbackEvalCount = fallback.evalCount
        copy.fallbackEvalDurationNS = fallback.evalDurationNS
        return copy.sanitized()
    }

    public func sanitized() -> PipelineMeasurement {
        var copy = self
        copy.schema = Self.schema
        copy.durationUnit = Self.durationUnit
        copy.nanosecondUnit = Self.nanosecondUnit
        copy.countUnit = Self.countUnit
        copy.clock = Self.clockName
        copy.releaseToInsertMeaning = Self.criticalStageSumMeaning
        copy.excludeFromCriticalSum = true
        copy.criticalStageSumMS = Self.nonNegative(copy.criticalStageSumMS)
        copy.ruleFloorMS = Self.nonNegative(copy.ruleFloorMS)
        copy.llmWaitMS = Self.nonNegative(copy.llmWaitMS)
        copy.guardMS = Self.nonNegative(copy.guardMS)
        copy.translationFallbackMS = Self.nonNegative(copy.translationFallbackMS)
        copy.promptEvalCount = Self.nonNegative(copy.promptEvalCount)
        copy.loadDurationNS = Self.nonNegative(copy.loadDurationNS)
        copy.evalCount = Self.nonNegative(copy.evalCount)
        copy.evalDurationNS = Self.nonNegative(copy.evalDurationNS)
        copy.fallbackLLMWaitMS = Self.nonNegative(copy.fallbackLLMWaitMS)
        copy.fallbackGuardMS = Self.nonNegative(copy.fallbackGuardMS)
        copy.fallbackPromptEvalCount = Self.nonNegative(copy.fallbackPromptEvalCount)
        copy.fallbackLoadDurationNS = Self.nonNegative(copy.fallbackLoadDurationNS)
        copy.fallbackEvalCount = Self.nonNegative(copy.fallbackEvalCount)
        copy.fallbackEvalDurationNS = Self.nonNegative(copy.fallbackEvalDurationNS)
        copy.ruleFloorScope = Self.scope(copy.ruleFloorScope, allowed: ["rule_engine_only", "compose_stage"])
        copy.llmWaitScope = Self.scope(copy.llmWaitScope, allowed: ["generate_only", "deadline_or_error_envelope"])
        copy.fallbackLLMWaitScope = Self.scope(
            copy.fallbackLLMWaitScope,
            allowed: ["generate_only", "deadline_or_error_envelope"]
        )
        copy.engine = Self.engineToken(copy.engine)
        copy.observationSource = Self.scope(
            copy.observationSource,
            allowed: ["debug_file", "real_key_release", "cli"]
        )
        let guiReplay = copy.observationSource == "debug_file" || copy.observationSource == "real_key_release"
        if guiReplay,
           let wall = Self.nonNegative(copy.hudWallMS),
           let insert = Self.nonNegative(copy.insertMS) {
            copy.hudWallMS = wall
            copy.insertMS = insert
            copy.physicalKeyAndInsertObserved = copy.observationSource == "real_key_release"
        } else {
            copy.physicalKeyAndInsertObserved = false
            copy.hudWallMS = nil
            copy.insertMS = nil
        }
        return copy
    }

    private static func nonNegative(_ value: Int?) -> Int? {
        guard let value, value >= 0 else {
            return nil
        }
        return value
    }

    private static func nonNegative(_ value: Int64?) -> Int64? {
        guard let value, value >= 0 else {
            return nil
        }
        return value
    }

    private static func scope(_ value: String?, allowed: Set<String>) -> String? {
        guard let value, allowed.contains(value) else {
            return nil
        }
        return value
    }

    private static func engineToken(_ value: String?) -> String? {
        guard let value, !value.isEmpty, value.count <= 80,
              !value.contains("/"), !value.contains("\\"), !value.contains("\n"), !value.contains(" ")
        else {
            return nil
        }
        return value
    }
}

extension PipelineMeasurement: Codable {
    private enum CodingKeys: String, CodingKey {
        case schema
        case durationUnit
        case nanosecondUnit
        case countUnit
        case clock
        case releaseToInsertMeaning
        case excludeFromCriticalSum
        case criticalStageSumMS
        case observationSource
        case physicalKeyAndInsertObserved
        case hudWallMS
        case insertMS
        case ruleFloorMS
        case ruleFloorScope
        case llmWaitMS
        case llmWaitScope
        case guardMS
        case translationFallbackMS
        case promptEvalCount
        case loadDurationNS
        case evalCount
        case evalDurationNS
        case fallbackLLMWaitMS
        case fallbackLLMWaitScope
        case fallbackGuardMS
        case fallbackPromptEvalCount
        case fallbackLoadDurationNS
        case fallbackEvalCount
        case fallbackEvalDurationNS
        case engine
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schema = try container.decodeIfPresent(String.self, forKey: .schema) ?? Self.schema
        durationUnit = try container.decodeIfPresent(String.self, forKey: .durationUnit) ?? Self.durationUnit
        nanosecondUnit = try container.decodeIfPresent(String.self, forKey: .nanosecondUnit) ?? Self.nanosecondUnit
        countUnit = try container.decodeIfPresent(String.self, forKey: .countUnit) ?? Self.countUnit
        clock = try container.decodeIfPresent(String.self, forKey: .clock) ?? Self.clockName
        releaseToInsertMeaning = try container.decodeIfPresent(String.self, forKey: .releaseToInsertMeaning) ?? Self.criticalStageSumMeaning
        excludeFromCriticalSum = try container.decodeIfPresent(Bool.self, forKey: .excludeFromCriticalSum) ?? true
        criticalStageSumMS = try container.decodeIfPresent(Int.self, forKey: .criticalStageSumMS)
        observationSource = try container.decodeIfPresent(String.self, forKey: .observationSource)
        physicalKeyAndInsertObserved = try container.decodeIfPresent(Bool.self, forKey: .physicalKeyAndInsertObserved) ?? false
        hudWallMS = try container.decodeIfPresent(Int.self, forKey: .hudWallMS)
        insertMS = try container.decodeIfPresent(Int.self, forKey: .insertMS)
        ruleFloorMS = try container.decodeIfPresent(Int.self, forKey: .ruleFloorMS)
        ruleFloorScope = try container.decodeIfPresent(String.self, forKey: .ruleFloorScope)
        llmWaitMS = try container.decodeIfPresent(Int.self, forKey: .llmWaitMS)
        llmWaitScope = try container.decodeIfPresent(String.self, forKey: .llmWaitScope)
        guardMS = try container.decodeIfPresent(Int.self, forKey: .guardMS)
        translationFallbackMS = try container.decodeIfPresent(Int.self, forKey: .translationFallbackMS)
        promptEvalCount = try container.decodeIfPresent(Int.self, forKey: .promptEvalCount)
        loadDurationNS = try container.decodeIfPresent(Int64.self, forKey: .loadDurationNS)
        evalCount = try container.decodeIfPresent(Int.self, forKey: .evalCount)
        evalDurationNS = try container.decodeIfPresent(Int64.self, forKey: .evalDurationNS)
        fallbackLLMWaitMS = try container.decodeIfPresent(Int.self, forKey: .fallbackLLMWaitMS)
        fallbackLLMWaitScope = try container.decodeIfPresent(String.self, forKey: .fallbackLLMWaitScope)
        fallbackGuardMS = try container.decodeIfPresent(Int.self, forKey: .fallbackGuardMS)
        fallbackPromptEvalCount = try container.decodeIfPresent(Int.self, forKey: .fallbackPromptEvalCount)
        fallbackLoadDurationNS = try container.decodeIfPresent(Int64.self, forKey: .fallbackLoadDurationNS)
        fallbackEvalCount = try container.decodeIfPresent(Int.self, forKey: .fallbackEvalCount)
        fallbackEvalDurationNS = try container.decodeIfPresent(Int64.self, forKey: .fallbackEvalDurationNS)
        engine = try container.decodeIfPresent(String.self, forKey: .engine)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schema, forKey: .schema)
        try container.encode(durationUnit, forKey: .durationUnit)
        try container.encode(nanosecondUnit, forKey: .nanosecondUnit)
        try container.encode(countUnit, forKey: .countUnit)
        try container.encode(clock, forKey: .clock)
        try container.encode(releaseToInsertMeaning, forKey: .releaseToInsertMeaning)
        try container.encode(excludeFromCriticalSum, forKey: .excludeFromCriticalSum)
        try container.encodeIfPresent(criticalStageSumMS, forKey: .criticalStageSumMS)
        try container.encodeIfPresent(observationSource, forKey: .observationSource)
        try container.encode(physicalKeyAndInsertObserved, forKey: .physicalKeyAndInsertObserved)
        try container.encodeIfPresent(hudWallMS, forKey: .hudWallMS)
        try container.encodeIfPresent(insertMS, forKey: .insertMS)
        try container.encodeIfPresent(ruleFloorMS, forKey: .ruleFloorMS)
        try container.encodeIfPresent(ruleFloorScope, forKey: .ruleFloorScope)
        try container.encodeIfPresent(llmWaitMS, forKey: .llmWaitMS)
        try container.encodeIfPresent(llmWaitScope, forKey: .llmWaitScope)
        try container.encodeIfPresent(guardMS, forKey: .guardMS)
        try container.encodeIfPresent(translationFallbackMS, forKey: .translationFallbackMS)
        try container.encodeIfPresent(promptEvalCount, forKey: .promptEvalCount)
        try container.encodeIfPresent(loadDurationNS, forKey: .loadDurationNS)
        try container.encodeIfPresent(evalCount, forKey: .evalCount)
        try container.encodeIfPresent(evalDurationNS, forKey: .evalDurationNS)
        try container.encodeIfPresent(fallbackLLMWaitMS, forKey: .fallbackLLMWaitMS)
        try container.encodeIfPresent(fallbackLLMWaitScope, forKey: .fallbackLLMWaitScope)
        try container.encodeIfPresent(fallbackGuardMS, forKey: .fallbackGuardMS)
        try container.encodeIfPresent(fallbackPromptEvalCount, forKey: .fallbackPromptEvalCount)
        try container.encodeIfPresent(fallbackLoadDurationNS, forKey: .fallbackLoadDurationNS)
        try container.encodeIfPresent(fallbackEvalCount, forKey: .fallbackEvalCount)
        try container.encodeIfPresent(fallbackEvalDurationNS, forKey: .fallbackEvalDurationNS)
        try container.encodeIfPresent(engine, forKey: .engine)
    }
}

final class LLMMeasurementHandoff: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: PipelineMeasurement?

    func store(_ measurement: PipelineMeasurement) {
        lock.lock()
        stored = measurement
        lock.unlock()
    }

    /// Safe after the producing task has thrown. Do not call this when a deadline cancelled that task.
    func take() -> PipelineMeasurement? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}

enum MonotonicMilliseconds {
    static func since(_ start: ContinuousClock.Instant, clock: ContinuousClock = ContinuousClock()) -> Int? {
        let duration = start.duration(to: clock.now)
        let parts = duration.components
        let milliseconds = parts.seconds * 1_000 + parts.attoseconds / 1_000_000_000_000_000
        guard milliseconds >= 0, milliseconds <= Int64(Int.max) else {
            return nil
        }
        return Int(milliseconds)
    }
}

extension ComposeResult: Codable {
    private enum CodingKeys: String, CodingKey {
        case polishedText
        case targetText
        case edits
        case glossaryHits
        case warnings
        case confidence
        case reviewRequired
        case engine
        case measurement
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        polishedText = try container.decode(String.self, forKey: .polishedText)
        targetText = try container.decodeIfPresent(String.self, forKey: .targetText)
        edits = try container.decodeIfPresent([TextEdit].self, forKey: .edits) ?? []
        glossaryHits = try container.decodeIfPresent([String].self, forKey: .glossaryHits) ?? []
        warnings = try container.decodeIfPresent([String].self, forKey: .warnings) ?? []
        confidence = try container.decode(Double.self, forKey: .confidence)
        reviewRequired = try container.decode(Bool.self, forKey: .reviewRequired)
        engine = try container.decode(String.self, forKey: .engine)
        measurement = try container.decodeIfPresent(PipelineMeasurement.self, forKey: .measurement)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(polishedText, forKey: .polishedText)
        try container.encodeIfPresent(targetText, forKey: .targetText)
        try container.encode(edits, forKey: .edits)
        try container.encode(glossaryHits, forKey: .glossaryHits)
        try container.encode(warnings, forKey: .warnings)
        try container.encode(confidence, forKey: .confidence)
        try container.encode(reviewRequired, forKey: .reviewRequired)
        try container.encode(engine, forKey: .engine)
        try container.encodeIfPresent(measurement, forKey: .measurement)
    }
}

extension PipelineTrace: Codable {
    private enum CodingKeys: String, CodingKey {
        case stages
        case measurement
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        stages = try container.decodeIfPresent([LatencyStage].self, forKey: .stages) ?? []
        measurement = try container.decodeIfPresent(PipelineMeasurement.self, forKey: .measurement)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(stages, forKey: .stages)
        try container.encodeIfPresent(measurement, forKey: .measurement)
    }
}

extension LocalTranslationOutput: Codable {
    private enum CodingKeys: String, CodingKey {
        case targetText
        case glossaryHits
        case warnings
        case confidence
        case reviewRequired
        case measurement
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        targetText = try container.decode(String.self, forKey: .targetText)
        glossaryHits = try container.decodeIfPresent([String].self, forKey: .glossaryHits) ?? []
        warnings = try container.decodeIfPresent([String].self, forKey: .warnings) ?? []
        confidence = try container.decode(Double.self, forKey: .confidence)
        reviewRequired = try container.decode(Bool.self, forKey: .reviewRequired)
        measurement = try container.decodeIfPresent(PipelineMeasurement.self, forKey: .measurement)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(targetText, forKey: .targetText)
        try container.encode(glossaryHits, forKey: .glossaryHits)
        try container.encode(warnings, forKey: .warnings)
        try container.encode(confidence, forKey: .confidence)
        try container.encode(reviewRequired, forKey: .reviewRequired)
        try container.encodeIfPresent(measurement, forKey: .measurement)
    }
}

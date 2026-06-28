import Foundation

public enum PipelineError: Error, Sendable, Equatable {
    case emptyInput
    case unsupportedMode(String)
    case asrUnavailable(String)
    case localModelUnavailable(String)
}

public enum InsertionStrategy: String, Codable, Sendable, Equatable {
    case none
    case inputMethod
    case accessibility
    case pasteboard
    case keyboardBridge
}

public struct DictationSession: Codable, Sendable, Equatable {
    public var id: UUID
    public var createdAt: Date
    public var platform: VeloraPlatform
    public var mode: DictationMode
    public var sourceLanguage: String
    public var targetLanguage: String?
    public var networkAllowed: Bool

    public init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        platform: VeloraPlatform,
        mode: DictationMode,
        sourceLanguage: String,
        targetLanguage: String? = nil,
        networkAllowed: Bool = false
    ) {
        self.id = id
        self.createdAt = createdAt
        self.platform = platform
        self.mode = mode
        self.sourceLanguage = sourceLanguage
        self.targetLanguage = targetLanguage
        self.networkAllowed = networkAllowed
    }
}

public struct ContextSnapshot: Codable, Sendable, Equatable {
    public var appBundle: String
    public var windowTitle: String
    public var selectedText: String
    public var nearbyText: String
    public var mode: DictationMode
    public var languagePair: String?
    public var privacyScope: String

    public init(
        appBundle: String,
        windowTitle: String = "",
        selectedText: String = "",
        nearbyText: String = "",
        mode: DictationMode,
        languagePair: String? = nil,
        privacyScope: String = "ephemeral"
    ) {
        self.appBundle = appBundle
        self.windowTitle = windowTitle
        self.selectedText = selectedText
        self.nearbyText = nearbyText
        self.mode = mode
        self.languagePair = languagePair
        self.privacyScope = privacyScope
    }
}

public struct HotwordCandidate: Codable, Sendable, Equatable {
    public var term: String
    public var replacement: String
    public var score: Double
    public var reasons: [String]

    public init(
        term: String,
        replacement: String,
        score: Double,
        reasons: [String]
    ) {
        self.term = term
        self.replacement = replacement
        self.score = score
        self.reasons = reasons
    }
}

public struct ASRRequest: Codable, Sendable, Equatable {
    public var audioPath: String?
    public var sampleText: String?
    public var sourceLanguage: String
    public var contextualPhrases: [String]
    public var deadlineMS: Int

    public init(
        audioPath: String? = nil,
        sampleText: String? = nil,
        sourceLanguage: String,
        contextualPhrases: [String] = [],
        deadlineMS: Int = 300
    ) {
        self.audioPath = audioPath
        self.sampleText = sampleText
        self.sourceLanguage = sourceLanguage
        self.contextualPhrases = contextualPhrases
        self.deadlineMS = deadlineMS
    }
}

public struct ASRSegment: Codable, Sendable, Equatable {
    public var text: String
    public var startMS: Int
    public var endMS: Int
    public var confidence: Double

    public init(text: String, startMS: Int, endMS: Int, confidence: Double) {
        self.text = text
        self.startMS = startMS
        self.endMS = endMS
        self.confidence = confidence
    }
}

public struct ASRResult: Codable, Sendable, Equatable {
    public var text: String
    public var language: String
    public var confidence: Double
    public var segments: [ASRSegment]
    public var alternatives: [String]
    public var engine: String
    public var modelVersion: String

    public init(
        text: String,
        language: String,
        confidence: Double,
        segments: [ASRSegment],
        alternatives: [String] = [],
        engine: String,
        modelVersion: String
    ) {
        self.text = text
        self.language = language
        self.confidence = confidence
        self.segments = segments
        self.alternatives = alternatives
        self.engine = engine
        self.modelVersion = modelVersion
    }
}

public struct TextEdit: Codable, Sendable, Equatable {
    public var from: String
    public var to: String
    public var reason: String
    public var confidence: Double

    public init(from: String, to: String, reason: String, confidence: Double) {
        self.from = from
        self.to = to
        self.reason = reason
        self.confidence = confidence
    }
}

public struct CorrectionRequest: Codable, Sendable, Equatable {
    public var text: String
    public var context: ContextSnapshot
    public var hotwords: [HotwordCandidate]
    public var deadlineMS: Int

    public init(text: String, context: ContextSnapshot, hotwords: [HotwordCandidate], deadlineMS: Int = 100) {
        self.text = text
        self.context = context
        self.hotwords = hotwords
        self.deadlineMS = deadlineMS
    }
}

public struct CorrectionResult: Codable, Sendable, Equatable {
    public var correctedText: String
    public var edits: [TextEdit]
    public var selectedHotwords: [HotwordCandidate]
    public var warnings: [String]
    public var confidence: Double
    public var reviewRequired: Bool

    public init(
        correctedText: String,
        edits: [TextEdit],
        selectedHotwords: [HotwordCandidate],
        warnings: [String] = [],
        confidence: Double,
        reviewRequired: Bool
    ) {
        self.correctedText = correctedText
        self.edits = edits
        self.selectedHotwords = selectedHotwords
        self.warnings = warnings
        self.confidence = confidence
        self.reviewRequired = reviewRequired
    }
}

public struct PolishRequest: Codable, Sendable, Equatable {
    public var text: String
    public var style: String
    public var context: ContextSnapshot
    public var deadlineMS: Int

    public init(text: String, style: String, context: ContextSnapshot, deadlineMS: Int = 250) {
        self.text = text
        self.style = style
        self.context = context
        self.deadlineMS = deadlineMS
    }
}

public struct PolishResult: Codable, Sendable, Equatable {
    public var finalText: String
    public var edits: [TextEdit]
    public var warnings: [String]
    public var confidence: Double
    public var reviewRequired: Bool

    public init(
        finalText: String,
        edits: [TextEdit] = [],
        warnings: [String] = [],
        confidence: Double,
        reviewRequired: Bool
    ) {
        self.finalText = finalText
        self.edits = edits
        self.warnings = warnings
        self.confidence = confidence
        self.reviewRequired = reviewRequired
    }
}

public struct LocalTranslationRequest: Codable, Sendable, Equatable {
    public var sourceText: String
    public var correctedSourceText: String
    public var sourceLanguage: String
    public var targetLanguage: String
    public var context: ContextSnapshot
    public var glossary: [HotwordCandidate]
    public var deadlineMS: Int

    public init(
        sourceText: String,
        correctedSourceText: String,
        sourceLanguage: String,
        targetLanguage: String,
        context: ContextSnapshot,
        glossary: [HotwordCandidate],
        deadlineMS: Int = 300
    ) {
        self.sourceText = sourceText
        self.correctedSourceText = correctedSourceText
        self.sourceLanguage = sourceLanguage
        self.targetLanguage = targetLanguage
        self.context = context
        self.glossary = glossary
        self.deadlineMS = deadlineMS
    }
}

public struct LocalTranslationOutput: Codable, Sendable, Equatable {
    public var targetText: String
    public var glossaryHits: [String]
    public var warnings: [String]
    public var confidence: Double
    public var reviewRequired: Bool

    public init(
        targetText: String,
        glossaryHits: [String] = [],
        warnings: [String] = [],
        confidence: Double,
        reviewRequired: Bool
    ) {
        self.targetText = targetText
        self.glossaryHits = glossaryHits
        self.warnings = warnings
        self.confidence = confidence
        self.reviewRequired = reviewRequired
    }
}

public struct InsertionRequest: Codable, Sendable, Equatable {
    public var text: String
    public var strategy: InsertionStrategy

    public init(text: String, strategy: InsertionStrategy) {
        self.text = text
        self.strategy = strategy
    }
}

public struct InsertionResult: Codable, Sendable, Equatable {
    public var strategy: InsertionStrategy
    public var inserted: Bool
    public var fallbackText: String?
    public var latencyMS: Int

    public init(strategy: InsertionStrategy, inserted: Bool, fallbackText: String? = nil, latencyMS: Int) {
        self.strategy = strategy
        self.inserted = inserted
        self.fallbackText = fallbackText
        self.latencyMS = latencyMS
    }
}

public struct PipelineTrace: Codable, Sendable, Equatable {
    public var stages: [LatencyStage]

    public init(stages: [LatencyStage] = []) {
        self.stages = stages
    }

    public var releaseToInsertMS: Int {
        stages
            .filter(\.critical)
            .map(\.durationMS)
            .reduce(0, +)
    }
}

public struct PipelineRunRequest: Codable, Sendable, Equatable {
    public var platform: VeloraPlatform
    public var mode: DictationMode
    public var sampleText: String
    public var audioPath: String?
    public var sourceLanguage: String
    public var targetLanguage: String?
    public var insertPolicy: InsertPolicy
    public var preferredInsertLanguage: String
    public var polishStyle: String
    public var insertionStrategy: InsertionStrategy

    public init(
        platform: VeloraPlatform,
        mode: DictationMode,
        sampleText: String,
        audioPath: String? = nil,
        sourceLanguage: String,
        targetLanguage: String? = nil,
        insertPolicy: InsertPolicy = .bilingual,
        preferredInsertLanguage: String = "zh",
        polishStyle: String = "clean",
        insertionStrategy: InsertionStrategy = .none
    ) {
        self.platform = platform
        self.mode = mode
        self.sampleText = sampleText
        self.audioPath = audioPath
        self.sourceLanguage = sourceLanguage
        self.targetLanguage = targetLanguage
        self.insertPolicy = insertPolicy
        self.preferredInsertLanguage = TranslationLanguageResolver.normalizedLanguage(preferredInsertLanguage)
        self.polishStyle = polishStyle
        self.insertionStrategy = insertionStrategy
    }
}

public struct PipelineRunResult: Codable, Sendable, Equatable {
    public var session: DictationSession
    public var context: ContextSnapshot
    public var asr: ASRResult
    public var correction: CorrectionResult
    public var polish: PolishResult?
    public var translation: TranslationResult?
    public var finalText: String
    public var insertion: InsertionResult?
    public var trace: PipelineTrace

    public init(
        session: DictationSession,
        context: ContextSnapshot,
        asr: ASRResult,
        correction: CorrectionResult,
        polish: PolishResult? = nil,
        translation: TranslationResult? = nil,
        finalText: String,
        insertion: InsertionResult? = nil,
        trace: PipelineTrace
    ) {
        self.session = session
        self.context = context
        self.asr = asr
        self.correction = correction
        self.polish = polish
        self.translation = translation
        self.finalText = finalText
        self.insertion = insertion
        self.trace = trace
    }
}

public protocol ASREngine: Sendable {
    var id: String { get }
    func transcribe(_ request: ASRRequest) async throws -> ASRResult
}

public protocol ContextProvider: Sendable {
    func currentSnapshot(for request: PipelineRunRequest) async -> ContextSnapshot
}

public protocol MemoryStore: Sendable {
    func rankHotwords(for snapshot: ContextSnapshot, limit: Int) async throws -> [HotwordCandidate]
}

public protocol TextIntelligenceEngine: Sendable {
    func correct(_ request: CorrectionRequest) async throws -> CorrectionResult
    func polish(_ request: PolishRequest) async throws -> PolishResult
}

public protocol TranslationEngine: Sendable {
    func translate(_ request: LocalTranslationRequest) async throws -> LocalTranslationOutput
}

public protocol InsertionEngine: Sendable {
    func insert(_ request: InsertionRequest) async throws -> InsertionResult
}

import Foundation

public struct KeyboardBridgePayload: Codable, Sendable, Equatable {
    public var id: UUID
    public var createdAt: Date
    public var expiresAt: Date
    public var mode: DictationMode
    public var sourceLanguage: String
    public var targetLanguage: String?
    public var sourceText: String
    public var correctedSourceText: String
    public var targetText: String?
    public var displayText: String
    public var insertText: String
    public var insertPolicy: InsertPolicy
    public var warnings: [String]
    /// Optional for backward compatibility with payloads written before the
    /// review contract existed; use `needsReview` when reading.
    public var reviewRequired: Bool?

    public var needsReview: Bool {
        reviewRequired ?? false
    }

    public init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        expiresAt: Date,
        mode: DictationMode,
        sourceLanguage: String,
        targetLanguage: String? = nil,
        sourceText: String,
        correctedSourceText: String,
        targetText: String? = nil,
        displayText: String,
        insertText: String,
        insertPolicy: InsertPolicy,
        warnings: [String] = [],
        reviewRequired: Bool? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.expiresAt = expiresAt
        self.mode = mode
        self.sourceLanguage = sourceLanguage
        self.targetLanguage = targetLanguage
        self.sourceText = sourceText
        self.correctedSourceText = correctedSourceText
        self.targetText = targetText
        self.displayText = displayText
        self.insertText = insertText
        self.insertPolicy = insertPolicy
        self.warnings = warnings
        self.reviewRequired = reviewRequired
    }

    public var isTranslation: Bool {
        mode == .translate && targetText != nil
    }

    public func isExpired(at date: Date = Date()) -> Bool {
        date >= expiresAt
    }

    public static func from(
        _ result: PipelineRunResult,
        ttl: TimeInterval = 10 * 60,
        now: Date = Date()
    ) -> KeyboardBridgePayload {
        if let translation = result.translation {
            return KeyboardBridgePayload(
                createdAt: now,
                expiresAt: now.addingTimeInterval(ttl),
                mode: result.session.mode,
                sourceLanguage: translation.mode.sourceLanguage,
                targetLanguage: translation.mode.targetLanguage,
                sourceText: translation.sourceText,
                correctedSourceText: translation.correctedSourceText,
                targetText: translation.targetText,
                displayText: translation.displayText,
                insertText: result.finalText,
                insertPolicy: translation.mode.insertPolicy,
                warnings: translation.warnings,
                reviewRequired: result.reviewRequired
            )
        }

        return KeyboardBridgePayload(
            createdAt: now,
            expiresAt: now.addingTimeInterval(ttl),
            mode: result.session.mode,
            sourceLanguage: result.session.sourceLanguage,
            targetLanguage: result.session.targetLanguage,
            sourceText: result.asr.text,
            correctedSourceText: result.correction.correctedText,
            displayText: result.finalText,
            insertText: result.finalText,
            insertPolicy: .targetOnly,
            warnings: result.correction.warnings + result.compose.warnings,
            reviewRequired: result.reviewRequired
        )
    }
}

import Foundation

public enum InsertPolicy: String, Codable, Sendable, Equatable {
    case bilingual
    case targetOnly
    case reviewCard
}

public struct TranslationMode: Codable, Sendable, Equatable {
    public var sourceLanguage: String
    public var targetLanguage: String
    public var insertPolicy: InsertPolicy
    public var sourceLabel: String
    public var targetLabel: String
    public var separator: String

    public init(
        sourceLanguage: String,
        targetLanguage: String,
        insertPolicy: InsertPolicy,
        sourceLabel: String = "原文",
        targetLabel: String = "译文",
        separator: String = "\n"
    ) {
        self.sourceLanguage = sourceLanguage
        self.targetLanguage = targetLanguage
        self.insertPolicy = insertPolicy
        self.sourceLabel = sourceLabel
        self.targetLabel = targetLabel
        self.separator = separator
    }
}

public struct TranslationResult: Codable, Sendable, Equatable {
    public var mode: TranslationMode
    public var sourceText: String
    public var correctedSourceText: String
    public var targetText: String
    public var displayText: String
    public var insertText: String
    public var glossaryHits: [String]
    public var warnings: [String]

    public init(
        mode: TranslationMode,
        sourceText: String,
        correctedSourceText: String,
        targetText: String,
        displayText: String,
        insertText: String,
        glossaryHits: [String],
        warnings: [String]
    ) {
        self.mode = mode
        self.sourceText = sourceText
        self.correctedSourceText = correctedSourceText
        self.targetText = targetText
        self.displayText = displayText
        self.insertText = insertText
        self.glossaryHits = glossaryHits
        self.warnings = warnings
    }

    public func insertText(preferredLanguage: String) -> String {
        TranslationLanguageResolver.insertText(
            preferredLanguage: preferredLanguage,
            sourceLanguage: mode.sourceLanguage,
            targetLanguage: mode.targetLanguage,
            sourceText: correctedSourceText,
            targetText: targetText
        )
    }
}

public enum TranslationModeRenderer {
    public static func render(
        mode: TranslationMode,
        sourceText: String,
        correctedSourceText: String,
        targetText: String,
        glossaryHits: [String] = [],
        warnings: [String] = []
    ) -> TranslationResult {
        let bilingualBlock = """
        \(mode.sourceLabel):
        \(correctedSourceText)\(mode.separator)\(mode.targetLabel):
        \(targetText)
        """

        let insertText: String
        switch mode.insertPolicy {
        case .bilingual:
            insertText = bilingualBlock
        case .targetOnly:
            insertText = targetText
        case .reviewCard:
            insertText = """
            > \(correctedSourceText)

            \(targetText)
            """
        }

        return TranslationResult(
            mode: mode,
            sourceText: sourceText,
            correctedSourceText: correctedSourceText,
            targetText: targetText,
            displayText: bilingualBlock,
            insertText: insertText,
            glossaryHits: glossaryHits,
            warnings: warnings
        )
    }
}

public enum TranslationLanguageResolver {
    public static func resolvedDirection(
        text: String,
        configuredSourceLanguage: String,
        configuredTargetLanguage: String
    ) -> (sourceLanguage: String, targetLanguage: String) {
        let sourceBase = normalizedLanguage(configuredSourceLanguage)
        let targetBase = normalizedLanguage(configuredTargetLanguage)

        guard sourceBase != targetBase,
              let detected = dominantLanguage(in: text, candidates: [sourceBase, targetBase]),
              detected == targetBase else {
            return (configuredSourceLanguage, configuredTargetLanguage)
        }

        return (configuredTargetLanguage, configuredSourceLanguage)
    }

    public static func insertText(
        preferredLanguage: String,
        sourceLanguage: String,
        targetLanguage: String,
        sourceText: String,
        targetText: String
    ) -> String {
        let preferred = normalizedLanguage(preferredLanguage)
        if ["source", "original"].contains(preferred) {
            return sourceText
        }
        if ["target", "translation"].contains(preferred) {
            return targetText
        }
        if preferred == normalizedLanguage(sourceLanguage) {
            return sourceText
        }
        if preferred == normalizedLanguage(targetLanguage) {
            return targetText
        }
        return targetText
    }

    public static func normalizedLanguage(_ language: String) -> String {
        let trimmed = language
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: "-")
        let base = trimmed.split(separator: "-").first.map(String.init) ?? trimmed

        switch base {
        case "cmn", "mandarin", "chinese", "中文":
            return "zh"
        case "english", "英文":
            return "en"
        case "jp":
            return "ja"
        default:
            return base.isEmpty ? "zh" : base
        }
    }

    public static func displayName(for language: String) -> String {
        switch normalizedLanguage(language) {
        case "zh":
            return "中文"
        case "en":
            return "English"
        case "ja":
            return "日本語"
        case "ko":
            return "한국어"
        case "fr":
            return "Français"
        case "de":
            return "Deutsch"
        case "es":
            return "Español"
        default:
            return language.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "中文" : language
        }
    }

    /// Languages the script-based detector can actually distinguish. Pairs
    /// outside this set (e.g. fr/de/es) must not be silently trusted.
    public static func canDetect(_ language: String) -> Bool {
        ["zh", "en", "ja", "ko"].contains(normalizedLanguage(language))
    }

    public static func dominantLanguage(in text: String, candidates: [String]) -> String? {
        let candidateSet = Set(candidates.map(normalizedLanguage))
        guard !candidateSet.isEmpty else {
            return nil
        }

        var hanCount = 0
        var latinCount = 0
        var kanaCount = 0
        var hangulCount = 0

        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x4E00...0x9FFF, 0x3400...0x4DBF:
                hanCount += 1
            case 0x0041...0x005A, 0x0061...0x007A:
                latinCount += 1
            case 0x3040...0x30FF:
                kanaCount += 1
            case 0xAC00...0xD7AF:
                hangulCount += 1
            default:
                continue
            }
        }

        let zhScore = Double(hanCount) * 2.0
        let enScore = Double(latinCount) * 0.55
        let jaScore = Double(kanaCount) * 2.4 + Double(hanCount) * 0.6
        let koScore = Double(hangulCount) * 2.0

        let scored = [
            ("zh", zhScore),
            ("en", enScore),
            ("ja", jaScore),
            ("ko", koScore),
        ]
            .filter { candidateSet.contains($0.0) && $0.1 >= 2.0 }
            .sorted { lhs, rhs in lhs.1 > rhs.1 }

        return scored.first?.0
    }
}

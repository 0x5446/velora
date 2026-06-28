import Foundation

public struct FakeASREngine: ASREngine {
    public let id = "fake.asr"

    public init() {}

    public func transcribe(_ request: ASRRequest) async throws -> ASRResult {
        let text: String
        let sampleText = request.sampleText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if sampleText.isEmpty, let audioPath = request.audioPath {
            text = "Audio file \(URL(fileURLWithPath: audioPath).lastPathComponent)"
        } else {
            text = sampleText
        }

        guard !text.isEmpty else {
            throw PipelineError.emptyInput
        }

        return ASRResult(
            text: text,
            language: request.sourceLanguage,
            confidence: 0.93,
            segments: [
                ASRSegment(
                    text: text,
                    startMS: 0,
                    endMS: max(500, text.count * 40),
                    confidence: 0.93
                ),
            ],
            engine: id,
            modelVersion: "fake-0"
        )
    }
}

public struct StaticContextProvider: ContextProvider {
    public var appBundle: String
    public var windowTitle: String
    public var nearbyText: String

    public init(
        appBundle: String = "app.velora.prototype",
        windowTitle: String = "Velora Prototype",
        nearbyText: String = "Velora translation mode, prompt injection, bilingual review, agenda"
    ) {
        self.appBundle = appBundle
        self.windowTitle = windowTitle
        self.nearbyText = nearbyText
    }

    public func currentSnapshot(for request: PipelineRunRequest) async -> ContextSnapshot {
        let languagePair = request.targetLanguage.map { "\(request.sourceLanguage)-\($0)" }

        return ContextSnapshot(
            appBundle: appBundle,
            windowTitle: windowTitle,
            nearbyText: nearbyText,
            mode: request.mode,
            languagePair: languagePair
        )
    }
}

public struct InMemoryHotwordStore: MemoryStore {
    public var terms: [HotwordCandidate]

    public init(terms: [HotwordCandidate] = InMemoryHotwordStore.defaultTerms) {
        self.terms = terms
    }

    public func rankHotwords(for snapshot: ContextSnapshot, limit: Int) async throws -> [HotwordCandidate] {
        let nearby = snapshot.nearbyText.lowercased()
        let modeBonus = snapshot.mode == .translate ? 1.2 : 0

        return terms
            .map { term in
                var ranked = term
                if nearby.contains(term.term.lowercased()) || nearby.contains(term.replacement.lowercased()) {
                    ranked.score += 3.0
                    ranked.reasons.append("nearby_text_match")
                }
                ranked.score += modeBonus
                if modeBonus > 0 {
                    ranked.reasons.append("translation_mode_bonus")
                }
                return ranked
            }
            .sorted { lhs, rhs in
                if lhs.score == rhs.score {
                    return lhs.term < rhs.term
                }
                return lhs.score > rhs.score
            }
            .prefix(limit)
            .map { $0 }
    }

    public static let defaultTerms = [
        HotwordCandidate(
            term: "prom injection",
            replacement: "prompt injection",
            score: 8.0,
            reasons: ["accepted_correction"]
        ),
        HotwordCandidate(
            term: "velora",
            replacement: "Velora",
            score: 7.6,
            reasons: ["accepted_correction"]
        ),
        HotwordCandidate(
            term: "agenda",
            replacement: "agenda",
            score: 6.8,
            reasons: ["manual_term"]
        ),
        HotwordCandidate(
            term: "Alex",
            replacement: "Alex",
            score: 5.5,
            reasons: ["manual_name"]
        ),
        HotwordCandidate(
            term: "拥护",
            replacement: "用户",
            score: 7.4,
            reasons: ["input_product_term"]
        ),
        HotwordCandidate(
            term: "上评",
            replacement: "上屏",
            score: 7.3,
            reasons: ["input_product_term"]
        ),
        HotwordCandidate(
            term: "据认",
            replacement: "确认",
            score: 7.1,
            reasons: ["input_product_term"]
        ),
        HotwordCandidate(
            term: "终于门对照",
            replacement: "中英文对照",
            score: 7.0,
            reasons: ["input_product_term"]
        ),
    ]
}

public struct RuleBasedTextIntelligenceEngine: TextIntelligenceEngine {
    public init() {}

    public func correct(_ request: CorrectionRequest) async throws -> CorrectionResult {
        var corrected = request.text
        var edits: [TextEdit] = []

        for hotword in request.hotwords {
            guard hotword.term != hotword.replacement else {
                continue
            }

            let ranges = corrected.ranges(of: hotword.term, options: [.caseInsensitive])
            guard !ranges.isEmpty else {
                continue
            }

            corrected = corrected.replacingOccurrences(
                of: hotword.term,
                with: hotword.replacement,
                options: [.caseInsensitive]
            )
            edits.append(
                TextEdit(
                    from: hotword.term,
                    to: hotword.replacement,
                    reason: "selected_hotword",
                    confidence: min(0.96, max(0.72, hotword.score / 10.0))
                )
            )
        }

        corrected = normalizeSpacingAndTerminalPunctuation(corrected)

        return CorrectionResult(
            correctedText: corrected,
            edits: edits,
            selectedHotwords: request.hotwords,
            confidence: edits.isEmpty ? 0.86 : 0.91,
            reviewRequired: false
        )
    }

    public func polish(_ request: PolishRequest) async throws -> PolishResult {
        let cleaned = normalizeSpacingAndTerminalPunctuation(request.text)
        let finalText: String

        switch request.style {
        case "bullet", "bullets", "list":
            finalText = cleaned
                .split(separator: "，")
                .map { "- \($0.trimmingCharacters(in: .whitespacesAndNewlines))" }
                .joined(separator: "\n")
        case "email":
            finalText = cleaned
        default:
            finalText = cleaned
        }

        return PolishResult(
            finalText: finalText,
            edits: finalText == request.text ? [] : [
                TextEdit(
                    from: request.text,
                    to: finalText,
                    reason: "rule_based_polish",
                    confidence: 0.82
                ),
            ],
            confidence: 0.84,
            reviewRequired: false
        )
    }

    private func normalizeSpacingAndTerminalPunctuation(_ input: String) -> String {
        let collapsed = input
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let last = collapsed.last else {
            return collapsed
        }

        if [".", "!", "?", "。", "！", "？"].contains(String(last)) {
            return collapsed
        }

        return collapsed + "。"
    }
}

public struct StubTranslationEngine: TranslationEngine {
    public init() {}

    public func translate(_ request: LocalTranslationRequest) async throws -> LocalTranslationOutput {
        let key = request.correctedSourceText
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        let targetText: String
        if request.sourceLanguage == "zh", request.targetLanguage == "en" {
            targetText = zhToEn[key] ?? "I have a meeting with Alex tomorrow at 10 a.m. Please help me confirm the agenda."
        } else if request.sourceLanguage == "en", request.targetLanguage == "zh" {
            targetText = enToZh[key] ?? "最大的风险是本地语境层里的提示注入。"
        } else {
            targetText = request.correctedSourceText
        }

        let glossaryHits = request.glossary
            .map(\.replacement)
            .filter { term in
                request.correctedSourceText.localizedCaseInsensitiveContains(term)
                    || targetText.localizedCaseInsensitiveContains(term)
            }

        return LocalTranslationOutput(
            targetText: targetText,
            glossaryHits: Array(Set(glossaryHits)).sorted(),
            confidence: 0.82,
            reviewRequired: false
        )
    }

    private let zhToEn: [String: String] = [
        "明天上午十点我和 alex 开会，帮我确认一下 agenda。":
            "I have a meeting with Alex tomorrow at 10 a.m. Please help me confirm the agenda.",
        "翻译模式要同时上屏原文和译文。":
            "Translation mode should insert both the source text and the translated text.",
    ]

    private let enToZh: [String: String] = [
        "the biggest risk is prompt injection in velora when we keep long term context.":
            "最大的风险是Velora保留长期语境时出现提示注入。",
        "the biggest risk is prompt injection in the local context layer.":
            "最大的风险是本地语境层里的提示注入。",
    ]
}

public struct NoopInsertionEngine: InsertionEngine {
    public init() {}

    public func insert(_ request: InsertionRequest) async throws -> InsertionResult {
        InsertionResult(
            strategy: request.strategy,
            inserted: request.strategy == .none ? false : true,
            fallbackText: request.strategy == .none ? request.text : nil,
            latencyMS: request.strategy == .none ? 0 : 12
        )
    }
}

extension String {
    fileprivate func ranges(of searchString: String, options: String.CompareOptions = []) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        var searchStartIndex = startIndex

        while searchStartIndex < endIndex,
              let range = self.range(of: searchString, options: options, range: searchStartIndex..<endIndex) {
            ranges.append(range)
            searchStartIndex = range.upperBound
        }

        return ranges
    }
}

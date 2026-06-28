import Foundation

public struct PipelineOrchestrator: Sendable {
    public var asrEngine: any ASREngine
    public var contextProvider: any ContextProvider
    public var memoryStore: any MemoryStore
    public var textEngine: any TextIntelligenceEngine
    public var translationEngine: any TranslationEngine
    public var insertionEngine: any InsertionEngine

    public init(
        asrEngine: any ASREngine,
        contextProvider: any ContextProvider,
        memoryStore: any MemoryStore,
        textEngine: any TextIntelligenceEngine,
        translationEngine: any TranslationEngine,
        insertionEngine: any InsertionEngine
    ) {
        self.asrEngine = asrEngine
        self.contextProvider = contextProvider
        self.memoryStore = memoryStore
        self.textEngine = textEngine
        self.translationEngine = translationEngine
        self.insertionEngine = insertionEngine
    }

    public func run(_ request: PipelineRunRequest) async throws -> PipelineRunResult {
        let wallClock = PipelineWallClock()
        let trimmedInput = request.sampleText.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedAudioPath = request.audioPath?.trimmingCharacters(in: .whitespacesAndNewlines)
        let audioPath = trimmedAudioPath?.isEmpty == false ? trimmedAudioPath : nil

        guard !trimmedInput.isEmpty || audioPath != nil else {
            throw PipelineError.emptyInput
        }

        let session = DictationSession(
            platform: request.platform,
            mode: request.mode,
            sourceLanguage: request.sourceLanguage,
            targetLanguage: request.targetLanguage
        )

        var trace = PipelineTrace()
        let contextStart = wallClock.mark()
        let context = await contextProvider.currentSnapshot(for: request)
        trace.stages.append(
            LatencyStage(
                name: "context_capture",
                durationMS: wallClock.elapsedMS(since: contextStart),
                phase: "during_recording",
                critical: false,
                note: "Captured active context snapshot."
            )
        )

        let hotwordStart = wallClock.mark()
        let hotwords = try await memoryStore.rankHotwords(for: context, limit: 8)
        trace.stages.append(
            LatencyStage(
                name: "hotword_rank",
                durationMS: wallClock.elapsedMS(since: hotwordStart),
                phase: "during_recording",
                critical: false,
                note: "Ranked selected local terms."
            )
        )

        let asrStart = wallClock.mark()
        let asrSourceLanguage = request.mode == .translate && request.targetLanguage != nil
            ? "auto"
            : request.sourceLanguage
        let asr = try await asrEngine.transcribe(
            ASRRequest(
                audioPath: audioPath,
                sampleText: trimmedInput.isEmpty ? nil : trimmedInput,
                sourceLanguage: asrSourceLanguage,
                contextualPhrases: Self.asrContextualPhrases(context: context, hotwords: hotwords)
            )
        )
        try Task.checkCancellation()
        trace.stages.append(
            LatencyStage(
                name: "asr_finalize",
                durationMS: wallClock.elapsedMS(since: asrStart),
                phase: "after_release",
                critical: true,
                note: "\(asr.engine) \(asr.modelVersion)"
            )
        )

        try Task.checkCancellation()
        let correctionStart = wallClock.mark()
        let correction = try await textEngine.correct(
            CorrectionRequest(
                text: asr.text,
                context: context,
                hotwords: hotwords
            )
        )
        trace.stages.append(
            LatencyStage(
                name: "correction_reconcile",
                durationMS: wallClock.elapsedMS(since: correctionStart),
                phase: "after_release",
                critical: true,
                note: "Hotword-aware correction."
            )
        )

        let finalText: String
        let polish: PolishResult?
        let translation: TranslationResult?

        switch request.mode {
        case .dictate:
            polish = nil
            translation = nil
            finalText = correction.correctedText

        case .polish:
            try Task.checkCancellation()
            let polishStart = wallClock.mark()
            let polishResult = try await textEngine.polish(
                PolishRequest(
                    text: correction.correctedText,
                    style: request.polishStyle,
                    context: context
                )
            )
            trace.stages.append(
                LatencyStage(
                    name: "polish_reconcile",
                    durationMS: wallClock.elapsedMS(since: polishStart),
                    phase: "after_release",
                    critical: true,
                    note: "Local polish pass."
                )
            )
            polish = polishResult
            translation = nil
            finalText = polishResult.finalText

        case .translate:
            guard let targetLanguage = request.targetLanguage else {
                throw PipelineError.unsupportedMode("translate requires targetLanguage")
            }

            let resolvedDirection = TranslationLanguageResolver.resolvedDirection(
                text: correction.correctedText,
                configuredSourceLanguage: request.sourceLanguage,
                configuredTargetLanguage: targetLanguage
            )

            try Task.checkCancellation()
            let translationStart = wallClock.mark()
            let translationOutput = try await translationEngine.translate(
                LocalTranslationRequest(
                    sourceText: asr.text,
                    correctedSourceText: correction.correctedText,
                    sourceLanguage: resolvedDirection.sourceLanguage,
                    targetLanguage: resolvedDirection.targetLanguage,
                    context: context,
                    glossary: hotwords
                )
            )
            try Task.checkCancellation()
            trace.stages.append(
                LatencyStage(
                    name: "translation_reconcile",
                    durationMS: wallClock.elapsedMS(since: translationStart),
                    phase: "after_release",
                    critical: true,
                    note: "Local translation pass."
                )
            )

            let mode = TranslationMode(
                sourceLanguage: resolvedDirection.sourceLanguage,
                targetLanguage: resolvedDirection.targetLanguage,
                insertPolicy: request.insertPolicy
            )
            let renderStart = wallClock.mark()
            let rendered = TranslationModeRenderer.render(
                mode: mode,
                sourceText: asr.text,
                correctedSourceText: correction.correctedText,
                targetText: translationOutput.targetText,
                glossaryHits: translationOutput.glossaryHits,
                warnings: correction.warnings + translationOutput.warnings
            )
            trace.stages.append(
                LatencyStage(
                    name: "render_bilingual_text",
                    durationMS: wallClock.elapsedMS(since: renderStart),
                    phase: "after_release",
                    critical: true,
                    note: "Render source and target text."
                )
            )

            polish = nil
            translation = rendered
            finalText = rendered.insertText(preferredLanguage: request.preferredInsertLanguage)
        }

        let insertion: InsertionResult?
        if request.insertionStrategy == .none {
            insertion = nil
        } else {
            try Task.checkCancellation()
            let insertionStart = wallClock.mark()
            insertion = try await insertionEngine.insert(
                InsertionRequest(
                    text: finalText,
                    strategy: request.insertionStrategy
                )
            )
            trace.stages.append(
                LatencyStage(
                    name: "insert_text",
                    durationMS: insertion?.latencyMS ?? wallClock.elapsedMS(since: insertionStart),
                    phase: "after_release",
                    critical: true,
                    note: "Insert through configured strategy."
                )
            )
        }

        return PipelineRunResult(
            session: session,
            context: context,
            asr: asr,
            correction: correction,
            polish: polish,
            translation: translation,
            finalText: finalText,
            insertion: insertion,
            trace: trace
        )
    }

    private static func asrContextualPhrases(
        context: ContextSnapshot,
        hotwords: [HotwordCandidate]
    ) -> [String] {
        var phrases: [String] = []

        for hotword in hotwords {
            phrases.append(VeloraTextSanitizer.promptPhrase(hotword.replacement))
            if hotword.term != hotword.replacement {
                phrases.append(VeloraTextSanitizer.promptPhrase(hotword.term))
            }
        }

        let nearbyTerms = VeloraTextSanitizer.contextText(context.nearbyText)
            .split { character in
                character.isWhitespace || [",", ".", "，", "。", ":", "：", ";", "；"].contains(String(character))
            }
            .map(String.init)
            .map { VeloraTextSanitizer.promptPhrase($0) }
            .filter { $0.count >= 2 && $0.count <= 40 }

        phrases.append(contentsOf: nearbyTerms)

        var seen = Set<String>()
        return phrases.compactMap { phrase in
            let normalized = VeloraTextSanitizer.promptPhrase(phrase)
            guard !normalized.isEmpty else {
                return nil
            }
            let key = normalized.lowercased()
            guard seen.insert(key).inserted else {
                return nil
            }
            return normalized
        }
        .prefix(16)
        .map { $0 }
    }
}

private struct PipelineWallClock: Sendable {
    func mark() -> Date {
        Date()
    }

    func elapsedMS(since start: Date) -> Int {
        max(0, Int((Date().timeIntervalSince(start) * 1_000).rounded()))
    }
}

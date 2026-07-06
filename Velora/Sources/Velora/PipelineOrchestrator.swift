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
        // Honest tracing: these two stages are designed to run during recording,
        // but the current controller only starts the pipeline after release, so
        // they stay on the critical path until真正并行化.
        let contextStart = wallClock.mark()
        let context = await contextProvider.currentSnapshot(for: request)
        trace.stages.append(
            LatencyStage(
                name: "context_capture",
                durationMS: wallClock.elapsedMS(since: contextStart),
                phase: "after_release",
                critical: true,
                note: "Target phase is during_recording; currently runs after release."
            )
        )

        let hotwordStart = wallClock.mark()
        let hotwords = try await memoryStore.rankHotwords(for: context, limit: 12)
        trace.stages.append(
            LatencyStage(
                name: "hotword_rank",
                durationMS: wallClock.elapsedMS(since: hotwordStart),
                phase: "after_release",
                critical: true,
                note: "Target phase is during_recording; currently runs after release."
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

        // Hotword pass belongs to the ASR capability boundary: text leaving this
        // stage is treated as "what the user said", with structured edits kept
        // for diagnostics and feedback learning.
        try Task.checkCancellation()
        let correctionStart = wallClock.mark()
        let correction = HotwordCorrector.correct(text: asr.text, hotwords: hotwords)
        trace.stages.append(
            LatencyStage(
                name: "asr_hotword_correction",
                durationMS: wallClock.elapsedMS(since: correctionStart),
                phase: "after_release",
                critical: true,
                note: "Hotword pass inside the ASR capability boundary."
            )
        )

        let resolvedDirection: (sourceLanguage: String, targetLanguage: String)?
        if request.mode == .translate {
            guard let targetLanguage = request.targetLanguage else {
                throw PipelineError.unsupportedMode("translate requires targetLanguage")
            }
            resolvedDirection = TranslationLanguageResolver.resolvedDirection(
                text: correction.correctedText,
                configuredSourceLanguage: request.sourceLanguage,
                configuredTargetLanguage: targetLanguage
            )
        } else {
            resolvedDirection = nil
        }

        // Single text-intelligence call: mandatory tiered polish; translate mode
        // asks the same call for one more output field (the target language).
        try Task.checkCancellation()
        let composeStart = wallClock.mark()
        var compose = try await textEngine.compose(
            ComposeRequest(
                text: correction.correctedText,
                mode: request.mode,
                style: request.composeStyle,
                sourceLanguage: resolvedDirection?.sourceLanguage ?? request.sourceLanguage,
                targetLanguage: resolvedDirection?.targetLanguage,
                context: context,
                glossary: hotwords
            )
        )
        try Task.checkCancellation()
        trace.stages.append(
            LatencyStage(
                name: request.mode == .translate ? "compose_bilingual" : "compose",
                durationMS: wallClock.elapsedMS(since: composeStart),
                phase: "after_release",
                critical: true,
                note: "\(compose.engine) tiered polish\(request.mode == .translate ? " + target language" : "")."
            )
        )

        let finalText: String
        let translation: TranslationResult?

        switch request.mode {
        case .input:
            translation = nil
            finalText = compose.polishedText

        case .translate:
            guard let direction = resolvedDirection else {
                throw PipelineError.unsupportedMode("translate requires targetLanguage")
            }

            // Fallback slot: only when the compose call could not emit the
            // target. Bounded and non-fatal — a dead fallback engine must not
            // swallow the rule-tier result we already have.
            var targetText = compose.targetText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if targetText.isEmpty {
                try Task.checkCancellation()
                let fallbackStart = wallClock.mark()
                do {
                    let fallback = try await DeadlineRunner.run(
                        deadlineMS: ComposeRequest.defaultTranslateDeadlineMS
                    ) { [translationEngine, asr, compose, direction, context, hotwords] in
                        try await translationEngine.translate(
                            LocalTranslationRequest(
                                sourceText: asr.text,
                                correctedSourceText: compose.polishedText,
                                sourceLanguage: direction.sourceLanguage,
                                targetLanguage: direction.targetLanguage,
                                context: context,
                                glossary: hotwords,
                                deadlineMS: ComposeRequest.defaultTranslateDeadlineMS
                            )
                        )
                    }
                    if let fallback {
                        targetText = fallback.targetText.trimmingCharacters(in: .whitespacesAndNewlines)
                        compose.warnings.append(contentsOf: fallback.warnings)
                        compose.glossaryHits = Array(Set(compose.glossaryHits + fallback.glossaryHits)).sorted()
                        compose.reviewRequired = compose.reviewRequired || fallback.reviewRequired
                    } else {
                        compose.warnings.append("translation_fallback_deadline")
                        compose.reviewRequired = true
                    }
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    compose.warnings.append("translation_fallback_error:\(VeloraErrorPresenter.message(for: error))")
                    compose.reviewRequired = true
                }
                try Task.checkCancellation()
                trace.stages.append(
                    LatencyStage(
                        name: "translation_fallback",
                        durationMS: wallClock.elapsedMS(since: fallbackStart),
                        phase: "after_release",
                        critical: true,
                        note: "Compose emitted no target text; dedicated translation engine used."
                    )
                )
            }

            if targetText.isEmpty {
                // No translation at all: degrade to the polished source and
                // force review — never render a half-empty bilingual block.
                compose.reviewRequired = true
                translation = nil
                finalText = compose.polishedText
            } else {
                let mode = TranslationMode(
                    sourceLanguage: direction.sourceLanguage,
                    targetLanguage: direction.targetLanguage,
                    insertPolicy: request.insertPolicy
                )
                let renderStart = wallClock.mark()
                let rendered = TranslationModeRenderer.render(
                    mode: mode,
                    sourceText: asr.text,
                    correctedSourceText: compose.polishedText,
                    targetText: targetText,
                    glossaryHits: compose.glossaryHits,
                    warnings: correction.warnings + compose.warnings
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

                translation = rendered
                // Hard product rule (2026-07-05): inserted text is NEVER
                // bilingual. The bilingual block lives only in displayText
                // for the review overlay; what goes to the screen is the
                // target text (the overlay lets the user pick source instead).
                finalText = targetText
            }
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
            compose: compose,
            translation: translation,
            finalText: finalText,
            reviewRequired: correction.reviewRequired || compose.reviewRequired,
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

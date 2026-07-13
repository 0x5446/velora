import Foundation
import Testing
@testable import Velora

@Test func dictationModeNormalizeMapsLegacyValuesToInput() {
    #expect(DictationMode.normalize("input") == .input)
    #expect(DictationMode.normalize("dictate") == .input)
    #expect(DictationMode.normalize("polish") == .input)
    #expect(DictationMode.normalize("Translate") == .translate)
    #expect(DictationMode.normalize("unknown") == nil)
}

@Test func dictationModeDecodesLegacyRawValues() throws {
    let decoder = JSONDecoder()
    let legacy = try decoder.decode([DictationMode].self, from: Data(#"["dictate", "polish", "translate"]"#.utf8))

    #expect(legacy == [.input, .input, .translate])
}

@Test func hotwordCorrectorRespectsLatinWordBoundaries() {
    // Boundary rules are a hard-replace concern; contextual terms never reach this pass.
    let hotword = HotwordCandidate(term: "velora", replacement: "Velora", score: 8, reasons: [HotwordCorrector.hardReplaceReason])

    let standalone = HotwordCorrector.correct(text: "try velora today", hotwords: [hotword])
    #expect(standalone.correctedText == "try Velora today")
    #expect(standalone.edits.count == 1)

    let embedded = HotwordCorrector.correct(text: "veloraish tools and veloras", hotwords: [hotword])
    #expect(embedded.correctedText == "veloraish tools and veloras")
    #expect(embedded.edits.isEmpty)

    let punctuated = HotwordCorrector.correct(text: "ship velora.", hotwords: [hotword])
    #expect(punctuated.correctedText == "ship Velora.")
}

@Test func hotwordCorrectorReplacesCJKTermsWithoutBoundaries() {
    let hotword = HotwordCandidate(term: "上评", replacement: "上屏", score: 7, reasons: [HotwordCorrector.hardReplaceReason])

    let result = HotwordCorrector.correct(text: "确认之后再上评，就完成了", hotwords: [hotword])

    #expect(result.correctedText == "确认之后再上屏，就完成了")
    #expect(result.edits.count == 1)
}

@Test func textComposerKeepsParagraphsAndMatchesScriptPunctuation() {
    #expect(VeloraTextComposer.cleaned("  please   confirm the agenda  ") == "please confirm the agenda.")
    #expect(VeloraTextComposer.cleaned("明天上午十点开会") == "明天上午十点开会。")
    #expect(VeloraTextComposer.cleaned("第一段\n\n第二段") == "第一段\n\n第二段。")
    #expect(VeloraTextComposer.cleaned("已经有句号了。") == "已经有句号了。")
}

@Test func deadlineRunnerReturnsNilWhenDeadlineWins() async throws {
    let timedOut: Int? = try await DeadlineRunner.run(deadlineMS: 40) {
        try await Task.sleep(nanoseconds: 800_000_000)
        return 1
    }
    #expect(timedOut == nil)

    let completed: Int? = try await DeadlineRunner.run(deadlineMS: 5_000) { 2 }
    #expect(completed == 2)
}

@Test func deadlineRunnerPropagatesOperationErrors() async {
    do {
        let _: Int? = try await DeadlineRunner.run(deadlineMS: 5_000) {
            throw PipelineError.localModelUnavailable("boom")
        }
        Issue.record("Expected error to propagate")
    } catch PipelineError.localModelUnavailable(let reason) {
        #expect(reason == "boom")
    } catch {
        Issue.record("Unexpected error type: \(error)")
    }
}

@Test func composePayloadParserHandlesFencedAndLabeledJSON() {
    let plain = OllamaTextIntelligenceEngine.parseComposePayload(
        #"{"polished": "你好。", "target": "Hello."}"#
    )
    #expect(plain?.polished == "你好。")
    #expect(plain?.target == "Hello.")

    let fenced = OllamaTextIntelligenceEngine.parseComposePayload(
        "<think>x</think>\n```json\n{\"polished\": \"你好。\"}\n```"
    )
    #expect(fenced?.polished == "你好。")
    #expect(fenced?.target == nil)

    #expect(OllamaTextIntelligenceEngine.parseComposePayload("not json") == nil)
}

@Test func networkGuardBlocksNonLoopbackLLMEndpoints() async {
    let remote = OllamaLocalClient(
        endpoint: URL(string: "http://example.com/api/generate")!
    )

    do {
        _ = try await remote.generate(system: "s", prompt: "p", maxTokens: 4)
        Issue.record("Expected network guard to block remote endpoint")
    } catch PipelineError.localModelUnavailable(let reason) {
        #expect(reason.hasPrefix("network_guard_blocked_non_loopback"))
    } catch {
        Issue.record("Unexpected error type: \(error)")
    }

    #expect(OllamaLocalClient.isLoopbackEndpoint(URL(string: "http://127.0.0.1:11434/api/generate")!))
    #expect(OllamaLocalClient.isLoopbackEndpoint(URL(string: "http://localhost:11434/api/generate")!))
    #expect(!OllamaLocalClient.isLoopbackEndpoint(URL(string: "http://192.168.1.10:11434/api/generate")!))
}

@Test func fillerStripperRemovesInlineHesitationsOnly() {
    // Inline 嗯/呃 glued between Han characters are fillers.
    #expect(VeloraTextComposer.strippedFillers("我嗯觉得呃可以") == "我觉得可以")
    #expect(VeloraTextComposer.strippedFillers("嗯我觉得可以") == "我觉得可以")
    // Standalone acknowledgments are intentional content and must survive.
    #expect(VeloraTextComposer.strippedFillers("嗯，好的，明天见。") == "嗯，好的，明天见。")
    #expect(VeloraTextComposer.strippedFillers("嗯嗯，收到") == "嗯嗯，收到")
    // Cantonese negation 唔 is never touched.
    #expect(VeloraTextComposer.strippedFillers("我唔知道") == "我唔知道")
    // Medical term 呃逆 survives the 呃 rule.
    #expect(VeloraTextComposer.strippedFillers("持续呃逆是一种症状") == "持续呃逆是一种症状")
}

@Test func fillerStripperCollapsesWhitelistedStuttersOnly() {
    #expect(VeloraTextComposer.strippedFillers("这个这个功能有问题") == "这个功能有问题")
    #expect(VeloraTextComposer.strippedFillers("就是就是那个那个意思") == "就是那个意思")
    // Legit ABAB verb reduplication must survive.
    #expect(VeloraTextComposer.strippedFillers("我们商量商量") == "我们商量商量")
    #expect(VeloraTextComposer.strippedFillers("你考虑考虑再说") == "你考虑考虑再说")
    #expect(VeloraTextComposer.strippedFillers("谢谢") == "谢谢")
    #expect(VeloraTextComposer.strippedFillers("意思意思") == "意思意思")
}

@Test func fillerStripperHandlesEnglishCommaDelimitedFillers() {
    #expect(VeloraTextComposer.strippedFillers("Um, I think we should go", sourceLanguage: "en") == "I think we should go")
    #expect(VeloraTextComposer.strippedFillers("I was, uh, thinking about it", sourceLanguage: "en") == "I was, thinking about it")
    // Non-comma forms survive: uh-huh, uh oh.
    #expect(VeloraTextComposer.strippedFillers("uh-huh, sounds good", sourceLanguage: "en") == "uh-huh, sounds good")
    #expect(VeloraTextComposer.strippedFillers("uh oh", sourceLanguage: "en") == "uh oh")
    // Rule is gated off for non-English sources (German/Portuguese um).
    #expect(VeloraTextComposer.strippedFillers("quero um livro", sourceLanguage: "pt") == "quero um livro")
    #expect(VeloraTextComposer.strippedFillers("Um, test", sourceLanguage: "zh") == "Um, test")
}

#if os(macOS)
@Test func whisperSilenceHallucinationsAreCaught() {
    #expect(WhisperCLIASREngine.isKnownSilenceHallucination("Thank you."))
    #expect(WhisperCLIASREngine.isKnownSilenceHallucination("you"))
    #expect(WhisperCLIASREngine.isKnownSilenceHallucination("你"))
    #expect(WhisperCLIASREngine.isKnownSilenceHallucination("..."))
    #expect(WhisperCLIASREngine.isKnownSilenceHallucination("请不吝点赞 订阅 转发"))
    #expect(!WhisperCLIASREngine.isKnownSilenceHallucination("thank you for the update on the release"))
    #expect(!WhisperCLIASREngine.isKnownSilenceHallucination("你明天有空吗"))
}

@Test func whisperRepetitionLoopDetectorFlagsLoopedOutput() {
    let looped = String(repeating: "好的好的好的好的", count: 6)
    #expect(WhisperCLIASREngine.looksLikeRepetitionLoop(looped, audioSeconds: 0.5))
    let normal = "明天上午十点开会，帮我确认一下议程，然后把文档发给产品同事。"
    #expect(!WhisperCLIASREngine.looksLikeRepetitionLoop(normal, audioSeconds: 6.0))
    // Implausible char rate for the audio length is also a loop signal.
    #expect(WhisperCLIASREngine.looksLikeRepetitionLoop(normal + normal, audioSeconds: 1.0))
}

@Test func tunedDecodeArgumentsMatchRealCorpusVerdict() {
    // Real-mic gate (2026-07-05): audio-ctx trimming is banned outright —
    // lossy on conversational/code-switching audio; accurate keeps beam.
    #expect(WhisperCLIConfiguration.tunedDecodeArguments(for: .accurate) == ["-sns"])
    #expect(WhisperCLIConfiguration.tunedDecodeArguments(for: .fast) == ["-bs", "1", "-bo", "1", "-sns"])
    #expect(WhisperCLIConfiguration.tunedDecodeArguments(for: .fallback) == ["-bs", "1", "-bo", "1", "-sns"])
    for mode in WhisperModelMode.allCases {
        #expect(!WhisperCLIConfiguration.tunedDecodeArguments(for: mode).contains("-ac"))
    }
}

@Test func wavSilenceGateDistinguishesSilenceFromTone() throws {
    func writeWav(_ path: String, samples: [Int16]) throws {
        var data = Data()
        let byteCount = samples.count * 2
        data.append(Data("RIFF".utf8))
        var riffSize = UInt32(36 + byteCount).littleEndian
        data.append(Data(bytes: &riffSize, count: 4))
        data.append(Data("WAVE".utf8))
        data.append(Data("fmt ".utf8))
        var fmtSize = UInt32(16).littleEndian
        data.append(Data(bytes: &fmtSize, count: 4))
        var fmt: [UInt16] = [1, 1]
        data.append(Data(bytes: &fmt, count: 4))
        var rate = UInt32(16_000).littleEndian
        data.append(Data(bytes: &rate, count: 4))
        var byteRate = UInt32(32_000).littleEndian
        data.append(Data(bytes: &byteRate, count: 4))
        var align: [UInt16] = [2, 16]
        data.append(Data(bytes: &align, count: 4))
        data.append(Data("data".utf8))
        var dataSize = UInt32(byteCount).littleEndian
        data.append(Data(bytes: &dataSize, count: 4))
        samples.withUnsafeBufferPointer { data.append(Data(buffer: $0)) }
        try data.write(to: URL(fileURLWithPath: path))
    }

    let silentPath = NSTemporaryDirectory() + "velora-silent-\(UUID().uuidString).wav"
    try writeWav(silentPath, samples: Array(repeating: Int16(3), count: 16_000))
    defer { try? FileManager.default.removeItem(atPath: silentPath) }
    #expect(WhisperCLIConfiguration.wavAppearsSilent(atPath: silentPath))
    #expect(abs((WhisperCLIConfiguration.wavDurationSeconds(atPath: silentPath) ?? 0) - 1.0) < 0.01)

    let tonePath = NSTemporaryDirectory() + "velora-tone-\(UUID().uuidString).wav"
    let tone = (0..<16_000).map { Int16(8_000 * sin(Double($0) * 2 * .pi * 440 / 16_000)) }
    try writeWav(tonePath, samples: tone)
    defer { try? FileManager.default.removeItem(atPath: tonePath) }
    #expect(!WhisperCLIConfiguration.wavAppearsSilent(atPath: tonePath))
}
#endif

@Test func textSimilarityDetectsRetryRedictation() {
    // Same utterance re-dictated with small wording changes: high overlap.
    let first = "嗯那个明天的会改到下午三点议程你再发我一下"
    let retry = "明天的会改到下午三点然后议程你发我一下"
    #expect(VeloraTextSimilarity.normalizedSimilarity(first, retry) >= 0.55)

    // Unrelated consecutive dictations must stay far below the threshold.
    let unrelated = "帮我把发布说明整理一下再发给产品同事确认"
    #expect(VeloraTextSimilarity.normalizedSimilarity(first, unrelated) < 0.4)

    #expect(VeloraTextSimilarity.normalizedSimilarity("同一句话。", "同一句话") == 1.0)
    #expect(VeloraTextSimilarity.normalizedSimilarity("", "abc") == 0)
    // English retry with fillers removed and casing changed.
    #expect(VeloraTextSimilarity.normalizedSimilarity(
        "um let's move the meeting to Thursday",
        "Let's move the meeting to Thursday at three"
    ) >= 0.55)
}

@Test func languageDetectorDeclaresItsCoverage() {
    #expect(TranslationLanguageResolver.canDetect("zh"))
    #expect(TranslationLanguageResolver.canDetect("en-US"))
    #expect(TranslationLanguageResolver.canDetect("ja"))
    #expect(!TranslationLanguageResolver.canDetect("fr"))
    #expect(!TranslationLanguageResolver.canDetect("de"))
}

@Test func appFormatProfileRoutesDeveloperChatAndEmailWithoutFreeformToneInstructions() {
    let developer = OllamaTextIntelligenceEngine.appFormatProfile(
        for: ContextSnapshot(appBundle: "com.googlecode.iterm2", windowTitle: "Codex", mode: .input)
    )
    #expect(developer.hasPrefix("developer:"))
    #expect(developer.contains("identifiers"))

    let chat = OllamaTextIntelligenceEngine.appFormatProfile(
        for: ContextSnapshot(appBundle: "com.tinyspeck.slackmacgap", mode: .input)
    )
    #expect(chat.hasPrefix("work_chat:"))

    let email = OllamaTextIntelligenceEngine.appFormatProfile(
        for: ContextSnapshot(appBundle: "com.apple.mail", mode: .input)
    )
    #expect(email.hasPrefix("email:"))
    #expect(email.contains("do not invent"))
}

@Test func polishPreservationGuardProtectsOpaqueFactsAndAllowsFormatting() {
    let source = "请看 https://example.com/a 文档，运行 deploy_prod --dry-run，超时 1500ms"
    let safe = "请看 https://example.com/a 文档。运行 deploy_prod --dry-run，超时 1500ms。"
    #expect(OllamaTextIntelligenceEngine.preservationViolations(source: source, output: safe).isEmpty)

    let lost = "请看文档，然后运行部署命令。"
    let violations = OllamaTextIntelligenceEngine.preservationViolations(source: source, output: lost)
    #expect(violations.contains("protected_literal_loss"))
    #expect(violations.contains("excessive_rewrite"))
}

@Test func polishPreservationGuardProtectsLearnedEntitiesButAllowsMappedCorrection() {
    let glossary = [HotwordCandidate(term: "会画", replacement: "会话", score: 4, reasons: [])]
    #expect(OllamaTextIntelligenceEngine.preservationViolations(
        source: "再开一个会画讨论",
        output: "再开一个会话讨论。",
        glossary: glossary
    ).isEmpty)
    #expect(OllamaTextIntelligenceEngine.preservationViolations(
        source: "再开一个会画讨论",
        output: "再讨论一下。",
        glossary: glossary
    ).contains("glossary_entity_loss"))
}

@Test func polishPreservationGuardDoesNotRejectExplicitNumberRepair() {
    let violations = OllamaTextIntelligenceEngine.preservationViolations(
        source: "预算是50000不对应该是80000",
        output: "预算是 80000。"
    )
    #expect(!violations.contains("protected_literal_loss"))
    #expect(!violations.contains("excessive_rewrite"))
}

@Test func correctionHistoryHitCountDeduplicatesAndRequiresMatchingSound() {
    let examples = [
        VeloraCorrectionExample(beforeSpan: "会画", afterSpan: "会话", beforeText: "开会画", afterText: "开会话", pinyinKey: VeloraPinyin.latinized("会画")),
        VeloraCorrectionExample(beforeSpan: "会画", afterSpan: "会话", beforeText: "另一个会画", afterText: "另一个会话", pinyinKey: VeloraPinyin.latinized("会画")),
    ]
    #expect(OllamaTextIntelligenceEngine.relevantCorrectionExampleCount(text: "开个会画", examples: examples) == 1)
    #expect(OllamaTextIntelligenceEngine.relevantCorrectionExampleCount(text: "发布版本", examples: examples) == 0)
}

#if os(macOS)
@Test func whisperNonSpeechMarkersAreRecognized() {
    #expect(WhisperCLIASREngine.containsOnlyNonSpeechMarkers("[BLANK_AUDIO]"))
    #expect(WhisperCLIASREngine.containsOnlyNonSpeechMarkers(" (silence) "))
    #expect(WhisperCLIASREngine.containsOnlyNonSpeechMarkers("[BLANK_AUDIO] [Music] ♪"))
    #expect(WhisperCLIASREngine.containsOnlyNonSpeechMarkers("（无声）"))
    #expect(!WhisperCLIASREngine.containsOnlyNonSpeechMarkers("[BLANK_AUDIO] hello"))
    #expect(!WhisperCLIASREngine.containsOnlyNonSpeechMarkers("hello world"))
    #expect(!WhisperCLIASREngine.containsOnlyNonSpeechMarkers("明天开会 (上午)"))
}

@Test func localProcessDrainsLargeOutputWithoutDeadlock() async throws {
    // Both streams write well past the 64KB pipe buffer; a serial
    // read-after-wait implementation would deadlock here.
    let script = "BEGIN { for (i = 0; i < 20000; i++) { print \"0123456789ABCDEF\"; print \"E0123456789ABCDE\" > \"/dev/stderr\" } }"

    let result = try await DeadlineRunner.run(deadlineMS: 30_000) {
        try await LocalProcess.run(executablePath: "/usr/bin/awk", arguments: [script])
    }

    let unwrapped = try #require(result)
    #expect(unwrapped.exitCode == 0)
    #expect(unwrapped.standardOutput.count > 128_000)
    #expect(unwrapped.standardError.count > 128_000)
}
#endif

@Test func composeDeadlineDegradesToRuleTierInsteadOfBlocking() async throws {
    let slowEngine = OllamaTextIntelligenceEngine(
        client: OllamaLocalClient(endpoint: URL(string: "http://example.com/api/generate")!)
    )

    let result = try await slowEngine.compose(
        ComposeRequest(
            text: "please   confirm the agenda",
            mode: .translate,
            sourceLanguage: "en",
            targetLanguage: "zh",
            context: ContextSnapshot(appBundle: "tests", mode: .translate),
            deadlineMS: 500
        )
    )

    // Remote endpoint is blocked by the network guard, so the LLM tier errors
    // and the rule tier must ship with a warning and review flag.
    #expect(result.polishedText == "please confirm the agenda.")
    #expect(result.targetText == nil)
    #expect(result.engine == "rules")
    #expect(result.reviewRequired)
    #expect(result.warnings.contains { $0.hasPrefix("compose_llm_error") })
}

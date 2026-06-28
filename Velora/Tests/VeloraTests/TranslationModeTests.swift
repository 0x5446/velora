import Testing
@testable import Velora

@Test func bilingualTranslationKeepsSourceAndTargetOnInsert() {
    let mode = TranslationMode(
        sourceLanguage: "zh",
        targetLanguage: "en",
        insertPolicy: .bilingual
    )

    let result = TranslationModeRenderer.render(
        mode: mode,
        sourceText: "明天上午十点我和 Alex 开会，帮我确认一下 agenda。",
        correctedSourceText: "明天上午十点我和 Alex 开会，帮我确认一下 agenda。",
        targetText: "I have a meeting with Alex tomorrow at 10 a.m. Please help me confirm the agenda.",
        glossaryHits: ["agenda"]
    )

    #expect(result.insertText.contains("原文:"))
    #expect(result.insertText.contains("译文:"))
    #expect(result.insertText.contains("明天上午十点"))
    #expect(result.insertText.contains("I have a meeting with Alex"))
    #expect(result.glossaryHits == ["agenda"])
}

@Test func targetOnlyStillDisplaysBilingualReview() {
    let mode = TranslationMode(
        sourceLanguage: "zh",
        targetLanguage: "en",
        insertPolicy: .targetOnly
    )

    let result = TranslationModeRenderer.render(
        mode: mode,
        sourceText: "翻译模式要同时上屏原文和译文。",
        correctedSourceText: "翻译模式要同时上屏原文和译文。",
        targetText: "Translation mode should insert both the source text and the translated text."
    )

    #expect(result.insertText == "Translation mode should insert both the source text and the translated text.")
    #expect(result.displayText.contains("原文:"))
    #expect(result.displayText.contains("译文:"))
}

@Test func reviewCardQuotesSourceText() {
    let mode = TranslationMode(
        sourceLanguage: "zh",
        targetLanguage: "en",
        insertPolicy: .reviewCard
    )

    let result = TranslationModeRenderer.render(
        mode: mode,
        sourceText: "翻译模式要同时上屏原文和译文。",
        correctedSourceText: "翻译模式要同时上屏原文和译文。",
        targetText: "Translation mode should insert both the source text and the translated text."
    )

    #expect(result.insertText.hasPrefix("> 翻译模式要同时上屏原文和译文。"))
    #expect(result.insertText.contains("\n\nTranslation mode should insert"))
}

@Test func preferredLanguageSelectsOnlyOneInsertSide() {
    let mode = TranslationMode(
        sourceLanguage: "en",
        targetLanguage: "zh",
        insertPolicy: .bilingual
    )

    let result = TranslationModeRenderer.render(
        mode: mode,
        sourceText: "Please confirm the agenda.",
        correctedSourceText: "Please confirm the agenda.",
        targetText: "请确认议程。"
    )

    #expect(result.insertText(preferredLanguage: "zh") == "请确认议程。")
    #expect(result.insertText(preferredLanguage: "en") == "Please confirm the agenda.")
}

@Test func resolverReversesEnglishInputInsideChineseEnglishPair() {
    let direction = TranslationLanguageResolver.resolvedDirection(
        text: "Please confirm the agenda.",
        configuredSourceLanguage: "zh",
        configuredTargetLanguage: "en"
    )

    #expect(direction.sourceLanguage == "en")
    #expect(direction.targetLanguage == "zh")
}

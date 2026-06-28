import Testing
@testable import Velora

@Test func firstLaunchHasNoPermissionPrompts() throws {
    let journey = try #require(
        AuthorizationFlow.defaultJourneys.first { $0.name == "first_launch" }
    )
    let report = AuthorizationFlow.report(for: journey)

    #expect(report.systemPromptCount == 0)
    #expect(report.issues.isEmpty)
}

@Test func defaultRecordingOnlyPromptsForMicrophone() throws {
    let journey = try #require(
        AuthorizationFlow.defaultJourneys.first { $0.name == "default_record_with_local_asr" }
    )
    let report = AuthorizationFlow.report(for: journey)

    #expect(report.systemPromptCount == 1)
    #expect(journey.events.map(\.name) == [.microphone])
    #expect(report.issues.isEmpty)
}

@Test func appleSpeechPermissionIsNotOnDefaultPath() throws {
    let speechJourney = try #require(
        AuthorizationFlow.defaultJourneys.first { $0.name == "optional_apple_speech_engine" }
    )

    #expect(!speechJourney.defaultPath)
    #expect(speechJourney.events.map(\.name) == [.speechRecognition])
}

@Test func keyboardFullAccessIsOptionalAndHasFallback() throws {
    let keyboardJourney = try #require(
        AuthorizationFlow.defaultJourneys.first { $0.name == "optional_fast_insert_keyboard" }
    )

    let fullAccess = try #require(
        keyboardJourney.events.first { $0.name == .keyboardFullAccess }
    )

    #expect(!keyboardJourney.defaultPath)
    #expect(fullAccess.systemPrompt)
    #expect(!fullAccess.fallback.isEmpty)
    #expect(AuthorizationFlow.validate(keyboardJourney).isEmpty)
}

@Test func allPermissionEventsHaveFallbacks() {
    let reports = AuthorizationFlow.defaultJourneys.map(AuthorizationFlow.report)

    #expect(reports.allSatisfy { $0.issues.isEmpty })
}

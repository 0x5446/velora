import Foundation

public enum PermissionName: String, Codable, Sendable, Equatable {
    case microphone
    case speechRecognition = "speech_recognition"
    case addKeyboard = "add_keyboard"
    case keyboardFullAccess = "keyboard_full_access"
    case contacts
    case calendar
    case notifications
}

public struct PermissionEvent: Codable, Sendable, Equatable {
    public var name: PermissionName
    public var systemPrompt: Bool
    public var timing: String
    public var reason: String
    public var fallback: String

    public init(
        name: PermissionName,
        systemPrompt: Bool,
        timing: String,
        reason: String,
        fallback: String
    ) {
        self.name = name
        self.systemPrompt = systemPrompt
        self.timing = timing
        self.reason = reason
        self.fallback = fallback
    }
}

public struct AuthorizationJourney: Codable, Sendable, Equatable {
    public var name: String
    public var defaultPath: Bool
    public var events: [PermissionEvent]
    public var maxPromptsBeforeFirstValue: Int
    public var maxPromptsInSingleStep: Int

    public init(
        name: String,
        defaultPath: Bool,
        events: [PermissionEvent],
        maxPromptsBeforeFirstValue: Int,
        maxPromptsInSingleStep: Int
    ) {
        self.name = name
        self.defaultPath = defaultPath
        self.events = events
        self.maxPromptsBeforeFirstValue = maxPromptsBeforeFirstValue
        self.maxPromptsInSingleStep = maxPromptsInSingleStep
    }
}

public struct AuthorizationJourneyReport: Codable, Sendable, Equatable {
    public var name: String
    public var defaultPath: Bool
    public var systemPromptCount: Int
    public var issues: [String]
}

public enum AuthorizationFlow {
    public static let defaultJourneys = [
        AuthorizationJourney(
            name: "first_launch",
            defaultPath: true,
            events: [],
            maxPromptsBeforeFirstValue: 0,
            maxPromptsInSingleStep: 0
        ),
        AuthorizationJourney(
            name: "default_record_with_local_asr",
            defaultPath: true,
            events: [
                PermissionEvent(
                    name: .microphone,
                    systemPrompt: true,
                    timing: "on_first_record_tap",
                    reason: "capture speech audio locally",
                    fallback: "manual text input, import audio later, or open Settings"
                ),
            ],
            maxPromptsBeforeFirstValue: 1,
            maxPromptsInSingleStep: 1
        ),
        AuthorizationJourney(
            name: "optional_apple_speech_engine",
            defaultPath: false,
            events: [
                PermissionEvent(
                    name: .speechRecognition,
                    systemPrompt: true,
                    timing: "only_after_user_selects_apple_speech_engine",
                    reason: "use Apple Speech recognition backend",
                    fallback: "switch back to WhisperKit/local ASR engine"
                ),
            ],
            maxPromptsBeforeFirstValue: 0,
            maxPromptsInSingleStep: 1
        ),
        AuthorizationJourney(
            name: "optional_fast_insert_keyboard",
            defaultPath: false,
            events: [
                PermissionEvent(
                    name: .addKeyboard,
                    systemPrompt: false,
                    timing: "after_user_enables_fast_insert",
                    reason: "let the user insert recent results inside other apps",
                    fallback: "copy/share result from main app"
                ),
                PermissionEvent(
                    name: .keyboardFullAccess,
                    systemPrompt: true,
                    timing: "only_for_app_group_result_sharing",
                    reason: "keyboard reads the latest result from the containing app",
                    fallback: "keyboard can open the main app, or user can paste from clipboard"
                ),
            ],
            maxPromptsBeforeFirstValue: 0,
            maxPromptsInSingleStep: 1
        ),
        AuthorizationJourney(
            name: "optional_context_personalization",
            defaultPath: false,
            events: [
                PermissionEvent(
                    name: .contacts,
                    systemPrompt: true,
                    timing: "only_after_user_enables_people_names",
                    reason: "improve local recognition of names",
                    fallback: "manual hotword list"
                ),
                PermissionEvent(
                    name: .calendar,
                    systemPrompt: true,
                    timing: "only_after_user_enables_meeting_terms",
                    reason: "improve local recognition of meeting names",
                    fallback: "manual hotword list"
                ),
            ],
            maxPromptsBeforeFirstValue: 0,
            maxPromptsInSingleStep: 1
        ),
    ]

    public static func report(for journey: AuthorizationJourney) -> AuthorizationJourneyReport {
        AuthorizationJourneyReport(
            name: journey.name,
            defaultPath: journey.defaultPath,
            systemPromptCount: systemPromptCount(in: journey),
            issues: validate(journey)
        )
    }

    public static func systemPromptCount(in journey: AuthorizationJourney) -> Int {
        journey.events.filter(\.systemPrompt).count
    }

    public static func validate(_ journey: AuthorizationJourney) -> [String] {
        var issues: [String] = []
        let promptCount = systemPromptCount(in: journey)

        if journey.defaultPath && journey.name == "first_launch" && promptCount != 0 {
            issues.append("first_launch_must_not_prompt")
        }

        if journey.defaultPath && promptCount > journey.maxPromptsBeforeFirstValue {
            issues.append("too_many_prompts_before_first_value")
        }

        if journey.maxPromptsInSingleStep > 1 {
            issues.append("single_step_prompt_stack_not_allowed")
        }

        for event in journey.events where event.fallback.isEmpty {
            issues.append("missing_fallback:\(event.name.rawValue)")
        }

        return issues
    }
}

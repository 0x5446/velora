import Foundation

public enum VeloraPlatform: String, Codable, Sendable, Equatable {
    case macOS = "macos"
    case iOS = "ios"
}

public enum DictationMode: String, Codable, Sendable, Equatable, CaseIterable {
    case input
    case translate

    /// Accepts legacy stored/CLI values: dictate/polish collapse into input.
    public static func normalize(_ raw: String) -> DictationMode? {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "input", "dictate", "polish":
            return .input
        case "translate":
            return .translate
        default:
            return nil
        }
    }

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        guard let mode = DictationMode.normalize(raw) else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Unknown DictationMode value: \(raw)"
                )
            )
        }
        self = mode
    }
}

public struct LatencyStage: Codable, Sendable, Equatable {
    public var name: String
    public var durationMS: Int
    public var phase: String
    public var critical: Bool
    public var note: String

    public init(
        name: String,
        durationMS: Int,
        phase: String,
        critical: Bool,
        note: String
    ) {
        self.name = name
        self.durationMS = durationMS
        self.phase = phase
        self.critical = critical
        self.note = note
    }
}

public struct LatencyScenario: Codable, Sendable, Equatable {
    public var name: String
    public var platform: VeloraPlatform
    public var mode: DictationMode
    public var targetP50MS: Int
    public var targetP95MS: Int
    public var preReleaseStages: [LatencyStage]
    public var releaseStages: [LatencyStage]
    public var coldStartPenaltyMS: Int

    public init(
        name: String,
        platform: VeloraPlatform,
        mode: DictationMode,
        targetP50MS: Int,
        targetP95MS: Int,
        preReleaseStages: [LatencyStage],
        releaseStages: [LatencyStage],
        coldStartPenaltyMS: Int
    ) {
        self.name = name
        self.platform = platform
        self.mode = mode
        self.targetP50MS = targetP50MS
        self.targetP95MS = targetP95MS
        self.preReleaseStages = preReleaseStages
        self.releaseStages = releaseStages
        self.coldStartPenaltyMS = coldStartPenaltyMS
    }
}

public struct LatencyReport: Codable, Sendable, Equatable {
    public var scenarioName: String
    public var estimatedP50MS: Int
    public var estimatedP95MS: Int
    public var coldStartP50MS: Int
    public var targetP50MS: Int
    public var targetP95MS: Int
    public var passesWarmPath: Bool
    public var passesColdPath: Bool
    public var criticalPathMS: [String: Int]
}

public enum LatencyBudget {
    public static let requiredArchitecture = [
        "Prewarm ASR and text engines before recording starts.",
        "Run context capture and hotword ranking while the user is speaking.",
        "Use streaming ASR partials and speculative compose before release.",
        "Keep large LLM generation off the default critical path.",
        "Insert first, then offer background improvement when quality work is slow.",
        "Record per-stage latency for every session.",
    ]

    public static let commonPreReleaseStages = [
        LatencyStage(
            name: "engine_prewarm",
            durationMS: 0,
            phase: "before_recording",
            critical: false,
            note: "Models must already be resident."
        ),
        LatencyStage(
            name: "context_capture",
            durationMS: 28,
            phase: "during_recording",
            critical: false,
            note: "Active app, window, selection, nearby text."
        ),
        LatencyStage(
            name: "hotword_rank",
            durationMS: 14,
            phase: "during_recording",
            critical: false,
            note: "Top K memory terms selected before release."
        ),
        LatencyStage(
            name: "streaming_asr_partial",
            durationMS: 0,
            phase: "during_recording",
            critical: false,
            note: "Partial transcript continuously updated."
        ),
        LatencyStage(
            name: "speculative_compose",
            durationMS: 0,
            phase: "during_recording",
            critical: false,
            note: "Draft compose (polish + optional target language) starts from partial transcript."
        ),
    ]

    public static let defaultScenarios = [
        LatencyScenario(
            name: "macos_input_fast_path",
            platform: .macOS,
            mode: .input,
            targetP50MS: 800,
            targetP95MS: 1_300,
            preReleaseStages: commonPreReleaseStages,
            releaseStages: [
                LatencyStage(name: "vad_flush", durationMS: 30, phase: "after_release", critical: true, note: "Close final audio segment."),
                LatencyStage(name: "asr_finalize", durationMS: 300, phase: "after_release", critical: true, note: "Finalize streaming ASR."),
                LatencyStage(name: "asr_hotword_correction", durationMS: 60, phase: "after_release", critical: true, note: "Hotword pass inside the ASR capability boundary."),
                LatencyStage(name: "compose", durationMS: 250, phase: "after_release", critical: true, note: "Mandatory tiered polish; LLM must return within deadline or rules win."),
                LatencyStage(name: "render_insert_text", durationMS: 8, phase: "after_release", critical: true, note: "Build insertion payload."),
                LatencyStage(name: "insert_text", durationMS: 36, phase: "after_release", critical: true, note: "IMK/AX/pasteboard insertion."),
            ],
            coldStartPenaltyMS: 1_400
        ),
        LatencyScenario(
            name: "macos_translate_fast_path",
            platform: .macOS,
            mode: .translate,
            targetP50MS: 1_000,
            targetP95MS: 1_800,
            preReleaseStages: commonPreReleaseStages,
            releaseStages: [
                LatencyStage(name: "vad_flush", durationMS: 30, phase: "after_release", critical: true, note: "Close final audio segment."),
                LatencyStage(name: "asr_finalize", durationMS: 300, phase: "after_release", critical: true, note: "Finalize streaming ASR."),
                LatencyStage(name: "asr_hotword_correction", durationMS: 60, phase: "after_release", critical: true, note: "Hotword pass inside the ASR capability boundary."),
                LatencyStage(name: "compose_bilingual", durationMS: 420, phase: "after_release", critical: true, note: "Single LLM call emits polished source plus target language."),
                LatencyStage(name: "render_bilingual_text", durationMS: 12, phase: "after_release", critical: true, note: "Source + target render."),
                LatencyStage(name: "insert_text", durationMS: 42, phase: "after_release", critical: true, note: "IMK/AX/pasteboard insertion."),
            ],
            coldStartPenaltyMS: 2_200
        ),
        LatencyScenario(
            name: "ios_translate_bridge_path",
            platform: .iOS,
            mode: .translate,
            targetP50MS: 1_600,
            targetP95MS: 2_600,
            preReleaseStages: commonPreReleaseStages + [
                LatencyStage(name: "keyboard_bridge_prepare", durationMS: 0, phase: "during_recording", critical: false, note: "Prepare App Group output slot."),
            ],
            releaseStages: [
                LatencyStage(name: "vad_flush", durationMS: 40, phase: "after_release", critical: true, note: "Close final audio segment."),
                LatencyStage(name: "asr_finalize", durationMS: 360, phase: "after_release", critical: true, note: "Finalize mobile ASR."),
                LatencyStage(name: "asr_hotword_correction", durationMS: 80, phase: "after_release", critical: true, note: "Hotword pass inside the ASR capability boundary."),
                LatencyStage(name: "compose_bilingual", durationMS: 560, phase: "after_release", critical: true, note: "Single call emits polished source plus target language."),
                LatencyStage(name: "write_app_group_result", durationMS: 30, phase: "after_release", critical: true, note: "Make result visible to keyboard."),
                LatencyStage(name: "keyboard_insert_text", durationMS: 90, phase: "after_release", critical: true, note: "User returns and taps insert."),
            ],
            coldStartPenaltyMS: 2_400
        ),
    ]

    public static func report(for scenario: LatencyScenario) -> LatencyReport {
        let p50 = releaseLatencyMS(for: scenario)
        let p95 = p95EstimateMS(for: scenario)
        let coldP50 = p50 + scenario.coldStartPenaltyMS
        let criticalPath = Dictionary(
            uniqueKeysWithValues: scenario.releaseStages
                .filter(\.critical)
                .map { ($0.name, $0.durationMS) }
        )

        return LatencyReport(
            scenarioName: scenario.name,
            estimatedP50MS: p50,
            estimatedP95MS: p95,
            coldStartP50MS: coldP50,
            targetP50MS: scenario.targetP50MS,
            targetP95MS: scenario.targetP95MS,
            passesWarmPath: p50 <= scenario.targetP50MS && p95 <= scenario.targetP95MS,
            passesColdPath: coldP50 <= scenario.targetP50MS,
            criticalPathMS: criticalPath
        )
    }

    public static func releaseLatencyMS(for scenario: LatencyScenario) -> Int {
        scenario.releaseStages
            .filter(\.critical)
            .map(\.durationMS)
            .reduce(0, +)
    }

    public static func p95EstimateMS(for scenario: LatencyScenario) -> Int {
        let platformJitter: Int = switch scenario.platform {
        case .macOS: 220
        case .iOS: 420
        }

        let modeExtra: Int = switch scenario.mode {
        case .input: 120
        case .translate: 180
        }

        return releaseLatencyMS(for: scenario) + platformJitter + modeExtra
    }
}

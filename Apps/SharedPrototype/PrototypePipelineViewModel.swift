import Combine
import Foundation
import Velora

@MainActor
final class PrototypePipelineViewModel: ObservableObject {
    @Published var mode: DictationMode = .input {
        didSet { persistRuntimeSettingsFromView() }
    }
    @Published var insertPolicy: InsertPolicy = .bilingual {
        didSet { persistRuntimeSettingsFromView() }
    }
    @Published var preferredInsertLanguage = "zh" {
        didSet {
            // Reassign only when normalization actually changes the value —
            // an unconditional self-assignment here recurses until stack overflow.
            let normalized = TranslationLanguageResolver.normalizedLanguage(preferredInsertLanguage)
            guard normalized == preferredInsertLanguage else {
                preferredInsertLanguage = normalized
                return
            }
            persistRuntimeSettingsFromView()
        }
    }
    @Published var sampleText = "明天上午十点我和 Alex 开会，帮我确认一下 agenda"
    @Published var sourceLanguage = "zh" {
        didSet { persistRuntimeSettingsFromView() }
    }
    @Published var targetLanguage = "en" {
        didSet { persistRuntimeSettingsFromView() }
    }
    @Published var asrModelMode: WhisperModelMode = .fromEnvironment(ProcessInfo.processInfo.environment) {
        didSet { persistRuntimeSettingsFromView() }
    }
    @Published var outputText = ""
    @Published var diagnostics = ""
    @Published var keyboardCandidateStatus = ""
    @Published var isRunning = false

    private let settingsStore: VeloraSettingsStore
    private var isApplyingRuntimeSettings = false
    private var latestResult: PipelineRunResult?
    private var prewarmedWhisperModes = Set<WhisperModelMode>()

    init(settingsStore: VeloraSettingsStore = .shared) {
        self.settingsStore = settingsStore
        applyRuntimeSettings(settingsStore.load())
    }

    var modeOptions: [DictationMode] {
        [.input, .translate]
    }

    var insertPolicyOptions: [InsertPolicy] {
        [.bilingual, .targetOnly, .reviewCard]
    }

    var insertLanguageOptions: [String] {
        Array(Set([sourceLanguage, targetLanguage, preferredInsertLanguage].map(TranslationLanguageResolver.normalizedLanguage)))
            .sorted { lhs, rhs in
                if lhs == "zh" { return true }
                if rhs == "zh" { return false }
                return lhs < rhs
            }
    }

    var asrModelModeOptions: [WhisperModelMode] {
        WhisperModelMode.allCases
    }

    var runtimeSettingsSummary: String {
        currentRuntimeSettings.displaySummary
    }

    func reloadRuntimeSettings() {
        applyRuntimeSettings(settingsStore.load())
    }

    func run(platform: VeloraPlatform) {
        runPipeline(
            platform: platform,
            sampleText: sampleText,
            audioPath: nil,
            asrEngine: FakeASREngine()
        )
    }

    func prewarmLocalModels() async {
        await prewarmLocalModels(for: asrModelMode)
    }

    func prewarmLocalModels(for mode: WhisperModelMode) async {
        guard !prewarmedWhisperModes.contains(mode) else {
            return
        }

        prewarmedWhisperModes.insert(mode)
        diagnostics = "warming_local_models mode=\(mode.rawValue)"

        #if os(macOS)
        let results = await LocalModelPrewarmer.prewarmForMac(
            whisper: .configuration(for: mode)
        )
        #else
        let results = await LocalModelPrewarmer.prewarmForMac()
        #endif
        diagnostics = results
            .map { result in
                "\(result.component)=\(result.ok ? "ready" : "error") \(result.latencyMS)ms \(result.detail)"
            }
            .joined(separator: "\n")
    }

    func runAudio(platform: VeloraPlatform, audioPath: String) {
        runPipeline(
            platform: platform,
            sampleText: "",
            audioPath: audioPath,
            asrEngine: Self.makeAudioASREngine(sourceLanguage: sourceLanguage, modelMode: asrModelMode)
        )
    }

    func copyOutput() {
        #if os(macOS)
        MacClipboard.write(outputText)
        #elseif os(iOS)
        UIPasteboardBridge.write(outputText)
        #endif
    }

    func writeKeyboardCandidate() {
        guard let latestResult else {
            keyboardCandidateStatus = "no_result"
            return
        }

        writeKeyboardCandidate(from: latestResult)
    }

    private func runPipeline(
        platform: VeloraPlatform,
        sampleText: String,
        audioPath: String?,
        asrEngine: any ASREngine
    ) {
        isRunning = true
        keyboardCandidateStatus = ""

        Task {
            do {
                let result = try await Self.makePipeline(asrEngine: asrEngine).run(
                    PipelineRunRequest(
                        platform: platform,
                        mode: mode,
                        sampleText: sampleText,
                        audioPath: audioPath,
                        sourceLanguage: sourceLanguage,
                        targetLanguage: mode == .translate ? targetLanguage : nil,
                        insertPolicy: insertPolicy,
                        preferredInsertLanguage: preferredInsertLanguage
                    )
                )

                outputText = result.finalText
                diagnostics = Self.renderDiagnostics(result)
                latestResult = result
                if platform == .iOS {
                    writeKeyboardCandidate(from: result)
                }
                isRunning = false
            } catch {
                outputText = ""
                diagnostics = "error=\(VeloraErrorPresenter.message(for: error))"
                latestResult = nil
                isRunning = false
            }
        }
    }

    private func writeKeyboardCandidate(from result: PipelineRunResult) {
        do {
            let payload = KeyboardBridgePayload.from(result)
            try KeyboardBridgeStore.defaultStore().save(payload)
            keyboardCandidateStatus = payload.isTranslation ? "translation_payload_ready" : "payload_ready"
        } catch {
            keyboardCandidateStatus = "payload_error=\(error)"
        }
    }

    private static func makePipeline(asrEngine: any ASREngine) -> PipelineOrchestrator {
        PipelineOrchestrator(
            asrEngine: asrEngine,
            contextProvider: StaticContextProvider(),
            memoryStore: InMemoryHotwordStore(),
            textEngine: OllamaTextIntelligenceEngine(),
            translationEngine: OllamaTranslationEngine(),
            insertionEngine: NoopInsertionEngine()
        )
    }

    private static func makeAudioASREngine(sourceLanguage: String, modelMode: WhisperModelMode) -> any ASREngine {
        #if os(macOS)
        return WhisperCLIASREngine(configuration: .configuration(for: modelMode))
        #else
        return FakeASREngine()
        #endif
    }

    private var currentRuntimeSettings: VeloraRuntimeSettings {
        VeloraRuntimeSettings(
            mode: mode,
            sourceLanguage: sourceLanguage,
            targetLanguage: targetLanguage,
            insertPolicy: insertPolicy,
            preferredInsertLanguage: preferredInsertLanguage,
            asrModelMode: asrModelMode
        )
    }

    private func applyRuntimeSettings(_ settings: VeloraRuntimeSettings) {
        guard currentRuntimeSettings != settings else {
            return
        }

        isApplyingRuntimeSettings = true
        mode = settings.mode
        sourceLanguage = settings.sourceLanguage
        targetLanguage = settings.targetLanguage
        insertPolicy = settings.insertPolicy
        preferredInsertLanguage = settings.preferredInsertLanguage
        asrModelMode = settings.asrModelMode
        isApplyingRuntimeSettings = false
    }

    private func persistRuntimeSettingsFromView() {
        guard !isApplyingRuntimeSettings else {
            return
        }

        settingsStore.save(currentRuntimeSettings)
    }

    private static func renderDiagnostics(_ result: PipelineRunResult) -> String {
        let hotwords = result.correction.selectedHotwords
            .prefix(4)
            .map { "\($0.replacement)=\(String(format: "%.1f", $0.score))" }
            .joined(separator: ", ")

        return [
            "engine=\(result.asr.engine)",
            "compose_engine=\(result.compose.engine)",
            "mode=\(result.session.mode.rawValue)",
            "review_required=\(result.reviewRequired)",
            "warnings=\(result.compose.warnings.joined(separator: ","))",
            "release_to_insert_ms=\(result.trace.releaseToInsertMS)",
            "stages=\(Self.renderStageTimings(result.trace))",
            "hotwords=\(hotwords)",
        ].joined(separator: "\n")
    }

    private static func renderStageTimings(_ trace: PipelineTrace) -> String {
        trace.stages
            .map { "\($0.name):\($0.durationMS)ms" }
            .joined(separator: ",")
    }
}

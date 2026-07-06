import AppKit
import ApplicationServices
import AVFoundation
import Velora
import SwiftUI

private enum MacProductCopy {
    static let name = "Velora"
    static let subtitle = "本地语音输入"
}

@main
struct VeloraMacApp: App {
    @NSApplicationDelegateAdaptor(MacAppDelegate.self) private var appDelegate

    var body: some Scene {
        // Menu-bar accessory app: the settings window is owned and presented
        // by MacAppDelegate, so nothing may auto-open at launch. A Settings
        // scene never self-presents; it exists only to satisfy SwiftUI.
        // Removing the appSettings command keeps the synthesized ⌘, from
        // opening this empty scene while our own window is key.
        Settings {
            EmptyView()
        }
        .commands {
            CommandGroup(replacing: .appSettings) {}
        }
    }
}

/// Product settings panel. Everything a user needs lives in three groups
/// (快捷键 / 翻译 / 权限异常时的修复入口); every debugging surface is behind
/// the developer-mode toggle.
struct MacSettingsView: View {
    @StateObject private var viewModel = PrototypePipelineViewModel()
    @StateObject private var hotKeys = MacHotKeySettingsModel()
    @StateObject private var audioRecorder = MacAudioRecorderViewModel()
    @ObservedObject private var developerMode = MacDeveloperModeStore.shared
    @State private var accessibilityTrusted = AXIsProcessTrusted()
    @State private var microphoneStatus = AVCaptureDevice.authorizationStatus(for: .audio)
    @State private var systemProbeStatus = ""
    @AppStorage(OllamaLocalClient.residentKeepAliveDefaultsKey) private var keepModelResident = false

    var body: some View {
        Form {
            hotkeySection
            translationSection
            performanceSection
            if needsAttention {
                attentionSection
            }
            aboutSection
            if developerMode.isEnabled {
                developerRuntimeSection
                developerActionSection
                textLabSection
                diagnosticsSection
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .frame(height: developerMode.isEnabled ? 860 : 560)
        .onAppear {
            refreshPermissions()
        }
        // Event-driven permission refresh: the window regains key exactly when
        // the user returns from System Settings after granting access.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            refreshPermissions()
        }
        .onReceive(NotificationCenter.default.publisher(for: VeloraSettingsStore.didChangeNotification)) { _ in
            viewModel.reloadRuntimeSettings()
        }
        .onReceive(NotificationCenter.default.publisher(for: MacHotKeyStore.didChangeNotification)) { _ in
            hotKeys.reload()
        }
        .onChange(of: viewModel.asrModelMode) { _, newMode in
            Task {
                await viewModel.prewarmLocalModels(for: newMode)
            }
        }
        .onChange(of: viewModel.targetLanguage) { _, newTarget in
            // Keep "上屏译文" pointing at the newly chosen target language.
            if insertSide == .target {
                viewModel.preferredInsertLanguage = newTarget
            }
        }
    }

    // MARK: - Product sections

    private var hotkeySection: some View {
        Section {
            Picker("听写", selection: $hotKeys.capturePreset) {
                ForEach(MacHotKeyPreset.allCases) { preset in
                    Text(preset.displayName).tag(preset)
                }
            }
            Picker("翻译", selection: $hotKeys.translatePreset) {
                ForEach(MacHotKeyPreset.allCases) { preset in
                    Text(preset.displayName).tag(preset)
                }
            }
            if let conflict = MacHotKeyConflictDetector.functionKeyConflict(for: hotKeys.preferences) {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Color.veloraAccent)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(conflict.title)
                            .font(VeloraFont.body(12, weight: .semibold))
                            .foregroundStyle(Color.veloraInkPrimary)
                        Text(conflict.detail)
                            .font(VeloraFont.caption(11))
                            .foregroundStyle(Color.veloraInkSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    Button("改用 ⌥ Space") {
                        hotKeys.useSpaceFallback()
                    }
                    .controlSize(.small)
                }
            }
        } header: {
            Text("快捷键")
        } footer: {
            Text("按一下开始说话，再按一下结束并上屏。")
        }
    }

    private var translationSection: some View {
        Section {
            Picker("目标语言", selection: targetLanguageBinding) {
                ForEach(targetLanguageOptions, id: \.self) { code in
                    Text(TranslationLanguageResolver.displayName(for: code)).tag(code)
                }
            }
            Picker("确认后上屏", selection: insertSideBinding) {
                Text("译文").tag(MacInsertSide.target)
                Text("原文").tag(MacInsertSide.source)
            }
            .pickerStyle(.segmented)
        } header: {
            Text("翻译")
        } footer: {
            Text("按 \(hotKeys.translatePreset.displayName) 说话，结果先出确认卡片；确认后只上屏所选一侧，可在卡片上临时改选。")
        }
    }

    private var performanceSection: some View {
        Section {
            Toggle("润色模型常驻内存", isOn: $keepModelResident)
                .onChange(of: keepModelResident) { _, enabled in
                    if enabled {
                        // Pin the model right away instead of on the next
                        // dictation — the toggle should feel immediate.
                        Task {
                            try? await OllamaLocalClient().prewarm()
                        }
                    }
                }
        } header: {
            Text("性能")
        } footer: {
            Text("开启后模型常驻内存（约 6GB），闲置多久后的第一次上屏都无需等待模型加载。关闭时，Velora 会在你开始说话的同时预热模型来掩盖加载耗时。")
        }
    }

    private var attentionSection: some View {
        Section("需要处理") {
            if !accessibilityTrusted {
                LabeledContent {
                    Button("打开设置") {
                        openPrivacyPane("Privacy_Accessibility")
                    }
                } label: {
                    Text("无障碍权限")
                    Text("Velora 需要它才能把文字放进当前光标处")
                }
            }
            if microphoneBlocked {
                LabeledContent {
                    Button("打开设置") {
                        openPrivacyPane("Privacy_Microphone")
                    }
                } label: {
                    Text("麦克风权限")
                    Text("仅在你按下快捷键时录音")
                }
            }
        }
    }

    private var aboutSection: some View {
        Section {
            Toggle("开发者模式", isOn: $developerMode.isEnabled)
        } footer: {
            VStack(alignment: .leading, spacing: 3) {
                Text("识别、润色与翻译全部在本机完成，音频与文本不会离开这台 Mac。")
                Text("\(MacProductCopy.name) \(appVersion)")
                    .foregroundStyle(Color.veloraInkSecondary.opacity(0.7))
            }
        }
    }

    // MARK: - Developer sections

    private var developerRuntimeSection: some View {
        Section("开发者 · 运行时") {
            Picker("模式", selection: $viewModel.mode) {
                ForEach(viewModel.modeOptions, id: \.rawValue) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            TextField("源语言", text: $viewModel.sourceLanguage)
            TextField("目标语言（自由填写）", text: $viewModel.targetLanguage)
            Picker("ASR 档位", selection: $viewModel.asrModelMode) {
                ForEach(viewModel.asrModelModeOptions, id: \.rawValue) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            LabeledContent("运行时") {
                Text(viewModel.runtimeSettingsSummary)
                    .font(VeloraFont.mono(11))
                    .textSelection(.enabled)
            }
        }
    }

    private var developerActionSection: some View {
        Section("开发者 · 动作") {
            HStack(spacing: 10) {
                Button(audioRecorder.isRecording ? "停止录音测试" : "录音测试") {
                    audioRecorder.toggleRecording { clip in
                        viewModel.runAudio(platform: .macOS, audioPath: clip.url.path)
                    }
                }
                Button("插入探针文本") {
                    insertProbe()
                }
                Button("检查无障碍") {
                    systemProbeStatus = "accessibility_trusted=\(AXIsProcessTrusted()) pid=\(ProcessInfo.processInfo.processIdentifier)"
                }
            }
            Text([audioRecorder.status, systemProbeStatus].filter { !$0.isEmpty }.joined(separator: " · "))
                .font(VeloraFont.mono(11))
                .foregroundStyle(Color.veloraInkSecondary)
                .textSelection(.enabled)
        }
    }

    private var textLabSection: some View {
        Section("文本实验室") {
            MacTextEditorPanel(title: "输入", text: $viewModel.sampleText, minHeight: 84)
            MacTextEditorPanel(title: "输出", text: $viewModel.outputText, minHeight: 84)
            HStack(spacing: 10) {
                Button(viewModel.isRunning ? "处理中…" : "运行文本测试") {
                    viewModel.run(platform: .macOS)
                }
                .disabled(viewModel.isRunning)
                Button("复制输出") {
                    viewModel.copyOutput()
                }
                .disabled(viewModel.outputText.isEmpty)
            }
        }
    }

    private var diagnosticsSection: some View {
        Section("诊断") {
            Text(viewModel.diagnostics.isEmpty ? "ready" : viewModel.diagnostics)
                .font(VeloraFont.mono(11))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Helpers

    private enum MacInsertSide: Hashable {
        case source
        case target
    }

    private var insertSide: MacInsertSide {
        TranslationLanguageResolver.normalizedLanguage(viewModel.preferredInsertLanguage)
            == TranslationLanguageResolver.normalizedLanguage(viewModel.sourceLanguage)
            ? .source
            : .target
    }

    private var insertSideBinding: Binding<MacInsertSide> {
        Binding(
            get: { insertSide },
            set: { side in
                viewModel.preferredInsertLanguage = side == .source
                    ? viewModel.sourceLanguage
                    : viewModel.targetLanguage
            }
        )
    }

    /// Normalizes whatever is stored (developer mode allows free-form codes)
    /// so the product picker always has a valid selection.
    private var targetLanguageBinding: Binding<String> {
        Binding(
            get: { TranslationLanguageResolver.normalizedLanguage(viewModel.targetLanguage) },
            set: { viewModel.targetLanguage = $0 }
        )
    }

    private var targetLanguageOptions: [String] {
        // The source language is excluded: translating into the language you
        // spoke is meaningless, and offering it would make the 原文/译文
        // distinction ambiguous.
        let source = TranslationLanguageResolver.normalizedLanguage(viewModel.sourceLanguage)
        var options = ["en", "zh", "ja", "ko"].filter { $0 != source }
        let current = TranslationLanguageResolver.normalizedLanguage(viewModel.targetLanguage)
        if !options.contains(current) {
            options.append(current)
        }
        return options
    }

    private var needsAttention: Bool {
        !accessibilityTrusted || microphoneBlocked
    }

    private var microphoneBlocked: Bool {
        microphoneStatus == .denied || microphoneStatus == .restricted
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    }

    private func refreshPermissions() {
        accessibilityTrusted = AXIsProcessTrusted()
        microphoneStatus = AVCaptureDevice.authorizationStatus(for: .audio)
    }

    private func openPrivacyPane(_ pane: String) {
        NSWorkspace.shared.open(
            URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!
        )
    }

    private func insertProbe() {
        let text = "\(MacProductCopy.name) app window probe \(Int(Date().timeIntervalSince1970))"
        switch MacPasteboardInserter.insert(text) {
        case .inserted:
            systemProbeStatus = "insert_probe_posted text=\(text)"
        case .copiedNeedsAccessibility:
            systemProbeStatus = "copied_needs_accessibility text_in_clipboard=\(text)"
        case .targetUnavailable:
            systemProbeStatus = "target_unavailable text_in_clipboard=\(text)"
        case .failedToWrite:
            systemProbeStatus = "pasteboard_write_failed"
        }
    }
}

struct MacTextEditorPanel: View {
    var title: String
    @Binding var text: String
    var minHeight: CGFloat
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(VeloraFont.body(12, weight: .semibold))
                .foregroundStyle(Color.veloraInkSecondary)
            TextEditor(text: $text)
                .font(VeloraFont.body(13))
                .frame(minHeight: minHeight)
                .scrollContentBackground(.hidden)
                .padding(8)
                .veloraTextEditorStyle(isFocused: isFocused)
                .focused($isFocused)
        }
        .frame(maxWidth: .infinity)
    }
}

private extension DictationMode {
    var displayName: String {
        switch self {
        case .input:
            return "输入"
        case .translate:
            return "翻译"
        }
    }
}

enum MacClipboard {
    static func write(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

@MainActor
final class MacAudioRecorderViewModel: ObservableObject {
    @Published var isRecording = false
    @Published var status = "audio_ready"
    @Published var lastClip: MacRecordedAudioClip?

    private let service = MacAudioCaptureService()

    func toggleRecording(onFinished: @escaping @MainActor (MacRecordedAudioClip) -> Void) {
        if isRecording {
            stopRecording(onFinished: onFinished)
        } else {
            startRecording()
        }
    }

    private func startRecording() {
        status = "requesting_microphone"

        Task {
            do {
                let url = try await service.start()
                isRecording = true
                lastClip = nil
                status = "recording=\(url.lastPathComponent)"
            } catch {
                isRecording = false
                status = "audio_error=\(error)"
            }
        }
    }

    private func stopRecording(onFinished: @escaping @MainActor (MacRecordedAudioClip) -> Void) {
        guard let clip = service.stop() else {
            isRecording = false
            status = "audio_ready"
            return
        }

        isRecording = false
        lastClip = clip
        status = "audio_saved=\(clip.url.lastPathComponent) duration=\(String(format: "%.2f", clip.durationSeconds))s transcribing"
        onFinished(clip)
    }
}

struct MacRecordedAudioClip {
    var url: URL
    var startedAt: Date
    var endedAt: Date

    var durationSeconds: TimeInterval {
        endedAt.timeIntervalSince(startedAt)
    }
}

enum MacAudioCaptureError: Error {
    case microphoneDenied
    case recordingAlreadyRunning
}

final class MacAudioCaptureService: @unchecked Sendable {
    private let lock = NSLock()
    private var engine: AVAudioEngine?
    private var file: AVAudioFile?
    private var fileURL: URL?
    private var startedAt: Date?
    private var levelHandler: ((Float) -> Void)?

    func setLevelHandler(_ handler: ((Float) -> Void)?) {
        lock.lock()
        levelHandler = handler
        lock.unlock()
    }

    func start() async throws -> URL {
        let granted = await requestMicrophoneAccess()
        guard granted else {
            throw MacAudioCaptureError.microphoneDenied
        }

        return try startRecording()
    }

    func stop() -> MacRecordedAudioClip? {
        lock.lock()
        defer { lock.unlock() }

        guard let engine, let fileURL, let startedAt else {
            return nil
        }

        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        self.engine = nil
        self.file = nil
        self.fileURL = nil
        self.startedAt = nil

        return MacRecordedAudioClip(
            url: fileURL,
            startedAt: startedAt,
            endedAt: Date()
        )
    }

    private func requestMicrophoneAccess() async -> Bool {
        await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    private func startRecording() throws -> URL {
        lock.lock()
        defer { lock.unlock() }

        guard engine == nil else {
            throw MacAudioCaptureError.recordingAlreadyRunning
        }

        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("velora-\(UUID().uuidString)")
            .appendingPathExtension("caf")
        let file = try AVAudioFile(forWriting: url, settings: format.settings)

        input.installTap(onBus: 0, bufferSize: 2_048, format: format) { [weak self] buffer, _ in
            self?.write(buffer)
        }

        try engine.start()

        self.engine = engine
        self.file = file
        self.fileURL = url
        self.startedAt = Date()

        return url
    }

    private func write(_ buffer: AVAudioPCMBuffer) {
        let level = Self.normalizedLevel(from: buffer)
        let handler: ((Float) -> Void)?

        lock.lock()
        try? file?.write(from: buffer)
        handler = levelHandler
        lock.unlock()

        handler?(level)
    }

    private static func normalizedLevel(from buffer: AVAudioPCMBuffer) -> Float {
        guard let channels = buffer.floatChannelData,
              buffer.frameLength > 0 else {
            return 0
        }

        let frameCount = Int(buffer.frameLength)
        let channelCount = max(1, Int(buffer.format.channelCount))
        var sum: Float = 0
        var samples = 0

        for channelIndex in 0..<channelCount {
            let channel = channels[channelIndex]
            for frame in 0..<frameCount {
                let sample = channel[frame]
                sum += sample * sample
            }
            samples += frameCount
        }

        guard samples > 0 else {
            return 0
        }

        let rms = sqrt(sum / Float(samples))
        let decibels = 20 * log10(max(rms, 0.000_01))
        return min(max((decibels + 55) / 45, 0), 1)
    }
}

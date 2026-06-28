import AppKit
import ApplicationServices
import AVFoundation
import Velora
import SwiftUI

private enum MacProductCopy {
    static let name = "Velora"
    static let subtitle = "本地语音输入"
    static var hotKey: String {
        MacHotKeyStore.shared.load().captureDisplayName
    }
    static var translateHotKey: String {
        MacHotKeyStore.shared.load().translateDisplayName
    }
}

@main
struct VeloraMacApp: App {
    @NSApplicationDelegateAdaptor(MacAppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            MacControlCenterView()
                .frame(minWidth: 780, minHeight: 640)
        }
        .windowResizability(.contentMinSize)
    }
}

struct MacControlCenterView: View {
    @StateObject private var viewModel = PrototypePipelineViewModel()
    @StateObject private var audioRecorder = MacAudioRecorderViewModel()
    @StateObject private var hotKeys = MacHotKeySettingsModel()
    @State private var systemProbeStatus = "ready"
    @State private var showDiagnostics = false
    @State private var showTextLab = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    quickCapture
                    shortcutSettings
                    workflowSettings
                    modelAndPermissionStatus
                    textLab
                    diagnostics
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .task {
            await viewModel.prewarmLocalModels()
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
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "waveform.and.mic")
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(.blue)
                .frame(width: 36, height: 36)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(MacProductCopy.name)
                    .font(.system(size: 20, weight: .semibold))
                Text("\(MacProductCopy.subtitle) · \(hotKeys.capturePreset.displayName)")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            MacStatusPill(
                title: modeStatusTitle,
                detail: languagePairStatus,
                systemImage: viewModel.mode.systemImage,
                tint: viewModel.mode.tint
            )

            Button {
                viewModel.run(platform: .macOS)
            } label: {
                if viewModel.isRunning {
                    Label("处理中", systemImage: "hourglass")
                } else {
                    Label("运行文本测试", systemImage: "play.fill")
                }
            }
            .buttonStyle(.bordered)
            .disabled(viewModel.isRunning)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var quickCapture: some View {
        MacControlSection(title: "Capture", subtitle: "日常输入主路径。开始、结束、处理和上屏都保持低打扰。") {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .center, spacing: 14) {
                    ZStack {
                        Circle()
                            .fill(audioRecorder.isRecording ? Color.red.opacity(0.14) : viewModel.mode.tint.opacity(0.12))
                            .frame(width: 52, height: 52)
                        Image(systemName: audioRecorder.isRecording ? "stop.fill" : "mic.fill")
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundStyle(audioRecorder.isRecording ? .red : viewModel.mode.tint)
                    }
                    .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 5) {
                        Text(audioRecorder.isRecording ? "正在听" : "准备好输入")
                            .font(.system(size: 17, weight: .semibold))
                        Text(captureSubtitle)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }

                    Spacer()

                    VStack(alignment: .trailing, spacing: 6) {
                        MacShortcutKeycap(text: hotKeys.capturePreset.displayName)
                        Text(viewModel.mode == .translate ? "翻译确认后上屏" : "处理完成后上屏")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }

                Divider()

                HStack(alignment: .center, spacing: 14) {
                Button {
                    audioRecorder.toggleRecording { clip in
                        viewModel.runAudio(platform: .macOS, audioPath: clip.url.path)
                    }
                } label: {
                    Label(
                        audioRecorder.isRecording ? "停止录音" : "开始录音",
                        systemImage: audioRecorder.isRecording ? "stop.fill" : "mic.fill"
                    )
                    .frame(minWidth: 112)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .tint(audioRecorder.isRecording ? .red : .blue)

                VStack(alignment: .leading, spacing: 4) {
                    Text(audioRecorder.isRecording ? "正在听" : "就绪")
                        .font(.system(size: 13, weight: .semibold))
                    Text(audioRecorder.status)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                Spacer()

                MacStatusPill(
                    title: "Translate",
                    detail: hotKeys.translatePreset.displayName,
                    systemImage: "keyboard",
                    tint: .secondary
                )
                }
            }
        }
    }

    private var shortcutSettings: some View {
        MacControlSection(title: "Shortcuts", subtitle: "默认用 Fn；如果你的 macOS 把 Fn/Globe 分配给系统动作，可以立即切换备选键位。") {
            VStack(alignment: .leading, spacing: 13) {
                MacSettingsRow(title: "听写/润色", systemImage: "mic") {
                    Picker("听写/润色快捷键", selection: $hotKeys.capturePreset) {
                        ForEach(MacHotKeyPreset.allCases, id: \.rawValue) { preset in
                            Text(preset.displayName).tag(preset)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(width: 190)
                    .labelsHidden()

                    Text(hotKeys.capturePreset.detailText)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }

                MacSettingsRow(title: "翻译", systemImage: "character.bubble") {
                    Picker("翻译快捷键", selection: $hotKeys.translatePreset) {
                        ForEach(MacHotKeyPreset.allCases, id: \.rawValue) { preset in
                            Text(preset.displayName).tag(preset)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(width: 190)
                    .labelsHidden()

                    Text("直接切到翻译模式并开始录音；再次触发会停止。默认 \(MacProductCopy.translateHotKey)。")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 8) {
                    Image(systemName: "info.circle")
                        .foregroundStyle(.secondary)
                    Text(hotKeys.compatibilitySummary)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let conflict = MacHotKeyConflictDetector.functionKeyConflict(for: hotKeys.preferences) {
                    HStack(alignment: .center, spacing: 10) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.orange)
                            .frame(width: 22)
                            .accessibilityHidden(true)

                        VStack(alignment: .leading, spacing: 3) {
                            Text(conflict.title)
                                .font(.system(size: 12, weight: .semibold))
                            Text(conflict.detail)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        Spacer(minLength: 10)

                        Button {
                            hotKeys.useSpaceFallback()
                        } label: {
                            Label("改用 ⌥ Space", systemImage: "keyboard")
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                    .padding(10)
                    .background(Color.orange.opacity(0.10))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(Color.orange.opacity(0.35))
                    )
                }
            }
        }
    }

    private var workflowSettings: some View {
        MacControlSection(title: "工作方式", subtitle: "这些设置会同步到菜单栏和热键路径。") {
            VStack(alignment: .leading, spacing: 14) {
                MacSettingsRow(title: "模式", systemImage: "slider.horizontal.3") {
                    Picker("模式", selection: $viewModel.mode) {
                        ForEach(viewModel.modeOptions, id: \.rawValue) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 360)
                    .labelsHidden()
                }

                MacSettingsRow(title: "语言", systemImage: "character.cursor.ibeam") {
                    HStack(spacing: 8) {
                        TextField("zh", text: $viewModel.sourceLanguage)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 86)
                            .accessibilityLabel("源语言")

                        Image(systemName: "arrow.right")
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)

                        TextField("en", text: $viewModel.targetLanguage)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 86)
                            .disabled(viewModel.mode != .translate)
                            .accessibilityLabel("目标语言")
                    }
                }

                MacSettingsRow(title: "上屏语言", systemImage: "keyboard.badge.eye") {
                    HStack(spacing: 10) {
                        Picker("上屏语言", selection: $viewModel.preferredInsertLanguage) {
                            ForEach(viewModel.insertLanguageOptions, id: \.self) { language in
                                Text(TranslationLanguageResolver.displayName(for: language)).tag(language)
                            }
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 220)
                        .disabled(viewModel.mode != .translate)
                        .labelsHidden()

                        Text("确认面板可临时点任一侧上屏；再次按 \(hotKeys.capturePreset.displayName) 时默认上屏 \(TranslationLanguageResolver.displayName(for: viewModel.preferredInsertLanguage))。")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                MacSettingsRow(title: "ASR", systemImage: "waveform.badge.magnifyingglass") {
                    VStack(alignment: .leading, spacing: 6) {
                        Picker("ASR", selection: $viewModel.asrModelMode) {
                            ForEach(viewModel.asrModelModeOptions, id: \.rawValue) { mode in
                                Text(mode.displayName).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                        .frame(maxWidth: 520)
                        .labelsHidden()

                        Text(viewModel.asrModelMode.descriptionText)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var modelAndPermissionStatus: some View {
        MacControlSection(title: "状态", subtitle: "优先暴露会影响上屏和延迟的状态。") {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    MacStatusPill(
                        title: "无障碍",
                        detail: AXIsProcessTrusted() ? "可上屏" : "未授权",
                        systemImage: AXIsProcessTrusted() ? "checkmark.shield" : "exclamationmark.triangle",
                        tint: AXIsProcessTrusted() ? .green : .orange
                    )
                    MacStatusPill(
                        title: "麦克风",
                        detail: microphoneStatusText,
                        systemImage: microphoneStatusIcon,
                        tint: microphoneStatusTint
                    )
                    MacStatusPill(
                        title: "模型",
                        detail: modelStatusText,
                        systemImage: modelStatusIcon,
                        tint: modelStatusTint
                    )
                    Spacer()
                }

                HStack(spacing: 10) {
                    Button {
                        checkAccessibilityFromWindow()
                    } label: {
                        Label("检查无障碍", systemImage: "checkmark.shield")
                    }
                    .buttonStyle(.bordered)

                    Button {
                        insertProbeFromWindow()
                    } label: {
                        Label("插入探针", systemImage: "text.cursor")
                    }
                    .buttonStyle(.borderedProminent)

                    Text(systemProbeStatus)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private var textLab: some View {
        DisclosureGroup(isExpanded: $showTextLab) {
            MacControlSection(title: "文本实验室", subtitle: "不录音时快速验证纠错、润色和翻译。") {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .top, spacing: 12) {
                        MacTextEditorPanel(title: "输入", text: $viewModel.sampleText, minHeight: 116)
                        MacTextEditorPanel(title: "输出", text: $viewModel.outputText, minHeight: 116)
                    }

                    HStack {
                        Text(viewModel.runtimeSettingsSummary)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                        Spacer()
                        Button {
                            viewModel.copyOutput()
                        } label: {
                            Label("复制输出", systemImage: "doc.on.doc")
                        }
                        .disabled(viewModel.outputText.isEmpty)
                    }
                }
            }
            .padding(.top, 8)
        } label: {
            Label("文本实验室", systemImage: "text.magnifyingglass")
                .font(.system(size: 13, weight: .semibold))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color(nsColor: .separatorColor))
        )
    }

    private var diagnostics: some View {
        DisclosureGroup(isExpanded: $showDiagnostics) {
            Text(viewModel.diagnostics.isEmpty ? "ready" : viewModel.diagnostics)
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(Color(nsColor: .separatorColor))
                )
                .padding(.top, 8)
        } label: {
            Label("诊断", systemImage: "stethoscope")
                .font(.system(size: 13, weight: .semibold))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color(nsColor: .separatorColor))
        )
    }

    private func checkAccessibilityFromWindow() {
        let trusted = AXIsProcessTrusted()
        systemProbeStatus = "accessibility_trusted=\(trusted) pid=\(ProcessInfo.processInfo.processIdentifier)"
    }

    private func insertProbeFromWindow() {
        let text = "\(MacProductCopy.name) app window probe \(Int(Date().timeIntervalSince1970))"
        switch MacPasteboardInserter.insert(text) {
        case .inserted:
            systemProbeStatus = "insert_probe_posted text=\(text)"
        case .copiedNeedsAccessibility:
            systemProbeStatus = "copied_needs_accessibility text_in_clipboard=\(text)"
        case .failedToWrite:
            systemProbeStatus = "pasteboard_write_failed"
        }
    }

    private var modeStatusTitle: String {
        viewModel.isRunning ? "处理中" : viewModel.mode.displayName
    }

    private var languagePairStatus: String {
        viewModel.mode == .translate
            ? "\(viewModel.sourceLanguage)->\(viewModel.targetLanguage)"
            : viewModel.sourceLanguage
    }

    private var captureSubtitle: String {
        if audioRecorder.isRecording {
            return "说完后按 \(hotKeys.capturePreset.displayName) 或点停止，Velora 会在本地处理。"
        }

        switch viewModel.mode {
        case .dictate:
            return "按 \(hotKeys.capturePreset.displayName) 开始，识别后直接上屏。"
        case .polish:
            return "按 \(hotKeys.capturePreset.displayName) 开始，识别后自动润色排版。"
        case .translate:
            return "按 \(hotKeys.translatePreset.displayName) 开始翻译，先确认原文和译文再上屏。"
        }
    }

    private var microphoneStatusText: String {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return "可录音"
        case .denied, .restricted:
            return "未授权"
        case .notDetermined:
            return "待确认"
        @unknown default:
            return "未知"
        }
    }

    private var microphoneStatusIcon: String {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return "mic.fill"
        case .denied, .restricted:
            return "mic.slash"
        case .notDetermined:
            return "mic.badge.plus"
        @unknown default:
            return "questionmark.circle"
        }
    }

    private var microphoneStatusTint: Color {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return .green
        case .denied, .restricted:
            return .orange
        case .notDetermined:
            return .secondary
        @unknown default:
            return .secondary
        }
    }

    private var modelStatusText: String {
        if viewModel.diagnostics.contains("error") {
            return "需检查"
        }
        if viewModel.diagnostics.contains("ready") {
            return "已预热"
        }
        if viewModel.diagnostics.contains("warming") {
            return "预热中"
        }
        return "待预热"
    }

    private var modelStatusIcon: String {
        if viewModel.diagnostics.contains("error") {
            return "exclamationmark.triangle"
        }
        if viewModel.diagnostics.contains("ready") {
            return "checkmark.circle"
        }
        return "cpu"
    }

    private var modelStatusTint: Color {
        if viewModel.diagnostics.contains("error") {
            return .orange
        }
        if viewModel.diagnostics.contains("ready") {
            return .green
        }
        return .blue
    }
}

struct MacControlSection<Content: View>: View {
    var title: String
    var subtitle: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color(nsColor: .separatorColor))
        )
    }
}

struct MacSettingsRow<Content: View>: View {
    var title: String
    var systemImage: String
    @ViewBuilder var content: Content

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 92, alignment: .leading)
                .padding(.top, 5)

            content
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct MacStatusPill: View {
    var title: String
    var detail: String
    var systemImage: String
    var tint: Color

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                Text(detail)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color(nsColor: .separatorColor))
        )
    }
}

struct MacShortcutKeycap: View {
    var text: String

    var body: some View {
        Text(text)
            .font(.system(size: 13, weight: .semibold, design: .rounded))
            .lineLimit(1)
            .minimumScaleFactor(0.82)
            .padding(.horizontal, 11)
            .frame(minWidth: 58, minHeight: 30)
            .background(
                LinearGradient(
                    colors: [
                        Color(nsColor: .textBackgroundColor),
                        Color(nsColor: .controlBackgroundColor),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(Color(nsColor: .separatorColor))
            )
            .shadow(color: .black.opacity(0.08), radius: 2, y: 1)
            .accessibilityLabel("快捷键 \(text)")
    }
}

struct MacTextEditorPanel: View {
    var title: String
    @Binding var text: String
    var minHeight: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            TextEditor(text: $text)
                .font(.system(size: 13))
                .frame(minHeight: minHeight)
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(Color(nsColor: .separatorColor))
                )
        }
        .frame(maxWidth: .infinity)
    }
}

private extension DictationMode {
    var displayName: String {
        switch self {
        case .dictate:
            return "听写"
        case .polish:
            return "润色"
        case .translate:
            return "翻译"
        }
    }

    var systemImage: String {
        switch self {
        case .dictate:
            return "text.cursor"
        case .polish:
            return "wand.and.stars"
        case .translate:
            return "character.bubble"
        }
    }

    var tint: Color {
        switch self {
        case .dictate:
            return .blue
        case .polish:
            return .purple
        case .translate:
            return .teal
        }
    }
}

private extension InsertPolicy {
    var displayName: String {
        switch self {
        case .bilingual:
            return "双语上屏"
        case .targetOnly:
            return "仅译文"
        case .reviewCard:
            return "引用卡片"
        }
    }
}

private extension WhisperModelMode {
    var descriptionText: String {
        switch self {
        case .fast:
            return "默认路径，优先低延迟。适合日常短句。"
        case .accurate:
            return "更重的模型，适合术语、人名和中英混说。"
        case .fallback:
            return "轻量兜底模型，只用于故障排查或极低资源环境。"
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

import AVFoundation
import SwiftUI
import UIKit
import Velora

@main
struct VeloraiOSApp: App {
    var body: some Scene {
        WindowGroup {
            iOSPrototypeView()
        }
    }
}

struct iOSPrototypeView: View {
    @StateObject private var viewModel = PrototypePipelineViewModel()
    @StateObject private var audioRecorder = iOSAudioRecorderViewModel()
    @State private var didRunLaunchAutomation = false
    @State private var showsMicrophonePreflight = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    modeControls
                    audioControls
                    editor
                    actionRow
                    output
                    bridgeStatus
                    diagnostics
                }
                .padding(16)
            }
            .navigationTitle("Velora")
        }
        .onAppear {
            runLaunchAutomationIfNeeded()
        }
        .sheet(isPresented: $showsMicrophonePreflight) {
            microphonePreflightSheet
        }
    }

    private var modeControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("模式", selection: $viewModel.mode) {
                ForEach(viewModel.modeOptions, id: \.rawValue) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            HStack(spacing: 8) {
                TextField("source", text: $viewModel.sourceLanguage)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 86)
                Image(systemName: "arrow.right")
                    .foregroundStyle(.secondary)
                TextField("target", text: $viewModel.targetLanguage)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 86)
                    .disabled(viewModel.mode != .translate)
                Picker("插入", selection: $viewModel.insertPolicy) {
                    ForEach(viewModel.insertPolicyOptions, id: \.rawValue) { policy in
                        Text(policy.rawValue).tag(policy)
                    }
                }
                .disabled(viewModel.mode != .translate)
            }
        }
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("ASR 输入")
                .foregroundStyle(.secondary)
            TextEditor(text: $viewModel.sampleText)
                .frame(minHeight: 120)
                .padding(8)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(.quaternary)
                )
        }
    }

    private var audioControls: some View {
        HStack(spacing: 12) {
            Button {
                handleRecordButton()
            } label: {
                Label(
                    audioRecorder.isRecording ? "停止录音" : "录音",
                    systemImage: audioRecorder.isRecording ? "stop.fill" : "mic.fill"
                )
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(audioRecorder.isRecording ? Color.veloraDanger : Color.veloraAccent)

            Text(audioRecorder.status)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var microphonePreflightSheet: some View {
        VStack(alignment: .leading, spacing: 18) {
            Image(systemName: "mic.fill")
                .font(.system(size: 36, weight: .semibold))
                .foregroundStyle(Color.veloraDanger)

            Text("麦克风权限")
                .font(.title2.weight(.semibold))

            Text("录音只在这台 iPhone 上处理。不同意也可以粘贴文本做润色或翻译。")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 12) {
                Button("取消") {
                    showsMicrophonePreflight = false
                }
                .buttonStyle(.bordered)

                Button("继续录音") {
                    showsMicrophonePreflight = false
                    startOrStopRecording()
                }
                .buttonStyle(.borderedProminent)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(24)
        .presentationDetents([.height(260)])
        .presentationDragIndicator(.visible)
    }

    private var actionRow: some View {
        HStack(spacing: 12) {
            Button {
                viewModel.run(platform: .iOS)
            } label: {
                Label(viewModel.isRunning ? "处理中" : "运行", systemImage: "play.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(viewModel.isRunning)

            Button {
                viewModel.copyOutput()
            } label: {
                Image(systemName: "doc.on.doc")
                    .frame(width: 36, height: 36)
            }
            .buttonStyle(.bordered)
            .disabled(viewModel.outputText.isEmpty)
        }
    }

    private var output: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("输出")
                .foregroundStyle(.secondary)
            TextEditor(text: $viewModel.outputText)
                .frame(minHeight: 160)
                .padding(8)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(.quaternary)
                )
        }
    }

    private var bridgeStatus: some View {
        HStack(spacing: 12) {
            Button {
                viewModel.writeKeyboardCandidate()
            } label: {
                Label("写入候选", systemImage: "keyboard")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(viewModel.outputText.isEmpty)

            Text(viewModel.keyboardCandidateStatus.isEmpty ? "ready" : viewModel.keyboardCandidateStatus)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var diagnostics: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("诊断")
                .foregroundStyle(.secondary)
            Text(viewModel.diagnostics.isEmpty ? "ready" : viewModel.diagnostics)
                .font(.caption.monospaced())
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(.quaternary.opacity(0.35))
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    private func runLaunchAutomationIfNeeded() {
        guard !didRunLaunchAutomation else {
            return
        }

        guard ProcessInfo.processInfo.arguments.contains("--velora-autowrite") else {
            return
        }

        didRunLaunchAutomation = true
        viewModel.run(platform: .iOS)
    }

    private func handleRecordButton() {
        if audioRecorder.shouldShowMicrophonePreflight {
            showsMicrophonePreflight = true
        } else {
            startOrStopRecording()
        }
    }

    private func startOrStopRecording() {
        audioRecorder.toggleRecording { _ in
            // iOS audio capture is ready; the default ASR adapter is selected after true-device benchmarks.
        }
    }
}

enum UIPasteboardBridge {
    static func write(_ text: String) {
        UIPasteboard.general.string = text
    }
}

@MainActor
final class iOSAudioRecorderViewModel: ObservableObject {
    @Published var isRecording = false
    @Published var status = "audio_ready"
    @Published var lastClip: iOSRecordedAudioClip?

    private let service = iOSAudioCaptureService()

    var shouldShowMicrophonePreflight: Bool {
        !isRecording && service.recordPermission == .undetermined
    }

    func toggleRecording(onFinished: @escaping @MainActor (iOSRecordedAudioClip) -> Void) {
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

    private func stopRecording(onFinished: @escaping @MainActor (iOSRecordedAudioClip) -> Void) {
        guard let clip = service.stop() else {
            isRecording = false
            status = "audio_ready"
            return
        }

        isRecording = false
        lastClip = clip
        status = "audio_saved=\(clip.url.lastPathComponent) duration=\(String(format: "%.2f", clip.durationSeconds))s"
        onFinished(clip)
    }
}

struct iOSRecordedAudioClip {
    var url: URL
    var startedAt: Date
    var endedAt: Date

    var durationSeconds: TimeInterval {
        endedAt.timeIntervalSince(startedAt)
    }
}

enum iOSAudioCaptureError: Error {
    case microphoneDenied
    case recordingAlreadyRunning
}

final class iOSAudioCaptureService: @unchecked Sendable {
    private let lock = NSLock()
    private var engine: AVAudioEngine?
    private var file: AVAudioFile?
    private var fileURL: URL?
    private var startedAt: Date?

    var recordPermission: AVAudioApplication.recordPermission {
        AVAudioApplication.shared.recordPermission
    }

    func start() async throws -> URL {
        let granted = await requestMicrophoneAccess()
        guard granted else {
            throw iOSAudioCaptureError.microphoneDenied
        }

        return try startRecording()
    }

    func stop() -> iOSRecordedAudioClip? {
        lock.lock()
        defer { lock.unlock() }

        guard let engine, let fileURL, let startedAt else {
            return nil
        }

        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        self.engine = nil
        self.file = nil
        self.fileURL = nil
        self.startedAt = nil

        return iOSRecordedAudioClip(
            url: fileURL,
            startedAt: startedAt,
            endedAt: Date()
        )
    }

    private func requestMicrophoneAccess() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    private func startRecording() throws -> URL {
        lock.lock()
        defer { lock.unlock() }

        guard engine == nil else {
            throw iOSAudioCaptureError.recordingAlreadyRunning
        }

        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .spokenAudio, options: [.duckOthers])
        try session.setActive(true)

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

        engine.prepare()
        try engine.start()

        self.engine = engine
        self.file = file
        self.fileURL = url
        self.startedAt = Date()

        return url
    }

    private func write(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }

        try? file?.write(from: buffer)
    }
}

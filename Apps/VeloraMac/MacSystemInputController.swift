import AppKit
import ApplicationServices
import AVFoundation
import Carbon
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

@MainActor
final class MacAppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let dictationController = MacDictationController()
    private let hotKeyCenter = MacGlobalHotKeyCenter()
    private var statusItem: NSStatusItem?
    private var settingsWindow: NSWindow?
    private var observers: [NSObjectProtocol] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu-bar utility: no Dock icon, no main menu. The status item plus
        // the global hotkeys are the entire product surface.
        NSApp.setActivationPolicy(.accessory)
        configureStatusItem()
        registerHotKeys()
        // Prewarm at launch so the resident SenseVoice model and Ollama are
        // warm before the first Fn press — the whole point of the sidecar.
        dictationController.prewarmModelMode()

        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: MacHotKeyStore.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.registerHotKeys()
            }
        })
        observers.append(center.addObserver(
            forName: MacDictationController.captureStateDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refreshStatusIcon()
            }
        })
    }

    func applicationWillTerminate(_ notification: Notification) {
        dictationController.invalidate()
        hotKeyCenter.unregister()
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        observers.removeAll()
    }

    private func configureStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.toolTip = "\(MacProductCopy.name) · \(MacProductCopy.subtitle)"
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
        refreshStatusIcon()
    }

    private func refreshStatusIcon() {
        guard let button = statusItem?.button else {
            return
        }
        let symbol = dictationController.isRecordingActive ? "record.circle" : "waveform"
        if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: MacProductCopy.name) {
            button.image = image
            button.title = ""
        } else {
            button.image = nil
            button.title = MacProductCopy.name
        }
    }

    private func registerHotKeys() {
        let preferences = MacHotKeyStore.shared.load()
        // While a capture flow is active, bare Fn stops it immediately instead
        // of waiting out the Fn⇧ disambiguation delay — that delay would be
        // charged straight to release-to-insert.
        hotKeyCenter.prefersImmediateBareFunction = { [weak self] in
            MainActor.assumeIsolated {
                self?.dictationController.isCaptureBusy ?? false
            }
        }
        do {
            try hotKeyCenter.register(preferences: preferences) { [weak self] invocation in
                Task { @MainActor in
                    switch invocation {
                    case .capture:
                        self?.dictationController.toggleRecordingFromHotKey()
                    case .translate:
                        self?.dictationController.toggleTranslationFromHotKey()
                    }
                }
            }
            if let conflict = MacHotKeyConflictDetector.functionKeyConflict(for: preferences) {
                dictationController.updateStatus(conflict.statusLine)
            } else {
                dictationController.updateStatus("ready hotkey=\(preferences.capture.rawValue) translate=\(preferences.translate.rawValue)")
            }
        } catch {
            dictationController.updateStatus("hotkey_error=\(error)")
        }
    }

    /// The status menu is rebuilt on every open: items are contextual
    /// (recording / pending review / missing permission), so static wiring
    /// would immediately go stale.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let hotKeys = MacHotKeyStore.shared.load()

        if !AXIsProcessTrusted() {
            let warning = menuItem("需要无障碍权限才能上屏…", #selector(openAccessibilitySettings))
            warning.image = NSImage(
                systemSymbolName: "exclamationmark.triangle.fill",
                accessibilityDescription: nil
            )
            menu.addItem(warning)
            menu.addItem(.separator())
        }

        if dictationController.hasPendingReview {
            menu.addItem(menuItem("确认并上屏（\(hotKeys.captureDisplayName)）", #selector(confirmPendingReview)))
            menu.addItem(menuItem("放弃本次结果（esc）", #selector(cancelPendingReview)))
        } else if dictationController.isRecordingActive {
            menu.addItem(menuItem("完成并上屏（\(hotKeys.captureDisplayName)）", #selector(toggleRecording)))
            menu.addItem(menuItem("取消本次录音（esc）", #selector(cancelActiveCapture)))
        } else {
            menu.addItem(menuItem("开始听写（\(hotKeys.captureDisplayName)）", #selector(toggleRecording)))
            menu.addItem(menuItem("开始翻译（\(hotKeys.translateDisplayName)）", #selector(toggleTranslation)))
        }

        menu.addItem(.separator())
        menu.addItem(menuItem("设置…", #selector(showSettingsWindow), key: ","))
        if MacDeveloperModeStore.shared.isEnabled {
            menu.addItem(developerMenuItem())
        }
        menu.addItem(menuItem("退出 \(MacProductCopy.name)", #selector(quitVelora), key: "q"))
    }

    private func menuItem(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    private func developerMenuItem() -> NSMenuItem {
        let settings = VeloraSettingsStore.shared.load()
        let submenu = NSMenu()

        let input = menuItem("输入模式", #selector(useInputMode))
        input.state = settings.mode == .input ? .on : .off
        let translate = menuItem("翻译模式", #selector(useTranslateMode))
        translate.state = settings.mode == .translate ? .on : .off
        submenu.addItem(input)
        submenu.addItem(translate)
        submenu.addItem(.separator())

        let fast = menuItem("ASR 快速模型", #selector(useFastASRModel))
        fast.state = settings.asrModelMode == .fast ? .on : .off
        let accurate = menuItem("ASR 准确模型", #selector(useAccurateASRModel))
        accurate.state = settings.asrModelMode == .accurate ? .on : .off
        let fallback = menuItem("ASR 兜底模型", #selector(useFallbackASRModel))
        fallback.state = settings.asrModelMode == .fallback ? .on : .off
        submenu.addItem(fast)
        submenu.addItem(accurate)
        submenu.addItem(fallback)
        submenu.addItem(.separator())

        submenu.addItem(menuItem("插入探针文本", #selector(insertProbeText)))
        submenu.addItem(menuItem("检查无障碍权限", #selector(checkAccessibilityPermission)))

        let item = NSMenuItem(title: "开发者", action: nil, keyEquivalent: "")
        item.submenu = submenu
        return item
    }

    @objc private func toggleRecording() {
        Task { @MainActor in
            dictationController.toggleRecordingFromHotKey()
        }
    }

    @objc private func toggleTranslation() {
        Task { @MainActor in
            dictationController.toggleTranslationFromHotKey()
        }
    }

    @objc private func confirmPendingReview() {
        dictationController.confirmPendingReview()
    }

    @objc private func cancelPendingReview() {
        dictationController.cancelPendingReview()
    }

    @objc private func useInputMode() {
        dictationController.setMode(.input)
    }

    @objc private func useTranslateMode() {
        dictationController.setMode(.translate)
    }

    @objc private func useFastASRModel() {
        dictationController.setASRModelMode(.fast)
    }

    @objc private func useAccurateASRModel() {
        dictationController.setASRModelMode(.accurate)
    }

    @objc private func useFallbackASRModel() {
        dictationController.setASRModelMode(.fallback)
    }

    @objc private func openAccessibilitySettings() {
        NSWorkspace.shared.open(
            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        )
    }

    @objc private func insertProbeText() {
        dictationController.insertProbeText()
    }

    @objc private func checkAccessibilityPermission() {
        dictationController.checkAccessibilityPermission()
    }

    @objc private func cancelActiveCapture() {
        dictationController.cancelActiveCapture()
    }

    @objc private func quitVelora() {
        NSApp.terminate(nil)
    }

    @objc private func showSettingsWindow() {
        if settingsWindow == nil {
            let hosting = NSHostingController(rootView: MacSettingsView())
            hosting.sizingOptions = .preferredContentSize
            let window = NSWindow(contentViewController: hosting)
            window.title = "\(MacProductCopy.name) 设置"
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        if settingsWindow?.isMiniaturized == true {
            settingsWindow?.deminiaturize(nil)
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
}

@MainActor
final class MacDictationController {
    /// Posted whenever recording starts or stops so the status-bar icon can
    /// mirror capture state without polling.
    static let captureStateDidChangeNotification = Notification.Name("app.velora.captureState.didChange")

    private let settingsStore = VeloraSettingsStore.shared
    private let audioService = MacAudioCaptureService()
    private let floatingPanel = MacFloatingStatusPanelController()
    private lazy var reviewPanel = MacTranslationReviewPanelController(
        onConfirm: { [weak self] selection in
            self?.confirmPendingReview(selection: selection)
        },
        onCancel: { [weak self] in
            self?.cancelPendingReview()
        },
        onRetranslate: { [weak self] in
            self?.retranslatePendingReview()
        }
    )
    private var isRecording = false {
        didSet {
            guard oldValue != isRecording else {
                return
            }
            NotificationCenter.default.post(name: Self.captureStateDidChangeNotification, object: nil)
        }
    }
    private var currentClipStartedAt: Date?
    private var activeSettings: VeloraRuntimeSettings?
    private var pendingReview: MacPendingTranslationReview?
    private var recordingStartTask: Task<Void, Never>?
    private var pipelineTask: Task<Void, Never>?
    private var pipelineGeneration = 0
    private var recordingGeneration = 0
    private var lastInsertion: MacLastInsertionRecord?
    private var undoMonitor: Any?
    private var undoWatchExpiry: Task<Void, Never>?
    private var contextPrepTask: Task<MacPreparedPipelineContext?, Never>?
    /// Persistent hotword memory (Phase 2). Seeded once from the demo term
    /// set, then grows from the correction journal. Nil only if the store
    /// cannot open — we then fall back to the in-memory demo terms.
    private let memoryStore: SQLiteMemoryStore? = {
        let store = SQLiteMemoryStore.defaultStore()
        store?.seedIfEmpty(InMemoryHotwordStore.defaultTerms)
        return store
    }()

    private var activeMemoryStore: any MemoryStore {
        memoryStore ?? InMemoryHotwordStore()
    }

    private func ingestJournalIncrementally() {
        guard let memoryStore,
              let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return
        }
        let journal = directory.appendingPathComponent("Velora/corrections.jsonl")
        Task.detached(priority: .utility) {
            memoryStore.ingestCorrectionJournal(at: journal)
        }
    }
    private var globalEscapeMonitor: Any?
    private var localEscapeMonitor: Any?
    private lazy var escapeHotKeyCenter = MacEscapeHotKeyCenter { [weak self] in
        Task { @MainActor in
            self?.cancelActiveFlow()
        }
    }
    private lazy var escapeEventTap = MacEscapeEventTap { [weak self] in
        Task { @MainActor in
            self?.cancelActiveFlow()
        }
    }

    init() {
        installEscapeMonitors()
    }

    func invalidate() {
        if let globalEscapeMonitor {
            NSEvent.removeMonitor(globalEscapeMonitor)
            self.globalEscapeMonitor = nil
        }
        if let localEscapeMonitor {
            NSEvent.removeMonitor(localEscapeMonitor)
            self.localEscapeMonitor = nil
        }
        escapeHotKeyCenter.invalidate()
        escapeEventTap.invalidate()
        recordingStartTask?.cancel()
        pipelineTask?.cancel()
        contextPrepTask?.cancel()
        stopUndoWatch()
    }

    var isCaptureBusy: Bool {
        isRecording || recordingStartTask != nil
    }

    var isRecordingActive: Bool {
        isRecording
    }

    var hasPendingReview: Bool {
        pendingReview != nil
    }

    func cancelActiveCapture() {
        _ = cancelActiveFlow()
    }

    func toggleRecordingFromHotKey() {
        if pendingReview != nil {
            confirmPendingReview()
            return
        }

        if isRecording {
            stopAndRunPipeline()
        } else {
            settingsStore.update { settings in
                settings.mode = .input
            }
            startRecording()
        }
    }

    func toggleTranslationFromHotKey() {
        if pendingReview != nil {
            confirmPendingReview()
            return
        }

        if isRecording {
            stopAndRunPipeline()
            return
        }

        settingsStore.update { settings in
            settings.mode = .translate
        }
        startRecording()
    }

    @discardableResult
    func cancelActiveFlow() -> Bool {
        if pendingReview != nil {
            cancelPendingReview()
            return true
        }

        if isRecording || recordingStartTask != nil {
            cancelRecording()
            return true
        }

        if pipelineTask != nil {
            pipelineTask?.cancel()
            pipelineTask = nil
            refreshEscapeCancellationState()
            floatingPanel.show(
                MacFloatingStatus(
                    phase: .idle,
                    title: "已取消",
                    detail: "processing_cancelled",
                    startedAt: nil
                )
            )
            floatingPanel.hide(after: 0.8)
            return true
        }

        return false
    }

    func setMode(_ mode: DictationMode) {
        settingsStore.update { settings in
            settings.mode = mode
        }
        updateStatus(settingsStore.load().displaySummary)
    }

    func setASRModelMode(_ modelMode: WhisperModelMode) {
        settingsStore.update { settings in
            settings.asrModelMode = modelMode
        }
        prewarmModelMode(modelMode)
        updateStatus(settingsStore.load().displaySummary)
    }

    func updateStatus(_ message: String) {
        floatingPanel.show(
                MacFloatingStatus(
                    phase: .idle,
                    title: MacProductCopy.name,
                    detail: message,
                    startedAt: nil
                )
        )
        floatingPanel.hide(after: 1.2)
    }

    /// SenseVoice is the primary ASR engine (18× faster, better CER on real
    /// speech — see docs/ASR_POLISH_TUNING_REPORT.md §3.4); whisper.cpp is the
    /// automatic fallback when the sidecar assets aren't installed. Held for
    /// the whole controller lifetime so the resident model stays warm.
    private let senseVoiceEngine: SenseVoiceASREngine? = SenseVoiceASREngine.Configuration
        .resolvedDefault()
        .map(SenseVoiceASREngine.init)

    func prewarmModelMode(_ mode: WhisperModelMode? = nil) {
        let mode = mode ?? settingsStore.load().asrModelMode
        Task { [senseVoiceEngine] in
            if let senseVoiceEngine {
                try? await senseVoiceEngine.prewarm()
            }
            _ = await LocalModelPrewarmer.prewarmForMac(
                whisper: .configuration(for: mode)
            )
        }
    }

    func insertProbeText() {
        let text = "\(MacProductCopy.name) app insert probe \(Int(Date().timeIntervalSince1970))"
        let outcome = MacPasteboardInserter.insert(text)
        switch outcome {
        case .inserted:
            floatingPanel.show(
                MacFloatingStatus(
                    phase: .inserted,
                    title: "App 插入探针已发送",
                    detail: text,
                    startedAt: nil
                )
            )
            floatingPanel.hide(after: 1.2)
        case .copiedNeedsAccessibility:
            floatingPanel.show(
                MacFloatingStatus(
                    phase: .review,
                    title: "已复制，等待授权",
                    detail: "给 \(MacProductCopy.name) 开启无障碍权限后重启 App，再试一次。",
                    startedAt: nil
                )
            )
        case .targetUnavailable:
            floatingPanel.show(
                MacFloatingStatus(
                    phase: .review,
                    title: "目标应用不可用，已复制",
                    detail: "结果已在剪贴板，请手动粘贴。",
                    startedAt: nil
                )
            )
        case .failedToWrite:
            floatingPanel.show(
                MacFloatingStatus(
                    phase: .error,
                    title: "探针失败",
                    detail: "pasteboard_write_failed",
                    startedAt: nil
                )
            )
        }
    }

    func checkAccessibilityPermission() {
        let trusted = AXIsProcessTrusted()
        let appName = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? Bundle.main.bundleURL.lastPathComponent
        let bundleID = Bundle.main.bundleIdentifier ?? "unknown_bundle"
        floatingPanel.show(
            MacFloatingStatus(
                phase: trusted ? .inserted : .review,
                title: trusted ? "无障碍权限可用" : "无障碍权限未生效",
                detail: "trusted=\(trusted) app=\(appName) bundle=\(bundleID) pid=\(ProcessInfo.processInfo.processIdentifier)",
                startedAt: nil
            )
        )
        if trusted {
            floatingPanel.hide(after: 2.0)
        }
    }

    func confirmPendingReview() {
        // Plain confirm (hotkey / menu) honors the side the user picked in
        // settings; the overlay buttons remain a per-utterance override.
        confirmPendingReview(selection: pendingReview?.preferredSelection ?? .target)
    }

    func confirmPendingReview(selection: MacTranslationReviewSelection) {
        guard let review = pendingReview else {
            updateStatus("no_pending_review")
            return
        }

        let insertText = reviewPanel.editedText(for: selection)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !insertText.isEmpty else {
            floatingPanel.show(
                MacFloatingStatus(phase: .error, title: "内容为空，未上屏", detail: "", startedAt: nil)
            )
            return
        }

        // User edits in the overlay are the highest-quality learning signal:
        // capture the diff locally so the memory layer (Phase 2) can grow
        // hotwords and glossary pairs from real corrections.
        MacCorrectionJournal.recordIfEdited(
            review: review,
            editedSource: reviewPanel.editedSource,
            editedTarget: reviewPanel.editedTarget,
            insertedSelection: selection
        )

        pendingReview = nil
        reviewPanel.hide()
        refreshEscapeCancellationState()
        let outcome = MacPasteboardInserter.insert(insertText, target: review.target)
        switch outcome {
        case .inserted:
            lastInsertion = MacLastInsertionRecord(
                finalText: insertText,
                asrText: review.asrText,
                appliedEdits: review.appliedEdits,
                targetBundleID: review.target?.bundleIdentifier,
                mode: .translate,
                at: Date()
            )
            startUndoWatch()
            floatingPanel.show(
                MacFloatingStatus(
                    phase: .inserted,
                    title: "已上屏",
                    detail: "\(selection == .source ? "原文" : "译文") · \(insertText.oneLinePreview(maxLength: 96))",
                    startedAt: nil
                )
            )
            floatingPanel.hide(after: 1.0)
        case .copiedNeedsAccessibility:
            floatingPanel.show(
                MacFloatingStatus(
                    phase: .review,
                    title: "已复制，等待授权",
                    detail: "给 \(MacProductCopy.name) 开启无障碍权限后重启 App，再试一次。",
                    startedAt: nil
                )
            )
        case .targetUnavailable:
            floatingPanel.show(
                MacFloatingStatus(
                    phase: .review,
                    title: "目标应用不可用，已复制",
                    detail: "原目标窗口无法唤回。结果已在剪贴板，请手动粘贴。",
                    startedAt: nil
                )
            )
        case .failedToWrite:
            floatingPanel.show(
                MacFloatingStatus(
                    phase: .error,
                    title: "上屏失败",
                    detail: "pasteboard_write_failed",
                    startedAt: nil
                )
            )
        }
    }

    func cancelPendingReview() {
        guard pendingReview != nil else {
            updateStatus("no_pending_review")
            return
        }

        pendingReview = nil
        reviewPanel.hide()
        refreshEscapeCancellationState()
        floatingPanel.show(
            MacFloatingStatus(
                phase: .idle,
                title: "已取消",
                detail: "pending_review_cancelled",
                startedAt: nil
            )
        )
        floatingPanel.hide(after: 1.0)
    }

    private func installEscapeMonitors() {
        let mask: NSEvent.EventTypeMask = [.keyDown]
        globalEscapeMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            guard event.keyCode == UInt16(kVK_Escape) else {
                return
            }
            Task { @MainActor in
                self?.cancelActiveFlow()
            }
        }
        localEscapeMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            guard event.keyCode == UInt16(kVK_Escape) else {
                return event
            }
            return self?.cancelActiveFlow() == true ? nil : event
        }
    }

    private func refreshEscapeCancellationState() {
        let enabled = pendingReview != nil
            || isRecording
            || recordingStartTask != nil
            || pipelineTask != nil
        escapeHotKeyCenter.setEnabled(enabled)
        escapeEventTap.setEnabled(enabled)
    }

    private func cancelRecording() {
        recordingStartTask?.cancel()
        recordingStartTask = nil
        contextPrepTask?.cancel()
        contextPrepTask = nil
        isRecording = false
        activeSettings = nil
        audioService.setLevelHandler(nil)
        if let clip = audioService.stop() {
            try? FileManager.default.removeItem(at: clip.url)
        }
        refreshEscapeCancellationState()
        floatingPanel.show(
            MacFloatingStatus(
                phase: .idle,
                title: "已取消",
                detail: "recording_cancelled",
                startedAt: nil
            )
        )
        floatingPanel.hide(after: 0.8)
    }

    private func startRecording() {
        let settings = settingsStore.load()
        recordingStartTask?.cancel()
        recordingGeneration += 1
        let generation = recordingGeneration
        activeSettings = settings
        refreshEscapeCancellationState()
        floatingPanel.show(
            MacFloatingStatus(
                phase: .requestingPermission,
                title: "请求麦克风权限",
                detail: "音频只保存在本机临时文件",
                startedAt: nil
            )
        )

        // The compose model may have been evicted by Ollama's keep_alive
        // after a long idle; kick the reload now so its ~4s cost hides
        // inside the user's own speaking time instead of stalling the first
        // insert. Cheap no-op when the model is already warm.
        Task {
            try? await OllamaLocalClient().prewarm()
        }

        // Latency-budget contract: context capture and hotword ranking run
        // DURING recording (the user is still speaking — this time is free),
        // so the after-release critical path starts straight at ASR.
        contextPrepTask?.cancel()
        ingestJournalIncrementally()
        let memoryStore = activeMemoryStore
        contextPrepTask = Task {
            let probeRequest = PipelineRunRequest(
                platform: .macOS,
                mode: settings.mode,
                sampleText: "",
                sourceLanguage: settings.sourceLanguage,
                targetLanguage: settings.effectiveTargetLanguage
            )
            let snapshot = await MacContextProvider().currentSnapshot(for: probeRequest)
            guard !Task.isCancelled else {
                return nil
            }
            let hotwords = (try? await memoryStore.rankHotwords(for: snapshot, limit: 12)) ?? []
            return MacPreparedPipelineContext(snapshot: snapshot, hotwords: hotwords)
        }

        recordingStartTask = Task {
            do {
                audioService.setLevelHandler { [weak self] level in
                    DispatchQueue.main.async {
                        self?.floatingPanel.updateAudioLevel(level)
                    }
                }
                let url = try await audioService.start()
                guard !Task.isCancelled, generation == recordingGeneration else {
                    if let clip = audioService.stop() {
                        try? FileManager.default.removeItem(at: clip.url)
                    }
                    return
                }
                recordingStartTask = nil
                isRecording = true
                currentClipStartedAt = Date()
                refreshEscapeCancellationState()
                floatingPanel.show(
                    MacFloatingStatus(
                        phase: .listening,
                        title: modeTitle(for: settings),
                        detail: "\(MacProductCopy.hotKey) 结束 · Esc 取消",
                        startedAt: Date()
                    )
                )
                _ = url
            } catch {
                guard generation == recordingGeneration else {
                    return
                }
                recordingStartTask = nil
                isRecording = false
                activeSettings = nil
                audioService.setLevelHandler(nil)
                refreshEscapeCancellationState()
                floatingPanel.show(
                    MacFloatingStatus(
                        phase: .error,
                        title: "录音失败",
                        detail: "\(error)",
                        startedAt: nil
                    )
                )
            }
        }
        refreshEscapeCancellationState()
    }

    private func stopAndRunPipeline() {
        recordingStartTask?.cancel()
        recordingStartTask = nil
        guard let clip = audioService.stop() else {
            isRecording = false
            refreshEscapeCancellationState()
            floatingPanel.show(
                MacFloatingStatus(
                    phase: .error,
                    title: "没有录音",
                    detail: "audio_clip_missing",
                    startedAt: nil
                )
            )
            return
        }

        let settings = activeSettings ?? settingsStore.load()
        let insertionTarget = MacInsertionTarget.captureFrontmost()
        activeSettings = nil
        isRecording = false
        audioService.setLevelHandler(nil)
        refreshEscapeCancellationState()
        floatingPanel.show(
            MacFloatingStatus(
                phase: .transcribing,
                title: "正在本地处理",
                detail: "duration=\(String(format: "%.2f", clip.durationSeconds))s",
                startedAt: nil
            )
        )

        let contextTask = contextPrepTask
        contextPrepTask = nil
        pipelineTask?.cancel()
        pipelineGeneration += 1
        let generation = pipelineGeneration
        pipelineTask = Task {
            let releaseTime = ContinuousClock.now
            // Harvest the during-recording preparation; falls back to live
            // capture inside the pipeline when unavailable (e.g. instant stop).
            let prepared = await contextTask?.value
            defer {
                // Only the newest pipeline may clear shared state; a cancelled
                // predecessor finishing late must not wipe its successor.
                if generation == pipelineGeneration {
                    pipelineTask = nil
                }
                refreshEscapeCancellationState()
                try? FileManager.default.removeItem(at: clip.url)
            }
            do {
                // Insertion is driven here (not inside the pipeline) so both
                // modes get target-app protection: we re-activate the app the
                // user was in at release time before posting Cmd+V.
                let result = try await makePipeline(for: settings, prepared: prepared).run(
                    PipelineRunRequest(
                        platform: .macOS,
                        mode: settings.mode,
                        sampleText: "",
                        audioPath: clip.url.path,
                        sourceLanguage: settings.sourceLanguage,
                        targetLanguage: settings.effectiveTargetLanguage,
                        insertPolicy: settings.insertPolicy,
                        preferredInsertLanguage: settings.preferredInsertLanguage,
                        insertionStrategy: .none
                    )
                )
                guard !Task.isCancelled else {
                    return
                }

                // Retry-redictation detection: quick re-recording of highly
                // similar content within the window is negative feedback on
                // the previous output. Deterministic (time + mode + edit
                // distance) — no model in this loop, misses are acceptable,
                // false positives are not.
                if let previous = lastInsertion,
                   Date().timeIntervalSince(previous.at) <= 30,
                   previous.mode == settings.mode {
                    let similarity = VeloraTextSimilarity.normalizedSimilarity(result.asr.text, previous.asrText)
                    if similarity >= 0.55 {
                        MacCorrectionJournal.recordRetryRedictation(
                            previous: previous,
                            newASRText: result.asr.text,
                            similarity: similarity
                        )
                        lastInsertion = nil
                    }
                }

                // Translate mode with no translation at all (compose and the
                // fallback engine both failed): never auto-paste source-only
                // text into the target app — copy it and say why.
                if settings.mode == .translate, result.translation == nil {
                    MacClipboard.write(result.finalText)
                    floatingPanel.show(
                        MacFloatingStatus(
                            phase: .error,
                            title: "译文不可用，原文已复制",
                            detail: result.compose.warnings.joined(separator: ","),
                            startedAt: nil
                        )
                    )
                    return
                }

                // Translate ALWAYS goes through the confirmation overlay
                // (product decision 2026-07-05): translated output cannot be
                // self-checked by the user mid-flight, so the user decides —
                // not model confidence. Input mode stays direct-insert.
                if settings.mode == .translate {
                    let elapsedMS = releaseTime.duration(to: ContinuousClock.now).milliseconds
                    presentTranslationReview(
                        result: result,
                        elapsedMS: elapsedMS,
                        preferredInsertLanguage: settings.preferredInsertLanguage,
                        target: insertionTarget
                    )
                    return
                }

                let insertStart = ContinuousClock.now
                let outcome = MacPasteboardInserter.insert(result.finalText, target: insertionTarget)
                let insertMS = insertStart.duration(to: ContinuousClock.now).milliseconds
                // wall_ms is release-to-insert including the real paste work;
                // computing it before insertion would hide the protection cost.
                let elapsedMS = releaseTime.duration(to: ContinuousClock.now).milliseconds
                switch outcome {
                case .inserted:
                    lastInsertion = MacLastInsertionRecord(
                        finalText: result.finalText,
                        asrText: result.asr.text,
                        appliedEdits: result.correction.edits + result.compose.edits,
                        targetBundleID: insertionTarget?.bundleIdentifier,
                        mode: settings.mode,
                        at: Date()
                    )
                    startUndoWatch()
                    let warningsSuffix = result.compose.warnings.isEmpty
                        ? ""
                        : " ⚠︎\(result.compose.warnings.joined(separator: ","))"
                    floatingPanel.show(
                        MacFloatingStatus(
                            phase: .inserted,
                            title: "已上屏",
                            detail: "wall_ms=\(elapsedMS) insert_ms=\(insertMS)\(warningsSuffix) \(result.finalText.oneLinePreview(maxLength: 96))",
                            startedAt: nil
                        )
                    )
                    floatingPanel.hide(after: 1.0)
                case .copiedNeedsAccessibility:
                    floatingPanel.show(
                        MacFloatingStatus(
                            phase: .review,
                            title: "已复制，等待授权",
                            detail: "结果已复制，需开启无障碍权限后才能自动上屏。\(MacProductCopy.name) 菜单 -> 打开无障碍设置。\(result.finalText.oneLinePreview(maxLength: 56))",
                            startedAt: nil
                        )
                    )
                case .targetUnavailable:
                    floatingPanel.show(
                        MacFloatingStatus(
                            phase: .review,
                            title: "目标应用不可用，已复制",
                            detail: "原目标窗口无法唤回。结果已在剪贴板，请手动粘贴。\(result.finalText.oneLinePreview(maxLength: 56))",
                            startedAt: nil
                        )
                    )
                case .failedToWrite:
                    floatingPanel.show(
                        MacFloatingStatus(
                            phase: .error,
                            title: "上屏失败",
                            detail: "pasteboard_write_failed \(result.finalText.oneLinePreview(maxLength: 72))",
                            startedAt: nil
                        )
                    )
                }
            } catch is CancellationError {
                return
            } catch PipelineError.asrUnavailable("no_speech_detected") {
                // Silence is a normal outcome, not a failure — quiet hint only.
                floatingPanel.show(
                    MacFloatingStatus(
                        phase: .idle,
                        title: "没有听到声音",
                        detail: "",
                        startedAt: nil
                    )
                )
                floatingPanel.hide(after: 1.6)
            } catch {
                floatingPanel.show(
                    MacFloatingStatus(
                        phase: .error,
                        title: "处理失败",
                        detail: VeloraErrorPresenter.message(for: error),
                        startedAt: nil
                    )
                )
            }
        }
        refreshEscapeCancellationState()
    }

    private func presentTranslationReview(
        result: PipelineRunResult,
        elapsedMS: Int,
        preferredInsertLanguage: String,
        target: MacInsertionTarget?
    ) {
        guard let translation = result.translation else {
            floatingPanel.show(
                MacFloatingStatus(
                    phase: .error,
                    title: "缺少译文",
                    detail: "translation_result_missing",
                    startedAt: nil
                )
            )
            return
        }

        let preferredSelection: MacTranslationReviewSelection =
            TranslationLanguageResolver.normalizedLanguage(preferredInsertLanguage)
                == TranslationLanguageResolver.normalizedLanguage(translation.mode.sourceLanguage)
            ? .source
            : .target
        let review = MacPendingTranslationReview(
            sourceText: translation.correctedSourceText,
            targetText: translation.targetText,
            sourceLanguage: translation.mode.sourceLanguage,
            targetLanguage: translation.mode.targetLanguage,
            modeSummary: "\(TranslationLanguageResolver.displayName(for: translation.mode.sourceLanguage)) → \(TranslationLanguageResolver.displayName(for: translation.mode.targetLanguage))",
            latencyDetail: "wall_ms=\(elapsedMS)",
            warnings: translation.warnings,
            asrText: result.asr.text,
            appliedEdits: result.correction.edits + result.compose.edits,
            target: target,
            preferredSelection: preferredSelection
        )
        pendingReview = review
        refreshEscapeCancellationState()
        reviewPanel.show(review)
    }

    private func retranslatePendingReview() {
        guard let review = pendingReview else {
            return
        }

        let editedSource = reviewPanel.editedSource.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !editedSource.isEmpty else {
            return
        }

        reviewPanel.setRetranslating(true)
        Task { [weak self] in
            defer {
                self?.reviewPanel.setRetranslating(false)
            }
            do {
                let output = try await OllamaTranslationEngine().translate(
                    LocalTranslationRequest(
                        sourceText: editedSource,
                        correctedSourceText: editedSource,
                        sourceLanguage: review.sourceLanguage,
                        targetLanguage: review.targetLanguage,
                        context: ContextSnapshot(appBundle: "app.velora.review.retranslate", mode: .translate),
                        glossary: [],
                        deadlineMS: ComposeRequest.defaultTranslateDeadlineMS
                    )
                )
                let target = output.targetText.trimmingCharacters(in: .whitespacesAndNewlines)
                guard self?.pendingReview?.id == review.id else {
                    return
                }
                if target.isEmpty {
                    self?.reviewPanel.showRetranslateIssue("重译超时，保留原译文")
                } else {
                    self?.reviewPanel.updateTarget(target)
                }
            } catch {
                guard self?.pendingReview?.id == review.id else {
                    return
                }
                self?.reviewPanel.showRetranslateIssue(VeloraErrorPresenter.message(for: error))
            }
        }
    }

    /// Watches for ⌘Z in the target app shortly after an insertion — a strong
    /// negative signal we can capture WITHOUT reading any app content (we only
    /// observe the key chord, never text). Auto-expires with the window.
    private func startUndoWatch() {
        stopUndoWatch()
        undoMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.modifierFlags.contains(.command),
                  event.charactersIgnoringModifiers?.lowercased() == "z" else {
                return
            }
            Task { @MainActor in
                self?.handlePotentialUndo()
            }
        }
        undoWatchExpiry = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 30_000_000_000)
            guard !Task.isCancelled else {
                return
            }
            self?.stopUndoWatch()
        }
    }

    private func stopUndoWatch() {
        if let undoMonitor {
            NSEvent.removeMonitor(undoMonitor)
            self.undoMonitor = nil
        }
        undoWatchExpiry?.cancel()
        undoWatchExpiry = nil
    }

    private func handlePotentialUndo() {
        guard let record = lastInsertion,
              Date().timeIntervalSince(record.at) <= 30,
              let targetBundleID = record.targetBundleID,
              NSWorkspace.shared.frontmostApplication?.bundleIdentifier == targetBundleID else {
            return
        }

        MacCorrectionJournal.recordUndoAfterInsert(
            record: record,
            secondsAfterInsert: Date().timeIntervalSince(record.at)
        )
        stopUndoWatch()
        lastInsertion = nil
    }

    private func modeTitle(for settings: VeloraRuntimeSettings) -> String {
        switch settings.mode {
        case .input:
            return "输入 \(settings.sourceLanguage) \(settings.asrModelMode.rawValue)"
        case .translate:
            return "翻译 \(settings.sourceLanguage)->\(settings.targetLanguage) \(settings.asrModelMode.rawValue)"
        }
    }

    private func makePipeline(
        for settings: VeloraRuntimeSettings,
        prepared: MacPreparedPipelineContext? = nil
    ) -> PipelineOrchestrator {
        PipelineOrchestrator(
            asrEngine: senseVoiceEngine
                ?? WhisperCLIASREngine(configuration: .configuration(for: settings.asrModelMode)),
            contextProvider: prepared.map { MacPreparedContextProvider(snapshot: $0.snapshot) }
                ?? MacContextProvider() as any ContextProvider,
            memoryStore: prepared.map { MacPreparedMemoryStore(hotwords: $0.hotwords) }
                ?? activeMemoryStore,
            textEngine: OllamaTextIntelligenceEngine(),
            translationEngine: OllamaTranslationEngine(),
            insertionEngine: MacPasteboardInsertionEngine()
        )
    }
}

/// Context + hotwords captured while the user was still speaking. Handing
/// them to the pipeline as constant providers moves那两段工作 out of the
/// after-release critical path (their trace stages then measure ~0ms).
struct MacPreparedPipelineContext: Sendable {
    var snapshot: ContextSnapshot
    var hotwords: [HotwordCandidate]
}

struct MacPreparedContextProvider: ContextProvider {
    var snapshot: ContextSnapshot

    func currentSnapshot(for request: PipelineRunRequest) async -> ContextSnapshot {
        var snapshot = snapshot
        snapshot.mode = request.mode
        snapshot.languagePair = request.targetLanguage.map { "\(request.sourceLanguage)-\($0)" }
        return snapshot
    }
}

struct MacPreparedMemoryStore: MemoryStore {
    var hotwords: [HotwordCandidate]

    func rankHotwords(for snapshot: ContextSnapshot, limit: Int) async throws -> [HotwordCandidate] {
        Array(hotwords.prefix(limit))
    }
}

private extension Duration {
    var milliseconds: Int {
        let components = components
        return Int(components.seconds * 1_000 + components.attoseconds / 1_000_000_000_000_000)
    }
}

private extension String {
    func oneLinePreview(maxLength: Int) -> String {
        let preview = split(whereSeparator: \.isNewline).joined(separator: " ")
        guard preview.count > maxLength else {
            return preview
        }
        return String(preview.prefix(maxLength)) + "..."
    }
}

struct MacContextProvider: ContextProvider {
    func currentSnapshot(for request: PipelineRunRequest) async -> ContextSnapshot {
        await MainActor.run {
            let app = NSWorkspace.shared.frontmostApplication
            let appBundle = app?.bundleIdentifier ?? "unknown"
            let windowTitle = VeloraTextSanitizer.contextText(Self.focusedWindowTitle(), maxLength: 160)
            let selectedText = VeloraTextSanitizer.contextText(Self.focusedSelectedText(), maxLength: 800)
            let nearbyText = selectedText.isEmpty
                ? VeloraTextSanitizer.contextText(Self.focusedValuePreview(), maxLength: 400)
                : selectedText
            let languagePair = request.targetLanguage.map { "\(request.sourceLanguage)-\($0)" }

            return ContextSnapshot(
                appBundle: appBundle,
                windowTitle: windowTitle,
                selectedText: selectedText,
                nearbyText: nearbyText,
                mode: request.mode,
                languagePair: languagePair,
                privacyScope: "ephemeral"
            )
        }
    }

    private static func focusedWindowTitle() -> String {
        guard AXIsProcessTrusted(),
              let appElement = frontmostApplicationElement(),
              let window = copyAXElementAttribute(appElement, kAXFocusedWindowAttribute),
              let title = copyAXAttribute(window, kAXTitleAttribute) as? String else {
            return ""
        }
        return title
    }

    private static func focusedSelectedText() -> String {
        guard AXIsProcessTrusted(),
              let element = focusedElement(),
              let selectedText = copyAXAttribute(element, kAXSelectedTextAttribute) as? String else {
            return ""
        }
        return selectedText
    }

    private static func focusedValuePreview() -> String {
        guard AXIsProcessTrusted(),
              let element = focusedElement(),
              let value = copyAXAttribute(element, kAXValueAttribute) as? String else {
            return ""
        }
        return value.oneLinePreview(maxLength: 400)
    }

    private static func focusedElement() -> AXUIElement? {
        let systemWide = AXUIElementCreateSystemWide()
        return copyAXElementAttribute(systemWide, kAXFocusedUIElementAttribute)
    }

    private static func frontmostApplicationElement() -> AXUIElement? {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else {
            return nil
        }
        return AXUIElementCreateApplication(pid)
    }

    private static func copyAXAttribute(_ element: AXUIElement, _ attribute: String) -> AnyObject? {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard error == .success else {
            return nil
        }
        return value
    }

    private static func copyAXElementAttribute(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard error == .success,
              let value,
              CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }
        return (value as! AXUIElement)
    }
}

struct MacPasteboardInsertionEngine: InsertionEngine {
    func insert(_ request: InsertionRequest) async throws -> InsertionResult {
        let start = ContinuousClock.now
        let outcome = await MainActor.run {
            MacPasteboardInserter.insert(request.text)
        }
        let elapsedMS = start.duration(to: ContinuousClock.now).milliseconds
        return InsertionResult(
            strategy: .pasteboard,
            inserted: outcome == .inserted,
            fallbackText: outcome == .inserted ? nil : request.text,
            latencyMS: elapsedMS
        )
    }
}

enum MacPasteboardInsertOutcome {
    case inserted
    case copiedNeedsAccessibility
    /// The release-time target app could not be brought back to front.
    /// Text stays on the clipboard; we never paste into whatever is frontmost.
    case targetUnavailable
    case failedToWrite
}

struct MacInsertionTarget: Equatable {
    var processIdentifier: pid_t
    var bundleIdentifier: String
    var localizedName: String

    var displayName: String {
        if !localizedName.isEmpty {
            return localizedName
        }
        if !bundleIdentifier.isEmpty {
            return bundleIdentifier
        }
        return "pid=\(processIdentifier)"
    }

    @MainActor
    static func captureFrontmost() -> MacInsertionTarget? {
        guard let app = NSWorkspace.shared.frontmostApplication else {
            return nil
        }

        return MacInsertionTarget(
            processIdentifier: app.processIdentifier,
            bundleIdentifier: app.bundleIdentifier ?? "",
            localizedName: app.localizedName ?? ""
        )
    }

    @MainActor
    func activateBeforeInsertion() -> Bool {
        guard let app = NSRunningApplication(processIdentifier: processIdentifier),
              !app.isTerminated else {
            return false
        }

        if AXIsProcessTrusted() {
            let appElement = AXUIElementCreateApplication(processIdentifier)
            let axResult = AXUIElementSetAttributeValue(
                appElement,
                kAXFrontmostAttribute as CFString,
                kCFBooleanTrue
            )
            if axResult == .success {
                return true
            }
        }

        return app.activate(options: [])
    }
}

@MainActor
enum MacPasteboardInserter {
    static func insert(
        _ text: String,
        target: MacInsertionTarget? = nil
    ) -> MacPasteboardInsertOutcome {
        guard !text.isEmpty else {
            return .failedToWrite
        }

        guard AXIsProcessTrusted() else {
            requestAccessibilityPermissionPrompt()
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            return pasteboard.setString(text, forType: .string)
                ? .copiedNeedsAccessibility
                : .failedToWrite
        }

        let pasteboard = NSPasteboard.general
        let snapshot = MacPasteboardSnapshot.capture(from: pasteboard)
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else {
            snapshot.restoreIfUnchanged(to: pasteboard)
            return .failedToWrite
        }

        let writtenChangeCount = pasteboard.changeCount
        // Fail closed: with a known target, never paste into whatever app
        // happens to be frontmost. Activation must succeed AND the frontmost
        // app must actually be the target before Cmd+V is posted.
        if let target {
            guard target.activateBeforeInsertion() else {
                return .targetUnavailable
            }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.08))
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier else {
                return .targetUnavailable
            }
        }
        postCommandV()

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            snapshot.restoreIfUnchanged(to: pasteboard, expectedChangeCount: writtenChangeCount)
        }

        return .inserted
    }

    private static func requestAccessibilityPermissionPrompt() {
        let options = [
            "AXTrustedCheckOptionPrompt": true,
        ] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    private static func postCommandV() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let keyDown = CGEvent(
            keyboardEventSource: source,
            virtualKey: CGKeyCode(kVK_ANSI_V),
            keyDown: true
        )
        let keyUp = CGEvent(
            keyboardEventSource: source,
            virtualKey: CGKeyCode(kVK_ANSI_V),
            keyDown: false
        )
        keyDown?.flags = .maskCommand
        keyUp?.flags = .maskCommand
        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)
    }
}

struct MacPasteboardSnapshot {
    private var changeCount: Int
    private var items: [[NSPasteboard.PasteboardType: Data]]

    static func capture(from pasteboard: NSPasteboard) -> MacPasteboardSnapshot {
        let items = pasteboard.pasteboardItems?.map { item in
            item.types.reduce(into: [NSPasteboard.PasteboardType: Data]()) { result, type in
                result[type] = item.data(forType: type)
            }
        } ?? []

        return MacPasteboardSnapshot(
            changeCount: pasteboard.changeCount,
            items: items
        )
    }

    func restoreIfUnchanged(to pasteboard: NSPasteboard, expectedChangeCount: Int? = nil) {
        let expected = expectedChangeCount ?? changeCount
        guard pasteboard.changeCount == expected else {
            return
        }

        pasteboard.clearContents()
        let restoredItems = items.map { itemData in
            let item = NSPasteboardItem()
            for (type, data) in itemData {
                item.setData(data, forType: type)
            }
            return item
        }
        if !restoredItems.isEmpty {
            pasteboard.writeObjects(restoredItems)
        }
    }
}

/// What we remember about the most recent successful insertion, so a quick
/// retry (re-dictating the same thing) or an undo in the target app can be
/// journaled as negative feedback. Detection is deterministic on purpose:
/// this signal demotes hotwords, and a false positive is worse than a miss.
struct MacLastInsertionRecord {
    var finalText: String
    var asrText: String
    var appliedEdits: [TextEdit]
    var targetBundleID: String?
    var mode: DictationMode
    var at: Date
}

struct MacPendingTranslationReview: Identifiable {
    let id = UUID()
    var sourceText: String
    var targetText: String
    var sourceLanguage: String
    var targetLanguage: String
    var modeSummary: String
    var latencyDetail: String
    var warnings: [String]
    var asrText: String
    var appliedEdits: [TextEdit]
    var target: MacInsertionTarget?
    /// The side the settings panel promises to insert on plain confirm
    /// (hotkey / ⌘⏎ / menu). The overlay buttons can still pick either side.
    var preferredSelection: MacTranslationReviewSelection = .target

    var sourceLanguageDisplayName: String {
        TranslationLanguageResolver.displayName(for: sourceLanguage)
    }

    var targetLanguageDisplayName: String {
        TranslationLanguageResolver.displayName(for: targetLanguage)
    }
}

/// Which single-language text to insert. Insertion is never bilingual
/// (product decision 2026-07-05); the bilingual view lives only in the overlay.
enum MacTranslationReviewSelection {
    case source
    case target

    var actionTitle: String {
        self == .source ? "上屏原文" : "上屏译文"
    }
}

/// Locally journaled correction pairs — the raw feed for Phase 2 memory
/// (hotword/glossary evolution). Result text stays on this machine, same
/// privacy tier as History; nothing here is ever logged or sent anywhere.
enum MacCorrectionJournal {
    static func recordIfEdited(
        review: MacPendingTranslationReview,
        editedSource: String,
        editedTarget: String,
        insertedSelection: MacTranslationReviewSelection
    ) {
        let sourceEdited = editedSource != review.sourceText
        let targetEdited = editedTarget != review.targetText
        guard sourceEdited || targetEdited else {
            return
        }

        var entry: [String: Any] = [
            "kind": "translate_review_edit",
            "at": ISO8601DateFormatter().string(from: Date()),
            "language_pair": "\(review.sourceLanguage)-\(review.targetLanguage)",
            "inserted": insertedSelection == .source ? "source" : "target",
        ]
        if sourceEdited {
            entry["source_before"] = review.sourceText
            entry["source_after"] = editedSource
        }
        if targetEdited {
            entry["target_before"] = review.targetText
            entry["target_after"] = editedTarget
        }
        append(entry)
    }

    static func recordRetryRedictation(
        previous: MacLastInsertionRecord,
        newASRText: String,
        similarity: Double
    ) {
        append([
            "kind": "retry_redictation",
            "at": ISO8601DateFormatter().string(from: Date()),
            "mode": previous.mode.rawValue,
            "similarity": (similarity * 100).rounded() / 100,
            "previous_asr": previous.asrText,
            "previous_final": previous.finalText,
            "new_asr": newASRText,
            "applied_edits": previous.appliedEdits.map { ["from": $0.from, "to": $0.to, "reason": $0.reason] },
        ])
    }

    static func recordUndoAfterInsert(
        record: MacLastInsertionRecord,
        secondsAfterInsert: TimeInterval
    ) {
        append([
            "kind": "undo_after_insert",
            "at": ISO8601DateFormatter().string(from: Date()),
            "mode": record.mode.rawValue,
            "seconds_after_insert": (secondsAfterInsert * 10).rounded() / 10,
            "final_text": record.finalText,
            "asr_text": record.asrText,
            "applied_edits": record.appliedEdits.map { ["from": $0.from, "to": $0.to, "reason": $0.reason] },
        ])
    }

    private static func append(_ entry: [String: Any]) {
        guard let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return
        }
        let folder = directory.appendingPathComponent("Velora", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("corrections.jsonl")
        guard let data = try? JSONSerialization.data(withJSONObject: entry),
              let line = String(data: data, encoding: .utf8) else {
            return
        }
        if let handle = try? FileHandle(forWritingTo: file) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data((line + "\n").utf8))
        } else {
            try? Data((line + "\n").utf8).write(to: file)
        }
    }
}

@MainActor
final class MacTranslationReviewPanelModel: ObservableObject {
    @Published var review: MacPendingTranslationReview?
    @Published var editedSource = ""
    @Published var editedTarget = ""
    @Published var isRetranslating = false
    @Published var retranslateIssue = ""
    var onConfirm: ((MacTranslationReviewSelection) -> Void)?
    var onCancel: (() -> Void)?
    var onRetranslate: (() -> Void)?

    var sourceWasEdited: Bool {
        guard let review else {
            return false
        }
        return editedSource != review.sourceText
    }
}

/// Borderless non-activating panels refuse key status by default; the overlay
/// hosts editable text, so it must be able to take keyboard focus without
/// activating the app (the target app keeps frontmost status for re-insertion).
final class MacKeyableReviewPanel: NSPanel {
    override var canBecomeKey: Bool {
        true
    }
}

@MainActor
final class MacTranslationReviewPanelController {
    private let model = MacTranslationReviewPanelModel()
    private lazy var panel: NSPanel = makePanel()

    init(
        onConfirm: @escaping (MacTranslationReviewSelection) -> Void,
        onCancel: @escaping () -> Void,
        onRetranslate: @escaping () -> Void
    ) {
        model.onConfirm = onConfirm
        model.onCancel = onCancel
        model.onRetranslate = onRetranslate
    }

    var editedSource: String {
        model.editedSource
    }

    var editedTarget: String {
        model.editedTarget
    }

    func editedText(for selection: MacTranslationReviewSelection) -> String {
        selection == .source ? model.editedSource : model.editedTarget
    }

    func show(_ review: MacPendingTranslationReview) {
        model.review = review
        model.editedSource = review.sourceText
        model.editedTarget = review.targetText
        model.isRetranslating = false
        model.retranslateIssue = ""
        positionPanel()
        panel.orderFrontRegardless()
        panel.makeKey()
    }

    func hide() {
        panel.orderOut(nil)
    }

    func updateTarget(_ text: String) {
        model.editedTarget = text
        model.retranslateIssue = ""
    }

    func setRetranslating(_ retranslating: Bool) {
        model.isRetranslating = retranslating
    }

    func showRetranslateIssue(_ message: String) {
        model.retranslateIssue = message
    }

    private func makePanel() -> NSPanel {
        let panel = MacKeyableReviewPanel(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 360),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // Shadow is drawn by the card itself via .veloraCard(...); a window
        // shadow would double up and show the transparent canvas rectangle.
        panel.hasShadow = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.contentView = NSHostingView(rootView: MacTranslationReviewPanelView(model: model))
        return panel
    }

    private func positionPanel() {
        guard let screen = NSScreen.main else {
            return
        }

        let frame = screen.visibleFrame
        let size = panel.frame.size
        let origin = NSPoint(
            x: frame.midX - size.width / 2,
            // 56 keeps the visible card at the old minY+96 spot now that the
            // window carries a 40pt transparent shadow margin below the card.
            y: frame.minY + 56
        )
        panel.setFrameOrigin(origin)
    }
}

struct MacTranslationReviewPanelView: View {
    @ObservedObject var model: MacTranslationReviewPanelModel
    @FocusState private var focusedField: Field?

    enum Field {
        case source
        case target
    }

    var body: some View {
        if let review = model.review {
            VStack(alignment: .leading, spacing: 10) {
                header(review)
                sourceSection(review)
                targetSection(review)
                footer
            }
            .padding(16)
            .frame(width: 560)
            .veloraCard(radius: VeloraRadius.large, elevation: .high)
            // Transparent margin so the card's shadow can fade out naturally.
            // Without it the window is exactly card-sized and the shadow gets
            // clipped into the four rounded-corner notches, leaving
            // square-edged shadow remnants at each corner.
            .padding(40)
            .onAppear {
                focusedField = .target
            }
        }
    }

    private func header(_ review: MacPendingTranslationReview) -> some View {
        HStack(spacing: 8) {
            Text("确认翻译")
                .font(VeloraFont.heading(13))
                .foregroundStyle(Color.veloraInkPrimary)
            Text(review.modeSummary)
                .font(VeloraFont.caption(11, weight: .medium))
                .foregroundStyle(Color.veloraInkSecondary)
            if !review.warnings.isEmpty {
                Text("⚠︎ \(review.warnings.joined(separator: " · "))")
                    .font(VeloraFont.caption(10, weight: .medium))
                    .foregroundStyle(Color.veloraAccent)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Button {
                model.onCancel?()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .accessibilityLabel("取消")
        }
    }

    private func sourceSection(_ review: MacPendingTranslationReview) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("原文 · \(review.sourceLanguageDisplayName)")
                    .font(VeloraFont.caption(11, weight: .semibold))
                    .foregroundStyle(Color.veloraInkSecondary)
                if model.isRetranslating {
                    ProgressView()
                        .controlSize(.small)
                } else if model.sourceWasEdited {
                    Button {
                        model.onRetranslate?()
                    } label: {
                        Label("重新翻译", systemImage: "arrow.triangle.2.circlepath")
                            .font(VeloraFont.caption(11, weight: .medium))
                    }
                    .buttonStyle(.borderless)
                    .keyboardShortcut("r", modifiers: .command)
                }
                if !model.retranslateIssue.isEmpty {
                    Text(model.retranslateIssue)
                        .font(VeloraFont.caption(10))
                        .foregroundStyle(Color.veloraAccent)
                        .lineLimit(1)
                }
                Spacer()
            }

            TextEditor(text: $model.editedSource)
                .font(VeloraFont.body(12.5))
                .scrollContentBackground(.hidden)
                .padding(7)
                .frame(height: 76)
                .veloraTextEditorStyle(isFocused: focusedField == .source)
                .focused($focusedField, equals: .source)
        }
    }

    private func targetSection(_ review: MacPendingTranslationReview) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("译文 · \(review.targetLanguageDisplayName)")
                    .font(VeloraFont.caption(11, weight: .semibold))
                    .foregroundStyle(Color.veloraInkSecondary)
                Text("将上屏 · 可直接修改")
                    .font(VeloraFont.caption(10))
                    .foregroundStyle(Color.veloraInkSecondary.opacity(0.7))
                Spacer()
            }

            TextEditor(text: $model.editedTarget)
                .font(VeloraFont.body(14))
                .lineSpacing(2)
                .scrollContentBackground(.hidden)
                .padding(8)
                .frame(height: 112)
                .veloraTextEditorStyle(isFocused: focusedField == .target)
                .focused($focusedField, equals: .target)
        }
    }

    private var footer: some View {
        // The prominent ⌘⏎ button always carries the settings-preferred side;
        // the bordered button is the per-utterance override for the other side.
        let preferred = model.review?.preferredSelection ?? .target
        let other: MacTranslationReviewSelection = preferred == .source ? .target : .source
        return HStack(spacing: 10) {
            Text("Esc 取消 · \(MacProductCopy.hotKey) 或 ⌘⏎ \(preferred.actionTitle) · 修改将用于优化热词")
                .font(VeloraFont.caption(10))
                .foregroundStyle(Color.veloraInkSecondary.opacity(0.7))
                .lineLimit(1)
            Spacer()
            Button(other.actionTitle) {
                model.onConfirm?(other)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            Button {
                model.onConfirm?(preferred)
            } label: {
                Label(preferred.actionTitle, systemImage: "keyboard")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .tint(Color.veloraAccent)
            .keyboardShortcut(.return, modifiers: .command)
        }
    }
}

final class MacEscapeHotKeyCenter {
    private static let signature = OSType(UInt32(ascii: "VESC"))
    private static let hotKeyID = UInt32(99)

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    private var enabled = false
    private let handler: () -> Void

    init(handler: @escaping () -> Void) {
        self.handler = handler
    }

    func setEnabled(_ enabled: Bool) {
        if enabled {
            guard !self.enabled else {
                return
            }
            do {
                try register()
                self.enabled = true
            } catch {
                unregisterHotKey()
                self.enabled = false
            }
        } else {
            unregisterHotKey()
            self.enabled = false
        }
    }

    func invalidate() {
        unregisterHotKey()
        if let eventHandlerRef {
            RemoveEventHandler(eventHandlerRef)
            self.eventHandlerRef = nil
        }
        enabled = false
    }

    deinit {
        invalidate()
    }

    private func register() throws {
        try installHandlerIfNeeded()

        let hotKeyID = EventHotKeyID(
            signature: Self.signature,
            id: Self.hotKeyID
        )
        var newRef: EventHotKeyRef?
        let status = RegisterEventHotKey(
            UInt32(kVK_Escape),
            0,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &newRef
        )

        guard status == noErr, let newRef else {
            throw MacGlobalHotKeyCenter.HotKeyError.registerFailed(status)
        }

        hotKeyRef = newRef
    }

    private func unregisterHotKey() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
    }

    private func installHandlerIfNeeded() throws {
        guard eventHandlerRef == nil else {
            return
        }

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let selfPointer = Unmanaged.passUnretained(self).toOpaque()
        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                guard let userData else {
                    return noErr
                }

                let center = Unmanaged<MacEscapeHotKeyCenter>.fromOpaque(userData).takeUnretainedValue()
                var hotKeyID = EventHotKeyID()
                GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )

                guard hotKeyID.signature == MacEscapeHotKeyCenter.signature,
                      hotKeyID.id == MacEscapeHotKeyCenter.hotKeyID else {
                    return noErr
                }

                center.handler()
                return noErr
            },
            1,
            &eventType,
            selfPointer,
            &eventHandlerRef
        )

        guard installStatus == noErr else {
            throw MacGlobalHotKeyCenter.HotKeyError.installHandlerFailed(installStatus)
        }
    }
}

final class MacEscapeEventTap {
    private let enabledQueue = DispatchQueue(label: "app.velora.mac.escape-event-tap")
    private var enabled = false
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private let handler: () -> Void

    init(handler: @escaping () -> Void) {
        self.handler = handler
        install()
    }

    func setEnabled(_ enabled: Bool) {
        enabledQueue.sync {
            self.enabled = enabled
        }
    }

    func invalidate() {
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
        setEnabled(false)
    }

    deinit {
        invalidate()
    }

    private func install() {
        let mask = CGEventMask(1) << CGEventType.keyDown.rawValue
        let selfPointer = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, userData in
                guard let userData else {
                    return Unmanaged.passUnretained(event)
                }

                let bridge = Unmanaged<MacEscapeEventTap>.fromOpaque(userData).takeUnretainedValue()
                return bridge.handle(type: type, event: event)
            },
            userInfo: selfPointer
        ) else {
            return
        }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        if let runLoopSource {
            CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        guard type == .keyDown,
              event.getIntegerValueField(.keyboardEventKeycode) == Int64(kVK_Escape) else {
            return Unmanaged.passUnretained(event)
        }

        let shouldCancel = enabledQueue.sync { enabled }
        guard shouldCancel else {
            return Unmanaged.passUnretained(event)
        }

        handler()
        return nil
    }
}

/// Owns the physical Fn key at the session event-tap level so a bare Fn press
/// can be swallowed before macOS's own "press 🌐 key to switch input source"
/// handling ever sees it. `NSEvent` global/local monitors can only observe
/// `flagsChanged`, never consume it, which is why the system action used to
/// fire alongside (or instead of) Velora's own action.
final class MacFunctionKeyEventTap {
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private let handler: (CGEvent) -> Bool

    init(handler: @escaping (CGEvent) -> Bool) {
        self.handler = handler
        install()
    }

    func invalidate() {
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
    }

    deinit {
        invalidate()
    }

    private func install() {
        let mask = CGEventMask(1) << CGEventType.flagsChanged.rawValue
        let selfPointer = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, userData in
                guard let userData else {
                    return Unmanaged.passUnretained(event)
                }

                let bridge = Unmanaged<MacFunctionKeyEventTap>.fromOpaque(userData).takeUnretainedValue()
                return bridge.handle(type: type, event: event)
            },
            userInfo: selfPointer
        ) else {
            return
        }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        if let runLoopSource {
            CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        guard type == .flagsChanged else {
            return Unmanaged.passUnretained(event)
        }

        return handler(event) ? nil : Unmanaged.passUnretained(event)
    }
}

final class MacGlobalHotKeyCenter {
    enum HotKeyError: Error {
        case registerFailed(OSStatus)
        case installHandlerFailed(OSStatus)
    }

    private var hotKeyRefs: [EventHotKeyRef] = []
    private var eventHandlerRef: EventHandlerRef?
    private var functionKeyEventTap: MacFunctionKeyEventTap?
    private var pendingFunctionWorkItem: DispatchWorkItem?
    private var lastModifierFlags: CGEventFlags = []
    private var functionComboTriggered = false
    private var functionMappings: [MacHotKeyPreset: MacHotKeyInvocation] = [:]
    private var handler: ((MacHotKeyInvocation) -> Void)?

    /// When true, a bare Fn press fires without the Fn⇧ disambiguation delay.
    /// Set by the controller while a capture flow is active, so stopping a
    /// recording never pays the 140ms wait.
    var prefersImmediateBareFunction: (() -> Bool)?

    func register(
        preferences: MacHotKeyPreferences,
        handler: @escaping (MacHotKeyInvocation) -> Void
    ) throws {
        unregister()
        self.handler = handler
        functionMappings = [:]
        if preferences.capture.usesFunctionModifier {
            functionMappings[preferences.capture] = .capture
        }
        if preferences.translate.usesFunctionModifier, functionMappings[preferences.translate] == nil {
            functionMappings[preferences.translate] = .translate
        }

        let carbonAssignments: [(preset: MacHotKeyPreset, invocation: MacHotKeyInvocation, id: UInt32)] = [
            (preferences.capture, .capture, 1),
            (preferences.translate, .translate, 2),
        ].filter { $0.preset.carbonRegistration != nil }

        if !carbonAssignments.isEmpty {
            try installCarbonHandlerIfNeeded()
            var registeredPresets = Set<MacHotKeyPreset>()
            for assignment in carbonAssignments where !registeredPresets.contains(assignment.preset) {
                try registerCarbonHotKey(assignment.preset, id: assignment.id)
                registeredPresets.insert(assignment.preset)
            }
        }

        if !functionMappings.isEmpty {
            installFunctionKeyEventTap()
        }
    }

    func unregister() {
        pendingFunctionWorkItem?.cancel()
        pendingFunctionWorkItem = nil

        for hotKeyRef in hotKeyRefs {
            UnregisterEventHotKey(hotKeyRef)
        }
        hotKeyRefs.removeAll()

        if let eventHandlerRef {
            RemoveEventHandler(eventHandlerRef)
            self.eventHandlerRef = nil
        }

        functionKeyEventTap?.invalidate()
        functionKeyEventTap = nil

        handler = nil
        functionMappings.removeAll()
        lastModifierFlags = []
        functionComboTriggered = false
    }

    deinit {
        unregister()
    }

    private func installCarbonHandlerIfNeeded() throws {
        guard eventHandlerRef == nil else {
            return
        }

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let selfPointer = Unmanaged.passUnretained(self).toOpaque()
        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                guard let userData else {
                    return noErr
                }

                let center = Unmanaged<MacGlobalHotKeyCenter>.fromOpaque(userData).takeUnretainedValue()
                var hotKeyID = EventHotKeyID()
                GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )

                switch hotKeyID.id {
                case 1:
                    center.handler?(.capture)
                case 2:
                    center.handler?(.translate)
                default:
                    break
                }
                return noErr
            },
            1,
            &eventType,
            selfPointer,
            &eventHandlerRef
        )

        guard installStatus == noErr else {
            throw HotKeyError.installHandlerFailed(installStatus)
        }
    }

    private func registerCarbonHotKey(_ preset: MacHotKeyPreset, id: UInt32) throws {
        guard let registration = preset.carbonRegistration else {
            return
        }

        let hotKeyID = EventHotKeyID(
            signature: OSType(UInt32(ascii: "VLRA")),
            id: id
        )
        var hotKeyRef: EventHotKeyRef?
        let registerStatus = RegisterEventHotKey(
            registration.keyCode,
            registration.modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )

        guard registerStatus == noErr, let hotKeyRef else {
            unregister()
            throw HotKeyError.registerFailed(registerStatus)
        }

        hotKeyRefs.append(hotKeyRef)
    }

    private func installFunctionKeyEventTap() {
        functionKeyEventTap = MacFunctionKeyEventTap { [weak self] event in
            self?.handleModifierEvent(event) ?? false
        }
    }

    /// Whether Velora claims the physical Fn key end-to-end. Only true when a
    /// bare Fn press is actually mapped to something — if the user only wired
    /// up Fn⇧, a lone Fn tap is left untouched so macOS's own input-source
    /// switch keeps working exactly as before.
    private var ownsFunctionKey: Bool {
        functionMappings[.function] != nil
    }

    /// - Returns: `true` if the tap should swallow this event (prevent it
    ///   from reaching the focused app or the system's default Fn handling).
    private func handleModifierEvent(_ event: CGEvent) -> Bool {
        let flags = event.flags.intersection([.maskSecondaryFn, .maskShift])
        let functionWasDown = lastModifierFlags.contains(.maskSecondaryFn)
        let functionIsDown = flags.contains(.maskSecondaryFn)
        let shiftWasDown = lastModifierFlags.contains(.maskShift)
        let shiftIsDown = flags.contains(.maskShift)

        defer {
            lastModifierFlags = flags
        }

        if functionIsDown && !functionWasDown {
            functionComboTriggered = false
            if shiftIsDown {
                pendingFunctionWorkItem?.cancel()
                fireFunctionPreset(.functionShift)
            } else {
                scheduleOrFireBareFunction()
            }
            return ownsFunctionKey
        }

        if functionIsDown && shiftIsDown && !shiftWasDown {
            pendingFunctionWorkItem?.cancel()
            fireFunctionPreset(.functionShift)
            return ownsFunctionKey
        }

        if !functionIsDown && functionWasDown {
            functionComboTriggered = false
            return ownsFunctionKey
        }

        return false
    }

    private func scheduleOrFireBareFunction() {
        guard functionMappings[.function] != nil else {
            return
        }

        if functionMappings[.functionShift] == nil || prefersImmediateBareFunction?() == true {
            fireFunctionPreset(.function)
            return
        }

        pendingFunctionWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, !self.functionComboTriggered else {
                return
            }
            self.fireFunctionPreset(.function)
        }
        pendingFunctionWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(140), execute: workItem)
    }

    private func fireFunctionPreset(_ preset: MacHotKeyPreset) {
        guard !functionComboTriggered,
              let invocation = functionMappings[preset] else {
            return
        }

        functionComboTriggered = true
        handler?(invocation)
    }
}

private extension UInt32 {
    init(ascii string: String) {
        self = string.utf8.reduce(0) { partial, byte in
            (partial << 8) + UInt32(byte)
        }
    }
}

enum MacFloatingPhase {
    case idle
    case requestingPermission
    case listening
    case transcribing
    case review
    case inserted
    case error

    var color: Color {
        switch self {
        case .idle:
            return .veloraInkSecondary
        case .requestingPermission, .transcribing, .review:
            return .veloraAccent
        case .listening:
            return .veloraDanger
        case .inserted:
            return .veloraSuccess
        case .error:
            return .veloraDanger
        }
    }

    var symbolName: String {
        switch self {
        case .idle:
            return "waveform"
        case .requestingPermission:
            return "mic.badge.plus"
        case .listening:
            return "record.circle"
        case .transcribing:
            return "waveform.and.magnifyingglass"
        case .review:
            return "text.bubble"
        case .inserted:
            return "checkmark.circle.fill"
        case .error:
            return "exclamationmark.triangle.fill"
        }
    }
}

struct MacFloatingStatus {
    var phase: MacFloatingPhase
    var title: String
    var detail: String
    var startedAt: Date?
}

@MainActor
final class MacFloatingStatusModel: ObservableObject {
    @Published var status = MacFloatingStatus(
        phase: .idle,
        title: MacProductCopy.name,
        detail: "ready",
        startedAt: nil
    )
    @Published var isVisible = false
    @Published var levelHistory: [Float] = MacFloatingStatusModel.quietLevels

    static var quietLevels: [Float] {
        Array(repeating: 0, count: MacVoiceWaveform.barCount)
    }

    func pushLevel(_ level: Float) {
        var next = levelHistory
        next.removeFirst()
        next.append(min(max(level, 0), 1))
        levelHistory = next
    }

    func resetLevels() {
        levelHistory = Self.quietLevels
    }
}

/// Quiet HUD in the spirit of Typeless: a small bottom-center capsule that
/// appears only while Velora is doing something, never steals clicks, and
/// animates in/out instead of popping.
@MainActor
final class MacFloatingStatusPanelController {
    private let model = MacFloatingStatusModel()
    private lazy var panel: NSPanel = makePanel()
    private var hideTask: Task<Void, Never>?

    func show(_ status: MacFloatingStatus) {
        hideTask?.cancel()
        model.status = status
        if status.phase != .listening {
            model.resetLevels()
        }
        positionPanel()
        panel.orderFrontRegardless()
        model.isVisible = true

        // Nothing on this HUD is interactive, so terminal states must
        // self-clear — a persistent toast would squat on the screen forever.
        // Callers may still schedule a shorter hide after this returns.
        switch status.phase {
        case .error:
            hide(after: 6.0)
        case .review:
            hide(after: 5.0)
        case .idle, .requestingPermission, .listening, .transcribing, .inserted:
            break
        }
    }

    func updateAudioLevel(_ level: Float) {
        model.pushLevel(level)
    }

    func hide(after delay: TimeInterval) {
        hideTask?.cancel()
        hideTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else {
                return
            }
            model.isVisible = false
            // Let the exit transition finish before the window disappears.
            try? await Task.sleep(nanoseconds: 260_000_000)
            guard !Task.isCancelled else {
                return
            }
            panel.orderOut(nil)
        }
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 96),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // Shadow is drawn by the capsule itself; a window shadow would show
        // the full transparent canvas rectangle.
        panel.hasShadow = false
        // Display-only HUD: it must never intercept clicks meant for the app under it.
        panel.ignoresMouseEvents = true
        panel.contentView = NSHostingView(rootView: MacFloatingStatusView(model: model))
        return panel
    }

    private func positionPanel() {
        guard let screen = NSScreen.main else {
            return
        }

        let frame = screen.visibleFrame
        let size = panel.frame.size
        let origin = NSPoint(
            x: frame.midX - size.width / 2,
            y: frame.minY + 40
        )
        panel.setFrameOrigin(origin)
    }
}

struct MacFloatingStatusView: View {
    @ObservedObject var model: MacFloatingStatusModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            if model.isVisible {
                pill
                    .transition(pillTransition)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .padding(.bottom, 12)
        .animation(
            reduceMotion ? .easeOut(duration: 0.12) : .spring(response: 0.34, dampingFraction: 0.8),
            value: model.isVisible
        )
        .animation(.spring(response: 0.3, dampingFraction: 0.86), value: model.status.phase)
        .allowsHitTesting(false)
    }

    private var pillTransition: AnyTransition {
        if reduceMotion {
            return .opacity
        }
        return .scale(scale: 0.9, anchor: .bottom)
            .combined(with: .opacity)
            .combined(with: .offset(y: 10))
    }

    private var pill: some View {
        content
            .padding(.horizontal, 16)
            .frame(height: 38)
            .frame(minWidth: 128)
            .background(.ultraThinMaterial, in: Capsule(style: .continuous))
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(
                        Color.veloraBorder.opacity(colorScheme == .dark ? 0.4 : 0.7),
                        lineWidth: 0.5
                    )
            )
            .veloraShadow(.low)
            .fixedSize()
    }

    @ViewBuilder
    private var content: some View {
        switch model.status.phase {
        case .listening:
            listening
        case .requestingPermission, .transcribing:
            processing
        case .inserted:
            inserted
        case .review, .error, .idle:
            message
        }
    }

    private var listening: some View {
        HStack(spacing: 11) {
            MacPulsingDot(reduceMotion: reduceMotion)
            MacVoiceWaveform(
                levels: model.levelHistory,
                tint: .veloraInkPrimary,
                reduceMotion: reduceMotion
            )
            if let startedAt = model.status.startedAt {
                MacElapsedTimeText(startedAt: startedAt)
            }
        }
        .accessibilityLabel("正在录音")
    }

    private var processing: some View {
        HStack(spacing: 9) {
            MacThinkingDots()
            Text(model.status.title)
                .font(VeloraFont.body(12, weight: .medium))
                .foregroundStyle(Color.veloraInkSecondary)
                .lineLimit(1)
        }
        .accessibilityLabel("正在处理")
    }

    private var inserted: some View {
        HStack(spacing: 7) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.veloraSuccess)
                .accessibilityHidden(true)
            Text("已上屏")
                .font(VeloraFont.body(12, weight: .semibold))
                .foregroundStyle(Color.veloraInkPrimary)
            if !model.status.detail.isEmpty {
                Text(model.status.detail)
                    .font(VeloraFont.mono(11))
                    .foregroundStyle(Color.veloraInkSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: 260)
            }
        }
    }

    private var message: some View {
        HStack(spacing: 8) {
            Image(systemName: model.status.phase.symbolName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(model.status.phase.color)
                .accessibilityHidden(true)
            Text(model.status.title)
                .font(VeloraFont.body(12, weight: .semibold))
                .foregroundStyle(Color.veloraInkPrimary)
                .lineLimit(1)
            if !model.status.detail.isEmpty {
                Text(model.status.detail)
                    .font(VeloraFont.caption(11))
                    .foregroundStyle(Color.veloraInkSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 300)
            }
        }
    }
}

/// Scrolling live waveform: each incoming level pushes the bars one slot to
/// the left, voice-memo style, instead of a synthetic sine wobble.
struct MacVoiceWaveform: View {
    static let barCount = 26

    var levels: [Float]
    var tint: Color
    var reduceMotion: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 2.5) {
            ForEach(levels.indices, id: \.self) { index in
                Capsule(style: .continuous)
                    .fill(tint.opacity(0.35 + Double(levels[index]) * 0.6))
                    .frame(width: 2.5, height: barHeight(levels[index]))
            }
        }
        .frame(height: 22)
        .animation(reduceMotion ? nil : .linear(duration: 0.06), value: levels)
        .accessibilityLabel("录音音量")
    }

    private func barHeight(_ level: Float) -> CGFloat {
        2.5 + CGFloat(pow(Double(level), 0.8)) * 17.5
    }
}

struct MacPulsingDot: View {
    var reduceMotion: Bool
    @State private var dimmed = false

    var body: some View {
        Circle()
            .fill(Color.veloraDanger)
            .frame(width: 7, height: 7)
            .opacity(dimmed ? 0.45 : 1)
            .accessibilityHidden(true)
            .onAppear {
                guard !reduceMotion else {
                    return
                }
                withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                    dimmed = true
                }
            }
    }
}

struct MacThinkingDots: View {
    @State private var animating = false

    var body: some View {
        HStack(spacing: 3.5) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(Color.veloraInkSecondary)
                    .frame(width: 4.5, height: 4.5)
                    .scaleEffect(animating ? 1 : 0.55)
                    .opacity(animating ? 1 : 0.4)
                    .animation(
                        .easeInOut(duration: 0.55)
                            .repeatForever(autoreverses: true)
                            .delay(Double(index) * 0.16),
                        value: animating
                    )
            }
        }
        .accessibilityHidden(true)
        .onAppear {
            animating = true
        }
    }
}

struct MacElapsedTimeText: View {
    var startedAt: Date

    var body: some View {
        TimelineView(.periodic(from: startedAt, by: 1)) { context in
            Text(Self.formattedElapsed(from: startedAt, to: context.date))
                .font(VeloraFont.mono(11, weight: .medium))
                .foregroundStyle(Color.veloraInkSecondary)
                .monospacedDigit()
        }
        .accessibilityLabel("录音时长")
    }

    private static func formattedElapsed(from start: Date, to end: Date) -> String {
        let elapsed = max(0, Int(end.timeIntervalSince(start)))
        return String(format: "%02d:%02d", elapsed / 60, elapsed % 60)
    }
}

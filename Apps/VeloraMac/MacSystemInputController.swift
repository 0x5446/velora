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
    private var hotKeyObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        configureStatusItem()
        registerHotKeys()
        hotKeyObserver = NotificationCenter.default.addObserver(
            forName: MacHotKeyStore.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.registerHotKeys()
                self?.refreshStatusMenu()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        dictationController.invalidate()
        hotKeyCenter.unregister()
        if let hotKeyObserver {
            NotificationCenter.default.removeObserver(hotKeyObserver)
        }
    }

    private func configureStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = MacProductCopy.name
        item.button?.toolTip = "\(MacProductCopy.name) - \(MacProductCopy.subtitle)"

        let menu = NSMenu()
        menu.delegate = self
        menu.addItem(NSMenuItem(title: "开始/停止录音 (\(MacProductCopy.hotKey))", action: #selector(toggleRecording), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "开始翻译 (\(MacProductCopy.translateHotKey))", action: #selector(toggleTranslation), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "确认并上屏", action: #selector(confirmPendingReview), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "取消待确认文本", action: #selector(cancelPendingReview), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "听写模式", action: #selector(useDictateMode), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "润色模式", action: #selector(usePolishMode), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "翻译模式", action: #selector(useTranslateMode), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "ASR 快速模型", action: #selector(useFastASRModel), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "ASR 准确模型", action: #selector(useAccurateASRModel), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "ASR 兜底模型", action: #selector(useFallbackASRModel), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "插入探针文本", action: #selector(insertProbeText), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "检查无障碍权限", action: #selector(checkAccessibilityPermission), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "打开无障碍设置", action: #selector(openAccessibilitySettings), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "显示 Velora 窗口", action: #selector(showMainWindow), keyEquivalent: ""))
        item.menu = menu
        statusItem = item
    }

    private func registerHotKeys() {
        let preferences = MacHotKeyStore.shared.load()
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

    private func refreshStatusMenu() {
        guard let menu = statusItem?.menu else {
            return
        }
        menu.item(at: 0)?.title = "开始/停止录音 (\(MacProductCopy.hotKey))"
        menu.item(at: 1)?.title = "开始翻译 (\(MacProductCopy.translateHotKey))"
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        let settings = VeloraSettingsStore.shared.load()
        menu.item(withTitle: "听写模式")?.state = settings.mode == .dictate ? .on : .off
        menu.item(withTitle: "润色模式")?.state = settings.mode == .polish ? .on : .off
        menu.item(withTitle: "翻译模式")?.state = settings.mode == .translate ? .on : .off
        menu.item(withTitle: "ASR 快速模型")?.state = settings.asrModelMode == .fast ? .on : .off
        menu.item(withTitle: "ASR 准确模型")?.state = settings.asrModelMode == .accurate ? .on : .off
        menu.item(withTitle: "ASR 兜底模型")?.state = settings.asrModelMode == .fallback ? .on : .off
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

    @objc private func useDictateMode() {
        dictationController.setMode(.dictate)
    }

    @objc private func usePolishMode() {
        dictationController.setMode(.polish)
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

    @objc private func showMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first?.makeKeyAndOrderFront(nil)
    }
}

@MainActor
final class MacDictationController {
    private let settingsStore = VeloraSettingsStore.shared
    private let audioService = MacAudioCaptureService()
    private let floatingPanel = MacFloatingStatusPanelController()
    private lazy var reviewPanel = MacTranslationReviewPanelController(
        onConfirm: { [weak self] selection in
            self?.confirmPendingReview(selection: selection)
        },
        onCancel: { [weak self] in
            self?.cancelPendingReview()
        }
    )
    private var isRecording = false
    private var currentClipStartedAt: Date?
    private var activeSettings: VeloraRuntimeSettings?
    private var pendingReview: MacPendingTranslationReview?
    private var recordingStartTask: Task<Void, Never>?
    private var pipelineTask: Task<Void, Never>?
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
    }

    func toggleRecordingFromHotKey() {
        if pendingReview != nil {
            confirmPendingReview()
            return
        }

        if isRecording {
            stopAndRunPipeline()
        } else {
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

    func prewarmModelMode(_ mode: WhisperModelMode? = nil) {
        let mode = mode ?? settingsStore.load().asrModelMode
        Task {
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
        confirmPendingReview(selection: .preferred)
    }

    func confirmPendingReview(selection: MacTranslationReviewSelection) {
        guard let review = pendingReview else {
            updateStatus("no_pending_review")
            return
        }

        pendingReview = nil
        reviewPanel.hide()
        refreshEscapeCancellationState()
        let insertText = review.insertText(for: selection)
        let outcome = MacPasteboardInserter.insert(insertText, target: review.target)
        switch outcome {
        case .inserted:
            floatingPanel.show(
                MacFloatingStatus(
                    phase: .inserted,
                    title: "已上屏",
                    detail: "\(review.displayName(for: selection)) · \(insertText.oneLinePreview(maxLength: 96))",
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

        recordingStartTask = Task {
            do {
                audioService.setLevelHandler { [weak self] level in
                    DispatchQueue.main.async {
                        self?.floatingPanel.updateAudioLevel(level)
                    }
                }
                let url = try await audioService.start()
                guard !Task.isCancelled else {
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

        pipelineTask?.cancel()
        pipelineTask = Task {
            let releaseTime = ContinuousClock.now
            defer {
                pipelineTask = nil
                refreshEscapeCancellationState()
                try? FileManager.default.removeItem(at: clip.url)
            }
            do {
                let reviewBeforeInsert = settings.mode == .translate
                let result = try await makePipeline(for: settings).run(
                    PipelineRunRequest(
                        platform: .macOS,
                        mode: settings.mode,
                        sampleText: "",
                        audioPath: clip.url.path,
                        sourceLanguage: settings.sourceLanguage,
                        targetLanguage: settings.effectiveTargetLanguage,
                        insertPolicy: settings.insertPolicy,
                        preferredInsertLanguage: settings.preferredInsertLanguage,
                        insertionStrategy: reviewBeforeInsert ? .none : .pasteboard
                    )
                )
                guard !Task.isCancelled else {
                    return
                }
                let elapsedMS = releaseTime.duration(to: ContinuousClock.now).milliseconds
                if reviewBeforeInsert {
                    presentTranslationReview(
                        result: result,
                        elapsedMS: elapsedMS,
                        preferredInsertLanguage: settings.preferredInsertLanguage,
                        target: insertionTarget
                    )
                    return
                }

                let inserted = result.insertion?.inserted == true
                let detail = inserted
                    ? "wall_ms=\(elapsedMS) \(result.finalText.oneLinePreview(maxLength: 96))"
                    : "结果已复制，需开启无障碍权限后才能自动上屏。\(MacProductCopy.name) 菜单 -> 打开无障碍设置。\(result.finalText.oneLinePreview(maxLength: 56))"
                floatingPanel.show(
                    MacFloatingStatus(
                        phase: inserted ? .inserted : .review,
                        title: inserted ? "已上屏" : "已复制，等待授权",
                        detail: detail,
                        startedAt: nil
                    )
                )
                if inserted {
                    floatingPanel.hide(after: 1.0)
                }
            } catch is CancellationError {
                return
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

        let review = MacPendingTranslationReview(
            sourceText: translation.correctedSourceText,
            targetText: translation.targetText,
            sourceLanguage: translation.mode.sourceLanguage,
            targetLanguage: translation.mode.targetLanguage,
            preferredInsertLanguage: preferredInsertLanguage,
            defaultInsertText: result.finalText,
            modeSummary: "\(translation.mode.sourceLanguage)->\(translation.mode.targetLanguage)",
            latencyDetail: "wall_ms=\(elapsedMS)",
            target: target
        )
        pendingReview = review
        refreshEscapeCancellationState()
        reviewPanel.show(review)
        floatingPanel.show(
                MacFloatingStatus(
                    phase: .review,
                    title: "等待确认",
                    detail: "\(review.latencyDetail) · 默认上屏 \(review.preferredLanguageDisplayName)",
                    startedAt: nil
                )
            )
        floatingPanel.hide(after: 1.0)
    }

    private func modeTitle(for settings: VeloraRuntimeSettings) -> String {
        switch settings.mode {
        case .dictate:
            return "听写 \(settings.sourceLanguage) \(settings.asrModelMode.rawValue)"
        case .polish:
            return "润色 \(settings.sourceLanguage) \(settings.asrModelMode.rawValue)"
        case .translate:
            return "翻译 \(settings.sourceLanguage)->\(settings.targetLanguage) \(settings.asrModelMode.rawValue)"
        }
    }

    private func makePipeline(for settings: VeloraRuntimeSettings) -> PipelineOrchestrator {
        PipelineOrchestrator(
            asrEngine: WhisperCLIASREngine(configuration: .configuration(for: settings.asrModelMode)),
            contextProvider: MacContextProvider(),
            memoryStore: InMemoryHotwordStore(),
            textEngine: OllamaTextIntelligenceEngine(),
            translationEngine: OllamaTranslationEngine(),
            insertionEngine: MacPasteboardInsertionEngine()
        )
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
        if target?.activateBeforeInsertion() == true {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.08))
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

struct MacPendingTranslationReview: Identifiable {
    let id = UUID()
    var sourceText: String
    var targetText: String
    var sourceLanguage: String
    var targetLanguage: String
    var preferredInsertLanguage: String
    var defaultInsertText: String
    var modeSummary: String
    var latencyDetail: String
    var target: MacInsertionTarget?

    var sourceLanguageDisplayName: String {
        TranslationLanguageResolver.displayName(for: sourceLanguage)
    }

    var targetLanguageDisplayName: String {
        TranslationLanguageResolver.displayName(for: targetLanguage)
    }

    var preferredLanguageDisplayName: String {
        TranslationLanguageResolver.displayName(for: preferredInsertLanguage)
    }

    func insertText(for selection: MacTranslationReviewSelection) -> String {
        switch selection {
        case .preferred:
            return defaultInsertText
        case .source:
            return sourceText
        case .target:
            return targetText
        }
    }

    func displayName(for selection: MacTranslationReviewSelection) -> String {
        switch selection {
        case .preferred:
            return preferredLanguageDisplayName
        case .source:
            return sourceLanguageDisplayName
        case .target:
            return targetLanguageDisplayName
        }
    }
}

@MainActor
final class MacTranslationReviewPanelModel: ObservableObject {
    @Published var review: MacPendingTranslationReview?
    var onConfirm: ((MacTranslationReviewSelection) -> Void)?
    var onCancel: (() -> Void)?
}

enum MacTranslationReviewSelection {
    case preferred
    case source
    case target
}

@MainActor
final class MacTranslationReviewPanelController {
    private let model = MacTranslationReviewPanelModel()
    private lazy var panel: NSPanel = makePanel()

    init(
        onConfirm: @escaping (MacTranslationReviewSelection) -> Void,
        onCancel: @escaping () -> Void
    ) {
        model.onConfirm = onConfirm
        model.onCancel = onCancel
    }

    func show(_ review: MacPendingTranslationReview) {
        model.review = review
        positionPanel()
        panel.orderFrontRegardless()
    }

    func hide() {
        panel.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 286),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
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
            y: frame.minY + 116
        )
        panel.setFrameOrigin(origin)
    }
}

struct MacTranslationReviewPanelView: View {
    @ObservedObject var model: MacTranslationReviewPanelModel

    var body: some View {
        if let review = model.review {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Text("确认上屏")
                        .font(.system(size: 13, weight: .semibold))
                    Text("\(review.modeSummary) · 默认 \(review.preferredLanguageDisplayName) · Esc 取消")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer()
                    Button {
                        model.onCancel?()
                    } label: {
                        Image(systemName: "xmark")
                            .frame(width: 22, height: 22)
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityLabel("取消")
                }

                HStack(alignment: .top, spacing: 12) {
                    MacTranslationReviewTextBlock(
                        role: "原文",
                        languageName: review.sourceLanguageDisplayName,
                        text: review.sourceText,
                        isDefault: TranslationLanguageResolver.normalizedLanguage(review.sourceLanguage)
                            == TranslationLanguageResolver.normalizedLanguage(review.preferredInsertLanguage),
                        onConfirm: { model.onConfirm?(.source) }
                    )
                    MacTranslationReviewTextBlock(
                        role: "译文",
                        languageName: review.targetLanguageDisplayName,
                        text: review.targetText,
                        isDefault: TranslationLanguageResolver.normalizedLanguage(review.targetLanguage)
                            == TranslationLanguageResolver.normalizedLanguage(review.preferredInsertLanguage),
                        onConfirm: { model.onConfirm?(.target) }
                    )
                }

                Text("再次按 \(MacProductCopy.hotKey) 上屏 \(review.preferredLanguageDisplayName)：\(review.defaultInsertText.oneLinePreview(maxLength: 76))")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(14)
            .frame(width: 640, height: 286)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(.separator.opacity(0.75))
            )
        }
    }
}

struct MacTranslationReviewTextBlock: View {
    var role: String
    var languageName: String
    var text: String
    var isDefault: Bool
    var onConfirm: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(languageName)
                    .font(.system(size: 12, weight: .semibold))
                Text(role)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                if isDefault {
                    Text("默认")
                        .font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                        .foregroundStyle(Color.accentColor)
                }
                Spacer()
            }
            ScrollView {
                Text(text)
                    .font(.system(size: 13))
                    .lineSpacing(2)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.background.opacity(0.82))
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(.separator.opacity(0.65))
            )

            if isDefault {
                confirmButton
                    .buttonStyle(.borderedProminent)
            } else {
                confirmButton
                    .buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var confirmButton: some View {
        Button {
            onConfirm()
        } label: {
            Label("上屏\(languageName)", systemImage: "keyboard")
                .frame(maxWidth: .infinity)
        }
        .controlSize(.small)
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

final class MacGlobalHotKeyCenter {
    enum HotKeyError: Error {
        case registerFailed(OSStatus)
        case installHandlerFailed(OSStatus)
    }

    private var hotKeyRefs: [EventHotKeyRef] = []
    private var eventHandlerRef: EventHandlerRef?
    private var globalModifierMonitor: Any?
    private var localModifierMonitor: Any?
    private var pendingFunctionWorkItem: DispatchWorkItem?
    private var lastModifierFlags: NSEvent.ModifierFlags = []
    private var functionComboTriggered = false
    private var functionMappings: [MacHotKeyPreset: MacHotKeyInvocation] = [:]
    private var handler: ((MacHotKeyInvocation) -> Void)?

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
            installFunctionModifierMonitors()
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

        if let globalModifierMonitor {
            NSEvent.removeMonitor(globalModifierMonitor)
            self.globalModifierMonitor = nil
        }

        if let localModifierMonitor {
            NSEvent.removeMonitor(localModifierMonitor)
            self.localModifierMonitor = nil
        }

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

    private func installFunctionModifierMonitors() {
        let mask: NSEvent.EventTypeMask = [.flagsChanged]
        globalModifierMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            self?.handleModifierEvent(event)
        }
        localModifierMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            self?.handleModifierEvent(event)
            return event
        }
    }

    private func handleModifierEvent(_ event: NSEvent) {
        let flags = event.modifierFlags.intersection([.function, .shift])
        let functionWasDown = lastModifierFlags.contains(.function)
        let functionIsDown = flags.contains(.function)
        let shiftWasDown = lastModifierFlags.contains(.shift)
        let shiftIsDown = flags.contains(.shift)

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
            return
        }

        if functionIsDown && shiftIsDown && !shiftWasDown {
            pendingFunctionWorkItem?.cancel()
            fireFunctionPreset(.functionShift)
            return
        }

        if !functionIsDown && functionWasDown {
            functionComboTriggered = false
        }
    }

    private func scheduleOrFireBareFunction() {
        guard functionMappings[.function] != nil else {
            return
        }

        if functionMappings[.functionShift] == nil {
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
            return .secondary
        case .requestingPermission, .transcribing, .review:
            return .blue
        case .listening:
            return .red
        case .inserted:
            return .green
        case .error:
            return .red
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
    @Published var audioLevel: Float = 0
}

@MainActor
final class MacFloatingStatusPanelController {
    private let model = MacFloatingStatusModel()
    private lazy var panel: NSPanel = makePanel()
    private var hideTask: Task<Void, Never>?

    func show(_ status: MacFloatingStatus) {
        hideTask?.cancel()
        model.status = status
        if status.phase != .listening {
            model.audioLevel = 0
        }
        positionPanel()
        panel.orderFrontRegardless()
    }

    func updateDetail(_ detail: String) {
        model.status.detail = detail
    }

    func updateAudioLevel(_ level: Float) {
        model.audioLevel = min(max(level, 0), 1)
    }

    func hide(after delay: TimeInterval) {
        hideTask?.cancel()
        hideTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            panel.orderOut(nil)
        }
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 52),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
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
            y: frame.minY + 72
        )
        panel.setFrameOrigin(origin)
    }
}

struct MacFloatingStatusView: View {
    @ObservedObject var model: MacFloatingStatusModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 10) {
            if model.status.phase == .listening {
                Circle()
                    .fill(model.status.phase.color)
                    .frame(width: 8, height: 8)
                    .accessibilityHidden(true)
                MacVoiceLevelStrip(
                    phase: model.status.phase,
                    level: model.audioLevel,
                    reduceMotion: reduceMotion
                )
                if let startedAt = model.status.startedAt {
                    MacElapsedTimeText(startedAt: startedAt)
                }
            } else {
                Image(systemName: model.status.phase.symbolName)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(model.status.phase.color)
                    .frame(width: 16)
                    .accessibilityHidden(true)
                Text(model.status.title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Text(model.status.detail)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 4)

            if model.status.phase == .listening {
                MacFloatingKeycap(text: MacProductCopy.hotKey)
                MacFloatingKeycap(text: "Esc")
            }
        }
        .padding(.horizontal, 12)
        .frame(width: 360, height: 52)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(.separator.opacity(0.7))
        )
    }
}

struct MacVoiceLevelStrip: View {
    var phase: MacFloatingPhase
    var level: Float
    var reduceMotion: Bool

    private let barCount = 14

    var body: some View {
        HStack(alignment: .center, spacing: 3) {
            ForEach(0..<barCount, id: \.self) { index in
                Capsule(style: .continuous)
                    .fill(phase.color.opacity(phase == .listening ? 0.82 : 0.45))
                    .frame(width: 3, height: barHeight(at: index))
                    .animation(reduceMotion ? nil : .spring(response: 0.16, dampingFraction: 0.82), value: level)
            }
        }
        .frame(width: 84, height: 18)
        .accessibilityLabel(accessibilityLabel)
    }

    private func barHeight(at index: Int) -> CGFloat {
        switch phase {
        case .listening:
            let wave = Float((sin(Double(index) * 0.9) + 1) / 2)
            let weighted = max(0.08, min(1, level * (0.55 + wave * 0.7)))
            return CGFloat(3 + weighted * 15)
        case .transcribing:
            return CGFloat(7 + (index % 4) * 3)
        default:
            return CGFloat(6 + (index % 3) * 2)
        }
    }

    private var accessibilityLabel: String {
        switch phase {
        case .listening:
            return "录音音量"
        case .transcribing:
            return "正在处理"
        default:
            return "状态指示"
        }
    }
}

struct MacElapsedTimeText: View {
    var startedAt: Date

    var body: some View {
        TimelineView(.periodic(from: startedAt, by: 1)) { context in
            Text(Self.formattedElapsed(from: startedAt, to: context.date))
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .accessibilityLabel("录音时长")
    }

    private static func formattedElapsed(from start: Date, to end: Date) -> String {
        let elapsed = max(0, Int(end.timeIntervalSince(start)))
        return String(format: "%02d:%02d", elapsed / 60, elapsed % 60)
    }
}

struct MacFloatingKeycap: View {
    var text: String

    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold, design: .rounded))
            .lineLimit(1)
            .minimumScaleFactor(0.78)
            .padding(.horizontal, 8)
            .frame(minWidth: text.count <= 3 ? 38 : 50, minHeight: 26)
            .background(.background.opacity(0.72))
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(.separator.opacity(0.7))
            )
            .accessibilityLabel("停止快捷键 \(text)")
    }
}

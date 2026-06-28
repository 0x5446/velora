import Foundation
import Velora

#if os(macOS)
import AppKit
import ApplicationServices
import AVFoundation
import Carbon
#endif

struct DiagnosticReport: Codable {
    var module: String
    var ok: Bool
    var summary: String
    var details: [String: String]
    var metrics: [String: Int]
    var output: String?

    init(
        module: String,
        ok: Bool,
        summary: String,
        details: [String: String] = [:],
        metrics: [String: Int] = [:],
        output: String? = nil
    ) {
        self.module = module
        self.ok = ok
        self.summary = summary
        self.details = details
        self.metrics = metrics
        self.output = output
    }
}

@main
struct VeloraDiagnostics {
    static func main() async {
        do {
            let arguments = Array(CommandLine.arguments.dropFirst())
            guard let command = arguments.first else {
                emit(
                    DiagnosticReport(
                        module: "usage",
                        ok: false,
                        summary: usage()
                    )
                )
                exit(2)
            }

            let options = DiagnosticOptions(Array(arguments.dropFirst()))
            let report: DiagnosticReport
            switch command {
            case "environment":
                report = environmentReport()
            case "text":
                report = try await textReport(options: options)
            case "asr":
                report = try await asrReport(options: options)
            case "ollama":
                report = try await ollamaReport(options: options)
            #if os(macOS)
            case "pasteboard":
                report = pasteboardReport(options: options)
            case "accessibility":
                report = accessibilityReport(options: options)
            case "insert-focused":
                report = await focusedInsertReport(options: options)
            case "audio-record":
                report = try await audioRecordReport(options: options)
            #endif
            case "--help", "-h", "help":
                emit(
                    DiagnosticReport(
                        module: "usage",
                        ok: true,
                        summary: usage()
                    )
                )
                exit(0)
            default:
                emit(
                    DiagnosticReport(
                        module: "usage",
                        ok: false,
                        summary: "unknown_command:\(command)",
                        details: ["usage": usage()]
                    )
                )
                exit(2)
            }

            emit(report)
            exit(report.ok ? 0 : 1)
        } catch {
            emit(
                DiagnosticReport(
                    module: "diagnostics",
                    ok: false,
                    summary: VeloraErrorPresenter.message(for: error),
                    details: ["error": "\(error)"]
                )
            )
            exit(1)
        }
    }

    private static func usage() -> String {
        """
        Usage:
          VeloraDiagnostics environment
          VeloraDiagnostics text --mode translate --text TEXT --source zh --target en
          VeloraDiagnostics asr --audio PATH --source en --asr-mode fast
          VeloraDiagnostics ollama --task prewarm|polish|translate
          VeloraDiagnostics pasteboard --text TEXT
          VeloraDiagnostics accessibility [--prompt]
          VeloraDiagnostics insert-focused --text TEXT [--delay 3]
          VeloraDiagnostics audio-record [--seconds 2] [--output /tmp/test.caf]
        """
    }
}

struct DiagnosticOptions {
    private var values: [String: String] = [:]
    private var flags: Set<String> = []

    init(_ arguments: [String]) {
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if argument.hasPrefix("--") {
                if index + 1 < arguments.count, !arguments[index + 1].hasPrefix("--") {
                    values[argument] = arguments[index + 1]
                    index += 2
                } else {
                    flags.insert(argument)
                    index += 1
                }
            } else {
                index += 1
            }
        }
    }

    func value(_ key: String, default defaultValue: String) -> String {
        values[key] ?? defaultValue
    }

    func optionalValue(_ key: String) -> String? {
        values[key]
    }

    func intValue(_ key: String, default defaultValue: Int) -> Int {
        guard let value = values[key], let parsed = Int(value) else {
            return defaultValue
        }
        return parsed
    }

    func flag(_ key: String) -> Bool {
        flags.contains(key)
    }
}

func emit(_ report: DiagnosticReport) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = (try? encoder.encode(report)) ?? Data()
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
}

func elapsedMS(since start: Date) -> Int {
    max(0, Int((Date().timeIntervalSince(start) * 1_000).rounded()))
}

func environmentReport() -> DiagnosticReport {
    var details: [String: String] = [:]
    var ok = true

    #if os(macOS)
    let executable = WhisperCLIConfiguration.default.resolvedExecutablePath()
    details["whisper_cli"] = executable
    if !FileManager.default.isExecutableFile(atPath: executable) {
        ok = false
        details["whisper_cli_status"] = "missing_or_not_executable"
    }

    for mode in WhisperModelMode.allCases {
        let config = WhisperCLIConfiguration.configuration(for: mode)
        do {
            details["whisper_model_\(mode.rawValue)"] = try config.resolvedModelPath()
        } catch {
            ok = false
            details["whisper_model_\(mode.rawValue)"] = VeloraErrorPresenter.message(for: error)
        }
    }

    details["accessibility_trusted"] = AXIsProcessTrusted() ? "true" : "false"
    #endif

    let ollama = OllamaLocalClient.default
    details["ollama_endpoint"] = ollama.endpoint.absoluteString
    details["ollama_model"] = ollama.model

    return DiagnosticReport(
        module: "environment",
        ok: ok,
        summary: ok ? "environment_ready" : "environment_has_missing_dependency",
        details: details
    )
}

func textReport(options: DiagnosticOptions) async throws -> DiagnosticReport {
    let modeValue = options.value("--mode", default: "translate")
    guard let mode = DictationMode(rawValue: modeValue) else {
        throw PipelineError.unsupportedMode("mode:\(modeValue)")
    }

    let insertPolicyValue = options.value("--insert-policy", default: "bilingual")
    let insertPolicy: InsertPolicy
    switch insertPolicyValue {
    case "bilingual":
        insertPolicy = .bilingual
    case "target_only", "targetOnly":
        insertPolicy = .targetOnly
    case "review_card", "reviewCard":
        insertPolicy = .reviewCard
    default:
        throw PipelineError.unsupportedMode("insert-policy:\(insertPolicyValue)")
    }

    let text = options.value(
        "--text",
        default: "明天上午十点我和 Alex 开会，帮我确认一下 agenda"
    )
    let source = options.value("--source", default: "zh")
    let target = options.value("--target", default: "en")
    let useLocalModels = options.flag("--local-models")
    let start = Date()

    let pipeline = PipelineOrchestrator(
        asrEngine: FakeASREngine(),
        contextProvider: StaticContextProvider(),
        memoryStore: InMemoryHotwordStore(),
        textEngine: useLocalModels ? OllamaTextIntelligenceEngine() : RuleBasedTextIntelligenceEngine(),
        translationEngine: useLocalModels ? OllamaTranslationEngine() : StubTranslationEngine(),
        insertionEngine: NoopInsertionEngine()
    )

    let result = try await pipeline.run(
        PipelineRunRequest(
            platform: .macOS,
            mode: mode,
            sampleText: text,
            sourceLanguage: source,
            targetLanguage: mode == .translate ? target : nil,
            insertPolicy: insertPolicy,
            polishStyle: options.value("--style", default: "clean"),
            insertionStrategy: .none
        )
    )

    var details = [
        "mode": mode.rawValue,
        "source": source,
        "target": mode == .translate ? target : "",
        "engine": useLocalModels ? "ollama" : "rule_stub",
        "final_text_preview": result.finalText.oneLinePreview(maxLength: 220),
        "stages": result.trace.stages.map(\.name).joined(separator: ","),
    ]
    if let translation = result.translation {
        details["translation_display_preview"] = translation.displayText.oneLinePreview(maxLength: 220)
    }

    return DiagnosticReport(
        module: "text",
        ok: !result.finalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
        summary: "text_pipeline_ok",
        details: details,
        metrics: [
            "wall_ms": elapsedMS(since: start),
            "release_to_insert_ms": result.trace.releaseToInsertMS,
        ],
        output: result.finalText
    )
}

#if os(macOS)
func asrReport(options: DiagnosticOptions) async throws -> DiagnosticReport {
    guard let audioPath = options.optionalValue("--audio") else {
        throw PipelineError.unsupportedMode("asr requires --audio")
    }

    let source = options.value("--source", default: "en")
    let modeValue = options.value("--asr-mode", default: "fast")
    guard let mode = WhisperModelMode(rawValue: modeValue) else {
        throw PipelineError.unsupportedMode("asr-mode:\(modeValue)")
    }

    let start = Date()
    let engine = WhisperCLIASREngine(configuration: .configuration(for: mode))
    let result = try await engine.transcribe(
        ASRRequest(
            audioPath: audioPath,
            sourceLanguage: source,
            contextualPhrases: options.value("--context", default: "")
                .split(separator: ",")
                .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        )
    )

    return DiagnosticReport(
        module: "asr",
        ok: !result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
        summary: "asr_ok",
        details: [
            "audio": audioPath,
            "source": source,
            "asr_mode": mode.rawValue,
            "engine": result.engine,
            "model": result.modelVersion,
            "text_preview": result.text.oneLinePreview(maxLength: 220),
        ],
        metrics: ["wall_ms": elapsedMS(since: start)],
        output: result.text
    )
}
#endif

func ollamaReport(options: DiagnosticOptions) async throws -> DiagnosticReport {
    let task = options.value("--task", default: "prewarm")
    let start = Date()

    switch task {
    case "prewarm":
        let client = OllamaLocalClient.default
        try await client.prewarm()
        return DiagnosticReport(
            module: "ollama",
            ok: true,
            summary: "ollama_prewarm_ok",
            details: ["model": client.model, "endpoint": client.endpoint.absoluteString],
            metrics: ["wall_ms": elapsedMS(since: start)]
        )

    case "polish":
        let engine = OllamaTextIntelligenceEngine()
        let input = options.value("--text", default: "明天上午十点我和 Alex 开会 帮我确认一下 agenda")
        let result = try await engine.polish(
            PolishRequest(
                text: input,
                style: options.value("--style", default: "clean"),
                context: ContextSnapshot(appBundle: "diagnostics", nearbyText: "agenda", mode: .polish)
            )
        )
        return DiagnosticReport(
            module: "ollama",
            ok: !result.finalText.isEmpty,
            summary: "ollama_polish_ok",
            details: ["input_preview": input.oneLinePreview(maxLength: 160)],
            metrics: ["wall_ms": elapsedMS(since: start)],
            output: result.finalText
        )

    case "translate":
        let engine = OllamaTranslationEngine()
        let input = options.value("--text", default: "明天上午十点我和 Alex 开会，帮我确认一下 agenda。")
        let result = try await engine.translate(
            LocalTranslationRequest(
                sourceText: input,
                correctedSourceText: input,
                sourceLanguage: options.value("--source", default: "zh"),
                targetLanguage: options.value("--target", default: "en"),
                context: ContextSnapshot(appBundle: "diagnostics", nearbyText: "agenda", mode: .translate),
                glossary: InMemoryHotwordStore.defaultTerms
            )
        )
        return DiagnosticReport(
            module: "ollama",
            ok: !result.targetText.isEmpty,
            summary: "ollama_translate_ok",
            details: ["input_preview": input.oneLinePreview(maxLength: 160)],
            metrics: ["wall_ms": elapsedMS(since: start)],
            output: result.targetText
        )

    default:
        throw PipelineError.unsupportedMode("ollama-task:\(task)")
    }
}

#if os(macOS)
@MainActor
func pasteboardReport(options: DiagnosticOptions) -> DiagnosticReport {
    let text = options.value("--text", default: "Velora pasteboard probe \(UUID().uuidString)")
    let pasteboard = NSPasteboard.general
    let start = Date()
    pasteboard.clearContents()
    let wrote = pasteboard.setString(text, forType: .string)
    let readBack = pasteboard.string(forType: .string) ?? ""
    let ok = wrote && readBack == text

    return DiagnosticReport(
        module: "pasteboard",
        ok: ok,
        summary: ok ? "pasteboard_write_read_ok" : "pasteboard_write_read_failed",
        details: [
            "expected_preview": text.oneLinePreview(maxLength: 120),
            "actual_preview": readBack.oneLinePreview(maxLength: 120),
        ],
        metrics: ["wall_ms": elapsedMS(since: start)]
    )
}

@MainActor
func accessibilityReport(options: DiagnosticOptions) -> DiagnosticReport {
    if options.flag("--prompt") {
        let promptOptions = [
            "AXTrustedCheckOptionPrompt": true,
        ] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(promptOptions)
    }

    let trusted = AXIsProcessTrusted()
    return DiagnosticReport(
        module: "accessibility",
        ok: trusted,
        summary: trusted ? "accessibility_trusted" : "accessibility_not_trusted",
        details: [
            "trusted": trusted ? "true" : "false",
            "next_step": trusted
                ? "none"
                : "系统设置 -> 隐私与安全性 -> 辅助功能，允许当前终端或Velora App",
        ]
    )
}

@MainActor
func focusedInsertReport(options: DiagnosticOptions) async -> DiagnosticReport {
    let text = options.value("--text", default: "Velora focused insertion probe \(UUID().uuidString)")
    let delay = options.intValue("--delay", default: 3)

    guard AXIsProcessTrusted() else {
        return DiagnosticReport(
            module: "insert-focused",
            ok: false,
            summary: "accessibility_not_trusted",
            details: [
                "next_step": "先运行 accessibility --prompt 并在系统设置里授权",
            ]
        )
    }

    try? await Task.sleep(nanoseconds: UInt64(max(0, delay)) * 1_000_000_000)
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    let wrote = pasteboard.setString(text, forType: .string)
    guard wrote else {
        return DiagnosticReport(
            module: "insert-focused",
            ok: false,
            summary: "pasteboard_write_failed"
        )
    }

    postCommandV()
    return DiagnosticReport(
        module: "insert-focused",
        ok: true,
        summary: "command_v_posted",
        details: [
            "text_preview": text.oneLinePreview(maxLength: 160),
            "verification": "脚本无法可靠读取任意目标 App，请在当前光标位置确认文本是否出现",
        ]
    )
}

func audioRecordReport(options: DiagnosticOptions) async throws -> DiagnosticReport {
    let seconds = max(1, options.intValue("--seconds", default: 2))
    let outputPath = options.optionalValue("--output")
        ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("velora-audio-probe-\(UUID().uuidString)")
            .appendingPathExtension("caf")
            .path

    let granted = await requestMicrophoneAccess()
    guard granted else {
        return DiagnosticReport(
            module: "audio-record",
            ok: false,
            summary: "microphone_denied",
            details: [
                "next_step": "系统设置 -> 隐私与安全性 -> 麦克风，允许当前终端或Velora App",
            ]
        )
    }

    let recorder = AudioProbeRecorder()
    let start = Date()
    try recorder.start(outputPath: outputPath)
    try await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000)
    recorder.stop()

    let attributes = try FileManager.default.attributesOfItem(atPath: outputPath)
    let bytes = (attributes[.size] as? NSNumber)?.intValue ?? 0
    let ok = bytes > 4_096

    return DiagnosticReport(
        module: "audio-record",
        ok: ok,
        summary: ok ? "audio_record_ok" : "audio_record_too_small",
        details: ["path": outputPath],
        metrics: [
            "wall_ms": elapsedMS(since: start),
            "bytes": bytes,
            "seconds": seconds,
        ]
    )
}

func requestMicrophoneAccess() async -> Bool {
    await withCheckedContinuation { continuation in
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            continuation.resume(returning: granted)
        }
    }
}

final class AudioProbeRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var engine: AVAudioEngine?
    private var file: AVAudioFile?

    func start(outputPath: String) throws {
        lock.lock()
        defer { lock.unlock() }

        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        let file = try AVAudioFile(forWriting: URL(fileURLWithPath: outputPath), settings: format.settings)

        input.installTap(onBus: 0, bufferSize: 2_048, format: format) { [weak self] buffer, _ in
            self?.write(buffer)
        }

        try engine.start()
        self.engine = engine
        self.file = file
    }

    func stop() {
        lock.lock()
        defer { lock.unlock() }

        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        file = nil
    }

    private func write(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }
        try? file?.write(from: buffer)
    }
}

func postCommandV() {
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
#endif

private extension String {
    func oneLinePreview(maxLength: Int) -> String {
        let preview = split(whereSeparator: \.isNewline).joined(separator: " ")
        guard preview.count > maxLength else {
            return preview
        }
        return String(preview.prefix(maxLength)) + "..."
    }
}

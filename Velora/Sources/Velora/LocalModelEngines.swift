import Foundation

public enum WhisperModelMode: String, Codable, Sendable, Hashable, CaseIterable {
    case fast
    case accurate
    case fallback

    public var displayName: String {
        switch self {
        case .fast:
            return "fast / base"
        case .accurate:
            return "accurate / large"
        case .fallback:
            return "fallback / tiny"
        }
    }

    public static func fromEnvironment(_ environment: [String: String]) -> WhisperModelMode {
        let rawValue = environment["VELORA_WHISPER_MODE"]
            ?? environment["VELORA_ASR_MODE"]
            ?? ""
        return WhisperModelMode(rawValue: rawValue.lowercased()) ?? .fast
    }
}

#if os(macOS)
public struct WhisperCLIASREngine: ASREngine {
    public let id = "whisper.cpp.cli"
    public var configuration: WhisperCLIConfiguration

    public init(configuration: WhisperCLIConfiguration = .default) {
        self.configuration = configuration
    }

    public func transcribe(_ request: ASRRequest) async throws -> ASRResult {
        guard let audioPath = request.audioPath?.trimmingCharacters(in: .whitespacesAndNewlines),
              !audioPath.isEmpty else {
            throw PipelineError.emptyInput
        }

        guard FileManager.default.fileExists(atPath: audioPath) else {
            throw PipelineError.asrUnavailable("audio_file_missing")
        }

        let executable = configuration.resolvedExecutablePath()
        guard FileManager.default.isExecutableFile(atPath: executable) else {
            throw PipelineError.asrUnavailable("whisper_cli_missing:\(executable)")
        }

        let modelPath = try configuration.resolvedModelPath()
        let preparedAudioPath = try await configuration.prepareAudioIfNeeded(audioPath)
        defer {
            if preparedAudioPath != audioPath {
                try? FileManager.default.removeItem(atPath: preparedAudioPath)
            }
        }

        let outputBase = FileManager.default.temporaryDirectory
            .appendingPathComponent("velora-whisper-\(UUID().uuidString)")
            .path
        defer {
            try? FileManager.default.removeItem(atPath: outputBase + ".txt")
        }

        var arguments = [
            "-m", modelPath,
            "-l", configuration.whisperLanguage(for: request.sourceLanguage),
            "-otxt",
            "-of", outputBase,
            "-nt",
            "-np",
        ]
        let prompt = configuration.initialPrompt(from: request.contextualPhrases)
        if !prompt.isEmpty {
            arguments.append(contentsOf: ["--prompt", prompt])
        }
        arguments.append(preparedAudioPath)

        let result = try await LocalProcess.run(executablePath: executable, arguments: arguments)
        let outputPath = outputBase + ".txt"
        let text = (try? String(contentsOfFile: outputPath, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        guard !text.isEmpty else {
            let diagnostic = (result.standardError + result.standardOutput)
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "\n", with: " ")
            throw PipelineError.asrUnavailable("whisper_no_output:\(diagnostic.prefix(240))")
        }

        return ASRResult(
            text: text,
            language: request.sourceLanguage,
            confidence: 0.86,
            segments: [
                ASRSegment(
                    text: text,
                    startMS: 0,
                    endMS: max(500, text.count * 45),
                    confidence: 0.86
                ),
            ],
            engine: id,
            modelVersion: URL(fileURLWithPath: modelPath).lastPathComponent
        )
    }
}

public struct WhisperCLIConfiguration: Sendable {
    public var executablePath: String
    public var modelPath: String?
    public var modelCandidates: [WhisperModelCandidate]
    public var modelMode: WhisperModelMode

    public init(
        executablePath: String = "/opt/homebrew/bin/whisper-cli",
        modelPath: String? = nil,
        modelCandidates: [WhisperModelCandidate] = .defaultCandidates,
        modelMode: WhisperModelMode = .fast
    ) {
        self.executablePath = executablePath
        self.modelPath = modelPath
        self.modelCandidates = modelCandidates
        self.modelMode = modelMode
    }

    public static var `default`: WhisperCLIConfiguration {
        let environment = ProcessInfo.processInfo.environment
        let mode = WhisperModelMode.fromEnvironment(environment)
        return configuration(for: mode, environment: environment)
    }

    public static func configuration(
        for mode: WhisperModelMode,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> WhisperCLIConfiguration {
        return WhisperCLIConfiguration(
            executablePath: environment["VELORA_WHISPER_CLI"] ?? "/opt/homebrew/bin/whisper-cli",
            modelPath: environment["VELORA_WHISPER_MODEL"],
            modelCandidates: .candidates(for: mode),
            modelMode: mode
        )
    }

    public func resolvedExecutablePath() -> String {
        if FileManager.default.isExecutableFile(atPath: executablePath) {
            return executablePath
        }

        let fallback = "/usr/local/bin/whisper-cli"
        if FileManager.default.isExecutableFile(atPath: fallback) {
            return fallback
        }

        return executablePath
    }

    public func resolvedModelPath() throws -> String {
        if let modelPath, Self.isUsableModel(at: modelPath, minimumBytes: 30_000_000) {
            return modelPath
        }

        for candidate in modelCandidates where Self.isUsableModel(at: candidate.path, minimumBytes: candidate.minimumBytes) {
            return candidate.path
        }

        let searched = ([modelPath].compactMap { $0 } + modelCandidates.map(\.path)).joined(separator: ",")
        throw PipelineError.asrUnavailable("whisper_model_missing:\(searched)")
    }

    public func whisperLanguage(for sourceLanguage: String) -> String {
        switch sourceLanguage.lowercased() {
        case "zh", "zh-cn", "cmn", "mandarin":
            return "zh"
        case "en", "en-us":
            return "en"
        case "ja", "jp":
            return "ja"
        case "ko":
            return "ko"
        case "auto", "":
            return "auto"
        default:
            return sourceLanguage
        }
    }

    public func initialPrompt(from contextualPhrases: [String]) -> String {
        var seen = Set<String>()
        let phrases = contextualPhrases.compactMap { phrase -> String? in
            let normalized = VeloraTextSanitizer.promptPhrase(phrase)
            guard !normalized.isEmpty else {
                return nil
            }
            let key = normalized.lowercased()
            guard seen.insert(key).inserted else {
                return nil
            }
            return normalized
        }

        let prompt = phrases
            .prefix(16)
            .joined(separator: ", ")
        return VeloraTextSanitizer.promptText(prompt)
    }

    public func prepareAudioIfNeeded(_ audioPath: String) async throws -> String {
        let supportedExtensions: Set<String> = ["wav", "mp3", "flac", "ogg"]
        let pathExtension = URL(fileURLWithPath: audioPath).pathExtension.lowercased()
        if supportedExtensions.contains(pathExtension) {
            return audioPath
        }

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("velora-audio-\(UUID().uuidString)")
            .appendingPathExtension("wav")
        let result = try await LocalProcess.run(
            executablePath: "/usr/bin/afconvert",
            arguments: [
                "-f", "WAVE",
                "-d", "LEI16@16000",
                audioPath,
                outputURL.path,
            ]
        )

        guard result.exitCode == 0, FileManager.default.fileExists(atPath: outputURL.path) else {
            let diagnostic = (result.standardError + result.standardOutput)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw PipelineError.asrUnavailable("whisper_audio_convert_failed:\(diagnostic.prefix(240))")
        }

        return outputURL.path
    }

    public func prewarmModelFileCache(readBytes: Int = 4 * 1_024 * 1_024) throws -> String {
        let modelPath = try resolvedModelPath()
        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: modelPath))
        defer {
            try? handle.close()
        }
        _ = try handle.read(upToCount: readBytes)
        return modelPath
    }

    public static func isUsableModel(at path: String, minimumBytes: UInt64) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attributes[.size] as? NSNumber else {
            return false
        }

        return size.uint64Value >= minimumBytes
    }
}

public struct WhisperModelCandidate: Sendable, Equatable {
    public var path: String
    public var minimumBytes: UInt64

    public init(path: String, minimumBytes: UInt64) {
        self.path = path
        self.minimumBytes = minimumBytes
    }
}

public extension Array where Element == WhisperModelCandidate {
    static var defaultCandidates: [WhisperModelCandidate] {
        candidates(for: .fast)
    }

    static func candidates(for mode: WhisperModelMode) -> [WhisperModelCandidate] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let roots = [
            "\(home)/Documents/workspace/velora/Models/whisper.cpp",
            "\(FileManager.default.currentDirectoryPath)/Models/whisper.cpp",
        ]

        return roots.flatMap { root in
            let base = WhisperModelCandidate(
                path: "\(root)/ggml-base.bin",
                minimumBytes: 80_000_000
            )
            let small = WhisperModelCandidate(
                path: "\(root)/ggml-small.bin",
                minimumBytes: 150_000_000
            )
            let largeTurbo = WhisperModelCandidate(
                path: "\(root)/ggml-large-v3-turbo-q5_0.bin",
                minimumBytes: 500_000_000
            )
            let tiny = WhisperModelCandidate(
                path: "\(root)/ggml-tiny.bin",
                minimumBytes: 30_000_000
            )

            switch mode {
            case .fast:
                return [base, tiny, small, largeTurbo]
            case .accurate:
                return [largeTurbo, small, base, tiny]
            case .fallback:
                return [tiny, base]
            }
        }
    }
}

struct LocalProcessResult: Sendable {
    var exitCode: Int32
    var standardOutput: String
    var standardError: String
}

enum LocalProcess {
    static func run(
        executablePath: String,
        arguments: [String],
        environment: [String: String] = defaultEnvironment()
    ) async throws -> LocalProcessResult {
        let executablePath = try validatedExecutablePath(executablePath)
        let arguments = try arguments.map { try validatedArgument($0) }
        let environment = sanitizedEnvironment(environment)

        return try await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executablePath)
            process.arguments = arguments
            process.environment = environment

            let outputPipe = Pipe()
            let errorPipe = Pipe()
            process.standardOutput = outputPipe
            process.standardError = errorPipe

            try process.run()
            process.waitUntilExit()

            let output = String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let error = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

            return LocalProcessResult(
                exitCode: process.terminationStatus,
                standardOutput: output,
                standardError: error
            )
        }.value
    }

    private static func defaultEnvironment() -> [String: String] {
        [
            "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
            "TMPDIR": NSTemporaryDirectory(),
            "LANG": "en_US.UTF-8",
            "LC_ALL": "en_US.UTF-8",
        ]
    }

    private static func validatedExecutablePath(_ path: String) throws -> String {
        let trimmedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPath.isEmpty else {
            throw PipelineError.asrUnavailable("local_process_empty_executable")
        }
        guard !VeloraTextSanitizer.containsProcessUnsafeCharacters(trimmedPath) else {
            throw PipelineError.asrUnavailable("local_process_invalid_executable")
        }
        guard FileManager.default.isExecutableFile(atPath: trimmedPath) else {
            throw PipelineError.asrUnavailable("local_process_executable_missing:\(trimmedPath)")
        }
        return trimmedPath
    }

    private static func validatedArgument(_ argument: String) throws -> String {
        guard !VeloraTextSanitizer.containsProcessUnsafeCharacters(argument) else {
            throw PipelineError.asrUnavailable("local_process_invalid_argument")
        }
        return argument
    }

    private static func sanitizedEnvironment(_ environment: [String: String]) -> [String: String] {
        environment.reduce(into: [:]) { result, entry in
            let key = entry.key
            let value = entry.value
            guard !key.isEmpty,
                  !key.contains("="),
                  !VeloraTextSanitizer.containsProcessUnsafeCharacters(key),
                  !VeloraTextSanitizer.containsProcessUnsafeCharacters(value) else {
                return
            }
            result[key] = value
        }
    }
}
#endif

public struct LocalModelWarmupResult: Codable, Sendable, Equatable {
    public var component: String
    public var ok: Bool
    public var detail: String
    public var latencyMS: Int

    public init(component: String, ok: Bool, detail: String, latencyMS: Int) {
        self.component = component
        self.ok = ok
        self.detail = detail
        self.latencyMS = latencyMS
    }
}

public enum LocalModelPrewarmer {
    #if os(macOS)
    public static func prewarmForMac(
        whisper: WhisperCLIConfiguration = .default,
        ollama: OllamaLocalClient = .default
    ) async -> [LocalModelWarmupResult] {
        var results: [LocalModelWarmupResult] = []

        let start = Date()
        do {
            let modelPath = try whisper.prewarmModelFileCache()
            results.append(
                LocalModelWarmupResult(
                    component: "whisper.cpp",
                    ok: true,
                    detail: URL(fileURLWithPath: modelPath).lastPathComponent,
                    latencyMS: elapsedMS(since: start)
                )
            )
        } catch {
            results.append(
                LocalModelWarmupResult(
                    component: "whisper.cpp",
                    ok: false,
                    detail: VeloraErrorPresenter.message(for: error),
                    latencyMS: elapsedMS(since: start)
                )
            )
        }

        let ollamaStart = Date()
        do {
            try await ollama.prewarm()
            results.append(
                LocalModelWarmupResult(
                    component: "ollama",
                    ok: true,
                    detail: ollama.model,
                    latencyMS: elapsedMS(since: ollamaStart)
                )
            )
        } catch {
            results.append(
                LocalModelWarmupResult(
                    component: "ollama",
                    ok: false,
                    detail: VeloraErrorPresenter.message(for: error),
                    latencyMS: elapsedMS(since: ollamaStart)
                )
            )
        }

        return results
    }
    #else
    public static func prewarmForMac(
        ollama: OllamaLocalClient = .default
    ) async -> [LocalModelWarmupResult] {
        let ollamaStart = Date()
        do {
            try await ollama.prewarm()
            return [
                LocalModelWarmupResult(
                    component: "ollama",
                    ok: true,
                    detail: ollama.model,
                    latencyMS: elapsedMS(since: ollamaStart)
                ),
            ]
        } catch {
            return [
                LocalModelWarmupResult(
                    component: "ollama",
                    ok: false,
                    detail: VeloraErrorPresenter.message(for: error),
                    latencyMS: elapsedMS(since: ollamaStart)
                ),
            ]
        }
    }
    #endif

    private static func elapsedMS(since start: Date) -> Int {
        max(0, Int((Date().timeIntervalSince(start) * 1_000).rounded()))
    }
}

public struct OllamaTextIntelligenceEngine: TextIntelligenceEngine {
    public var client: OllamaLocalClient
    public var ruleEngine: RuleBasedTextIntelligenceEngine

    public init(
        client: OllamaLocalClient = .default,
        ruleEngine: RuleBasedTextIntelligenceEngine = RuleBasedTextIntelligenceEngine()
    ) {
        self.client = client
        self.ruleEngine = ruleEngine
    }

    public func correct(_ request: CorrectionRequest) async throws -> CorrectionResult {
        try await ruleEngine.correct(request)
    }

    public func polish(_ request: PolishRequest) async throws -> PolishResult {
        let nearbyContext = VeloraTextSanitizer.contextText(request.context.nearbyText)
        let prompt = """
        任务：把下面的输入法听写文本整理成可直接发送或上屏的文本。
        要求：
        - 只输出最终文本，不要解释，不要加标题。
        - 保留事实、数字、人名、产品名和代码词。
        - 修正明显错字、标点、大小写和断句。
        - style=\(request.style)
        - nearby_context=\(nearbyContext)

        文本：
        \(request.text)
        """

        let output = try await client.generate(
            system: "你是一个完全本地运行的输入法润色模块。输出必须简洁、准确、无解释。",
            prompt: prompt,
            maxTokens: 320
        )

        let finalText = Self.cleanModelText(output)
        guard !finalText.isEmpty else {
            throw PipelineError.localModelUnavailable("ollama_empty_output:polish")
        }

        return PolishResult(
            finalText: finalText,
            edits: finalText == request.text ? [] : [
                TextEdit(
                    from: request.text,
                    to: finalText,
                    reason: "ollama_local_polish",
                    confidence: 0.84
                ),
            ],
            confidence: 0.84,
            reviewRequired: false
        )
    }

    public static func cleanModelText(_ text: String) -> String {
        var cleaned = text
        while let start = cleaned.range(of: "<think>", options: [.caseInsensitive]),
              let end = cleaned.range(of: "</think>", options: [.caseInsensitive]),
              start.lowerBound < end.upperBound {
            cleaned.removeSubrange(start.lowerBound..<end.upperBound)
        }

        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)

        if cleaned.hasPrefix("```") {
            cleaned = cleaned
                .split(separator: "\n")
                .dropFirst()
                .dropLast(cleaned.hasSuffix("```") ? 1 : 0)
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        for prefix in ["最终文本：", "最终文本:", "输出：", "输出:", "译文：", "译文:"] {
            if cleaned.hasPrefix(prefix) {
                cleaned.removeFirst(prefix.count)
                cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        return cleaned.trimmingCharacters(in: CharacterSet(charactersIn: "\"' \n\t"))
    }
}

public struct OllamaTranslationEngine: TranslationEngine {
    public var client: OllamaLocalClient

    public init(client: OllamaLocalClient = .default) {
        self.client = client
    }

    public func translate(_ request: LocalTranslationRequest) async throws -> LocalTranslationOutput {
        let glossary = request.glossary
            .map { "\($0.term) => \($0.replacement)" }
            .joined(separator: "\n")
        let nearbyContext = VeloraTextSanitizer.contextText(request.context.nearbyText)
        let prompt = """
        任务：翻译输入法听写文本。
        要求：
        - 只输出 \(request.targetLanguage) 译文，不要输出原文，不要解释。
        - 保留人名、产品名、代码、URL、数字。
        - source_language=\(request.sourceLanguage)
        - target_language=\(request.targetLanguage)
        - nearby_context=\(nearbyContext)
        - glossary:
        \(glossary)

        原文：
        \(request.correctedSourceText)
        """

        let output = try await client.generate(
            system: "你是一个完全本地运行的翻译引擎。只输出目标语言译文。",
            prompt: prompt,
            maxTokens: 360
        )

        var targetText = OllamaTextIntelligenceEngine.cleanModelText(output)
        guard !targetText.isEmpty else {
            throw PipelineError.localModelUnavailable("ollama_empty_output:translate")
        }
        var warnings: [String] = []

        if Self.translationLooksLikeSourceLanguage(
            targetText,
            sourceLanguage: request.sourceLanguage,
            targetLanguage: request.targetLanguage
        ) {
            warnings.append("translation_language_retry")
            let retryOutput = try await client.generate(
                system: "你是一个完全本地运行的翻译引擎。只输出目标语言译文。",
                prompt: """
                上一次输出的语言不符合要求。请重新翻译。
                硬性要求：
                - 目标语言只能是 \(request.targetLanguage)。
                - 不要输出 \(request.sourceLanguage) 原文。
                - 不要解释，不要加标题。
                - 保留人名、产品名、代码、URL、数字。

                原文：
                \(request.correctedSourceText)
                """,
                maxTokens: 360
            )
            let repairedText = OllamaTextIntelligenceEngine.cleanModelText(retryOutput)
            if !repairedText.isEmpty {
                targetText = repairedText
            }
        }

        if Self.translationLooksLikeSourceLanguage(
            targetText,
            sourceLanguage: request.sourceLanguage,
            targetLanguage: request.targetLanguage
        ) {
            warnings.append("translation_language_uncertain")
        }

        let glossaryHits = request.glossary
            .map(\.replacement)
            .filter { term in
                request.correctedSourceText.localizedCaseInsensitiveContains(term)
                    || targetText.localizedCaseInsensitiveContains(term)
            }

        return LocalTranslationOutput(
            targetText: targetText,
            glossaryHits: Array(Set(glossaryHits)).sorted(),
            warnings: warnings,
            confidence: 0.82,
            reviewRequired: warnings.contains("translation_language_uncertain")
        )
    }

    public static func translationLooksLikeSourceLanguage(
        _ text: String,
        sourceLanguage: String,
        targetLanguage: String
    ) -> Bool {
        let source = TranslationLanguageResolver.normalizedLanguage(sourceLanguage)
        let target = TranslationLanguageResolver.normalizedLanguage(targetLanguage)
        guard source != target else {
            return false
        }
        guard let detected = TranslationLanguageResolver.dominantLanguage(
            in: text,
            candidates: [source, target]
        ) else {
            return false
        }
        return detected == source
    }
}

public struct OllamaLocalClient: Sendable {
    public var endpoint: URL
    public var model: String
    public var temperature: Double
    public var keepAlive: String

    public init(
        endpoint: URL = URL(string: "http://127.0.0.1:11434/api/generate")!,
        model: String = ProcessInfo.processInfo.environment["VELORA_OLLAMA_MODEL"] ?? "qwen3:8b",
        temperature: Double = 0.1,
        keepAlive: String = "30m"
    ) {
        self.endpoint = endpoint
        self.model = model
        self.temperature = temperature
        self.keepAlive = keepAlive
    }

    public static var `default`: OllamaLocalClient {
        OllamaLocalClient()
    }

    public func generate(system: String, prompt: String, maxTokens: Int) async throws -> String {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 12

        let payload = OllamaGenerateRequest(
            model: model,
            system: system,
            prompt: "/no_think\n\(prompt)",
            stream: false,
            keepAlive: keepAlive,
            think: false,
            options: OllamaGenerateOptions(
                temperature: temperature,
                numPredict: maxTokens
            )
        )
        request.httpBody = try JSONEncoder().encode(payload)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                let body = String(data: data, encoding: .utf8) ?? ""
                throw PipelineError.localModelUnavailable("ollama_unavailable:http_\(http.statusCode):\(body.prefix(200))")
            }

            let decoded = try JSONDecoder().decode(OllamaGenerateResponse.self, from: data)
            return decoded.response
        } catch let error as PipelineError {
            throw error
        } catch {
            throw PipelineError.localModelUnavailable("ollama_unavailable:\(error)")
        }
    }

    public func prewarm() async throws {
        _ = try await generate(
            system: "你是本地输入法模型预热进程。只输出 OK。",
            prompt: "输出 OK",
            maxTokens: 4
        )
    }
}

private struct OllamaGenerateRequest: Encodable {
    var model: String
    var system: String
    var prompt: String
    var stream: Bool
    var keepAlive: String
    var think: Bool
    var options: OllamaGenerateOptions

    enum CodingKeys: String, CodingKey {
        case model
        case system
        case prompt
        case stream
        case keepAlive = "keep_alive"
        case think
        case options
    }
}

private struct OllamaGenerateOptions: Encodable {
    var temperature: Double
    var numPredict: Int

    enum CodingKeys: String, CodingKey {
        case temperature
        case numPredict = "num_predict"
    }
}

private struct OllamaGenerateResponse: Decodable {
    var response: String
}

import Foundation

#if canImport(Speech)
@preconcurrency import Speech

public struct AppleSpeechASREngine: ASREngine {
    public let id = "apple.speech"
    public var localeIdentifier: String?
    public var requiresOnDeviceRecognition: Bool

    public init(
        localeIdentifier: String? = nil,
        requiresOnDeviceRecognition: Bool = true
    ) {
        self.localeIdentifier = localeIdentifier
        self.requiresOnDeviceRecognition = requiresOnDeviceRecognition
    }

    public func transcribe(_ request: ASRRequest) async throws -> ASRResult {
        guard let audioPath = request.audioPath?.trimmingCharacters(in: .whitespacesAndNewlines),
              !audioPath.isEmpty else {
            throw PipelineError.emptyInput
        }

        guard FileManager.default.fileExists(atPath: audioPath) else {
            throw PipelineError.asrUnavailable("audio_file_missing")
        }

        let authorizationStatus = await Self.requestSpeechAuthorization()
        guard authorizationStatus == .authorized else {
            throw PipelineError.asrUnavailable("speech_not_authorized:\(authorizationStatus.rawValue)")
        }

        let locale = Locale(identifier: localeIdentifier ?? Self.defaultLocaleIdentifier(for: request.sourceLanguage))
        guard let recognizer = SFSpeechRecognizer(locale: locale) else {
            throw PipelineError.asrUnavailable("recognizer_unavailable:\(locale.identifier)")
        }

        guard recognizer.isAvailable else {
            throw PipelineError.asrUnavailable("recognizer_not_available:\(locale.identifier)")
        }

        let speechRequest = SFSpeechURLRecognitionRequest(url: URL(fileURLWithPath: audioPath))
        speechRequest.shouldReportPartialResults = false
        if !request.contextualPhrases.isEmpty {
            // Same hotword/nearby-text list the whisper engine gets as
            // --prompt; Apple's API takes it as vocabulary-bias phrases.
            speechRequest.contextualStrings = request.contextualPhrases
        }

        if requiresOnDeviceRecognition {
            guard recognizer.supportsOnDeviceRecognition else {
                throw PipelineError.asrUnavailable("on_device_not_supported:\(locale.identifier)")
            }
            speechRequest.requiresOnDeviceRecognition = true
        }

        return try await withCheckedThrowingContinuation { continuation in
            let completion = SpeechRecognitionCompletion(continuation: continuation)

            _ = recognizer.recognitionTask(with: speechRequest) { result, error in
                if let result, result.isFinal {
                    completion.resume(with: .success(Self.makeResult(from: result, request: request)))
                } else if let error {
                    completion.resume(with: .failure(Self.mapRecognitionError(error)))
                }
            }
        }
    }

    private static func requestSpeechAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
    }

    private static func makeResult(from result: SFSpeechRecognitionResult, request: ASRRequest) -> ASRResult {
        let transcription = result.bestTranscription
        let segments = transcription.segments.map { segment in
            ASRSegment(
                text: segment.substring,
                startMS: Int(segment.timestamp * 1_000),
                endMS: Int((segment.timestamp + segment.duration) * 1_000),
                confidence: Double(segment.confidence)
            )
        }

        let averageConfidence: Double
        if segments.isEmpty {
            averageConfidence = 0
        } else {
            averageConfidence = segments.map(\.confidence).reduce(0, +) / Double(segments.count)
        }

        let alternatives = result.transcriptions
            .dropFirst()
            .prefix(3)
            .map(\.formattedString)

        return ASRResult(
            text: transcription.formattedString,
            language: request.sourceLanguage,
            confidence: averageConfidence,
            segments: segments,
            alternatives: Array(alternatives),
            engine: "apple.speech",
            modelVersion: "system-on-device"
        )
    }

    public static func defaultLocaleIdentifier(for sourceLanguage: String) -> String {
        switch sourceLanguage.lowercased() {
        case "zh", "zh-cn", "cmn", "mandarin":
            return "zh-CN"
        case "zh-tw", "zh-hant":
            return "zh-TW"
        case "en", "en-us":
            return "en-US"
        case "ja", "jp":
            return "ja-JP"
        case "ko":
            return "ko-KR"
        case "fr":
            return "fr-FR"
        case "de":
            return "de-DE"
        case "es":
            return "es-ES"
        default:
            return sourceLanguage
        }
    }

    public static func recognitionFailureReason(domain: String, code: Int) -> String? {
        if domain == "kLSRErrorDomain", code == 201 {
            return "apple_speech_disabled_siri_dictation"
        }

        return nil
    }

    private static func mapRecognitionError(_ error: Error) -> Error {
        let nsError = error as NSError
        if let reason = recognitionFailureReason(domain: nsError.domain, code: nsError.code) {
            return PipelineError.asrUnavailable(reason)
        }

        return error
    }
}

private final class SpeechRecognitionCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var didResume = false
    private let continuation: CheckedContinuation<ASRResult, Error>

    init(continuation: CheckedContinuation<ASRResult, Error>) {
        self.continuation = continuation
    }

    func resume(with result: Result<ASRResult, Error>) {
        lock.lock()
        guard !didResume else {
            lock.unlock()
            return
        }
        didResume = true
        lock.unlock()

        switch result {
        case .success(let value):
            continuation.resume(returning: value)
        case .failure(let error):
            continuation.resume(throwing: error)
        }
    }
}
#endif

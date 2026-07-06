import Foundation

public enum VeloraErrorPresenter {
    public static func message(for error: Error) -> String {
        if let pipelineError = error as? PipelineError {
            return message(for: pipelineError)
        }

        let nsError = error as NSError
        if nsError.domain == "kLSRErrorDomain", nsError.code == 201 {
            return message(for: .asrUnavailable("apple_speech_disabled_siri_dictation"))
        }

        return "\(error)"
    }

    public static func message(for error: PipelineError) -> String {
        switch error {
        case .emptyInput:
            return "没有可处理的语音或文本。"
        case .unsupportedMode(let reason):
            return "当前模式不可用：\(reason)"
        case .asrUnavailable(let reason):
            return asrMessage(reason: reason)
        case .localModelUnavailable(let reason):
            return localModelMessage(reason: reason)
        }
    }

    private static func asrMessage(reason: String) -> String {
        if reason == "no_speech_detected" {
            return "没有听到清晰的人声。请靠近麦克风再说一次。"
        }

        if reason == "apple_speech_disabled_siri_dictation" {
            return "Apple Speech 当前不可用。请开启系统 Siri/听写，或切换到 whisper.cpp 本地 ASR。"
        }

        if reason.hasPrefix("speech_not_authorized") {
            return "没有语音识别权限。若使用 Apple Speech，请在系统设置里允许 Velora 使用语音识别。"
        }

        if reason.hasPrefix("whisper_cli_missing") {
            return "没有找到 whisper-cli。请先运行：brew install whisper-cpp"
        }

        if reason.hasPrefix("whisper_model_missing") {
            return "没有找到可用的 whisper.cpp 模型。请下载模型，或设置 VELORA_WHISPER_MODEL。"
        }

        if reason.hasPrefix("whisper_audio_convert_failed") {
            return "录音文件转 WAV 失败，whisper.cpp 暂时无法读取这段音频。"
        }

        if reason.hasPrefix("whisper_decode_failed") || reason.hasPrefix("whisper_no_output") {
            return "whisper.cpp 转写失败。请检查模型文件是否完整，或换一个更小的模型先验证。"
        }

        return "本地语音识别不可用：\(reason)"
    }

    private static func localModelMessage(reason: String) -> String {
        if reason.hasPrefix("ollama_unavailable") {
            return "Ollama 本地模型服务不可用。请先运行 Ollama，并确认 qwen3:8b 已下载。"
        }

        if reason.hasPrefix("ollama_empty_output") {
            return "Ollama 没有返回有效文本。请检查模型是否仍在加载，或换一个本地模型。"
        }

        return "本地文本模型不可用：\(reason)"
    }
}

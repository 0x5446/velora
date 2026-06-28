import AppKit
import Foundation
import Velora

struct CLIOptions {
    var mode: DictationMode = .translate
    var text = "明天上午十点我和 Alex 开会，帮我确认一下 agenda"
    var audioPath: String?
    var sourceLanguage = "zh"
    var targetLanguage = "en"
    var insertPolicy: InsertPolicy = .bilingual
    var copyToPasteboard = false
    var localModels = false
    var asrModelMode: WhisperModelMode = .fromEnvironment(ProcessInfo.processInfo.environment)
    var pretty = true
}

@main
struct VeloraMacCLI {
    static func main() async {
        do {
            let options = try parseOptions(Array(CommandLine.arguments.dropFirst()))
            let orchestrator = makeOrchestrator(options: options)

            let targetLanguage = options.mode == .translate ? options.targetLanguage : nil
            let result = try await orchestrator.run(
                PipelineRunRequest(
                    platform: .macOS,
                    mode: options.mode,
                    sampleText: options.audioPath == nil ? options.text : "",
                    audioPath: options.audioPath,
                    sourceLanguage: options.sourceLanguage,
                    targetLanguage: targetLanguage,
                    insertPolicy: options.insertPolicy,
                    insertionStrategy: .none
                )
            )

            if options.copyToPasteboard {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(result.finalText, forType: .string)
            }

            if options.pretty {
                print(result.finalText)
                print("")
                print("mode=\(options.mode.rawValue) release_to_insert_ms=\(result.trace.releaseToInsertMS) copy=\(options.copyToPasteboard)")
            } else {
                let data = try JSONEncoder.veloraPretty.encode(result)
                FileHandle.standardOutput.write(data)
                FileHandle.standardOutput.write(Data("\n".utf8))
            }
        } catch {
            fputs("VeloraMac error: \(VeloraErrorPresenter.message(for: error))\n", stderr)
            exit(1)
        }
    }

    private static func makeOrchestrator(options: CLIOptions) -> PipelineOrchestrator {
        let useLocalModels = options.localModels || options.audioPath != nil
        let asrEngine: any ASREngine = options.audioPath == nil
            ? FakeASREngine()
            : WhisperCLIASREngine(configuration: .configuration(for: options.asrModelMode))
        let textEngine: any TextIntelligenceEngine = useLocalModels
            ? OllamaTextIntelligenceEngine()
            : RuleBasedTextIntelligenceEngine()
        let translationEngine: any TranslationEngine = useLocalModels
            ? OllamaTranslationEngine()
            : StubTranslationEngine()

        return PipelineOrchestrator(
            asrEngine: asrEngine,
            contextProvider: StaticContextProvider(),
            memoryStore: InMemoryHotwordStore(),
            textEngine: textEngine,
            translationEngine: translationEngine,
            insertionEngine: NoopInsertionEngine()
        )
    }

    private static func parseOptions(_ args: [String]) throws -> CLIOptions {
        var options = CLIOptions()
        var index = 0

        while index < args.count {
            let arg = args[index]
            switch arg {
            case "--mode":
                let value = try value(after: arg, in: args, index: &index)
                guard let mode = DictationMode(rawValue: value) else {
                    throw PipelineError.unsupportedMode(value)
                }
                options.mode = mode
            case "--text":
                options.text = try value(after: arg, in: args, index: &index)
            case "--audio":
                options.audioPath = try value(after: arg, in: args, index: &index)
            case "--source":
                options.sourceLanguage = try value(after: arg, in: args, index: &index)
            case "--target":
                options.targetLanguage = try value(after: arg, in: args, index: &index)
            case "--insert-policy":
                let value = try value(after: arg, in: args, index: &index)
                switch value {
                case "bilingual":
                    options.insertPolicy = .bilingual
                case "target_only", "targetOnly":
                    options.insertPolicy = .targetOnly
                case "review_card", "reviewCard":
                    options.insertPolicy = .reviewCard
                default:
                    throw PipelineError.unsupportedMode("insert-policy:\(value)")
                }
            case "--copy":
                options.copyToPasteboard = true
            case "--local-models":
                options.localModels = true
            case "--asr-mode":
                let value = try value(after: arg, in: args, index: &index)
                guard let modelMode = WhisperModelMode(rawValue: value) else {
                    throw PipelineError.unsupportedMode("asr-mode:\(value)")
                }
                options.asrModelMode = modelMode
            case "--json":
                options.pretty = false
            case "--help", "-h":
                printHelp()
                exit(0)
            default:
                throw PipelineError.unsupportedMode("unknown argument:\(arg)")
            }

            index += 1
        }

        return options
    }

    private static func value(after flag: String, in args: [String], index: inout Int) throws -> String {
        let valueIndex = index + 1
        guard valueIndex < args.count else {
            throw PipelineError.unsupportedMode("missing value for \(flag)")
        }
        index = valueIndex
        return args[valueIndex]
    }

    private static func printHelp() {
        print(
            """
            Usage:
              VeloraMac --mode translate --text "明天上午十点我和 Alex 开会，帮我确认一下 agenda" --source zh --target en
              VeloraMac --mode translate --audio /tmp/clip.caf --source zh --target en --local-models

            Options:
              --mode dictate|polish|translate
              --text TEXT
              --audio PATH
              --source LANG
              --target LANG
              --insert-policy bilingual|target_only|review_card
              --asr-mode fast|accurate|fallback
              --local-models
              --copy
              --json
            """
        )
    }
}

extension JSONEncoder {
    fileprivate static var veloraPretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

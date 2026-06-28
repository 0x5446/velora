import Foundation

public struct VeloraRuntimeSettings: Codable, Sendable, Equatable {
    public var mode: DictationMode
    public var sourceLanguage: String
    public var targetLanguage: String
    public var insertPolicy: InsertPolicy
    public var preferredInsertLanguage: String
    public var asrModelMode: WhisperModelMode

    public init(
        mode: DictationMode,
        sourceLanguage: String,
        targetLanguage: String,
        insertPolicy: InsertPolicy,
        preferredInsertLanguage: String = "zh",
        asrModelMode: WhisperModelMode
    ) {
        self.mode = mode
        self.sourceLanguage = Self.cleanLanguage(sourceLanguage, defaultValue: "zh")
        self.targetLanguage = Self.cleanLanguage(targetLanguage, defaultValue: "en")
        self.insertPolicy = insertPolicy
        self.preferredInsertLanguage = TranslationLanguageResolver.normalizedLanguage(
            Self.cleanLanguage(preferredInsertLanguage, defaultValue: "zh")
        )
        self.asrModelMode = asrModelMode
    }

    public static func defaults(environment: [String: String] = ProcessInfo.processInfo.environment) -> VeloraRuntimeSettings {
        VeloraRuntimeSettings(
            mode: .translate,
            sourceLanguage: "zh",
            targetLanguage: "en",
            insertPolicy: .bilingual,
            preferredInsertLanguage: "zh",
            asrModelMode: .fromEnvironment(environment)
        )
    }

    public var effectiveTargetLanguage: String? {
        mode == .translate ? targetLanguage : nil
    }

    public var displaySummary: String {
        switch mode {
        case .dictate:
            return "mode=dictate source=\(sourceLanguage) asr=\(asrModelMode.rawValue)"
        case .polish:
            return "mode=polish source=\(sourceLanguage) asr=\(asrModelMode.rawValue)"
        case .translate:
            return "mode=translate \(sourceLanguage)->\(targetLanguage) output=\(preferredInsertLanguage) asr=\(asrModelMode.rawValue)"
        }
    }

    private static func cleanLanguage(_ value: String, defaultValue: String) -> String {
        let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? defaultValue : cleaned
    }
}

public final class VeloraSettingsStore: @unchecked Sendable {
    public static let shared = VeloraSettingsStore()
    public static let didChangeNotification = Notification.Name("VeloraSettingsStoreDidChange")
    public static let notificationSettingsKey = "settings"

    private enum Key {
        static let mode = "velora.runtime.mode"
        static let sourceLanguage = "velora.runtime.sourceLanguage"
        static let targetLanguage = "velora.runtime.targetLanguage"
        static let insertPolicy = "velora.runtime.insertPolicy"
        static let preferredInsertLanguage = "velora.runtime.preferredInsertLanguage"
        static let asrModelMode = "velora.runtime.asrModelMode"
    }

    private let defaults: UserDefaults
    private let environment: [String: String]
    private let notificationCenter: NotificationCenter

    public init(
        defaults: UserDefaults = .standard,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        notificationCenter: NotificationCenter = .default
    ) {
        self.defaults = defaults
        self.environment = environment
        self.notificationCenter = notificationCenter
    }

    public func load() -> VeloraRuntimeSettings {
        let fallback = VeloraRuntimeSettings.defaults(environment: environment)
        return VeloraRuntimeSettings(
            mode: enumValue(forKey: Key.mode, defaultValue: fallback.mode),
            sourceLanguage: stringValue(forKey: Key.sourceLanguage, defaultValue: fallback.sourceLanguage),
            targetLanguage: stringValue(forKey: Key.targetLanguage, defaultValue: fallback.targetLanguage),
            insertPolicy: enumValue(forKey: Key.insertPolicy, defaultValue: fallback.insertPolicy),
            preferredInsertLanguage: stringValue(
                forKey: Key.preferredInsertLanguage,
                defaultValue: fallback.preferredInsertLanguage
            ),
            asrModelMode: enumValue(forKey: Key.asrModelMode, defaultValue: fallback.asrModelMode)
        )
    }

    public func save(_ settings: VeloraRuntimeSettings) {
        let previous = load()
        defaults.set(settings.mode.rawValue, forKey: Key.mode)
        defaults.set(settings.sourceLanguage, forKey: Key.sourceLanguage)
        defaults.set(settings.targetLanguage, forKey: Key.targetLanguage)
        defaults.set(settings.insertPolicy.rawValue, forKey: Key.insertPolicy)
        defaults.set(settings.preferredInsertLanguage, forKey: Key.preferredInsertLanguage)
        defaults.set(settings.asrModelMode.rawValue, forKey: Key.asrModelMode)

        guard previous != settings else {
            return
        }

        notificationCenter.post(
            name: Self.didChangeNotification,
            object: self,
            userInfo: [Self.notificationSettingsKey: settings]
        )
    }

    public func update(_ mutate: (inout VeloraRuntimeSettings) -> Void) {
        var settings = load()
        mutate(&settings)
        save(settings)
    }

    private func stringValue(forKey key: String, defaultValue: String) -> String {
        guard let value = defaults.string(forKey: key)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return defaultValue
        }

        return value
    }

    private func enumValue<T>(forKey key: String, defaultValue: T) -> T where T: RawRepresentable, T.RawValue == String {
        guard let rawValue = defaults.string(forKey: key),
              let value = T(rawValue: rawValue) else {
            return defaultValue
        }

        return value
    }
}

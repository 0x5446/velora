import AppKit
import Carbon
import Foundation

enum MacHotKeyInvocation {
    case capture
    case translate
}

enum MacHotKeyPreset: String, CaseIterable, Identifiable {
    case function
    case functionShift
    case optionSpace
    case optionShiftSpace
    case controlSpace
    case controlShiftSpace
    case commandShiftSpace

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .function:
            return "Fn"
        case .functionShift:
            return "Fn ⇧"
        case .optionSpace:
            return "⌥ Space"
        case .optionShiftSpace:
            return "⌥ ⇧ Space"
        case .controlSpace:
            return "⌃ Space"
        case .controlShiftSpace:
            return "⌃ ⇧ Space"
        case .commandShiftSpace:
            return "⌘ ⇧ Space"
        }
    }

    var shortDisplayName: String {
        switch self {
        case .function:
            return "Fn"
        case .functionShift:
            return "Fn+⇧"
        case .optionSpace:
            return "⌥ Space"
        case .optionShiftSpace:
            return "⌥⇧ Space"
        case .controlSpace:
            return "⌃ Space"
        case .controlShiftSpace:
            return "⌃⇧ Space"
        case .commandShiftSpace:
            return "⌘⇧ Space"
        }
    }

    var detailText: String {
        switch self {
        case .function, .functionShift:
            return "低干扰默认键位。若系统把 Fn/Globe 分配给表情或听写，可切到 Space 组合键。"
        case .optionSpace, .optionShiftSpace:
            return "兼容性最好，适合外接键盘。"
        case .controlSpace, .controlShiftSpace:
            return "适合不想占用 Option 的键盘布局。"
        case .commandShiftSpace:
            return "更显式，误触最低。"
        }
    }

    var carbonRegistration: (keyCode: UInt32, modifiers: UInt32)? {
        switch self {
        case .optionSpace:
            return (UInt32(kVK_Space), UInt32(optionKey))
        case .optionShiftSpace:
            return (UInt32(kVK_Space), UInt32(optionKey | shiftKey))
        case .controlSpace:
            return (UInt32(kVK_Space), UInt32(controlKey))
        case .controlShiftSpace:
            return (UInt32(kVK_Space), UInt32(controlKey | shiftKey))
        case .commandShiftSpace:
            return (UInt32(kVK_Space), UInt32(cmdKey | shiftKey))
        case .function, .functionShift:
            return nil
        }
    }

    var usesFunctionModifier: Bool {
        self == .function || self == .functionShift
    }
}

struct MacHotKeyPreferences: Equatable {
    var capture: MacHotKeyPreset
    var translate: MacHotKeyPreset

    static let defaults = MacHotKeyPreferences(
        capture: .function,
        translate: .functionShift
    )

    var captureDisplayName: String {
        capture.displayName
    }

    var translateDisplayName: String {
        translate.displayName
    }
}

struct MacHotKeyConflict: Equatable {
    var title: String
    var detail: String
    var statusLine: String
}

enum MacHotKeyConflictDetector {
    @MainActor
    static func functionKeyConflict(for preferences: MacHotKeyPreferences) -> MacHotKeyConflict? {
        guard preferences.capture.usesFunctionModifier || preferences.translate.usesFunctionModifier else {
            return nil
        }

        let conflictingApps = NSWorkspace.shared.runningApplications
            .filter { app in
                let name = app.localizedName ?? ""
                let bundleID = app.bundleIdentifier ?? ""
                return name.localizedCaseInsensitiveContains("Typeless")
                    || bundleID.localizedCaseInsensitiveContains("typeless")
            }
            .compactMap(\.localizedName)

        guard !conflictingApps.isEmpty else {
            return nil
        }

        let appList = conflictingApps.uniqued().joined(separator: ", ")
        return MacHotKeyConflict(
            title: "Fn 可能被 Typeless 占用",
            detail: "\(appList) 正在运行。两个 App 同时监听 Fn 时会一起响应；退出 Typeless，或把 Velora 改成 Space 组合键。",
            statusLine: "fn_conflict app=\(appList)"
        )
    }
}

final class MacHotKeyStore: @unchecked Sendable {
    static let shared = MacHotKeyStore()
    static let didChangeNotification = Notification.Name("MacHotKeyStoreDidChange")
    static let notificationPreferencesKey = "preferences"

    private enum Key {
        static let capture = "velora.mac.hotkey.capture"
        static let translate = "velora.mac.hotkey.translate"
    }

    private let defaults: UserDefaults
    private let notificationCenter: NotificationCenter

    init(
        defaults: UserDefaults = .standard,
        notificationCenter: NotificationCenter = .default
    ) {
        self.defaults = defaults
        self.notificationCenter = notificationCenter
    }

    func load() -> MacHotKeyPreferences {
        MacHotKeyPreferences(
            capture: preset(forKey: Key.capture, defaultValue: MacHotKeyPreferences.defaults.capture),
            translate: preset(forKey: Key.translate, defaultValue: .functionShift)
        )
    }

    func save(_ preferences: MacHotKeyPreferences) {
        let previous = load()
        defaults.set(preferences.capture.rawValue, forKey: Key.capture)
        defaults.set(preferences.translate.rawValue, forKey: Key.translate)

        guard previous != preferences else {
            return
        }

        notificationCenter.post(
            name: Self.didChangeNotification,
            object: self,
            userInfo: [Self.notificationPreferencesKey: preferences]
        )
    }

    func update(_ mutate: (inout MacHotKeyPreferences) -> Void) {
        var preferences = load()
        mutate(&preferences)
        save(preferences)
    }

    private func preset(forKey key: String, defaultValue: MacHotKeyPreset) -> MacHotKeyPreset {
        guard let rawValue = defaults.string(forKey: key),
              let preset = MacHotKeyPreset(rawValue: rawValue) else {
            return defaultValue
        }
        return preset
    }

}

@MainActor
final class MacHotKeySettingsModel: ObservableObject {
    @Published var capturePreset: MacHotKeyPreset {
        didSet { persistFromView() }
    }
    @Published var translatePreset: MacHotKeyPreset {
        didSet { persistFromView() }
    }

    private let store: MacHotKeyStore
    private var isApplying = false

    init(store: MacHotKeyStore = .shared) {
        self.store = store
        let preferences = store.load()
        capturePreset = preferences.capture
        translatePreset = preferences.translate
    }

    var preferences: MacHotKeyPreferences {
        MacHotKeyPreferences(
            capture: capturePreset,
            translate: translatePreset
        )
    }

    var compatibilitySummary: String {
        if capturePreset.usesFunctionModifier || translatePreset.usesFunctionModifier {
            return "Fn 会优先监听；若当前系统设置拦截 Fn/Globe，切到 Space 组合键即可继续使用。"
        }
        return "当前快捷键走系统 Hot Key 注册，兼容性最高。"
    }

    func useSpaceFallback() {
        capturePreset = .optionSpace
        translatePreset = .optionShiftSpace
    }

    func reload() {
        apply(store.load())
    }

    private func apply(_ preferences: MacHotKeyPreferences) {
        guard self.preferences != preferences else {
            return
        }

        isApplying = true
        capturePreset = preferences.capture
        translatePreset = preferences.translate
        isApplying = false
    }

    private func persistFromView() {
        guard !isApplying else {
            return
        }
        store.save(preferences)
    }
}

private extension Sequence where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}

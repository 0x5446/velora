import Foundation

/// Developer mode gates every debugging surface: the developer submenu, the
/// text lab, diagnostics, and raw runtime knobs. Product mode shows none of
/// it — the shipping UI is the status menu plus a small settings panel.
@MainActor
final class MacDeveloperModeStore: ObservableObject {
    static let shared = MacDeveloperModeStore()
    private static let key = "velora.developer_mode"

    @Published var isEnabled: Bool {
        didSet {
            guard oldValue != isEnabled else {
                return
            }
            UserDefaults.standard.set(isEnabled, forKey: Self.key)
        }
    }

    private init() {
        isEnabled = UserDefaults.standard.bool(forKey: Self.key)
    }
}

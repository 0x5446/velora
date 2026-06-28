import Foundation

public struct KeyboardBridgeStore {
    public static let appGroupSuiteName = "group.app.velora.shared"
    public static let latestPayloadKey = "latestKeyboardPayload"

    private let defaults: UserDefaults
    private let key: String

    public init(userDefaults: UserDefaults, key: String = KeyboardBridgeStore.latestPayloadKey) {
        self.defaults = userDefaults
        self.key = key
    }

    public init?(appGroupSuiteName: String = KeyboardBridgeStore.appGroupSuiteName, key: String = KeyboardBridgeStore.latestPayloadKey) {
        guard let defaults = UserDefaults(suiteName: appGroupSuiteName) else {
            return nil
        }

        self.init(userDefaults: defaults, key: key)
    }

    public static func defaultStore() -> KeyboardBridgeStore {
        KeyboardBridgeStore(appGroupSuiteName: appGroupSuiteName)
            ?? KeyboardBridgeStore(userDefaults: .standard)
    }

    public func save(_ payload: KeyboardBridgePayload) throws {
        let data = try KeyboardBridgeCoding.encoder.encode(payload)
        defaults.set(data, forKey: key)
        defaults.synchronize()
    }

    public func loadLatestPayload(now: Date = Date(), removeExpired: Bool = true) throws -> KeyboardBridgePayload? {
        guard let data = defaults.data(forKey: key) else {
            return nil
        }

        let payload = try KeyboardBridgeCoding.decoder.decode(KeyboardBridgePayload.self, from: data)
        guard !payload.isExpired(at: now) else {
            if removeExpired {
                clear()
            }
            return nil
        }

        return payload
    }

    public func clear() {
        defaults.removeObject(forKey: key)
        defaults.synchronize()
    }
}

public enum KeyboardBridgeCoding {
    public static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    public static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

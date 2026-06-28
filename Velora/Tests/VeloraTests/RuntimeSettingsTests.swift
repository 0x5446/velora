import Foundation
import Testing
@testable import Velora

@Test func runtimeSettingsDefaultToTranslateBilingualFastPath() {
    let settings = VeloraRuntimeSettings.defaults(
        environment: ["VELORA_WHISPER_MODE": "accurate"]
    )

    #expect(settings.mode == .translate)
    #expect(settings.sourceLanguage == "zh")
    #expect(settings.targetLanguage == "en")
    #expect(settings.insertPolicy == .bilingual)
    #expect(settings.preferredInsertLanguage == "zh")
    #expect(settings.asrModelMode == .accurate)
    #expect(settings.effectiveTargetLanguage == "en")
    #expect(settings.displaySummary.contains("mode=translate"))
    #expect(settings.displaySummary.contains("zh->en"))
}

@Test func runtimeSettingsStoreRoundTripsPersistedValues() throws {
    let suiteName = uniqueDefaultsSuiteName()
    let defaults = try temporaryUserDefaults(suiteName: suiteName)
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let store = VeloraSettingsStore(
        defaults: defaults,
        environment: ["VELORA_WHISPER_MODE": "fast"],
        notificationCenter: NotificationCenter()
    )

    let saved = VeloraRuntimeSettings(
        mode: .polish,
        sourceLanguage: "en",
        targetLanguage: "ja",
        insertPolicy: .targetOnly,
        preferredInsertLanguage: "ja",
        asrModelMode: .fallback
    )
    store.save(saved)

    #expect(store.load() == saved)
    #expect(store.load().effectiveTargetLanguage == nil)
}

@Test func runtimeSettingsStorePostsChangeNotificationsOnlyForRealChanges() throws {
    let suiteName = uniqueDefaultsSuiteName()
    let defaults = try temporaryUserDefaults(suiteName: suiteName)
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let notificationCenter = NotificationCenter()
    let store = VeloraSettingsStore(
        defaults: defaults,
        environment: [:],
        notificationCenter: notificationCenter
    )

    let counter = NotificationCounter()
    let observer = notificationCenter.addObserver(
        forName: VeloraSettingsStore.didChangeNotification,
        object: store,
        queue: nil
    ) { notification in
        counter.increment()
        let settings = notification.userInfo?[VeloraSettingsStore.notificationSettingsKey] as? VeloraRuntimeSettings
        #expect(settings?.mode == .dictate)
    }
    defer { notificationCenter.removeObserver(observer) }

    store.update { settings in
        settings.mode = .dictate
    }
    store.update { settings in
        settings.mode = .dictate
    }

    #expect(counter.value == 1)
}

private func uniqueDefaultsSuiteName() -> String {
    "VeloraRuntimeSettingsTests.\(UUID().uuidString)"
}

private func temporaryUserDefaults(suiteName: String) throws -> UserDefaults {
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defaults.removePersistentDomain(forName: suiteName)
    return defaults
}

private final class NotificationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }
}

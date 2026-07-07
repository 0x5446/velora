import AppKit
import ApplicationServices
import Carbon
import Foundation

/// Learning-loop preferences. Learning is on by default — the entire loop is
/// local and inspectable — but must die instantly when switched off, so every
/// journal write and observer start re-reads these flags.
enum MacLearningSettings {
    static let learningEnabledKey = "velora.learning.enabled"
    static let audioRetentionKey = "velora.learning.audioRetention"

    static var learningEnabled: Bool {
        UserDefaults.standard.object(forKey: learningEnabledKey) == nil
            ? true
            : UserDefaults.standard.bool(forKey: learningEnabledKey)
    }

    /// Audio retention is gated by the master learning switch too: turning
    /// learning off must stop new clips even if the retention flag was left on
    /// (the settings UI only hides that toggle, it doesn't clear it).
    static var audioRetentionEnabled: Bool {
        learningEnabled && UserDefaults.standard.bool(forKey: audioRetentionKey)
    }
}

/// The three privacy layers in front of ANY post-insertion observation
/// (design doc §10.3). Ordered cheapest-first; all three must pass.
/// This is also the anti-keylogger contract: observation is only ever armed
/// for the element we just inserted into, and these gates can veto even that.
enum MacLearningPrivacy {
    /// Never learn from password managers or system credential surfaces.
    /// Prefix match on bundle id.
    ///
    /// Terminals are deliberately NOT blocked: they are a primary dictation
    /// surface (talking to CLI agents), the diff only ever touches the span
    /// Velora itself inserted, and terminal password prompts (sudo, ssh)
    /// enable secure event input, which layer 1 already vetoes.
    static let blockedBundlePrefixes: [String] = [
        "com.1password.",
        "com.agilebits.",
        "com.bitwarden.",
        "com.lastpass.",
        "org.keepassxc.",
        "com.apple.keychainaccess",
        "com.apple.Passwords",
        "com.apple.systempreferences",
    ]

    /// nil = allowed; otherwise a journal-safe reason string.
    static func blockReason(bundleID: String?, elementSubrole: String?) -> String? {
        // Layer 1: the system-wide secure-input flag is on exactly when a
        // password is being typed somewhere.
        if IsSecureEventInputEnabled() {
            return "secure_event_input"
        }
        // Layer 2: native and web password fields both surface this subrole.
        if let elementSubrole, elementSubrole == (kAXSecureTextFieldSubrole as String) {
            return "secure_text_field"
        }
        // Layer 3: app-level blacklist.
        if let bundleID {
            let lowered = bundleID.lowercased()
            for prefix in blockedBundlePrefixes where lowered.hasPrefix(prefix.lowercased()) {
                return "blocked_app"
            }
        }
        return nil
    }

    static func subrole(of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &value) == .success else {
            return nil
        }
        return value as? String
    }

    /// Privacy verdict for the CURRENTLY focused element, computed on the main
    /// thread right after a paste. Journal writes and audio retention use this
    /// so a web/custom password field (identifiable only by its AX subrole, not
    /// the global secure-input flag) is refused BEFORE anything hits disk —
    /// closing the window where recordInsertion previously ran with subrole=nil.
    @MainActor
    static func focusedBlockReason(bundleID: String?) -> String? {
        var subrole: String?
        if AXIsProcessTrusted() {
            let systemWide = AXUIElementCreateSystemWide()
            var focused: CFTypeRef?
            if AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
               let focused,
               CFGetTypeID(focused) == AXUIElementGetTypeID() {
                subrole = self.subrole(of: focused as! AXUIElement)
            }
        }
        return blockReason(bundleID: bundleID, elementSubrole: subrole)
    }
}

/// Opt-in audio retention for future model fine-tuning. Clips live under
/// Application Support/Velora/clips with a hard ring-buffer quota; oldest
/// clips are deleted first. Everything stays on this machine.
enum MacAudioClipVault {
    static let quotaBytes: Int64 = 2 * 1_024 * 1_024 * 1_024

    static var vaultDirectory: URL? {
        guard let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        return directory.appendingPathComponent("Velora/clips", isDirectory: true)
    }

    /// Moves the recording into the vault and kicks an async 16k mono WAV
    /// conversion (≈6× smaller than the raw caf; also the format SenseVoice/
    /// whisper fine-tuning pipelines expect). Returns the journal reference.
    static func store(clipAt url: URL, sessionID: String) -> String? {
        guard MacLearningSettings.audioRetentionEnabled,
              let vault = vaultDirectory else {
            return nil
        }
        try? FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)
        let cafDestination = vault.appendingPathComponent("\(sessionID).caf")
        do {
            try FileManager.default.moveItem(at: url, to: cafDestination)
        } catch {
            return nil
        }

        let wavDestination = vault.appendingPathComponent("\(sessionID).wav")
        Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/afconvert")
            process.arguments = ["-f", "WAVE", "-d", "LEI16@16000", "-c", "1", cafDestination.path, wavDestination.path]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try? process.run()
            process.waitUntilExit()
            if process.terminationStatus == 0,
               FileManager.default.fileExists(atPath: wavDestination.path) {
                try? FileManager.default.removeItem(at: cafDestination)
            }
            enforceQuota()
        }
        return "clips/\(sessionID).wav"
    }

    static func remove(reference: String) {
        guard reference.hasPrefix("clips/"),
              let vault = vaultDirectory else {
            return
        }
        let name = String(reference.dropFirst("clips/".count))
        try? FileManager.default.removeItem(at: vault.appendingPathComponent(name))
        let caf = (name as NSString).deletingPathExtension + ".caf"
        try? FileManager.default.removeItem(at: vault.appendingPathComponent(caf))
    }

    static func enforceQuota() {
        guard let vault = vaultDirectory,
              let files = try? FileManager.default.contentsOfDirectory(
                  at: vault,
                  includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]
              ) else {
            return
        }
        var entries: [(url: URL, size: Int64, date: Date)] = files.compactMap { file in
            guard let values = try? file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
                  let size = values.fileSize else {
                return nil
            }
            return (file, Int64(size), values.contentModificationDate ?? .distantPast)
        }
        var total = entries.reduce(Int64(0)) { $0 + $1.size }
        guard total > quotaBytes else {
            return
        }
        entries.sort { $0.date < $1.date }
        for entry in entries {
            guard total > quotaBytes else {
                break
            }
            try? FileManager.default.removeItem(at: entry.url)
            total -= entry.size
        }
    }

    static func totalBytes() -> Int64 {
        guard let vault = vaultDirectory,
              let files = try? FileManager.default.contentsOfDirectory(
                  at: vault,
                  includingPropertiesForKeys: [.fileSizeKey]
              ) else {
            return 0
        }
        return files.reduce(Int64(0)) { sum, file in
            sum + Int64((try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        }
    }
}

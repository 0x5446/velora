import AppKit
import ApplicationServices
import Foundation
import Velora

/// Developer-mode-only automation bridge, listening on the distributed
/// notification center so a local harness (scripts/e2e/) can drive the EXACT
/// production pipeline without a microphone, synthetic key events, or any
/// TCC grant of its own:
///
///   app.velora.debug.dictate      object = "path.wav" or "path.wav|targetPID"
///       Injects the clip as if fn was just released: journal harvest/ingest,
///       ASR → polish → paste → post-insert learning. With a pid the paste
///       is pinned to that app (Velora activates it with its own AX trust —
///       background-launched harnesses may be denied self-activation);
///       without one it goes to the frontmost app like production.
///       The file is copied first — the pipeline deletes its clip when done.
///
///   app.velora.debug.probeFocused object = bundle id of a running app
///       Uses Velora's OWN accessibility trust to dump structural facts about
///       that app's focused element (value size, wrap/padding shape, whether
///       the last inserted text still matches raw/stripped) to
///       Application Support/Velora/debug-probe.json. Diagnoses grid hosts
///       without granting the harness AX rights and WITHOUT persisting any
///       screen content — counts and booleans only.
///
/// Gated on MacDeveloperModeStore at EVERY event, not just at install: the
/// bridge goes dead the moment developer mode is switched off.
@MainActor
final class MacDebugBridge {
    static let dictateNotification = Notification.Name("app.velora.debug.dictate")
    static let probeNotification = Notification.Name("app.velora.debug.probeFocused")

    private weak var controller: MacDictationController?
    private var tokens: [NSObjectProtocol] = []

    init(controller: MacDictationController) {
        self.controller = controller
        let center = DistributedNotificationCenter.default()
        tokens.append(center.addObserver(
            forName: Self.dictateNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let path = notification.object as? String
            Task { @MainActor in
                self?.handleDictate(path: path)
            }
        })
        tokens.append(center.addObserver(
            forName: Self.probeNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let bundleID = notification.object as? String
            Task { @MainActor in
                self?.handleProbe(bundleID: bundleID)
            }
        })
    }

    // No deinit: the bridge is owned by the app delegate for the whole
    // process lifetime, so the observer tokens die with the process.

    private func handleDictate(path: String?) {
        guard MacDeveloperModeStore.shared.isEnabled, let path else {
            return
        }
        let parts = path.split(separator: "|", maxSplits: 1)
        let wavPath = String(parts[0])
        let targetPID = parts.count > 1 ? pid_t(parts[1]) : nil
        guard FileManager.default.fileExists(atPath: wavPath) else {
            return
        }
        // The pipeline deletes its clip after the run; keep the caller's file.
        let copy = FileManager.default.temporaryDirectory
            .appendingPathComponent("velora-debug-\(UUID().uuidString).wav")
        do {
            try FileManager.default.copyItem(at: URL(fileURLWithPath: wavPath), to: copy)
        } catch {
            return
        }
        controller?.debugInjectClip(at: copy, targetPID: targetPID)
    }

    /// Structural diagnosis only — the element's text NEVER leaves the stats.
    /// Object may be "bundleID" or "bundleID|customNeedle" — the needle is
    /// text the CALLER already knows; results are match booleans and gap
    /// counts, never element content.
    private func handleProbe(bundleID rawObject: String?) {
        guard MacDeveloperModeStore.shared.isEnabled, let rawObject else {
            return
        }
        let parts = rawObject.split(separator: "|", maxSplits: 1)
        let bundleID = String(parts[0])
        let customNeedle = parts.count > 1 ? String(parts[1]) : nil
        var report: [String: Any] = [
            "bundle_id": bundleID,
            "at": ISO8601DateFormatter().string(from: Date()),
        ]
        defer { writeProbeReport(report) }

        guard let app = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == bundleID
        }) else {
            report["error"] = "app_not_running"
            return
        }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(appElement, 0.5)
        var focusedRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(
            appElement, kAXFocusedUIElementAttribute as CFString, &focusedRef
        ) != .success {
            // Electron hosts need the manual-accessibility nudge (same as
            // the observer's capture path) before their tree exists.
            AXUIElementSetAttributeValue(appElement, "AXManualAccessibility" as CFString, kCFBooleanTrue)
            usleep(500_000)
            _ = AXUIElementCopyAttributeValue(
                appElement, kAXFocusedUIElementAttribute as CFString, &focusedRef
            )
        }
        guard let focusedRef, CFGetTypeID(focusedRef) == AXUIElementGetTypeID() else {
            report["error"] = "no_focused_element"
            return
        }
        let element = focusedRef as! AXUIElement
        AXUIElementSetMessagingTimeout(element, 0.5)

        var roleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef)
        report["role"] = (roleRef as? String) ?? ""
        report["subrole"] = MacLearningPrivacy.subrole(of: element) ?? ""

        var valueRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element, kAXValueAttribute as CFString, &valueRef
        ) == .success, let value = valueRef as? String else {
            report["error"] = "value_unreadable"
            return
        }
        let rows = value.split(separator: "\n", omittingEmptySubsequences: false)
        report["value_chars"] = value.count
        report["over_capture_cap"] = value.count > 100_000
        report["newlines"] = value.filter(\.isNewline).count
        report["rows"] = rows.count
        report["rows_with_trailing_space"] = rows.filter { $0.hasSuffix(" ") }.count
        report["max_row_chars"] = rows.map(\.count).max() ?? 0

        // Would the LAST insertion into this app anchor today? Counts only.
        if let inserted = customNeedle ?? lastInsertedText(appBundle: bundleID) {
            let stripped = VeloraSpanAnchor.strippingHardWraps(value)
            report["needle_chars"] = inserted.count
            report["needle_matches_raw"] = value.contains(inserted)
            report["needle_matches_stripped"] = stripped.contains(inserted)
            let denseValue = stripped.filter { !$0.isWhitespace }
            let denseNeedle = inserted.filter { !$0.isWhitespace }
            report["needle_matches_whitespace_free"] =
                !denseNeedle.isEmpty && denseValue.contains(denseNeedle)
            // What exactly sits BETWEEN the needle's characters in the raw
            // buffer? Two-pointer scan allowing small gaps; reports gap
            // character classes only (this is how a grid host's padding /
            // wrap artifacts are identified without dumping screen content).
            report["gap_match"] = gapMatchStats(needle: inserted, in: value)
        }
    }

    /// Finds `needle`'s characters in order inside `hay`, tolerating up to
    /// `maxGap` filler chars between consecutive needle chars. Returns match
    /// success plus a histogram of the filler classes encountered.
    private func gapMatchStats(needle: String, in hay: String, maxGap: Int = 8) -> [String: Any] {
        let needleChars = Array(needle)
        let hayChars = Array(hay)
        guard let first = needleChars.first else {
            return ["matched": false]
        }
        var bestStats: [String: Any] = ["matched": false]
        for start in hayChars.indices where hayChars[start] == first {
            var gaps: [String: Int] = [:]
            var gapCodepoints = Set<UInt32>()
            var maxRun = 0
            var hayIndex = start + 1
            var needleIndex = 1
            var run = 0
            var failed = false
            while needleIndex < needleChars.count {
                guard hayIndex < hayChars.count, run <= maxGap else {
                    failed = true
                    break
                }
                let ch = hayChars[hayIndex]
                if ch == needleChars[needleIndex] {
                    needleIndex += 1
                    maxRun = max(maxRun, run)
                    run = 0
                } else {
                    let cls: String
                    if ch.isNewline {
                        cls = "newline"
                    } else if ch == " " {
                        cls = "space"
                    } else if ch.isWhitespace {
                        cls = "other_ws"
                    } else {
                        cls = "other"
                    }
                    gaps[cls, default: 0] += 1
                    if let scalar = ch.unicodeScalars.first {
                        gapCodepoints.insert(scalar.value)
                    }
                    run += 1
                }
                hayIndex += 1
            }
            if !failed {
                return ["matched": true, "gap_histogram": gaps, "max_gap_run": maxRun,
                        "gap_codepoints": Array(gapCodepoints).sorted().prefix(5).map { String(format: "U+%04X", $0) }]
            }
            bestStats = ["matched": false]
        }
        return bestStats
    }

    private func lastInsertedText(appBundle: String) -> String? {
        let journal = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Velora/corrections.jsonl")
        guard let data = try? String(contentsOf: journal, encoding: .utf8) else {
            return nil
        }
        var found: String?
        for line in data.split(separator: "\n") {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  object["kind"] as? String == "insertion",
                  object["app_bundle"] as? String == appBundle,
                  let text = object["final_text"] as? String else {
                continue
            }
            found = text
        }
        return found
    }

    private func writeProbeReport(_ report: [String: Any]) {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Velora/debug-probe.json")
        guard let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) else {
            return
        }
        try? data.write(to: url, options: .atomic)
    }
}

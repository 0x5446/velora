// E2E target window for the edit-capture learning loop.
//
// Plays the "user" side of the loop without needing ANY TCC permission of its
// own: Velora (which IS accessibility-trusted) pastes into this window's text
// view, and the harness then edits its OWN text storage programmatically —
// exactly what a human correction looks like to the AXObserver watching from
// the outside.
//
// Usage:  swift EditCaptureTarget.swift "商品=上屏,新引=新颖" [idleExitSeconds]
//
//   arg1: comma-separated from=to replacements applied ~2s after a paste
//         lands (first matching rule wins; applied at most once).
//   arg2: exit this many seconds after the edit was applied (default 20 —
//         long enough for the 5s quiet settle plus margin).
//
// Prints PASTED:/EDITED:/DONE lines to stdout for the orchestrator.
import AppKit

final class TargetAppDelegate: NSObject, NSApplicationDelegate {
    private let rules: [(from: String, to: String)]
    private let idleExitSeconds: TimeInterval
    private var window: NSWindow!
    private var textView: NSTextView!
    private var pollTimer: Timer?
    private var edited = false
    private var previousFrontmost: NSRunningApplication?

    init(rules: [(from: String, to: String)], idleExitSeconds: TimeInterval) {
        self.rules = rules
        self.idleExitSeconds = idleExitSeconds
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        previousFrontmost = NSWorkspace.shared.frontmostApplication
        installEditMenu()

        let frame = NSRect(x: 200, y: 200, width: 640, height: 220)
        window = NSWindow(
            contentRect: frame,
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Velora E2E Target"
        let scroll = NSScrollView(frame: window.contentView!.bounds)
        textView = NSTextView(frame: scroll.bounds)
        textView.isRichText = false
        textView.font = .systemFont(ofSize: 16)
        scroll.documentView = textView
        window.contentView!.addSubview(scroll)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(textView)
        // Best-effort only: macOS may deny self-activation of background-
        // launched processes. The orchestrator therefore passes our pid to
        // the debug bridge and Velora activates us with its own AX trust.
        NSApp.activate(ignoringOtherApps: true)
        print("READY PID:\(ProcessInfo.processInfo.processIdentifier)")
        fflush(stdout)

        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.poll()
        }
    }

    /// The window cannot become key while the app is denied activation at
    /// launch; when Velora AX-activates us right before pasting, re-assert
    /// key window + first responder so Cmd-V lands in the text view.
    func applicationDidBecomeActive(_ notification: Notification) {
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(textView)
    }

    /// Cmd-V is a MENU key equivalent — a menu-less background app has no
    /// guaranteed route for it. Install the minimal Edit menu.
    private func installEditMenu() {
        let mainMenu = NSMenu()
        let editItem = NSMenuItem()
        mainMenu.addItem(editItem)
        let editMenu = NSMenu(title: "Edit")
        editItem.submenu = editMenu
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        NSApp.mainMenu = mainMenu
    }

    private func poll() {
        let text = textView.string
        guard !edited, !text.isEmpty else {
            return
        }
        // No rules = receive-only round (used to trigger the next journal
        // ingest without adding edits): report the paste, idle, exit.
        guard !rules.isEmpty else {
            edited = true
            print("PASTED:\(text)")
            fflush(stdout)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.previousFrontmost?.activate()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + idleExitSeconds) {
                print("DONE")
                fflush(stdout)
                NSApp.terminate(nil)
            }
            return
        }
        guard let rule = rules.first(where: { text.contains($0.from) }) else {
            return
        }
        edited = true
        print("PASTED:\(text)")
        // A human takes a beat before fixing; also keeps the edit clear of
        // the observer's capture-retry window (though fuzzy-arm now covers
        // even an instant edit).
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) { [weak self] in
            guard let self else { return }
            let current = self.textView.string
            let corrected = current.replacingOccurrences(of: rule.from, with: rule.to)
            // Replace through the text storage so AX emits kAXValueChanged,
            // the same signal real typing produces.
            self.textView.textStorage?.replaceCharacters(
                in: NSRange(location: 0, length: (current as NSString).length),
                with: corrected
            )
            print("EDITED:\(corrected)")
            fflush(stdout)
            // Give the AXObserver one poll to sample the edit, then hand
            // focus straight back to the user's app — the app switch also
            // makes Velora settle (and journal) immediately instead of
            // waiting out the 5s quiet window.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                self.previousFrontmost?.activate()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + self.idleExitSeconds) {
                print("DONE")
                fflush(stdout)
                NSApp.terminate(nil)
            }
        }
    }
}

let arguments = CommandLine.arguments
let rules: [(from: String, to: String)] = (arguments.count > 1 ? arguments[1] : "")
    .split(separator: ",")
    .compactMap { pair in
        let parts = pair.split(separator: "=", maxSplits: 1)
        guard parts.count == 2 else { return nil }
        return (from: String(parts[0]), to: String(parts[1]))
    }
let idleExit = arguments.count > 2 ? TimeInterval(arguments[2]) ?? 20 : 20

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = TargetAppDelegate(rules: rules, idleExitSeconds: idleExit)
app.delegate = delegate
app.run()

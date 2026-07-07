import AppKit
import ApplicationServices
import Carbon
import Velora

/// Watches the text field we just inserted into and turns the user's manual
/// fixes into learning signals (hotword candidates + fine-tune triples).
///
/// Anti-keylogger contract, enforced structurally:
/// 1. Observation only ever targets the element Velora just pasted into, and
///    only for a bounded window (60s, earlier on focus/app change).
/// 2. The keyboard monitor NEVER reads key content — it only sets a dirty
///    flag; all text comes from re-reading that one element's AXValue.
/// 3. Only the inserted span (located by context anchors) is diffed and
///    persisted; edits anywhere else in the document are never extracted.
/// 4. `MacLearningPrivacy` (secure input / secure field / app blacklist) can
///    veto the whole observation before it starts.
@MainActor
final class MacPostInsertObserver {
    struct PendingObservation {
        var sessionID: String
        var mode: DictationMode
        var insertedText: String
        var asrText: String
        var polishedText: String
        var appliedEdits: [TextEdit]
        var targetPID: pid_t
        var targetBundleID: String
        var language: String
    }

    private struct ActiveObservation {
        var pending: PendingObservation
        var element: AXUIElement
        var appElement: AXUIElement
        var axObserver: AXObserver
        var baselineValue: String
        var spanStart: Int
        var startedAt: Date
        var lastSampledValue: String
        var lastChangeAt: Date?
        /// Terminal-grid host: hard wraps are stripped from every value read
        /// (baselineValue/spanStart already live in stripped space).
        var stripsHardWraps: Bool
        /// Character length of the located span in `baselineValue`. Equals
        /// the inserted text's length for exact matches, but can differ when
        /// capture had to fuzzy-arm over an already-edited field.
        var spanLength: Int
        /// Last poll sample where the span could still be located. Grid hosts
        /// clear the input line on send (Enter) and re-render the text with
        /// different wrapping, so the settle-time read often cannot anchor
        /// anymore — this preserves the edit state from just before the send.
        var lastGoodExtraction: VeloraSpanAnchor.Extraction?
    }

    /// What survives after an observation ends, so the NEXT dictation can do
    /// a free "lazy diff" and catch edits made after the live window closed.
    private struct Residue {
        var pending: PendingObservation
        var element: AXUIElement
        var baselineValue: String
        var spanStart: Int
        var lastReportedSpan: String
        var expiresAt: Date
        var stripsHardWraps: Bool
        var spanLength: Int
    }

    static let observationWindowSeconds: TimeInterval = 60
    static let quietSettleSeconds: TimeInterval = 5
    static let residueLifetimeSeconds: TimeInterval = 30 * 60

    private var active: ActiveObservation?
    private var residue: Residue?
    private var captureTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    private var keyboardMonitor: Any?
    private var workspaceObserver: NSObjectProtocol?
    private var dirty = false

    // MARK: - Lifecycle

    /// Arms observation for a fresh insertion. The paste lands asynchronously
    /// in the target app, so capture retries a few times before giving up.
    func begin(_ pending: PendingObservation) {
        guard MacLearningSettings.learningEnabled else {
            return
        }
        MacLearningDebugLog.log("begin session=\(pending.sessionID.prefix(8)) pid=\(pending.targetPID)")
        stopObservation(reason: "superseded")
        captureTask?.cancel()
        captureTask = Task { @MainActor [weak self] in
            // Denser early retries: capture must win the race against the
            // user's first correction, which can land within 2 seconds.
            for delayMS in [250, 450, 800, 1_400] {
                try? await Task.sleep(nanoseconds: UInt64(delayMS) * 1_000_000)
                guard let self, !Task.isCancelled else {
                    return
                }
                if self.tryCapture(pending) {
                    return
                }
            }
        }
    }

    /// Called when the user starts the next dictation: settle any live
    /// observation immediately and lazy-diff the previous span one last time.
    func harvestBeforeNextDictation() {
        // Cancel a still-pending capture (paste landed <350ms before the next
        // dictation): otherwise its delayed retry could arm an observation for
        // the previous utterance mid-way through the new recording.
        captureTask?.cancel()
        captureTask = nil
        if active != nil {
            settle(reason: "next_session")
        }
        lazyDiffResidue()
    }

    func invalidate() {
        captureTask?.cancel()
        captureTask = nil
        stopObservation(reason: "invalidated")
        residue = nil
    }

    // MARK: - Capture

    /// Returns true when observation started OR is permanently impossible
    /// (privacy veto); false asks the caller to retry (paste not landed yet).
    private func tryCapture(_ pending: PendingObservation) -> Bool {
        guard MacLearningSettings.learningEnabled else {
            return true
        }
        let appElement = AXUIElementCreateApplication(pending.targetPID)
        // Cap the timeout BEFORE the first cross-process read: a hung target
        // app must never stall Velora's main thread even on this initial fetch.
        AXUIElementSetMessagingTimeout(appElement, 0.3)
        guard let element = copyElement(appElement, kAXFocusedUIElementAttribute) else {
            MacLearningDebugLog.log("capture retry: no focused element")
            return false
        }
        AXUIElementSetMessagingTimeout(element, 0.3)

        if MacLearningPrivacy.blockReason(
            bundleID: pending.targetBundleID,
            elementSubrole: MacLearningPrivacy.subrole(of: element)
        ) != nil {
            MacLearningDebugLog.log("capture veto: privacy block")
            return true
        }

        guard let rawValue = stringValue(of: element), rawValue.count <= 100_000 else {
            MacLearningDebugLog.log("capture retry: value unreadable or > 100k")
            return false
        }
        // Anchor on the LAST occurrence — the freshly pasted text sits at the
        // cursor, and earlier duplicates would mis-anchor the span.
        var value = rawValue
        var stripsHardWraps = false
        var spanStart: Int
        var spanLength = pending.insertedText.count
        if let range = rawValue.range(of: pending.insertedText, options: [.backwards]) {
            spanStart = rawValue.distance(from: rawValue.startIndex, to: range.lowerBound)
        } else if case let stripped = VeloraSpanAnchor.strippingHardWraps(rawValue),
                  let range = stripped.range(of: pending.insertedText, options: [.backwards]) {
            // Terminal-grid hosts (iTerm2 & co.) expose the screen as wrapped
            // rows: any span longer than one row has hard \n injected inside
            // it, so the exact match above cannot hit. Match in wrap-stripped
            // space and keep the whole observation there.
            value = stripped
            stripsHardWraps = true
            spanStart = stripped.distance(from: stripped.startIndex, to: range.lowerBound)
        } else if rawValue.count <= 4_000,
                  let range = VeloraSpanAnchor.fuzzyLocate(
                      Array(pending.insertedText), in: Array(rawValue)
                  ) {
            // The user may already be editing the span (fast fixes land
            // within the capture retries): fuzzy-arm so the observation
            // still starts. The baseline span is the CURRENT, possibly
            // part-edited text — the settle diff still compares the
            // original inserted text against the user's final span.
            spanStart = range.lowerBound
            spanLength = range.upperBound - range.lowerBound
        } else if case let stripped = VeloraSpanAnchor.strippingHardWraps(rawValue),
                  stripped.count <= 4_000, stripped.count != rawValue.count,
                  let range = VeloraSpanAnchor.fuzzyLocate(
                      Array(pending.insertedText), in: Array(stripped)
                  ) {
            value = stripped
            stripsHardWraps = true
            spanStart = range.lowerBound
            spanLength = range.upperBound - range.lowerBound
        } else {
            MacLearningDebugLog.log("capture retry: span not located (value=\(rawValue.count) chars)")
            return false
        }

        var axObserverRef: AXObserver?
        guard AXObserverCreate(pending.targetPID, Self.axCallback, &axObserverRef) == .success,
              let axObserver = axObserverRef else {
            return true
        }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        AXObserverAddNotification(axObserver, element, kAXValueChangedNotification as CFString, refcon)
        AXObserverAddNotification(axObserver, element, kAXUIElementDestroyedNotification as CFString, refcon)
        AXObserverAddNotification(axObserver, appElement, kAXFocusedUIElementChangedNotification as CFString, refcon)
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(axObserver), .defaultMode)

        active = ActiveObservation(
            pending: pending,
            element: element,
            appElement: appElement,
            axObserver: axObserver,
            baselineValue: value,
            spanStart: spanStart,
            startedAt: Date(),
            lastSampledValue: value,
            lastChangeAt: nil,
            stripsHardWraps: stripsHardWraps,
            spanLength: spanLength,
            lastGoodExtraction: nil
        )
        dirty = false
        startAuxiliaryMonitors(targetPID: pending.targetPID)
        startPolling()
        MacLearningDebugLog.log("armed session=\(pending.sessionID.prefix(8)) stripsWraps=\(stripsHardWraps) spanStart=\(spanStart) spanLen=\(spanLength)")
        return true
    }

    private static let axCallback: AXObserverCallback = { _, _, notification, refcon in
        guard let refcon else {
            return
        }
        let observer = Unmanaged<MacPostInsertObserver>.fromOpaque(refcon).takeUnretainedValue()
        let name = notification as String
        // The observer's run-loop source lives on the main run loop, so this
        // callback always arrives on the main thread.
        MainActor.assumeIsolated {
            observer.handleAXNotification(name)
        }
    }

    private func handleAXNotification(_ name: String) {
        switch name {
        case kAXValueChangedNotification as String:
            dirty = true
        case kAXUIElementDestroyedNotification as String:
            settle(reason: "element_destroyed")
        case kAXFocusedUIElementChangedNotification as String:
            settleIfChanged(reason: "focus_change")
        default:
            break
        }
    }

    private func startAuxiliaryMonitors(targetPID: pid_t) {
        // Dirty-flag ONLY: we deliberately ignore which key was pressed.
        keyboardMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown]) { [weak self] _ in
            Task { @MainActor in
                self?.dirty = true
            }
        }
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let activated = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            Task { @MainActor in
                guard let self, let activated, self.active != nil else {
                    return
                }
                if activated.processIdentifier != targetPID {
                    self.settleIfChanged(reason: "app_switch")
                }
            }
        }
    }

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self, !Task.isCancelled else {
                    return
                }
                self.pollTick()
            }
        }
    }

    private func pollTick() {
        guard var observation = active else {
            pollTask?.cancel()
            return
        }
        let now = Date()
        if now.timeIntervalSince(observation.startedAt) >= Self.observationWindowSeconds {
            settle(reason: "timeout")
            return
        }
        guard dirty else {
            checkQuietSettle(observation, now: now)
            return
        }
        dirty = false
        guard let value = sampleValue(of: observation.element, stripped: observation.stripsHardWraps) else {
            settle(reason: "element_unreadable")
            return
        }
        MacLearningDebugLog.log("poll sample \(value.count)ch changed=\(value != observation.lastSampledValue)")
        if value != observation.lastSampledValue {
            observation.lastSampledValue = value
            observation.lastChangeAt = now
            // Try to locate the span in this sample while it still exists:
            // on grid hosts the send (Enter) clears the input line, so the
            // settle-time extraction can come up empty — this sample is then
            // the best record of what the user's edit actually looked like.
            if value != observation.baselineValue,
               let extraction = VeloraSpanAnchor.extractSpan(
                   baseline: observation.baselineValue,
                   spanStart: observation.spanStart,
                   spanLength: observation.spanLength,
                   updated: value
               ) {
                observation.lastGoodExtraction = extraction
            }
            active = observation
        }
        checkQuietSettle(observation, now: now)
    }

    private func checkQuietSettle(_ observation: ActiveObservation, now: Date) {
        if let lastChangeAt = observation.lastChangeAt,
           now.timeIntervalSince(lastChangeAt) >= Self.quietSettleSeconds,
           observation.lastSampledValue != observation.baselineValue {
            settle(reason: "quiet")
        }
    }

    // MARK: - Settle & journal

    /// Focus/app switches are NOT terminal while the span is still untouched:
    /// the user often glances at another window right after inserting and
    /// only then comes back to fix the text — and app-activation churn right
    /// after the paste itself would otherwise kill the observation within a
    /// second. Settle on a switch only once the field actually changed; the
    /// 60s window cap still bounds the untouched case.
    private func settleIfChanged(reason: String) {
        guard let observation = active else {
            return
        }
        let read = sampleValue(of: observation.element, stripped: observation.stripsHardWraps)
        let current = read ?? observation.lastSampledValue
        if current != observation.baselineValue {
            settle(reason: reason)
        } else {
            MacLearningDebugLog.log("switch ignored (span untouched) reason=\(reason) read=\(read.map { "\($0.count)ch" } ?? "nil")")
        }
    }

    private func settle(reason: String) {
        guard let observation = active else {
            return
        }
        MacLearningDebugLog.log("settle reason=\(reason) session=\(observation.pending.sessionID.prefix(8))")
        // One last read so edits between polls are not lost; fall back to the
        // last sample when the element is already gone.
        let finalRead = sampleValue(of: observation.element, stripped: observation.stripsHardWraps)
        MacLearningDebugLog.log("settle finalRead=\(finalRead.map { "\($0.count)ch" } ?? "nil") baseline=\(observation.baselineValue.count)ch changed=\(finalRead.map { $0 != observation.baselineValue } ?? false)")
        let finalValue = finalRead ?? observation.lastSampledValue
        let windowMS = Int(Date().timeIntervalSince(observation.startedAt) * 1_000)
        stopObservation(reason: reason)

        var reportedSpan = observation.pending.insertedText
        if finalValue != observation.baselineValue {
            // When the final read cannot anchor anymore (grid hosts re-render
            // the text after a send), fall back to the last poll sample that
            // could — tagged so journal stats can tell the two apart.
            let extraction = VeloraSpanAnchor.extractSpan(
                baseline: observation.baselineValue,
                spanStart: observation.spanStart,
                spanLength: observation.spanLength,
                updated: finalValue
            ) ?? observation.lastGoodExtraction.map {
                VeloraSpanAnchor.Extraction(span: $0.span, method: $0.method + "+last_sample")
            }
            MacLearningDebugLog.log("settle extraction=\(extraction?.method ?? "nil") changed=\(finalValue != observation.baselineValue)")
            if let extraction {
                reportedSpan = extraction.span
                journalIfMeaningful(
                    pending: observation.pending,
                    finalSpan: extraction.span,
                    windowMS: windowMS,
                    terminatedBy: reason,
                    anchorMethod: extraction.method
                )
            }
        }

        residue = Residue(
            pending: observation.pending,
            element: observation.element,
            baselineValue: observation.baselineValue,
            spanStart: observation.spanStart,
            lastReportedSpan: reportedSpan,
            expiresAt: Date().addingTimeInterval(Self.residueLifetimeSeconds),
            stripsHardWraps: observation.stripsHardWraps,
            spanLength: observation.spanLength
        )
    }

    private func journalIfMeaningful(
        pending: PendingObservation,
        finalSpan: String,
        windowMS: Int,
        terminatedBy: String,
        anchorMethod: String
    ) {
        guard finalSpan != pending.insertedText else {
            MacLearningDebugLog.log("journal skip: span unchanged")
            return
        }
        let analysis = VeloraEditAnalyzer.analyze(
            inserted: pending.insertedText,
            userFinal: finalSpan,
            appliedEdits: pending.appliedEdits
        )
        guard !analysis.blocks.isEmpty else {
            MacLearningDebugLog.log("journal skip: no meaningful blocks")
            return
        }
        MacLearningDebugLog.log("journal post_insert_edit session=\(pending.sessionID.prefix(8)) blocks=\(analysis.blocks.count) via=\(anchorMethod)")
        MacCorrectionJournal.recordPostInsertEdit(
            sessionID: pending.sessionID,
            mode: pending.mode,
            language: pending.language,
            appBundle: pending.targetBundleID,
            insertedText: pending.insertedText,
            finalSpan: finalSpan,
            analysis: analysis,
            windowMS: windowMS,
            terminatedBy: terminatedBy,
            anchorMethod: anchorMethod
        )
    }

    /// Free recall extension: when the user dictates again, re-read the
    /// previous span once and catch edits made after the live window closed.
    private func lazyDiffResidue() {
        guard MacLearningSettings.learningEnabled,
              var residue else {
            return
        }
        guard Date() < residue.expiresAt,
              NSRunningApplication(processIdentifier: residue.pending.targetPID)?.isTerminated == false else {
            self.residue = nil
            return
        }
        // Re-check privacy: over the 30-min residue window the element could
        // have become a secure field, or secure-input could now be on. Never
        // read a blocked surface even for the free lazy diff.
        if MacLearningPrivacy.blockReason(
            bundleID: residue.pending.targetBundleID,
            elementSubrole: MacLearningPrivacy.subrole(of: residue.element)
        ) != nil {
            self.residue = nil
            return
        }
        guard let value = sampleValue(of: residue.element, stripped: residue.stripsHardWraps) else {
            self.residue = nil
            return
        }
        guard let extraction = VeloraSpanAnchor.extractSpan(
            baseline: residue.baselineValue,
            spanStart: residue.spanStart,
            spanLength: residue.spanLength,
            updated: value
        ) else {
            self.residue = nil
            return
        }
        if extraction.span != residue.lastReportedSpan {
            journalIfMeaningful(
                pending: residue.pending,
                finalSpan: extraction.span,
                windowMS: 0,
                terminatedBy: "next_session",
                anchorMethod: extraction.method
            )
            residue.lastReportedSpan = extraction.span
            self.residue = residue
        }
    }

    // MARK: - Teardown & AX plumbing

    private func stopObservation(reason: String) {
        _ = reason
        if let observation = active {
            let refconElement = observation.element
            let axObserver = observation.axObserver
            AXObserverRemoveNotification(axObserver, refconElement, kAXValueChangedNotification as CFString)
            AXObserverRemoveNotification(axObserver, refconElement, kAXUIElementDestroyedNotification as CFString)
            AXObserverRemoveNotification(axObserver, observation.appElement, kAXFocusedUIElementChangedNotification as CFString)
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(axObserver), .defaultMode)
        }
        active = nil
        dirty = false
        pollTask?.cancel()
        pollTask = nil
        if let keyboardMonitor {
            NSEvent.removeMonitor(keyboardMonitor)
            self.keyboardMonitor = nil
        }
        if let workspaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(workspaceObserver)
            self.workspaceObserver = nil
        }
    }

    private func copyElement(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value,
              CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }
        return (value as! AXUIElement)
    }

    private func stringValue(of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value) == .success else {
            return nil
        }
        return value as? String
    }

    /// Every read after capture goes through this so a wrap-stripped
    /// observation never compares raw grid text against its stripped baseline.
    private func sampleValue(of element: AXUIElement, stripped: Bool) -> String? {
        guard let value = stringValue(of: element) else {
            return nil
        }
        return stripped ? VeloraSpanAnchor.strippingHardWraps(value) : value
    }
}

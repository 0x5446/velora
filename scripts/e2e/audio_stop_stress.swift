// Stress harness for the audio-capture stop() lock ordering.
//
// Mirrors the locking structure of MacAudioCaptureService (VeloraMacApp.swift)
// / iOSAudioCaptureService: an NSLock guards engine/file state, the tap
// callback takes the lock in write(_:), and stop() must tear the engine down
// OUTSIDE the lock. Keep this file's CaptureService in sync when that
// structure changes.
//
// Background: stop() used to call removeTap(onBus:)/engine.stop() while
// holding the lock. removeTap blocks until in-flight tap callbacks drain, and
// those callbacks take the same lock — an AB-BA deadlock with AVFAudio's
// RealtimeMessenger mutex that froze the app's main thread (HUD stuck,
// fn/esc dead). The natural race window is µs-wide, so each mode injects a
// 50ms delay at the racy program point to make one round deterministic.
//
// Usage: swift audio_stop_stress.swift <mode> [rounds]     (needs mic access)
//   old         pre-fix lock ordering — expected: DEADLOCK on round 1
//   new         fixed ordering, serial start/stop rounds — expected: clean
//   interleave  fixed ordering, start raced against in-flight stop —
//               expected: clean; racing start() either succeeds or throws
//               recordingAlreadyRunning (isTearingDown guard), never deadlocks
// Exit 0 = clean, 2 = deadlock reproduced, 3 = environment failure.

import AVFoundation
import Foundation

enum CaptureError: Error {
    case recordingAlreadyRunning
}

final class CaptureService: @unchecked Sendable {
    private let lock = NSLock()
    private var engine: AVAudioEngine?
    private var file: AVAudioFile?
    private var fileURL: URL?
    private var isTearingDown = false
    private let oldBehavior: Bool

    init(oldBehavior: Bool) { self.oldBehavior = oldBehavior }

    func start() throws {
        lock.lock()
        defer { lock.unlock() }
        guard engine == nil, !isTearingDown else {
            throw CaptureError.recordingAlreadyRunning
        }
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else {
            fputs("FATAL: input format unavailable (mic permission?)\n", stderr)
            exit(3)
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("stress-\(UUID().uuidString).caf")
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        input.installTap(onBus: 0, bufferSize: 2_048, format: format) { [weak self] buffer, _ in
            self?.write(buffer)
        }
        try engine.start()
        self.engine = engine
        self.file = file
        self.fileURL = url
    }

    func stop() {
        if oldBehavior {
            // Pre-fix ordering: teardown under the lock. The injected delay
            // widens the µs race (a tap callback starting between our lock
            // acquisition and removeTap's internal mutex) so it hits every time.
            lock.lock()
            defer { lock.unlock() }
            guard let engine else { return }
            usleep(50_000)
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            self.engine = nil
            self.file = nil
            if let fileURL { try? FileManager.default.removeItem(at: fileURL) }
            self.fileURL = nil
        } else {
            // Fixed ordering: claim state under the lock, tear down outside it.
            lock.lock()
            guard let engine else {
                lock.unlock()
                return
            }
            self.engine = nil
            self.file = nil
            let url = self.fileURL
            self.fileURL = nil
            isTearingDown = true
            lock.unlock()
            // Same injected delay at the same program point — the lock is
            // released here, so callbacks drain instead of deadlocking, and
            // isTearingDown keeps racing start() calls out of this window.
            usleep(50_000)
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            lock.lock()
            isTearingDown = false
            lock.unlock()
            if let url { try? FileManager.default.removeItem(at: url) }
        }
    }

    private func write(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        try? file?.write(from: buffer)
        lock.unlock()
    }
}

let mode = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "new"
let rounds = CommandLine.arguments.count > 2 ? Int(CommandLine.arguments[2]) ?? 100 : 100
guard ["old", "new", "interleave"].contains(mode) else {
    fputs("usage: swift audio_stop_stress.swift old|new|interleave [rounds]\n", stderr)
    exit(3)
}
let service = CaptureService(oldBehavior: mode == "old")

// Watchdog: any stop()/start() round taking > 5s means a deadlock.
let progressLock = NSLock()
var roundStartedAt = Date()
var currentRound = 0
Thread.detachNewThread {
    while true {
        Thread.sleep(forTimeInterval: 0.5)
        progressLock.lock()
        let started = roundStartedAt
        let round = currentRound
        progressLock.unlock()
        if Date().timeIntervalSince(started) > 5 {
            print("DEADLOCK REPRODUCED: round \(round) hung (mode=\(mode))")
            exit(2)
        }
    }
}

print("mode=\(mode) rounds=\(rounds)")
var rejectedStarts = 0
for i in 1...rounds {
    progressLock.lock()
    roundStartedAt = Date()
    currentRound = i
    progressLock.unlock()

    do {
        try service.start()
    } catch CaptureError.recordingAlreadyRunning {
        // interleave mode: previous round's teardown still draining; skip.
        rejectedStarts += 1
        usleep(60_000)
        continue
    } catch {
        fputs("start failed round \(i): \(error)\n", stderr)
        exit(3)
    }
    // Random dwell so stop() lands uniformly across the tap callback cycle.
    usleep(UInt32.random(in: 10_000...70_000))

    if mode == "interleave" {
        // Race a start() against the in-flight stop(): it must either succeed
        // (teardown already finished) or throw recordingAlreadyRunning —
        // never write into the old session's window, never deadlock.
        let stopDone = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            service.stop()
            stopDone.signal()
        }
        usleep(UInt32.random(in: 0...60_000))
        do {
            try service.start()
            stopDone.wait()
            service.stop() // clean up the racing session
        } catch CaptureError.recordingAlreadyRunning {
            rejectedStarts += 1
            stopDone.wait()
        } catch {
            fputs("racing start failed round \(i): \(error)\n", stderr)
            exit(3)
        }
    } else {
        service.stop()
    }

    if i % 25 == 0 { print("round \(i) ok") }
}
print("ALL \(rounds) ROUNDS CLEAN (mode=\(mode), rejected_starts=\(rejectedStarts))")

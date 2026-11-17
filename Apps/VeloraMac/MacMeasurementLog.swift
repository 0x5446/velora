import Foundation
import Velora

/// One JSON line of numeric measurements per finished pipeline.
/// No transcript, prompt, audio path, token id, or error body.
enum MacMeasurementLog {
    private static let folderName = "Velora"
    private static let fileName = "measurement.jsonl"

    static func record(result: PipelineRunResult, hudWallMS: Int?, insertMS: Int?) {
        let base = result.trace.measurement ?? PipelineMeasurement(
            criticalStageSumMS: result.trace.releaseToInsertMS,
            engine: result.compose.engine
        )
        let measurement = base.withObservedInsert(hudWallMS: hudWallMS, insertMS: insertMS)
        guard let line = jsonLine(measurement) else {
            return
        }
        guard let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return
        }
        let folder = directory.appendingPathComponent(folderName, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent(fileName)
        if let handle = try? FileHandle(forWritingTo: file) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(line.utf8))
        } else {
            try? Data(line.utf8).write(to: file)
        }
    }

    static func jsonLine(_ measurement: PipelineMeasurement) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(measurement.sanitized()),
              var line = String(data: data, encoding: .utf8) else {
            return nil
        }
        line += "\n"
        return line
    }
}

import Foundation

struct FileExporter {
    private let fileManager = FileManager.default

    private let filenameFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HHmmss"
        formatter.timeZone = .current
        return formatter
    }()

    /// The start time alone is not unique: two apps can record workouts in
    /// the same second, and a DST fall-back hour repeats local times. The
    /// first eight characters of the workout UUID keep one file per workout.
    /// v1 files, named without them, are left as they are.
    func generateFilename(for date: Date, workoutID: UUID) -> String {
        let suffix = workoutID.uuidString.prefix(8).lowercased()
        return "workout_\(filenameFormatter.string(from: date))_\(suffix).gpx"
    }

    func getExportDirectory() throws -> URL {
        let baseDir: URL
        if let iCloudURL = fileManager.url(forUbiquityContainerIdentifier: nil) {
            baseDir = iCloudURL.appendingPathComponent("Documents")
        } else {
            guard let documentDirectory = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else {
                throw FileExportError.directoryNotFound
            }
            baseDir = documentDirectory
        }

        let exportDir = baseDir
            .appendingPathComponent("Bike-Ride-Analyzer")
            .appendingPathComponent("imports")

        if !fileManager.fileExists(atPath: exportDir.path) {
            try fileManager.createDirectory(at: exportDir, withIntermediateDirectories: true)
        }

        return exportDir
    }

    func writeToICloud(gpxString: String, filename: String) throws {
        let directory = try getExportDirectory()
        let fileURL = directory.appendingPathComponent(filename)

        guard let data = gpxString.data(using: .utf8) else {
            throw FileExportError.encodingFailed
        }

        try data.write(to: fileURL, options: .atomic)
    }

    var isICloudAvailable: Bool {
        fileManager.url(forUbiquityContainerIdentifier: nil) != nil
    }
}

enum FileExportError: LocalizedError {
    case encodingFailed
    case directoryNotFound

    var errorDescription: String? {
        switch self {
        case .encodingFailed:
            return "Failed to encode GPX data."
        case .directoryNotFound:
            return "Could not find the document directory."
        }
    }
}

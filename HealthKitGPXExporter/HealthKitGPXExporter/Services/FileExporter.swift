import Foundation

/// Where an export ended up. Background export counts only `.iCloud` as
/// done: a local copy never reaches the server-side inbox on its own.
enum ExportDestination: Equatable {
    case iCloud
    /// iCloud Drive was unavailable; the file is in this device's Documents.
    case localFallback
    /// Nothing usable was written.
    case failed
}

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
        try exportDirectory().url
    }

    private func exportDirectory() throws -> (url: URL, destination: ExportDestination) {
        let baseDir: URL
        let destination: ExportDestination
        if let iCloudURL = fileManager.url(forUbiquityContainerIdentifier: nil) {
            baseDir = iCloudURL.appendingPathComponent("Documents")
            destination = .iCloud
        } else {
            guard let documentDirectory = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else {
                throw FileExportError.directoryNotFound
            }
            baseDir = documentDirectory
            destination = .localFallback
        }

        let exportDir = baseDir
            .appendingPathComponent("Bike-Ride-Analyzer")
            .appendingPathComponent("imports")

        if !fileManager.fileExists(atPath: exportDir.path) {
            try fileManager.createDirectory(at: exportDir, withIntermediateDirectories: true)
        }

        return (exportDir, destination)
    }

    /// Writes to iCloud Drive, or to local Documents when iCloud is
    /// unavailable, and says which. Throws when nothing could be written.
    @discardableResult
    func writeToICloud(gpxString: String, filename: String) throws -> ExportDestination {
        let (directory, destination) = try exportDirectory()
        let fileURL = directory.appendingPathComponent(filename)

        guard let data = gpxString.data(using: .utf8) else {
            throw FileExportError.encodingFailed
        }

        try data.write(to: fileURL, options: .atomic)
        return destination
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

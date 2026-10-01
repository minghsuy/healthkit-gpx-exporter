import Foundation

/// Which export directory a file was written to. Stored with each queued
/// upload as a symbolic location, not an absolute path: the app container
/// path changes across app updates, and iCloud can appear or disappear
/// between export and upload.
enum ExportLocation: String, Codable {
    case iCloudDrive
    case localDocuments
}

/// A GPX file written to the export directory for one workout.
struct ExportedGPX: Equatable {
    let workoutID: UUID
    let filename: String
    let location: ExportLocation
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
    /// first eight characters of the workout UUID keep one file per workout. v1 files, named
    /// without it, are left as they are.
    func generateFilename(for date: Date, workoutID: UUID) -> String {
        let suffix = workoutID.uuidString.prefix(8).lowercased()
        return "workout_\(filenameFormatter.string(from: date))_\(suffix).gpx"
    }

    var currentLocation: ExportLocation {
        isICloudAvailable ? .iCloudDrive : .localDocuments
    }

    func getExportDirectory() throws -> URL {
        try getExportDirectory(for: currentLocation)
    }

    func getExportDirectory(for location: ExportLocation) throws -> URL {
        let baseDir: URL
        switch location {
        case .iCloudDrive:
            guard let iCloudURL = fileManager.url(forUbiquityContainerIdentifier: nil) else {
                throw FileExportError.directoryNotFound
            }
            baseDir = iCloudURL.appendingPathComponent("Documents")
        case .localDocuments:
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

    /// Returns the location written to, for the upload queue.
    @discardableResult
    func writeToICloud(gpxString: String, filename: String) throws -> ExportLocation {
        let location = currentLocation
        let directory = try getExportDirectory(for: location)
        let fileURL = directory.appendingPathComponent(filename)

        guard let data = gpxString.data(using: .utf8) else {
            throw FileExportError.encodingFailed
        }

        try data.write(to: fileURL, options: .atomic)
        return location
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

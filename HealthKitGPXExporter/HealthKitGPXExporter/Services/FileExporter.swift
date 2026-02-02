import Foundation

struct FileExporter {
    private let fileManager = FileManager.default

    private let filenameFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HHmmss"
        formatter.timeZone = .current
        return formatter
    }()

    func generateFilename(for date: Date) -> String {
        "workout_\(filenameFormatter.string(from: date)).gpx"
    }

    func getExportDirectory() throws -> URL {
        if let iCloudURL = fileManager.url(forUbiquityContainerIdentifier: nil) {
            let exportDir = iCloudURL
                .appendingPathComponent("Documents")
                .appendingPathComponent("Bike-Ride-Analyzer")
                .appendingPathComponent("imports")

            if !fileManager.fileExists(atPath: exportDir.path) {
                try fileManager.createDirectory(at: exportDir, withIntermediateDirectories: true)
            }

            return exportDir
        }

        // Fallback to local Documents if iCloud unavailable
        let documentsDir = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
        let exportDir = documentsDir
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
        print("[GPXExporter] Saved to: \(fileURL.path)")
    }

    var isICloudAvailable: Bool {
        fileManager.url(forUbiquityContainerIdentifier: nil) != nil
    }
}

enum FileExportError: LocalizedError {
    case encodingFailed
    case iCloudNotAvailable

    var errorDescription: String? {
        switch self {
        case .encodingFailed:
            return "Failed to encode GPX data."
        case .iCloudNotAvailable:
            return "iCloud Drive is not available. Please sign in to iCloud."
        }
    }
}

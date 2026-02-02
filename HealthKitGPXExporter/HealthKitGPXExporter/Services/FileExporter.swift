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
        let baseDir: URL
        if let iCloudURL = fileManager.url(forUbiquityContainerIdentifier: nil) {
            baseDir = iCloudURL.appendingPathComponent("Documents")
        } else {
            baseDir = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
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

    var errorDescription: String? {
        switch self {
        case .encodingFailed:
            return "Failed to encode GPX data."
        }
    }
}

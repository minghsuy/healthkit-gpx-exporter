import Foundation

/// UserDefaults keys for the opt-in upload. SettingsView binds the same keys
/// with @AppStorage; upload stays off until the user turns it on.
enum UploadSettings {
    static let enabledKey = "uploadEnabled"
    static let serverURLKey = "uploadServerURL"

    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: enabledKey)
    }

    static var serverURL: String {
        UserDefaults.standard.string(forKey: serverURLKey) ?? ""
    }
}

/// POSTs exported GPX files to the user's server. Every export is queued
/// first; the queue drains on each app launch and background wake, and a
/// file leaves the queue only after a 2xx response.
final class GPXUploader {
    static let shared = GPXUploader()

    private static let pendingKey = "pendingUploads"
    private static let lastResultKey = "lastUploadResult"

    private let fileExporter = FileExporter()
    private let tokenStore = KeychainTokenStore()
    private var isUploading = false

    var pendingFilenames: [String] {
        UserDefaults.standard.stringArray(forKey: Self.pendingKey) ?? []
    }

    var lastResult: String? {
        UserDefaults.standard.string(forKey: Self.lastResultKey)
    }

    /// Queues a file only while upload is on; exports made with upload off
    /// are never sent later.
    func enqueue(_ filename: String) {
        guard UploadSettings.isEnabled else { return }
        var pending = pendingFilenames
        if !pending.contains(filename) {
            pending.append(filename)
            UserDefaults.standard.set(pending, forKey: Self.pendingKey)
        }
    }

    func uploadPending() async {
        guard UploadSettings.isEnabled, !isUploading else { return }
        isUploading = true
        defer { isUploading = false }

        for filename in pendingFilenames {
            do {
                try await upload(filename)
                remove(filename)
                record("Uploaded \(filename)")
            } catch GPXUploadError.fileMissing {
                remove(filename)
                record("Dropped \(filename): file no longer exists")
            } catch let error as URLError {
                // Server or tailnet unreachable: the rest would fail the same
                // way, so stop and retry the whole queue on the next wake.
                record("Upload failed: \(error.localizedDescription)")
                return
            } catch {
                record("Upload of \(filename) failed: \(error.localizedDescription)")
            }
        }
    }

    private func upload(_ filename: String) async throws {
        let fileURL = try fileExporter.getExportDirectory().appendingPathComponent(filename)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw GPXUploadError.fileMissing
        }
        let gpxData = try Data(contentsOf: fileURL)

        let upload = try UploadRequestBuilder.makeRequest(
            serverURL: UploadSettings.serverURL,
            bearerToken: tokenStore.readToken(),
            filename: filename,
            gpxData: gpxData,
            boundary: "Boundary-\(UUID().uuidString)"
        )
        var request = upload.request
        request.timeoutInterval = 30

        let (_, response) = try await URLSession.shared.upload(for: request, from: upload.body)
        guard let http = response as? HTTPURLResponse else {
            throw GPXUploadError.badResponse(nil)
        }
        guard (200..<300).contains(http.statusCode) else {
            throw GPXUploadError.badResponse(http.statusCode)
        }
    }

    private func remove(_ filename: String) {
        let pending = pendingFilenames.filter { $0 != filename }
        UserDefaults.standard.set(pending, forKey: Self.pendingKey)
    }

    private func record(_ message: String) {
        let stamp = Date().formatted(date: .abbreviated, time: .shortened)
        UserDefaults.standard.set("\(stamp): \(message)", forKey: Self.lastResultKey)
    }
}

enum GPXUploadError: LocalizedError {
    case fileMissing
    case badResponse(Int?)

    var errorDescription: String? {
        switch self {
        case .fileMissing:
            return "The exported file no longer exists."
        case .badResponse(let status):
            if let status {
                return "The server answered HTTP \(status)."
            }
            return "The server sent no HTTP response."
        }
    }
}

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

/// One queued upload. `rejections` counts client-error (4xx) answers only.
struct PendingUpload: Codable, Equatable {
    let filename: String
    var rejections: Int = 0
}

enum UploadOutcome: Equatable {
    case httpStatus(Int)
    /// No HTTP answer at all: offline, tailnet down, timeout.
    case transportError
}

enum UploadDecision: Equatable {
    case done
    /// Keep the file queued with this rejection count.
    case retry(rejections: Int)
    /// Stop retrying; the file stays on disk and is listed as failed.
    case giveUp
}

/// Plain-Swift retry rule, unit-tested. A 4xx other than 408 (timeout) and
/// 429 (rate limit) means the server refused this file, so it gets a few
/// tries in case the server was mid-deploy, then gives up. Everything else
/// (408, 429, 5xx, no answer) retries without limit.
enum UploadRetryPolicy {
    static let maxRejections = 5

    static func decision(for outcome: UploadOutcome, rejections: Int) -> UploadDecision {
        switch outcome {
        case .transportError:
            return .retry(rejections: rejections)
        case .httpStatus(let code):
            if (200..<300).contains(code) {
                return .done
            }
            if (400..<500).contains(code), code != 408, code != 429 {
                let count = rejections + 1
                return count >= maxRejections ? .giveUp : .retry(rejections: count)
            }
            return .retry(rejections: rejections)
        }
    }
}

/// POSTs exported GPX files to the user's server. Each export made while
/// upload is on is queued; turning upload on never backfills earlier exports.
/// The queue drains on each app launch and background wake.
final class GPXUploader {
    static let shared = GPXUploader()

    private static let queueKey = "uploadQueue"
    private static let failedKey = "failedUploads"
    private static let lastResultKey = "lastUploadResult"

    private let fileExporter = FileExporter()
    private let tokenStore = KeychainTokenStore()
    private var isUploading = false

    var pending: [PendingUpload] {
        guard let data = UserDefaults.standard.data(forKey: Self.queueKey) else { return [] }
        return (try? JSONDecoder().decode([PendingUpload].self, from: data)) ?? []
    }

    /// Files the server refused `UploadRetryPolicy.maxRejections` times.
    /// They are kept in the export directory.
    var failedFilenames: [String] {
        UserDefaults.standard.stringArray(forKey: Self.failedKey) ?? []
    }

    var lastResult: String? {
        UserDefaults.standard.string(forKey: Self.lastResultKey)
    }

    func enqueue(_ filename: String) {
        guard UploadSettings.isEnabled else { return }
        var queue = pending
        if !queue.contains(where: { $0.filename == filename }) {
            queue.append(PendingUpload(filename: filename))
            save(queue)
        }
    }

    func uploadPending() async {
        guard UploadSettings.isEnabled, !isUploading else { return }
        isUploading = true
        defer { isUploading = false }

        for item in pending {
            let outcome: UploadOutcome
            do {
                outcome = try await upload(item.filename)
            } catch GPXUploadError.fileMissing {
                update(item, with: nil)
                record("Dropped \(item.filename): file no longer exists")
                continue
            } catch is URLError {
                outcome = .transportError
            } catch {
                // Bad server URL or unreadable file: nothing reached the server.
                record("Upload of \(item.filename) failed: \(error.localizedDescription)")
                continue
            }

            let decision = UploadRetryPolicy.decision(for: outcome, rejections: item.rejections)
            switch decision {
            case .done:
                update(item, with: nil)
                record("Uploaded \(item.filename)")
            case .retry(let rejections):
                update(item, with: PendingUpload(filename: item.filename, rejections: rejections))
                record("Upload of \(item.filename) will retry: \(describe(outcome))")
            case .giveUp:
                update(item, with: nil)
                markFailed(item.filename)
                record("Upload of \(item.filename) failed for good: \(describe(outcome))")
            }

            if outcome == .transportError {
                // Server or tailnet unreachable: the rest would fail the same
                // way, so stop and retry the whole queue on the next wake.
                return
            }
        }
    }

    private func upload(_ filename: String) async throws -> UploadOutcome {
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
            return .transportError
        }
        return .httpStatus(http.statusCode)
    }

    private func describe(_ outcome: UploadOutcome) -> String {
        switch outcome {
        case .httpStatus(let code):
            return "HTTP \(code)"
        case .transportError:
            return "server not reachable"
        }
    }

    /// Replaces `item` in the saved queue, or removes it when `replacement`
    /// is nil. Re-reads the queue so an enqueue during the upload survives.
    private func update(_ item: PendingUpload, with replacement: PendingUpload?) {
        var queue = pending
        guard let index = queue.firstIndex(where: { $0.filename == item.filename }) else { return }
        if let replacement {
            queue[index] = replacement
        } else {
            queue.remove(at: index)
        }
        save(queue)
    }

    private func markFailed(_ filename: String) {
        var failed = failedFilenames
        if !failed.contains(filename) {
            failed.append(filename)
            UserDefaults.standard.set(failed, forKey: Self.failedKey)
        }
    }

    private func save(_ queue: [PendingUpload]) {
        if let data = try? JSONEncoder().encode(queue) {
            UserDefaults.standard.set(data, forKey: Self.queueKey)
        }
    }

    private func record(_ message: String) {
        let stamp = Date().formatted(date: .abbreviated, time: .shortened)
        UserDefaults.standard.set("\(stamp): \(message)", forKey: Self.lastResultKey)
    }
}

enum GPXUploadError: LocalizedError {
    case fileMissing

    var errorDescription: String? {
        switch self {
        case .fileMissing:
            return "The exported file no longer exists."
        }
    }
}

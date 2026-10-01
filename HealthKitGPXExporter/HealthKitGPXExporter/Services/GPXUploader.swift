import Foundation
#if canImport(UIKit)
import UIKit
#endif

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
/// `workoutID` and `location` are nil in entries queued before they existed;
/// those fall back to the filename and the current export directory.
struct PendingUpload: Codable, Equatable {
    var workoutID: UUID?
    let filename: String
    var location: ExportLocation?
    var rejections: Int = 0

    init(workoutID: UUID? = nil, filename: String, location: ExportLocation? = nil, rejections: Int = 0) {
        self.workoutID = workoutID
        self.filename = filename
        self.location = location
        self.rejections = rejections
    }

    init(_ file: ExportedGPX) {
        self.init(workoutID: file.workoutID, filename: file.filename, location: file.location)
    }

    /// One queue entry per workout; legacy entries are keyed by filename.
    var queueKey: String {
        workoutID?.uuidString ?? filename
    }
}

/// Plain-Swift queue edits, unit-tested.
enum UploadQueue {
    /// Adds `item`, or, when its workout is already queued, points the entry
    /// at the new file and keeps its rejection count.
    static func enqueuing(_ item: PendingUpload, into queue: [PendingUpload]) -> [PendingUpload] {
        var queue = queue
        if let index = queue.firstIndex(where: { $0.queueKey == item.queueKey }) {
            queue[index] = PendingUpload(
                workoutID: item.workoutID,
                filename: item.filename,
                location: item.location,
                rejections: queue[index].rejections
            )
        } else {
            queue.append(item)
        }
        return queue
    }

    /// After a 2xx: a file that once hit the rejection limit and was
    /// re-exported is no longer failed.
    static func failedAfterSuccess(of item: PendingUpload, failed: [String]) -> [String] {
        failed.filter { $0 != item.filename }
    }
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
    /// 401/403: the token is wrong for every file, so stop the pass without
    /// counting a refusal against this file.
    case authenticationFailed
}

/// Plain-Swift retry rule, unit-tested. 401/403 stop the pass uncounted. Any
/// other 4xx except 408 (timeout) and 429 (rate limit) means the server
/// refused this file, so it gets a few tries in case the server was
/// mid-deploy, then gives up. Everything else (408, 429, 5xx, no answer)
/// retries without limit.
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
            if code == 401 || code == 403 {
                return .authenticationFailed
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
    private static let authFailedKey = "uploadAuthenticationFailed"
    /// Stop starting uploads this long after a pass begins. A background
    /// task gets roughly 30 seconds before iOS expires it.
    private static let passBudget: TimeInterval = 20
    private static let requestTimeout: TimeInterval = 15

    private let fileExporter = FileExporter()
    private let tokenStore = KeychainTokenStore()
    private var isUploading = false
    #if canImport(UIKit)
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    #endif

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

    /// Set by a 401/403, cleared by the next successful upload.
    var authenticationFailed: Bool {
        UserDefaults.standard.bool(forKey: Self.authFailedKey)
    }

    func enqueue(_ file: ExportedGPX) {
        guard UploadSettings.isEnabled else { return }
        save(UploadQueue.enqueuing(PendingUpload(file), into: pending))
    }

    /// Runs one upload pass under a UIKit background task, so it can finish
    /// after the app leaves the foreground or after a HealthKit wake has
    /// been completed. Files not reached by the deadline stay queued.
    func uploadPendingInBackgroundTask() async {
        guard UploadSettings.isEnabled, !isUploading, !pending.isEmpty else { return }
        #if canImport(UIKit)
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "GPX upload") {
            MainActor.assumeIsolated {
                GPXUploader.shared.endBackgroundTask()
            }
        }
        defer { endBackgroundTask() }
        #endif
        await uploadPending(until: Date().addingTimeInterval(Self.passBudget))
    }

    #if canImport(UIKit)
    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }
    #endif

    private func uploadPending(until deadline: Date) async {
        guard UploadSettings.isEnabled, !isUploading else { return }
        isUploading = true
        defer { isUploading = false }

        for item in pending {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 1 else {
                record("Upload pass stopped at its time limit; \(pending.count) file(s) still queued")
                return
            }
            let outcome: UploadOutcome
            do {
                outcome = try await upload(item, timeout: min(Self.requestTimeout, remaining))
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
                UserDefaults.standard.set(
                    UploadQueue.failedAfterSuccess(of: item, failed: failedFilenames),
                    forKey: Self.failedKey
                )
                UserDefaults.standard.set(false, forKey: Self.authFailedKey)
                record("Uploaded \(item.filename)")
            case .retry(let rejections):
                var retried = item
                retried.rejections = rejections
                update(item, with: retried)
                record("Upload of \(item.filename) will retry: \(describe(outcome))")
            case .giveUp:
                update(item, with: nil)
                markFailed(item.filename)
                record("Upload of \(item.filename) failed for good: \(describe(outcome))")
            case .authenticationFailed:
                UserDefaults.standard.set(true, forKey: Self.authFailedKey)
                record("Upload stopped: authentication failed (\(describe(outcome))); check the token")
                return
            }

            if outcome == .transportError {
                // Server or tailnet unreachable: the rest would fail the same
                // way, so stop and retry the whole queue on the next wake.
                return
            }
        }
    }

    private func upload(_ item: PendingUpload, timeout: TimeInterval) async throws -> UploadOutcome {
        // Resolve against the directory the file was written to; only legacy
        // entries without a location use whichever directory is current.
        let directory: URL
        if let location = item.location {
            directory = try fileExporter.getExportDirectory(for: location)
        } else {
            directory = try fileExporter.getExportDirectory()
        }
        let filename = item.filename
        let fileURL = directory.appendingPathComponent(filename)
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
        request.timeoutInterval = timeout

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
        guard let index = queue.firstIndex(where: { $0.queueKey == item.queueKey }) else { return }
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

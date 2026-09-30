import Foundation
import HealthKit

/// Exports new cycling workouts automatically: an HKObserverQuery with
/// background delivery wakes the app, and an HKAnchoredObjectQuery returns
/// the workouts added since the persisted anchor.
final class BackgroundSyncManager {
    static let shared = BackgroundSyncManager()

    private static let anchorKey = "workoutSyncAnchor"
    private static let retryKey = "workoutSyncRetryUUIDs"
    private static let lastResultKey = "lastBackgroundSyncResult"
    // Same key WorkoutViewModel uses for "Export All New": a background export
    // advances it, so the button does not offer those workouts again.
    private static let lastExportDateKey = "lastExportDate"
    // A workout whose route has not landed after this long is given up on.
    private static let retryWindow: TimeInterval = 7 * 24 * 3600

    private let healthKitManager = HealthKitManager()
    private lazy var workoutExporter = WorkoutExporter(healthKitManager: healthKitManager)
    private var observerQuery: HKObserverQuery?
    private var isSyncing = false
    private var syncRequested = false

    var lastResult: String? {
        UserDefaults.standard.string(forKey: Self.lastResultKey)
    }

    /// Call from application(_:didFinishLaunchingWithOptions:) so the query
    /// exists before HealthKit delivers a background update, and again after
    /// authorization. Safe to call repeatedly.
    func start() {
        guard HKHealthStore.isHealthDataAvailable() else { return }

        if observerQuery == nil {
            observerQuery = healthKitManager.observeCyclingWorkouts { completion in
                Task { @MainActor in
                    await BackgroundSyncManager.shared.sync()
                    completion()
                }
            }
        }

        Task {
            do {
                try await healthKitManager.enableWorkoutBackgroundDelivery()
            } catch {
                record("Background delivery not enabled: \(error.localizedDescription)")
            }
        }
    }

    /// Exports workouts added since the last sync, then drains the upload
    /// queue. Overlapping calls coalesce into one extra pass.
    func sync() async {
        if isSyncing {
            syncRequested = true
            return
        }
        isSyncing = true
        defer { isSyncing = false }

        repeat {
            syncRequested = false
            await syncOnce()
        } while syncRequested

        await GPXUploader.shared.uploadPending()
    }

    private func syncOnce() async {
        let storedAnchor = loadAnchor()
        let result: (workouts: [HKWorkout], anchor: HKQueryAnchor?)
        do {
            result = try await healthKitManager.fetchCyclingWorkouts(since: storedAnchor)
        } catch {
            record("Workout query failed: \(error.localizedDescription)")
            return
        }

        let lastExport = UserDefaults.standard.object(forKey: Self.lastExportDateKey) as? Date
        var candidates: [HKWorkout]
        if storedAnchor == nil && lastExport == nil {
            // First run with no export history: take a baseline and export
            // nothing, so the whole history is not written in one wake.
            // "Export All New" still offers it.
            candidates = []
        } else {
            // Same "new" rule as Export All New.
            candidates = result.workouts.filter { workout in
                guard let lastExport else { return true }
                return workout.startDate > lastExport
            }
        }
        let alreadyCandidates = Set(candidates.map(\.uuid))
        let retryWorkouts = await loadRetryWorkouts(excluding: alreadyCandidates)
        candidates.append(contentsOf: retryWorkouts)

        var retry: [UUID] = []
        var exported = 0
        var lastError: String?
        for workout in candidates {
            let filename: String?
            do {
                filename = try await workoutExporter.export(workout)
            } catch {
                filename = nil
                lastError = error.localizedDescription
            }

            if let filename {
                exported += 1
                GPXUploader.shared.enqueue(filename)
            } else if Date().timeIntervalSince(workout.endDate) < Self.retryWindow {
                // No route yet, or the export failed: try again next wake.
                retry.append(workout.uuid)
            }
        }

        // The anchor advances only after every candidate was exported or
        // queued for retry, so a crash mid-loop re-delivers them.
        saveRetryUUIDs(retry)
        if let anchor = result.anchor {
            saveAnchor(anchor)
        }
        if exported > 0 {
            UserDefaults.standard.set(Date(), forKey: Self.lastExportDateKey)
        }
        var summary = "Checked \(result.workouts.count) new workout(s), exported \(exported), \(retry.count) to retry"
        if let lastError {
            summary += "; last error: \(lastError)"
        }
        record(summary)
    }

    private func loadRetryWorkouts(excluding: Set<UUID>) async -> [HKWorkout] {
        let uuids = (UserDefaults.standard.stringArray(forKey: Self.retryKey) ?? [])
            .compactMap(UUID.init(uuidString:))
            .filter { !excluding.contains($0) }

        var workouts: [HKWorkout] = []
        for uuid in uuids {
            // A deleted workout returns nil and drops out of the retry list.
            if let workout = try? await healthKitManager.fetchWorkout(uuid: uuid) {
                workouts.append(workout)
            }
        }
        return workouts
    }

    private func saveRetryUUIDs(_ uuids: [UUID]) {
        UserDefaults.standard.set(uuids.map(\.uuidString), forKey: Self.retryKey)
    }

    private func loadAnchor() -> HKQueryAnchor? {
        guard let data = UserDefaults.standard.data(forKey: Self.anchorKey) else { return nil }
        return try? NSKeyedUnarchiver.unarchivedObject(ofClass: HKQueryAnchor.self, from: data)
    }

    private func saveAnchor(_ anchor: HKQueryAnchor) {
        do {
            let data = try NSKeyedArchiver.archivedData(withRootObject: anchor, requiringSecureCoding: true)
            UserDefaults.standard.set(data, forKey: Self.anchorKey)
        } catch {
            record("Could not save the sync anchor: \(error.localizedDescription)")
        }
    }

    private func record(_ message: String) {
        let stamp = Date().formatted(date: .abbreviated, time: .shortened)
        UserDefaults.standard.set("\(stamp): \(message)", forKey: Self.lastResultKey)
    }
}

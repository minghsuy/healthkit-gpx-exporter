import Foundation
import HealthKit

/// Exports new cycling workouts automatically: HKObserverQuery background
/// delivery wakes the app, and an HKAnchoredObjectQuery returns the workouts
/// added since the persisted anchor. A second observer on workout routes
/// wakes the app when a route lands after its workout.
final class BackgroundSyncManager {
    static let shared = BackgroundSyncManager()

    private static let anchorKey = "workoutSyncAnchor"
    private static let retryKey = "workoutSyncRetryUUIDs"
    private static let lastResultKey = "lastBackgroundSyncResult"
    // Display only ("Last Export" in Settings); which workouts are exported
    // is tracked by UUID in ExportedWorkoutStore.
    private static let lastExportDateKey = "lastExportDate"
    // A workout whose route has not landed after this long is given up on.
    private static let retryWindow: TimeInterval = 7 * 24 * 3600

    private let healthKitManager = HealthKitManager()
    private lazy var workoutExporter = WorkoutExporter(healthKitManager: healthKitManager)
    private let exportedStore = ExportedWorkoutStore.shared
    private var workoutObserver: HKObserverQuery?
    private var routeObserver: HKObserverQuery?
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

        if workoutObserver == nil {
            workoutObserver = healthKitManager.observe(
                HKObjectType.workoutType(),
                predicate: HKQuery.predicateForWorkouts(with: .cycling)
            ) { completion in
                Task { @MainActor in
                    await BackgroundSyncManager.shared.sync()
                    completion()
                }
            }
        }
        // HealthKit saves a route only after its workout, so the workout wake
        // can find no route yet. The route save wakes the app again, and
        // sync() retries workouts that were waiting for one.
        if routeObserver == nil {
            routeObserver = healthKitManager.observe(HKSeriesType.workoutRoute(), predicate: nil) { completion in
                Task { @MainActor in
                    await BackgroundSyncManager.shared.sync()
                    completion()
                }
            }
        }

        Task {
            do {
                try await healthKitManager.enableBackgroundDelivery(for: HKObjectType.workoutType())
            } catch {
                record("Background delivery not enabled: \(error.localizedDescription)")
            }
            do {
                // Apple's list of background-delivery types does not name
                // series types; if HealthKit refuses routes, retries fall back
                // to the next workout wake or app launch.
                try await healthKitManager.enableBackgroundDelivery(for: HKSeriesType.workoutRoute())
            } catch {
                record("Route background delivery not enabled: \(error.localizedDescription)")
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
        let result: (workouts: [HKWorkout], deleted: [UUID], anchor: HKQueryAnchor?)
        do {
            result = try await healthKitManager.fetchCyclingWorkouts(since: storedAnchor)
        } catch {
            record("Workout query failed: \(error.localizedDescription)")
            return
        }

        exportedStore.removeDeleted(result.deleted)

        let added = result.workouts.map { WorkoutCandidate(uuid: $0.uuid, startDate: $0.startDate) }
        let selected = Set(
            exportedStore.ledger
                .newForBackgroundExport(added: added, hasStoredAnchor: storedAnchor != nil)
                .map(\.uuid)
        )
        var candidates = result.workouts.filter { selected.contains($0.uuid) }
        let retryWorkouts = await loadRetryWorkouts(excluding: selected)
        candidates.append(contentsOf: retryWorkouts.filter { !exportedStore.ledger.contains($0.uuid) })

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
                exportedStore.markExported(WorkoutCandidate(uuid: workout.uuid, startDate: workout.startDate))
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
        var summary = storedAnchor == nil
            ? "Baseline taken; \(result.workouts.count) existing workout(s) left for Export All New"
            : "Checked \(result.workouts.count) new workout(s), exported \(exported), \(retry.count) to retry"
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

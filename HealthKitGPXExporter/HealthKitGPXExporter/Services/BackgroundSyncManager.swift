import Foundation
import HealthKit

/// When a workout that could not be exported stays on the retry list.
/// Plain Swift so the rule is unit-testable.
enum RetryAdmission {
    /// A workout whose route has not landed this long after the app first
    /// saw it is given up on.
    static let window: TimeInterval = 7 * 24 * 3600

    /// Returns the first-seen date to keep, or nil when the workout expires.
    /// The window runs from when the app first saw the workout, never from
    /// its end date: a ride synced days after it ended still gets a full
    /// window. A workout seen for the first time always joins.
    static func firstSeen(previous: Date?, now: Date) -> Date? {
        let firstSeen = previous ?? now
        return now.timeIntervalSince(firstSeen) < window ? firstSeen : nil
    }
}

/// Counts "Reset Export History" events. A sync pass or manual export that
/// started before a reset must not write anything after it, or it would
/// restore the ledger entries, anchor and retry list the reset cleared.
/// Everything runs on the main actor, so a plain counter is enough.
struct SyncGeneration {
    private(set) var value = 0

    mutating func advance() {
        value += 1
    }

    /// Whether work that started at `token` may still commit.
    func isCurrent(_ token: Int) -> Bool {
        token == value
    }
}

/// The Settings line for one finished pass. Plain Swift so the wording,
/// including a failed anchor save, is unit-testable.
enum SyncSummary {
    static func text(
        baseline: Bool,
        checked: Int,
        exported: Int,
        toRetry: Int,
        lastError: String?,
        anchorSaveError: String?
    ) -> String {
        var summary = baseline
            ? "Baseline taken; \(checked) existing workout(s) left for Export All New"
            : "Checked \(checked) new workout(s), exported \(exported), \(toRetry) to retry"
        if let lastError {
            summary += "; last error: \(lastError)"
        }
        if let anchorSaveError {
            // Without a saved anchor the next wake replays this pass.
            summary += "; could not save sync position: \(anchorSaveError)"
        }
        return summary
    }
}

/// Exports new cycling workouts automatically: HKObserverQuery background
/// delivery wakes the app, and an HKAnchoredObjectQuery returns the workouts
/// added since the persisted anchor. A second observer on workout routes
/// wakes the app when a route lands after its workout.
final class BackgroundSyncManager {
    static let shared = BackgroundSyncManager()

    /// Advanced by resetSyncState; checked before every commit.
    static var generation = SyncGeneration()

    static let anchorKey = "workoutSyncAnchor"
    /// [UUID string: first seen]. Replaces the draft's plain UUID array.
    static let retryKey = "workoutSyncRetry"
    static let legacyRetryKey = "workoutSyncRetryUUIDs"
    private static let lastResultKey = "lastBackgroundSyncResult"
    // Display only ("Last Export" in Settings); which workouts are exported
    // is tracked by UUID in ExportedWorkoutStore.
    private static let lastExportDateKey = "lastExportDate"

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
                    await BackgroundSyncManager.shared.handleWake(completion)
                }
            }
        }
        // HealthKit saves a route only after its workout, so the workout wake
        // can find no route yet. The route save wakes the app again, and
        // sync() retries workouts that were waiting for one.
        if routeObserver == nil {
            routeObserver = healthKitManager.observe(HKSeriesType.workoutRoute(), predicate: nil) { completion in
                Task { @MainActor in
                    await BackgroundSyncManager.shared.handleWake(completion)
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

    /// HealthKit counts a wake as delivered only when `completion` runs, and
    /// stops background delivery after three misses. Call it as soon as the
    /// HealthKit and export work is done; add nothing slow before it.
    private func handleWake(_ completion: @escaping () -> Void) async {
        await sync()
        completion()
    }

    /// Exports workouts added since the last sync. Overlapping calls coalesce
    /// into one extra pass.
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
    }

    private func syncOnce() async {
        // Every commit below checks this token first.
        let token = Self.generation.value
        let storedAnchor: HKQueryAnchor?
        do {
            storedAnchor = try loadAnchor()
        } catch {
            // Never re-baseline silently: that would skip every workout added
            // since the last good anchor. Keep the stored anchor untouched.
            record("Sync skipped: the saved sync anchor could not be read (\(error.localizedDescription))")
            return
        }
        let result: (workouts: [HKWorkout], deleted: [UUID], anchor: HKQueryAnchor?)
        do {
            result = try await healthKitManager.fetchCyclingWorkouts(since: storedAnchor)
        } catch {
            record("Workout query failed: \(error.localizedDescription)")
            return
        }

        // The HealthKit query awaited; a reset meanwhile abandons the pass.
        guard Self.generation.isCurrent(token) else {
            record("Sync abandoned: export history was reset during the pass")
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
        let previousRetry = loadRetryList()
        let retryLookup = await loadRetryWorkouts(previousRetry.keys.filter { !selected.contains($0) })
        candidates.append(contentsOf: retryLookup.workouts.filter { !exportedStore.ledger.contains($0.uuid) })

        let now = Date()
        var retry: [UUID: Date] = [:]
        // A lookup that failed is not a deletion: keep it for the next wake.
        for uuid in retryLookup.unresolved {
            if let firstSeen = RetryAdmission.firstSeen(previous: previousRetry[uuid], now: now) {
                retry[uuid] = firstSeen
            }
        }
        var exported = 0
        var lastError: String?
        for workout in candidates {
            // A manual export may have run while this loop awaited.
            if exportedStore.ledger.contains(workout.uuid) {
                continue
            }
            let filename: String?
            do {
                filename = try await workoutExporter.export(workout)
            } catch {
                filename = nil
                lastError = error.localizedDescription
            }

            guard Self.generation.isCurrent(token) else {
                record("Sync abandoned: export history was reset during the pass")
                return
            }
            if filename != nil {
                exported += 1
                exportedStore.markExported(WorkoutCandidate(uuid: workout.uuid, startDate: workout.startDate))
            } else if let firstSeen = RetryAdmission.firstSeen(previous: previousRetry[workout.uuid], now: now) {
                // No route yet, or the export failed: try again next wake.
                retry[workout.uuid] = firstSeen
            }
        }

        // The anchor advances only after every candidate was exported or
        // queued for retry, so a crash mid-loop re-delivers them. No await
        // between this check and the saves, so a reset cannot slip between.
        guard Self.generation.isCurrent(token) else {
            record("Sync abandoned: export history was reset during the pass")
            return
        }
        saveRetryList(retry)
        var anchorSaveError: String?
        if let anchor = result.anchor {
            do {
                try saveAnchor(anchor)
            } catch {
                anchorSaveError = error.localizedDescription
            }
        }
        if exported > 0 {
            UserDefaults.standard.set(Date(), forKey: Self.lastExportDateKey)
        }
        record(SyncSummary.text(
            baseline: storedAnchor == nil,
            checked: result.workouts.count,
            exported: exported,
            toRetry: retry.count,
            lastError: lastError,
            anchorSaveError: anchorSaveError
        ))
    }

    /// Looks up retry-list workouts. A deleted workout comes back as neither
    /// and drops off the list; a failed lookup comes back as unresolved.
    private func loadRetryWorkouts(_ uuids: [UUID]) async -> (workouts: [HKWorkout], unresolved: [UUID]) {
        var workouts: [HKWorkout] = []
        var unresolved: [UUID] = []
        for uuid in uuids {
            do {
                if let workout = try await healthKitManager.fetchWorkout(uuid: uuid) {
                    workouts.append(workout)
                }
            } catch {
                unresolved.append(uuid)
            }
        }
        return (workouts, unresolved)
    }

    private func loadRetryList() -> [UUID: Date] {
        var list: [UUID: Date] = [:]
        let stored = UserDefaults.standard.dictionary(forKey: Self.retryKey) as? [String: Date] ?? [:]
        for (key, firstSeen) in stored {
            if let uuid = UUID(uuidString: key) {
                list[uuid] = firstSeen
            }
        }
        // The draft stored a plain array with no dates; its entries start
        // their window now.
        if let legacy = UserDefaults.standard.stringArray(forKey: Self.legacyRetryKey) {
            for uuid in legacy.compactMap(UUID.init(uuidString:)) where list[uuid] == nil {
                list[uuid] = Date()
            }
        }
        return list
    }

    private func saveRetryList(_ list: [UUID: Date]) {
        var stored: [String: Date] = [:]
        for (uuid, firstSeen) in list {
            stored[uuid.uuidString] = firstSeen
        }
        UserDefaults.standard.set(stored, forKey: Self.retryKey)
        UserDefaults.standard.removeObject(forKey: Self.legacyRetryKey)
    }

    /// nil means no anchor was ever saved (the first run). A stored anchor
    /// that fails to decode throws instead of reading as "first run".
    private func loadAnchor() throws -> HKQueryAnchor? {
        guard let data = UserDefaults.standard.data(forKey: Self.anchorKey) else { return nil }
        guard let anchor = try NSKeyedUnarchiver.unarchivedObject(ofClass: HKQueryAnchor.self, from: data) else {
            throw AnchorError.undecodable
        }
        return anchor
    }

    private func saveAnchor(_ anchor: HKQueryAnchor) throws {
        let data = try NSKeyedArchiver.archivedData(withRootObject: anchor, requiringSecureCoding: true)
        UserDefaults.standard.set(data, forKey: Self.anchorKey)
    }

    /// Part of "Reset Export History": forget the anchor and retry list too,
    /// so an unreadable anchor (which blocks every sync) is recoverable. The
    /// next sync then takes a fresh baseline and exports nothing; history is
    /// back with "Export All New".
    static func resetSyncState(in defaults: UserDefaults = .standard) {
        generation.advance()
        defaults.removeObject(forKey: anchorKey)
        defaults.removeObject(forKey: retryKey)
        defaults.removeObject(forKey: legacyRetryKey)
    }

    private func record(_ message: String) {
        let stamp = Date().formatted(date: .abbreviated, time: .shortened)
        UserDefaults.standard.set("\(stamp): \(message)", forKey: Self.lastResultKey)
    }
}

private enum AnchorError: LocalizedError {
    case undecodable

    var errorDescription: String? {
        "The stored data is not a query anchor."
    }
}

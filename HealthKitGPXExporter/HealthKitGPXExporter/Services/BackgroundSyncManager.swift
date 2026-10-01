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

/// Whether a workout's route can be treated as complete. HealthKit has no
/// "route finished" flag: a recorder saves the workout, then the route, and
/// some add route segments a little later. Waiting a while, and requiring at
/// least one route sample, is the best signal available.
enum RouteSettle {
    /// How long export waits before treating a route as complete, counted
    /// from the later of the workout's end and when this app first saw it.
    /// The end alone is not enough: a ride another app syncs days later
    /// ended long ago, yet its route samples are still arriving now. Ten
    /// minutes covers recorders that save the route shortly after the
    /// workout; a later wake or the route observer picks it up afterwards.
    static let minimumDelay: TimeInterval = 10 * 60

    enum Eligibility: Equatable {
        case eligible
        case wait
    }

    /// `firstSeen` nil means the app has no record of first seeing the
    /// workout, so only the end date counts.
    static func eligibility(endDate: Date, firstSeen: Date?, now: Date) -> Eligibility {
        let settlesFrom = max(endDate, firstSeen ?? endDate)
        return now.timeIntervalSince(settlesFrom) >= minimumDelay ? .eligible : .wait
    }
}

/// Whether a background pass writes anything. With iCloud Drive off, every
/// write would land in local Documents and be retried on every wake, so the
/// pass writes nothing: candidates wait on the retry list and the anchor is
/// held, and each wake costs only HealthKit queries.
enum ICloudGate {
    enum Plan: Equatable {
        case export
        case waitForICloud
    }

    static func plan(iCloudAvailable: Bool) -> Plan {
        iCloudAvailable ? .export : .waitForICloud
    }
}

/// What background export does with a written file. Only a file in iCloud
/// Drive counts as done; a local fallback (iCloud vanished mid-pass) is
/// retried until iCloud is back.
enum BackgroundExportDecision {
    enum Action: Equatable {
        case mark
        case retry
    }

    static func action(for destination: ExportDestination) -> Action {
        destination == .iCloud ? .mark : .retry
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

/// Whether a finished pass may move the sync anchor forward. Plain Swift so
/// the rule is unit-testable.
enum AnchorCommit {
    enum Decision: Equatable {
        case save
        /// Keep the old anchor: the next wake re-fetches the same range.
        case keep
    }

    /// The anchor says "everything before here is handled". That is only
    /// true once the export record holding those workouts is on disk; if the
    /// app died with the record unsaved, an advanced anchor would lose them.
    /// `heldWorkouts` counts workouts this pass deliberately left undone
    /// (route still settling, iCloud Drive unavailable, local-only write):
    /// while any are held the anchor stays, so the anchored query keeps
    /// returning them even after the retry list's window expires.
    static func decision(ledgerWritesSucceeded: Bool, heldWorkouts: Int = 0, generationCurrent: Bool) -> Decision {
        ledgerWritesSucceeded && heldWorkouts == 0 && generationCurrent ? .save : .keep
    }
}

/// What the stored sync anchor is, without needing a real HKQueryAnchor:
/// `decode` is injected, so tests never build HealthKit objects.
enum StoredAnchorState: Equatable {
    /// Never saved (first run, or after Reset): the next pass is a baseline.
    case missing
    case readable
    /// Saved but undecodable. Every pass stops until it is cleared.
    case unreadable

    static func classify<T>(_ data: Data?, decode: (Data) throws -> T?) -> StoredAnchorState {
        guard let data else { return .missing }
        return (try? decode(data)) == nil ? .unreadable : .readable
    }
}

/// Whether a background pass may run at all. Plain Swift so the rule is
/// unit-testable. Both skips write nothing (ledger, retry list, anchor), so
/// the next pass after recovery sees the same workouts: none is lost, and
/// none is exported against a record that cannot say what was exported.
enum SyncPreflight {
    enum Decision: Equatable {
        case run
        /// Never re-baseline silently: that would skip every workout added
        /// since the last good anchor.
        case skipUnreadableAnchor
        /// With the record unreadable the in-memory ledger is empty, so the
        /// re-delivered range (and the retry list) would include workouts
        /// the file already holds as exported, and export them again.
        case skipUnreadableLedger
    }

    static func decision(anchor: StoredAnchorState, ledgerReadable: Bool) -> Decision {
        if anchor == .unreadable {
            return .skipUnreadableAnchor
        }
        return ledgerReadable ? .run : .skipUnreadableLedger
    }

    static func skipMessage(_ decision: Decision, anchorError: String?) -> String? {
        switch decision {
        case .run:
            return nil
        case .skipUnreadableAnchor:
            let reason = anchorError.map { " (\($0))" } ?? ""
            return "Sync paused: the saved sync position could not be read\(reason). "
                + "Tap Restart Background Sync; workouts added meanwhile stay in Export All New"
        case .skipUnreadableLedger:
            return "Sync paused: export history could not be read, so nothing was exported. "
                + "It resumes once the file reads again, or after Reset Export History"
        }
    }
}

/// The admission/merge step of a background pass: which workouts it tries to
/// export and which start on the retry list. Plain Swift over UUIDs so the
/// wiring of the retry list's first-seen dates is unit-testable.
enum SyncAdmission {
    struct Plan: Equatable {
        /// To try in order; the route-settle check and the export follow.
        var attempt: [UUID]
        /// The retry list before the export loop adds to it.
        var retry: [UUID: Date]
        /// Set when iCloud Drive is off: how many candidates wait for it.
        var waitingForICloud: Int?
    }

    /// Retry-list workouts to look up in HealthKit. Ones the anchored query
    /// returned this pass are already candidates.
    static func retryLookups(previousRetry: [UUID: Date], selected: Set<UUID>) -> [UUID] {
        previousRetry.keys.filter { !selected.contains($0) }
    }

    /// Puts `uuid` on the retry list with its first-seen date, unless its
    /// window has expired.
    static func admit(_ uuid: UUID, into retry: inout [UUID: Date], previousRetry: [UUID: Date], now: Date) {
        if let firstSeen = RetryAdmission.firstSeen(previous: previousRetry[uuid], now: now) {
            retry[uuid] = firstSeen
        }
    }

    /// `selected`: anchored-query workouts chosen by `newForBackgroundExport`.
    /// `retryFound` / `retryUnresolved`: retry-list lookups that returned a
    /// workout / failed. A listed workout in neither was deleted and drops.
    static func plan(
        selected: [UUID],
        retryFound: [UUID],
        retryUnresolved: [UUID],
        previousRetry: [UUID: Date],
        ledger: ExportLedger,
        ledgerUnsaved: Bool,
        iCloudAvailable: Bool,
        now: Date
    ) -> Plan {
        var attempt = selected + retryFound.filter { !ledger.contains($0) }
        var retry: [UUID: Date] = [:]
        // A lookup that failed is not a deletion: keep it for the next wake.
        for uuid in retryUnresolved {
            admit(uuid, into: &retry, previousRetry: previousRetry, now: now)
        }
        // Retry-list workouts the in-memory record already holds are not
        // attempted; while that record is unsaved they stay listed, because
        // the anchor is already past them and a relaunch would lose them.
        if ledgerUnsaved {
            for uuid in retryFound where ledger.contains(uuid) {
                admit(uuid, into: &retry, previousRetry: previousRetry, now: now)
            }
        }
        var waitingForICloud: Int?
        // With iCloud Drive off, write nothing this pass.
        if ICloudGate.plan(iCloudAvailable: iCloudAvailable) == .waitForICloud {
            for uuid in attempt {
                admit(uuid, into: &retry, previousRetry: previousRetry, now: now)
            }
            waitingForICloud = attempt.count
            attempt = []
        }
        return Plan(attempt: attempt, retry: retry, waitingForICloud: waitingForICloud)
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
        anchorSaveError: String?,
        ledgerSaveFailed: Bool = false,
        localOnly: Int = 0,
        settleWaits: Int = 0,
        waitingForICloud: Int? = nil
    ) -> String {
        var summary: String
        if baseline {
            // A baseline pass exports nothing, so iCloud does not matter.
            summary = "Baseline taken; \(checked) existing workout(s) left for Export All New"
        } else if let waitingForICloud {
            summary = "iCloud Drive unavailable; \(waitingForICloud) waiting"
        } else {
            summary = "Checked \(checked) new workout(s), exported \(exported), \(toRetry) to retry"
        }
        if settleWaits > 0 {
            summary += "; \(settleWaits) waiting for the route to settle"
        }
        if let lastError {
            summary += "; last error: \(lastError)"
        }
        if ledgerSaveFailed {
            summary += "; export record could not be saved; will retry"
        }
        if localOnly > 0 {
            summary += "; \(localOnly) saved only on this iPhone (iCloud Drive unavailable); will retry"
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
///
/// Main-actor isolated (also the target default, SWIFT_DEFAULT_ACTOR_ISOLATION):
/// `isSyncing`, `syncRequested`, the ledger and the generation token rely on
/// every wake running here, so overlapping wakes serialise at each `await`.
@MainActor
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
    private let fileExporter = FileExporter()
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
        let anchorState: StoredAnchorState
        var anchorError: String?
        do {
            storedAnchor = try loadAnchor()
            anchorState = storedAnchor == nil ? .missing : .readable
        } catch {
            storedAnchor = nil
            anchorState = .unreadable
            anchorError = error.localizedDescription
        }
        // Also the retry for a record that failed to read at launch (say,
        // before first unlock). No await before this, so no reset check.
        let preflight = SyncPreflight.decision(
            anchor: anchorState,
            ledgerReadable: exportedStore.reloadIfUnreadable()
        )
        if let message = SyncPreflight.skipMessage(preflight, anchorError: anchorError) {
            record(message)
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
        // Re-fetching a range already handled re-exports a workout to the
        // same deterministic filename, overwriting it; that is the accepted
        // cost of not advancing the anchor while the record is unsaved.
        var ledgerWritesSucceeded = exportedStore.removeDeleted(result.deleted)

        let added = result.workouts.map { WorkoutCandidate(uuid: $0.uuid, startDate: $0.startDate) }
        let selected = exportedStore.ledger
            .newForBackgroundExport(added: added, hasStoredAnchor: storedAnchor != nil)
            .map(\.uuid)
        let previousRetry = loadRetryList()
        let retryLookup = await loadRetryWorkouts(
            SyncAdmission.retryLookups(previousRetry: previousRetry, selected: Set(selected))
        )

        let now = Date()
        let plan = SyncAdmission.plan(
            selected: selected,
            retryFound: retryLookup.workouts.map(\.uuid),
            retryUnresolved: retryLookup.unresolved,
            previousRetry: previousRetry,
            ledger: exportedStore.ledger,
            ledgerUnsaved: exportedStore.hasUnsavedChanges,
            iCloudAvailable: fileExporter.isICloudAvailable,
            now: now
        )
        let byID = Dictionary(
            (result.workouts + retryLookup.workouts).map { ($0.uuid, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let candidates = plan.attempt.compactMap { byID[$0] }
        var retry = plan.retry
        let waitingForICloud = plan.waitingForICloud
        var exported = 0
        var localOnly = 0
        var settleWaits = 0
        var lastError: String?
        for workout in candidates {
            // A manual export may have run while this loop awaited.
            if exportedStore.ledger.contains(workout.uuid) {
                continue
            }
            // Too soon after the workout ended, or after this app first saw
            // it: its route may still be arriving. Wait without exporting a
            // partial track. A workout first seen in this pass starts now.
            let firstSeen = previousRetry[workout.uuid] ?? now
            if RouteSettle.eligibility(endDate: workout.endDate, firstSeen: firstSeen, now: now) == .wait {
                settleWaits += 1
                SyncAdmission.admit(workout.uuid, into: &retry, previousRetry: previousRetry, now: now)
                continue
            }
            let file: ExportResult?
            do {
                file = try await workoutExporter.export(workout)
            } catch {
                file = nil
                lastError = error.localizedDescription
            }

            guard Self.generation.isCurrent(token) else {
                record("Sync abandoned: export history was reset during the pass")
                return
            }
            if let file, BackgroundExportDecision.action(for: file.destination) == .retry {
                // Written to this device only. Not done: retry until iCloud
                // Drive is back, and hold the anchor like a failed save.
                localOnly += 1
                SyncAdmission.admit(workout.uuid, into: &retry, previousRetry: previousRetry, now: now)
            } else if file != nil {
                exported += 1
                if !exportedStore.markExported(WorkoutCandidate(uuid: workout.uuid, startDate: workout.startDate)) {
                    // Exported but not recorded on disk: keep it on the retry
                    // list so a relaunch, which loses the in-memory record,
                    // still finishes it.
                    ledgerWritesSucceeded = false
                    SyncAdmission.admit(workout.uuid, into: &retry, previousRetry: previousRetry, now: now)
                }
            } else {
                // No route yet, or the export failed: try again next wake.
                SyncAdmission.admit(workout.uuid, into: &retry, previousRetry: previousRetry, now: now)
            }
        }

        // The anchor advances only after every candidate was exported or
        // queued for retry, so a crash mid-loop re-delivers them. No await
        // between this check and the saves, so a reset cannot slip between.
        guard Self.generation.isCurrent(token) else {
            record("Sync abandoned: export history was reset during the pass")
            return
        }
        // An earlier failed save gets another chance here, so a later wake
        // over the same range can still advance once storage recovers.
        ledgerWritesSucceeded = exportedStore.flush() && ledgerWritesSucceeded
        saveRetryList(retry)
        var anchorSaveError: String?
        let commit = AnchorCommit.decision(
            ledgerWritesSucceeded: ledgerWritesSucceeded,
            heldWorkouts: localOnly + settleWaits + (waitingForICloud ?? 0),
            generationCurrent: Self.generation.isCurrent(token)
        )
        if commit == .save, let anchor = result.anchor {
            do {
                try saveAnchor(anchor)
            } catch {
                anchorSaveError = error.localizedDescription
            }
        }
        // "Last Export" doubles as the v1 cutoff when the record file is
        // absent at launch, so it must not move past exports the record
        // failed to hold.
        if exported > 0, ledgerWritesSucceeded {
            UserDefaults.standard.set(Date(), forKey: Self.lastExportDateKey)
        }
        record(SyncSummary.text(
            baseline: storedAnchor == nil,
            checked: result.workouts.count,
            exported: exported,
            toRetry: retry.count,
            lastError: lastError,
            anchorSaveError: anchorSaveError,
            ledgerSaveFailed: !ledgerWritesSucceeded,
            localOnly: localOnly,
            settleWaits: settleWaits,
            waitingForICloud: waitingForICloud
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

    /// When background sync first saw this workout, if it is on the retry
    /// list. The manual export path uses it for the same settle rule.
    static func retryFirstSeen(_ uuid: UUID, in defaults: UserDefaults = .standard) -> Date? {
        (defaults.dictionary(forKey: retryKey) as? [String: Date])?[uuid.uuidString]
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
        guard let anchor = try Self.decodeAnchor(data) else {
            throw AnchorError.undecodable
        }
        return anchor
    }

    nonisolated static func decodeAnchor(_ data: Data) throws -> HKQueryAnchor? {
        try NSKeyedUnarchiver.unarchivedObject(ofClass: HKQueryAnchor.self, from: data)
    }

    /// For Settings: whether the stored anchor blocks every pass.
    static func storedAnchorState(
        in defaults: UserDefaults = .standard,
        decode: (Data) throws -> Any? = { try BackgroundSyncManager.decodeAnchor($0) }
    ) -> StoredAnchorState {
        StoredAnchorState.classify(defaults.data(forKey: anchorKey), decode: decode)
    }

    /// "Restart Background Sync": the narrow recovery from an unreadable
    /// anchor. Clears only the anchor, and only while it fails to decode;
    /// the export record and retry list stay, so nothing exported is offered
    /// again. The next pass takes a fresh baseline; workouts added since the
    /// last good anchor are not exported automatically but stay in Export
    /// All New. The generation is not advanced: with the anchor unreadable,
    /// every pass stops before its first commit, so none can be voided.
    /// Returns whether the anchor was cleared.
    @discardableResult
    static func restartSyncIfAnchorUnreadable(
        in defaults: UserDefaults = .standard,
        decode: (Data) throws -> Any? = { try BackgroundSyncManager.decodeAnchor($0) }
    ) -> Bool {
        guard storedAnchorState(in: defaults, decode: decode) == .unreadable else { return false }
        defaults.removeObject(forKey: anchorKey)
        return true
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

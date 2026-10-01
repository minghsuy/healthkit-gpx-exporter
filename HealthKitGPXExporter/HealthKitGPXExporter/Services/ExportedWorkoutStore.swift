import Foundation
import Observation

/// A workout reduced to what export selection needs, so the selection rules
/// are testable without HealthKit.
struct WorkoutCandidate: Equatable {
    let uuid: UUID
    let startDate: Date
}

/// Which workouts have been exported, by HealthKit UUID. Both the export
/// buttons and background delivery read and write it, so a workout is
/// exported once whichever path sees it first.
struct ExportLedger: Codable, Equatable {
    /// Exported workout UUID -> the workout's start date.
    var exported: [UUID: Date] = [:]
    /// v1 tracked exports only by the time of the last export. Workouts that
    /// started on or before that time count as exported for the buttons.
    var legacyCutoff: Date?

    func contains(_ uuid: UUID) -> Bool {
        exported[uuid] != nil
    }

    mutating func markExported(_ candidate: WorkoutCandidate) {
        exported[candidate.uuid] = candidate.startDate
    }

    /// Union of both records; used when an unreadable file becomes
    /// readable again while this process holds in-memory exports.
    func merging(_ other: ExportLedger) -> ExportLedger {
        var merged = self
        merged.exported.merge(other.exported) { mine, _ in mine }
        merged.legacyCutoff = legacyCutoff ?? other.legacyCutoff
        return merged
    }

    mutating func remove(_ uuids: [UUID]) {
        for uuid in uuids {
            exported.removeValue(forKey: uuid)
        }
    }

    /// "Export All New": every listed workout not yet exported. The v1
    /// cutoff applies here only, because the list is the whole history.
    func newForManualExport(_ workouts: [WorkoutCandidate]) -> [WorkoutCandidate] {
        workouts.filter { workout in
            if contains(workout.uuid) {
                return false
            }
            if let legacyCutoff, workout.startDate <= legacyCutoff {
                return false
            }
            return true
        }
    }

    /// Background delivery: the anchored query already returns only workouts
    /// added to HealthKit since the stored anchor, whatever their start date,
    /// so a ride another app syncs hours late is still exported. The v1
    /// cutoff is deliberately not applied: it would drop exactly those rides.
    /// With no stored anchor this is the first run, which only takes a
    /// baseline; history stays with "Export All New".
    func newForBackgroundExport(
        added: [WorkoutCandidate],
        hasStoredAnchor: Bool
    ) -> [WorkoutCandidate] {
        guard hasStoredAnchor else { return [] }
        return added.filter { !contains($0.uuid) }
    }
}

/// Persists the ledger as a JSON file in Application Support. It holds one
/// entry per exported workout and drops entries when HealthKit reports the
/// workout deleted, so it stays bounded by the cycling workouts in Health.
///
/// Observable: SwiftUI views that read `ledger` (directly or through the
/// view model's derived `isExported` and new count) re-render when a
/// background sync exports a workout.
@Observable
final class ExportedWorkoutStore {
    static let shared = ExportedWorkoutStore(fileURL: defaultFileURL)

    static var defaultFileURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("exported-workouts.json")
    }

    private static let lastExportDateKey = "lastExportDate"

    private(set) var ledger: ExportLedger
    /// Shown in Settings; a failed save means a later sync may re-export.
    private(set) var lastSaveError: String?
    /// Set when the file exists but cannot be read or decoded. Saves are then
    /// refused, so the unreadable file is kept for inspection rather than
    /// replaced by a near-empty history.
    private(set) var loadError: String?

    private let fileURL: URL?

    /// A nil `fileURL` keeps the ledger in memory only (tests).
    init(fileURL: URL?) {
        self.fileURL = fileURL

        guard let fileURL else {
            ledger = ExportLedger()
            return
        }
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            // No file yet, which means the first v2 launch: carry v1's
            // "last export" time over as the cutoff.
            ledger = ExportLedger(
                legacyCutoff: UserDefaults.standard.object(forKey: Self.lastExportDateKey) as? Date
            )
            return
        }

        do {
            ledger = try Self.read(fileURL)
        } catch {
            // Not the first launch, so the v1 cutoff must not be applied.
            ledger = ExportLedger()
            loadError = "Export history could not be read, and will not be overwritten: \(error.localizedDescription)"
        }
    }

    func markExported(_ candidate: WorkoutCandidate) {
        ledger.markExported(candidate)
        save()
    }

    func removeDeleted(_ uuids: [UUID]) {
        guard uuids.contains(where: { ledger.contains($0) }) else { return }
        ledger.remove(uuids)
        save()
    }

    /// "Reset Export History": every workout becomes new again. This is the
    /// one save allowed to replace an unreadable file, since the user asked
    /// for the history to be cleared.
    func reset() {
        ledger = ExportLedger()
        loadError = nil
        save()
    }

    private static func read(_ fileURL: URL) throws -> ExportLedger {
        try JSONDecoder().decode(ExportLedger.self, from: Data(contentsOf: fileURL))
    }

    private func save() {
        guard let fileURL else { return }
        if loadError != nil {
            // The read may have failed transiently (for example a launch
            // before first unlock). If the file reads now, merge it in and
            // carry on; otherwise keep refusing to overwrite it.
            guard let stored = try? Self.read(fileURL) else {
                lastSaveError = "Export history not saved: the existing file could not be read"
                return
            }
            ledger = ledger.merging(stored)
            loadError = nil
        }
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(ledger)
            // Background delivery can run while the phone is locked; the file
            // must stay writable after the first unlock since boot.
            try data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            lastSaveError = nil
        } catch {
            lastSaveError = "Could not save export history: \(error.localizedDescription)"
        }
    }
}

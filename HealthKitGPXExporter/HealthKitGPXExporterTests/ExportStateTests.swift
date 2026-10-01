import Testing
import Foundation
import Observation
@testable import HealthKitGPXExporter

/// Set from Observation's @Sendable onChange callback.
private final class ChangeFlag: @unchecked Sendable {
    private(set) var fired = false
    func fire() { fired = true }
}

@MainActor
struct ExportStateTests {
    private let start = Date(timeIntervalSince1970: 1_790_000_000)

    private func row(hoursAgo: Double) -> CyclingWorkout {
        CyclingWorkout(
            id: UUID(),
            date: start.addingTimeInterval(-hoursAgo * 3600),
            distance: 20_000,
            duration: 3600,
            averageHeartRate: nil
        )
    }

    private func tempFile() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("ledger-\(UUID().uuidString).json")
    }

    @Test func ledgerChangeUpdatesViewModelWithoutRefresh() {
        let store = ExportedWorkoutStore(fileURL: nil)
        let viewModel = WorkoutViewModel(exportedStore: store)
        let exportedLater = row(hoursAgo: 2)
        let other = row(hoursAgo: 1)
        viewModel.workouts = [exportedLater, other]

        #expect(!viewModel.isExported(exportedLater))
        #expect(viewModel.newWorkoutCount == 2)

        // What SwiftUI relies on: reading the derived values registers the
        // ledger, so a change made elsewhere (a background sync) notifies.
        let changed = ChangeFlag()
        withObservationTracking {
            _ = viewModel.newWorkoutCount
            _ = viewModel.isExported(exportedLater)
        } onChange: {
            changed.fire()
        }

        store.markExported(WorkoutCandidate(uuid: exportedLater.id, startDate: exportedLater.date))

        #expect(changed.fired)
        #expect(viewModel.isExported(exportedLater))
        #expect(!viewModel.isExported(other))
        #expect(viewModel.newWorkoutCount == 1)
    }

    @Test func unreadableLedgerDisablesExportAllNewAndRefusesSaves() throws {
        let file = tempFile()
        defer { try? FileManager.default.removeItem(at: file) }
        try Data("not json".utf8).write(to: file)

        let store = ExportedWorkoutStore(fileURL: file)
        let viewModel = WorkoutViewModel(exportedStore: store)

        #expect(store.loadError != nil)
        #expect(viewModel.exportHistoryUnavailable)

        store.markExported(WorkoutCandidate(uuid: UUID(), startDate: start))

        #expect(store.lastSaveError != nil)
        #expect(String(decoding: try Data(contentsOf: file), as: UTF8.self) == "not json")
    }

    @Test func saveMergesTheFileOnceItReadsAgain() throws {
        let file = tempFile()
        defer { try? FileManager.default.removeItem(at: file) }
        try Data("not json".utf8).write(to: file)
        let store = ExportedWorkoutStore(fileURL: file)
        #expect(store.loadError != nil)

        // The file becomes readable (say the phone was unlocked) and holds
        // an export this process never saw.
        let onDisk = WorkoutCandidate(uuid: UUID(), startDate: start)
        var stored = ExportLedger()
        stored.markExported(onDisk)
        try JSONEncoder().encode(stored).write(to: file)

        let inMemory = WorkoutCandidate(uuid: UUID(), startDate: start)
        store.markExported(inMemory)

        #expect(store.loadError == nil)
        #expect(store.lastSaveError == nil)
        #expect(store.ledger.contains(onDisk.uuid))
        #expect(store.ledger.contains(inMemory.uuid))
        let saved = try JSONDecoder().decode(ExportLedger.self, from: Data(contentsOf: file))
        #expect(saved.contains(onDisk.uuid) && saved.contains(inMemory.uuid))
    }

    @Test func reloadRecoversAnUnreadableRecordWithoutASave() throws {
        let file = tempFile()
        defer { try? FileManager.default.removeItem(at: file) }
        try Data("not json".utf8).write(to: file)
        let store = ExportedWorkoutStore(fileURL: file)
        let viewModel = WorkoutViewModel(exportedStore: store)

        // Still unreadable: the background pass must skip, and the file is
        // left as it was.
        #expect(!store.reloadIfUnreadable())
        #expect(viewModel.exportHistoryUnavailable)
        #expect(String(decoding: try Data(contentsOf: file), as: UTF8.self) == "not json")

        // Readable now (say, after first unlock).
        let onDisk = WorkoutCandidate(uuid: UUID(), startDate: start)
        var stored = ExportLedger()
        stored.markExported(onDisk)
        try JSONEncoder().encode(stored).write(to: file)

        viewModel.refreshExportHistory()

        #expect(store.loadError == nil)
        #expect(!viewModel.exportHistoryUnavailable)
        #expect(store.ledger.contains(onDisk.uuid))
        #expect(store.reloadIfUnreadable())
    }

    @Test func reloadKeepsExportsMadeWhileTheRecordWasUnreadable() throws {
        let file = tempFile()
        defer { try? FileManager.default.removeItem(at: file) }
        try Data("not json".utf8).write(to: file)
        let store = ExportedWorkoutStore(fileURL: file)
        let viewModel = WorkoutViewModel(exportedStore: store)
        // "Export Selected" while unreadable: held in memory, save refused.
        let inMemory = WorkoutCandidate(uuid: UUID(), startDate: start)
        #expect(!store.markExported(inMemory))
        #expect(store.lastSaveError != nil)

        try JSONEncoder().encode(ExportLedger()).write(to: file)

        // Foreground: the read succeeds and the held export is written.
        viewModel.refreshExportHistory()

        #expect(store.ledger.contains(inMemory.uuid))
        #expect(!store.hasUnsavedChanges)
        #expect(store.lastSaveError == nil)
        let saved = try JSONDecoder().decode(ExportLedger.self, from: Data(contentsOf: file))
        #expect(saved.contains(inMemory.uuid))
    }

    @Test func failedWriteIsReportedAndFlushRetriesIt() throws {
        // A regular file where the record's directory should be makes every
        // write fail, the way an unwritable or protected location would.
        let blocker = tempFile()
        defer { try? FileManager.default.removeItem(at: blocker) }
        try Data().write(to: blocker)
        let file = blocker.appendingPathComponent("exported-workouts.json")
        let store = ExportedWorkoutStore(fileURL: file)
        let ride = WorkoutCandidate(uuid: UUID(), startDate: start)

        #expect(!store.markExported(ride))
        #expect(store.hasUnsavedChanges)
        #expect(store.lastSaveError != nil)
        #expect(store.ledger.contains(ride.uuid))
        #expect(!store.flush())
        #expect(!store.removeDeleted([UUID()]))

        // Storage recovers: the next flush writes the held record.
        try FileManager.default.removeItem(at: blocker)
        #expect(store.flush())
        #expect(!store.hasUnsavedChanges)
        #expect(store.lastSaveError == nil)
        let saved = try JSONDecoder().decode(ExportLedger.self, from: Data(contentsOf: file))
        #expect(saved.contains(ride.uuid))
    }

    @Test func mergingKeepsBothSidesAndTheFirstCutoff() {
        let a = WorkoutCandidate(uuid: UUID(), startDate: start)
        let b = WorkoutCandidate(uuid: UUID(), startDate: start)
        var mine = ExportLedger()
        mine.markExported(a)
        var theirs = ExportLedger(legacyCutoff: start)
        theirs.markExported(b)

        let merged = mine.merging(theirs)

        #expect(merged.contains(a.uuid) && merged.contains(b.uuid))
        #expect(merged.legacyCutoff == start)
    }

    @Test func resetSyncStateClearsAnchorAndRetryList() throws {
        let suite = "ExportStateTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(Data([1, 2, 3]), forKey: BackgroundSyncManager.anchorKey)
        defaults.set([UUID().uuidString: Date()], forKey: BackgroundSyncManager.retryKey)
        defaults.set([UUID().uuidString], forKey: BackgroundSyncManager.legacyRetryKey)

        BackgroundSyncManager.resetSyncState(in: defaults)

        #expect(defaults.object(forKey: BackgroundSyncManager.anchorKey) == nil)
        #expect(defaults.object(forKey: BackgroundSyncManager.retryKey) == nil)
        #expect(defaults.object(forKey: BackgroundSyncManager.legacyRetryKey) == nil)
    }
}

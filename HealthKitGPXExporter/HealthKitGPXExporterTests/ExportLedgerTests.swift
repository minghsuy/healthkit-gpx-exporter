import Testing
import Foundation
@testable import HealthKitGPXExporter

@MainActor
struct ExportLedgerTests {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    private func workout(hoursAgo: Double) -> WorkoutCandidate {
        WorkoutCandidate(uuid: UUID(), startDate: now.addingTimeInterval(-hoursAgo * 3600))
    }

    @Test func backgroundExportsEveryAddedWorkoutNotYetExported() {
        let exported = workout(hoursAgo: 3)
        let fresh = workout(hoursAgo: 2)
        var ledger = ExportLedger()
        ledger.markExported(exported)

        let selected = ledger.newForBackgroundExport(added: [exported, fresh], hasStoredAnchor: true)

        #expect(selected == [fresh])
    }

    @Test func backgroundExportsALateSyncedWorkoutWithAnOldStartDate() {
        // A ride exported an hour ago, then another app syncs a ride that
        // started ten hours ago. The v1 date rule dropped it; it must export.
        let recent = workout(hoursAgo: 2)
        let lateSynced = workout(hoursAgo: 10)
        var ledger = ExportLedger(legacyCutoff: now.addingTimeInterval(-3600))
        ledger.markExported(recent)

        let selected = ledger.newForBackgroundExport(added: [lateSynced], hasStoredAnchor: true)

        #expect(selected == [lateSynced])
    }

    @Test func backgroundFirstRunWithoutAnchorExportsNothing() {
        let ledger = ExportLedger()
        let history = [workout(hoursAgo: 100), workout(hoursAgo: 50)]

        #expect(ledger.newForBackgroundExport(added: history, hasStoredAnchor: false).isEmpty)
    }

    @Test func manualNewSkipsExportedAndPreV2Workouts() {
        let beforeCutoff = workout(hoursAgo: 48)
        let exported = workout(hoursAgo: 5)
        let fresh = workout(hoursAgo: 1)
        var ledger = ExportLedger(legacyCutoff: now.addingTimeInterval(-24 * 3600))
        ledger.markExported(exported)

        let selected = ledger.newForManualExport([beforeCutoff, exported, fresh])

        #expect(selected == [fresh])
    }

    @Test func bothPathsAgreeOnceAWorkoutIsExported() {
        let ride = workout(hoursAgo: 1)
        var ledger = ExportLedger()

        #expect(ledger.newForManualExport([ride]) == [ride])
        ledger.markExported(ride)

        #expect(ledger.newForManualExport([ride]).isEmpty)
        #expect(ledger.newForBackgroundExport(added: [ride], hasStoredAnchor: true).isEmpty)
    }

    @Test func removedWorkoutIsNewAgain() {
        let ride = workout(hoursAgo: 1)
        var ledger = ExportLedger()
        ledger.markExported(ride)
        ledger.remove([ride.uuid])

        #expect(!ledger.contains(ride.uuid))
        #expect(ledger.newForManualExport([ride]) == [ride])
    }

    @Test func ledgerRoundTripsThroughJSON() throws {
        var ledger = ExportLedger(legacyCutoff: now)
        ledger.markExported(workout(hoursAgo: 1))

        let data = try JSONEncoder().encode(ledger)
        let decoded = try JSONDecoder().decode(ExportLedger.self, from: data)

        #expect(decoded == ledger)
    }
}

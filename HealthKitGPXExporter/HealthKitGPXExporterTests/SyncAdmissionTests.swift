import Testing
import Foundation
@testable import HealthKitGPXExporter

/// The admission/merge step of a background pass, over UUIDs only: no
/// HealthKit objects are built here.
@MainActor
struct SyncAdmissionTests {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)
    private let day: TimeInterval = 24 * 3600

    private func ledger(holding uuids: [UUID]) -> ExportLedger {
        var ledger = ExportLedger()
        for uuid in uuids {
            ledger.markExported(WorkoutCandidate(uuid: uuid, startDate: now))
        }
        return ledger
    }

    private func plan(
        selected: [UUID] = [],
        retryFound: [UUID] = [],
        retryUnresolved: [UUID] = [],
        previousRetry: [UUID: Date] = [:],
        ledger: ExportLedger = ExportLedger(),
        ledgerUnsaved: Bool = false,
        iCloudAvailable: Bool = true
    ) -> SyncAdmission.Plan {
        SyncAdmission.plan(
            selected: selected,
            retryFound: retryFound,
            retryUnresolved: retryUnresolved,
            previousRetry: previousRetry,
            ledger: ledger,
            ledgerUnsaved: ledgerUnsaved,
            iCloudAvailable: iCloudAvailable,
            now: now
        )
    }

    @Test func retryWorkoutHeldInAnUnsavedRecordStaysListedWithItsFirstSeen() {
        let ride = UUID()
        let firstSeen = now.addingTimeInterval(-2 * day)

        let unsaved = plan(
            retryFound: [ride], previousRetry: [ride: firstSeen],
            ledger: ledger(holding: [ride]), ledgerUnsaved: true
        )
        let saved = plan(
            retryFound: [ride], previousRetry: [ride: firstSeen],
            ledger: ledger(holding: [ride]), ledgerUnsaved: false
        )

        // Not attempted again either way: the record already holds it.
        #expect(unsaved.attempt.isEmpty)
        #expect(unsaved.retry == [ride: firstSeen])
        #expect(saved.attempt.isEmpty)
        #expect(saved.retry.isEmpty)
    }

    @Test func failedLookupKeepsItsFirstSeenUntilTheWindowExpires() {
        let recent = UUID()
        let expired = UUID()
        let recentSeen = now.addingTimeInterval(-6 * day)

        let result = plan(
            retryUnresolved: [recent, expired],
            previousRetry: [recent: recentSeen, expired: now.addingTimeInterval(-8 * day)]
        )

        #expect(result.retry == [recent: recentSeen])
        #expect(result.attempt.isEmpty)
    }

    @Test func deletedRetryWorkoutDropsOff() {
        // Listed, but the lookup returned neither a workout nor a failure.
        let result = plan(previousRetry: [UUID(): now.addingTimeInterval(-day)])

        #expect(result.retry.isEmpty)
        #expect(result.attempt.isEmpty)
    }

    @Test func newAndRetryWorkoutsAreAttemptedInOrderAndExportedOnesAreNot() {
        let fresh = UUID()
        let waiting = UUID()
        let alreadyDone = UUID()

        let result = plan(
            selected: [fresh],
            retryFound: [waiting, alreadyDone],
            previousRetry: [waiting: now, alreadyDone: now],
            ledger: ledger(holding: [alreadyDone])
        )

        #expect(result.attempt == [fresh, waiting])
        // Attempted workouts join the retry list only from the export loop.
        #expect(result.retry.isEmpty)
        #expect(result.waitingForICloud == nil)
    }

    @Test func withoutICloudNothingIsAttemptedAndEveryCandidateWaits() {
        let fresh = UUID()
        let waiting = UUID()
        let waitingSeen = now.addingTimeInterval(-day)

        let result = plan(
            selected: [fresh],
            retryFound: [waiting],
            previousRetry: [waiting: waitingSeen],
            iCloudAvailable: false
        )

        #expect(result.attempt.isEmpty)
        #expect(result.waitingForICloud == 2)
        // A workout first seen this pass starts its window now.
        #expect(result.retry == [fresh: now, waiting: waitingSeen])
    }

    @Test func retryLookupsSkipWorkoutsTheAnchoredQueryReturned() {
        let returnedAgain = UUID()
        let onlyListed = UUID()

        let lookups = SyncAdmission.retryLookups(
            previousRetry: [returnedAgain: now, onlyListed: now],
            selected: [returnedAgain]
        )

        #expect(lookups == [onlyListed])
    }

    @Test func admitSkipsAnExpiredWorkout() {
        let ride = UUID()
        var retry: [UUID: Date] = [:]

        SyncAdmission.admit(ride, into: &retry, previousRetry: [ride: now.addingTimeInterval(-8 * day)], now: now)

        #expect(retry.isEmpty)
    }
}

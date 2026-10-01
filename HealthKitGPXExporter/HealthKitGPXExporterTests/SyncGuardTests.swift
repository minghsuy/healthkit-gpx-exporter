import Testing
import Foundation
@testable import HealthKitGPXExporter

@MainActor
struct SyncGuardTests {
    @Test func generationChangeMidPassCommitsNothingAfterIt() {
        var generation = SyncGeneration()
        let token = generation.value
        var committed: [String] = []
        func commit(_ step: String) {
            if generation.isCurrent(token) {
                committed.append(step)
            }
        }

        commit("markExported")
        generation.advance()  // Reset while the pass is suspended
        commit("markExported")
        commit("saveRetryList")
        commit("saveAnchor")

        #expect(committed == ["markExported"])
        #expect(!generation.isCurrent(token))
        #expect(generation.isCurrent(generation.value))
    }

    @Test func resetSyncStateAdvancesTheSharedGeneration() throws {
        let suite = "SyncGuardTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let token = BackgroundSyncManager.generation.value

        BackgroundSyncManager.resetSyncState(in: defaults)

        #expect(!BackgroundSyncManager.generation.isCurrent(token))
    }

    @Test func summaryReportsAFailedAnchorSave() {
        let text = SyncSummary.text(
            baseline: false, checked: 2, exported: 1, toRetry: 1,
            lastError: nil, anchorSaveError: "disk full"
        )

        #expect(text == "Checked 2 new workout(s), exported 1, 1 to retry; could not save sync position: disk full")
    }

    @Test func summaryWithoutErrorsHasNoErrorClauses() {
        let checked = SyncSummary.text(
            baseline: false, checked: 3, exported: 3, toRetry: 0,
            lastError: nil, anchorSaveError: nil
        )
        let baseline = SyncSummary.text(
            baseline: true, checked: 321, exported: 0, toRetry: 0,
            lastError: nil, anchorSaveError: nil
        )

        #expect(checked == "Checked 3 new workout(s), exported 3, 0 to retry")
        #expect(baseline == "Baseline taken; 321 existing workout(s) left for Export All New")
    }

    @Test func anchorAdvancesOnlyWhenRecordIsSavedAndGenerationCurrent() {
        #expect(AnchorCommit.decision(ledgerWritesSucceeded: true, generationCurrent: true) == .save)
        #expect(AnchorCommit.decision(ledgerWritesSucceeded: false, generationCurrent: true) == .keep)
        #expect(AnchorCommit.decision(ledgerWritesSucceeded: true, generationCurrent: false) == .keep)
        #expect(AnchorCommit.decision(ledgerWritesSucceeded: false, generationCurrent: false) == .keep)
    }

    @Test func summaryReportsAnUnsavedRecord() {
        let text = SyncSummary.text(
            baseline: false, checked: 1, exported: 1, toRetry: 1,
            lastError: nil, anchorSaveError: nil, ledgerSaveFailed: true
        )

        #expect(text == "Checked 1 new workout(s), exported 1, 1 to retry; export record could not be saved; will retry")
    }

    @Test func summaryKeepsBothExportAndAnchorErrors() {
        let text = SyncSummary.text(
            baseline: false, checked: 1, exported: 0, toRetry: 1,
            lastError: "no route", anchorSaveError: "disk full"
        )

        #expect(text.hasSuffix("; last error: no route; could not save sync position: disk full"))
    }

    // MARK: - Anchor commit: baseline and held workouts

    @Test func baselineSavesTheAnchorEvenWithHeldRetryWorkouts() {
        // After Restart: a retry-list ride waits (iCloud off, settling) or
        // its mark fails to save; the retry list carries it either way.
        #expect(AnchorCommit.decision(
            baseline: true, ledgerWritesSucceeded: true, heldWorkouts: 1, generationCurrent: true
        ) == .save)
        #expect(AnchorCommit.decision(
            baseline: true, ledgerWritesSucceeded: false, heldWorkouts: 0, generationCurrent: true
        ) == .save)
        #expect(AnchorCommit.decision(
            baseline: true, ledgerWritesSucceeded: true, heldWorkouts: 0, generationCurrent: false
        ) == .keep)
    }

    @Test func onlyWorkoutsTheQueryReturnedHoldTheAnchor() {
        let fromQuery = UUID()
        let fromRetryList = UUID()
        let selected: Set<UUID> = [fromQuery]

        let queryHeld = SyncAdmission.heldFromQuery(held: [fromQuery, fromRetryList], selected: selected)
        let retryOnlyHeld = SyncAdmission.heldFromQuery(held: [fromRetryList], selected: selected)

        #expect(queryHeld == 1)
        #expect(retryOnlyHeld == 0)
        // A held query workout keeps the anchor, as before.
        #expect(AnchorCommit.decision(
            ledgerWritesSucceeded: true, heldWorkouts: queryHeld, generationCurrent: true
        ) == .keep)
        // A held retry-list workout alone does not: the anchor is already
        // past it, and the retry list keeps it.
        #expect(AnchorCommit.decision(
            ledgerWritesSucceeded: true, heldWorkouts: retryOnlyHeld, generationCurrent: true
        ) == .save)
    }

    @Test func baselineSummaryNeverClaimsAnUnsavedStartingPoint() {
        let unsaved = SyncSummary.text(
            baseline: true, checked: 5, exported: 0, toRetry: 0,
            lastError: nil, anchorSaveError: "disk full", anchorSaved: false
        )
        let withRetryWork = SyncSummary.text(
            baseline: true, checked: 5, exported: 1, toRetry: 1,
            lastError: nil, anchorSaveError: nil, waitingForICloud: nil
        )
        let retryWaitingForICloud = SyncSummary.text(
            baseline: true, checked: 5, exported: 0, toRetry: 2,
            lastError: nil, anchorSaveError: nil, waitingForICloud: 2
        )

        #expect(unsaved == "No starting point saved yet; 5 existing workout(s) left for Export All New"
            + "; could not save sync position: disk full")
        #expect(withRetryWork == "Baseline taken; 5 existing workout(s) left for Export All New"
            + "; from the retry list: exported 1, 1 to retry")
        #expect(retryWaitingForICloud == "Baseline taken; 5 existing workout(s) left for Export All New"
            + "; from the retry list: exported 0, 2 to retry; iCloud Drive unavailable; 2 waiting")
    }

    // MARK: - Preflight: unreadable anchor or record

    private struct DecodeFailed: Error {}

    @Test func anchorStateIsClassifiedWithoutAHealthKitAnchor() {
        let readable: (Data) throws -> Any? = { _ in "anchor" }
        let throwing: (Data) throws -> Any? = { _ in throw DecodeFailed() }
        let wrongType: (Data) throws -> Any? = { _ in nil }

        #expect(StoredAnchorState.classify(nil, decode: readable) == .missing)
        #expect(StoredAnchorState.classify(Data([1]), decode: readable) == .readable)
        #expect(StoredAnchorState.classify(Data([1]), decode: throwing) == .unreadable)
        #expect(StoredAnchorState.classify(Data([1]), decode: wrongType) == .unreadable)
    }

    @Test func passRunsOnlyWithAReadableRecordAndNoUnreadableAnchor() {
        #expect(SyncPreflight.decision(anchor: .readable, ledgerReadable: true) == .run)
        // Missing anchor: the pass is a baseline, which exports nothing.
        #expect(SyncPreflight.decision(anchor: .missing, ledgerReadable: true) == .run)
        #expect(SyncPreflight.decision(anchor: .readable, ledgerReadable: false) == .skipUnreadableLedger)
        #expect(SyncPreflight.decision(anchor: .missing, ledgerReadable: false) == .skipUnreadableLedger)
        #expect(SyncPreflight.decision(anchor: .unreadable, ledgerReadable: true) == .skipUnreadableAnchor)
        #expect(SyncPreflight.decision(anchor: .unreadable, ledgerReadable: false) == .skipUnreadableAnchor)
    }

    @Test func skipMessagesNameTheRecovery() {
        #expect(SyncPreflight.skipMessage(.run, anchorError: nil) == nil)

        let anchor = SyncPreflight.skipMessage(.skipUnreadableAnchor, anchorError: "bad data")
        let ledger = SyncPreflight.skipMessage(.skipUnreadableLedger, anchorError: nil)

        #expect(anchor == "Sync paused: the saved sync position could not be read (bad data). "
            + "Restart Background Sync in Settings; workouts added meanwhile are not exported "
            + "automatically, use Export All New")
        #expect(ledger == "Sync paused: export history could not be read, so nothing was exported. "
            + "It resumes once the file reads again, or after Reset Export History")
    }

    @Test func restartClearsOnlyAnUnreadableAnchorAndKeepsTheRetryList() throws {
        let suite = "SyncGuardTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let retry = [UUID().uuidString: Date(timeIntervalSince1970: 1_790_000_000)]
        defaults.set(Data([1, 2, 3]), forKey: BackgroundSyncManager.anchorKey)
        defaults.set(retry, forKey: BackgroundSyncManager.retryKey)
        let token = BackgroundSyncManager.generation.value

        let cleared = BackgroundSyncManager.restartSyncIfAnchorUnreadable(in: defaults, decode: { _ in throw DecodeFailed() })

        #expect(cleared)
        #expect(defaults.object(forKey: BackgroundSyncManager.anchorKey) == nil)
        #expect(defaults.dictionary(forKey: BackgroundSyncManager.retryKey) as? [String: Date] == retry)
        // Not a Reset: in-flight manual exports keep their marks.
        #expect(BackgroundSyncManager.generation.isCurrent(token))
        #expect(BackgroundSyncManager.storedAnchorState(in: defaults, decode: { _ in "anchor" }) == .missing)
    }

    @Test func restartLeavesAReadableAnchorAlone() throws {
        let suite = "SyncGuardTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(Data([1, 2, 3]), forKey: BackgroundSyncManager.anchorKey)

        let cleared = BackgroundSyncManager.restartSyncIfAnchorUnreadable(in: defaults, decode: { _ in "anchor" })

        #expect(!cleared)
        #expect(defaults.data(forKey: BackgroundSyncManager.anchorKey) == Data([1, 2, 3]))
    }
}

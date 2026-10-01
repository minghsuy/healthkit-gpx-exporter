import Testing
import Foundation
@testable import HealthKitGPXExporter

@MainActor
struct BackgroundExportRulesTests {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    private func minutesAgo(_ minutes: Double) -> Date {
        now.addingTimeInterval(-minutes * 60)
    }

    @Test func workoutThatEndedThreeMinutesAgoWaits() {
        #expect(RouteSettle.eligibility(endDate: minutesAgo(3), firstSeen: minutesAgo(3), now: now) == .wait)
        #expect(RouteSettle.eligibility(endDate: minutesAgo(3), firstSeen: nil, now: now) == .wait)
    }

    @Test func workoutThatEndedFifteenMinutesAgoIsEligible() {
        #expect(RouteSettle.eligibility(endDate: minutesAgo(15), firstSeen: minutesAgo(15), now: now) == .eligible)
        #expect(RouteSettle.eligibility(endDate: minutesAgo(15), firstSeen: nil, now: now) == .eligible)
    }

    @Test func lateSyncedWorkoutSettlesFromWhenItWasFirstSeen() {
        let threeDaysAgo = minutesAgo(3 * 24 * 60)
        #expect(RouteSettle.eligibility(endDate: threeDaysAgo, firstSeen: minutesAgo(2), now: now) == .wait)
        #expect(RouteSettle.eligibility(endDate: threeDaysAgo, firstSeen: minutesAgo(11), now: now) == .eligible)
        // First seen in this pass: background passes firstSeen = now.
        #expect(RouteSettle.eligibility(endDate: threeDaysAgo, firstSeen: now, now: now) == .wait)
    }

    @Test func settleDelayIsTenMinutesInclusive() {
        #expect(RouteSettle.minimumDelay == 10 * 60)
        #expect(RouteSettle.eligibility(endDate: minutesAgo(10), firstSeen: nil, now: now) == .eligible)
        #expect(RouteSettle.eligibility(endDate: now.addingTimeInterval(-10 * 60 + 1), firstSeen: nil, now: now) == .wait)
    }

    @Test func manualExportMarksOnlySettledICloudWrites() {
        #expect(ManualExportRule.outcome(destination: .iCloud, settle: .eligible) == .markDone)
        #expect(ManualExportRule.outcome(destination: .iCloud, settle: .wait) == .notSettled)
        #expect(ManualExportRule.outcome(destination: .localFallback, settle: .eligible) == .localOnly)
        #expect(ManualExportRule.outcome(destination: .localFallback, settle: .wait) == .localOnly)
    }

    @Test func manualExportUsesTheRetryListFirstSeen() throws {
        let suite = "BackgroundExportRulesTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let listed = UUID()
        defaults.set([listed.uuidString: minutesAgo(2)], forKey: BackgroundSyncManager.retryKey)

        let firstSeen = BackgroundSyncManager.retryFirstSeen(listed, in: defaults)

        #expect(firstSeen == minutesAgo(2))
        #expect(BackgroundSyncManager.retryFirstSeen(UUID(), in: defaults) == nil)
        // Ended long ago but seen 2 minutes ago: a manual export is not marked.
        let settle = RouteSettle.eligibility(endDate: minutesAgo(3 * 24 * 60), firstSeen: firstSeen, now: now)
        #expect(ManualExportRule.outcome(destination: .iCloud, settle: settle) == .notSettled)
    }

    @Test func onlyAnICloudWriteIsMarked() {
        #expect(BackgroundExportDecision.action(for: .iCloud) == .mark)
        #expect(BackgroundExportDecision.action(for: .localFallback) == .retry)
    }

    @Test func passWritesNothingWithoutICloud() {
        #expect(ICloudGate.plan(iCloudAvailable: true) == .export)
        #expect(ICloudGate.plan(iCloudAvailable: false) == .waitForICloud)
    }

    @Test func heldWorkoutsKeepTheAnchor() {
        #expect(AnchorCommit.decision(ledgerWritesSucceeded: true, heldWorkouts: 0, generationCurrent: true) == .save)
        // A settle wait, an iCloud-unavailable wait or a local-only write.
        #expect(AnchorCommit.decision(ledgerWritesSucceeded: true, heldWorkouts: 1, generationCurrent: true) == .keep)
        #expect(AnchorCommit.decision(ledgerWritesSucceeded: false, heldWorkouts: 0, generationCurrent: true) == .keep)
    }

    @Test func summaryReportsICloudWaitAndSettleWaitsSeparately() {
        let unavailable = SyncSummary.text(
            baseline: false, checked: 3, exported: 0, toRetry: 3,
            lastError: nil, anchorSaveError: nil, waitingForICloud: 3
        )
        let settling = SyncSummary.text(
            baseline: false, checked: 2, exported: 1, toRetry: 1,
            lastError: nil, anchorSaveError: nil, settleWaits: 1
        )
        let baselineWithoutICloud = SyncSummary.text(
            baseline: true, checked: 321, exported: 0, toRetry: 0,
            lastError: nil, anchorSaveError: nil, waitingForICloud: 0
        )

        #expect(unavailable == "iCloud Drive unavailable; 3 waiting")
        #expect(settling == "Checked 2 new workout(s), exported 1, 1 to retry; 1 waiting for the route to settle")
        #expect(baselineWithoutICloud == "Baseline taken; 321 existing workout(s) left for Export All New")
    }

    @Test func routeSegmentsJoinInTimeOrder() {
        struct Point: Equatable {
            let name: String
            let time: Date
        }
        func point(_ name: String, _ minute: Double) -> Point {
            Point(name: name, time: now.addingTimeInterval(minute * 60))
        }
        // Second segment returned first, and segments overlapping in time.
        let later = [point("c", 20), point("d", 30)]
        let earlier = [point("a", 0), point("b", 10), point("c2", 25)]

        let track = RouteAssembly.concatenated([later, earlier], timestamp: \.time)

        #expect(track.map(\.name) == ["a", "b", "c", "c2", "d"])
    }

    @Test func noSegmentsGiveAnEmptyTrack() {
        let track = RouteAssembly.concatenated([[Date](), []], timestamp: { $0 })
        #expect(track.isEmpty)
    }

    @Test func summaryReportsLocalOnlyWrites() {
        let text = SyncSummary.text(
            baseline: false, checked: 2, exported: 1, toRetry: 1,
            lastError: nil, anchorSaveError: nil, ledgerSaveFailed: false, localOnly: 1
        )

        #expect(text == "Checked 2 new workout(s), exported 1, 1 to retry; 1 saved only on this iPhone (iCloud Drive unavailable); will retry")
    }
}

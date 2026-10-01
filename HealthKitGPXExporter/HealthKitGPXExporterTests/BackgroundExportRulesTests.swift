import Testing
import Foundation
@testable import HealthKitGPXExporter

@MainActor
struct BackgroundExportRulesTests {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    @Test func workoutThatEndedThreeMinutesAgoWaits() {
        #expect(RouteSettle.eligibility(endDate: now.addingTimeInterval(-3 * 60), now: now) == .wait)
    }

    @Test func workoutThatEndedFifteenMinutesAgoIsEligible() {
        #expect(RouteSettle.eligibility(endDate: now.addingTimeInterval(-15 * 60), now: now) == .eligible)
    }

    @Test func settleDelayIsTenMinutesInclusive() {
        #expect(RouteSettle.minimumDelay == 10 * 60)
        #expect(RouteSettle.eligibility(endDate: now.addingTimeInterval(-10 * 60), now: now) == .eligible)
        #expect(RouteSettle.eligibility(endDate: now.addingTimeInterval(-10 * 60 + 1), now: now) == .wait)
    }

    @Test func onlyAnICloudWriteIsMarked() {
        #expect(BackgroundExportDecision.action(for: .iCloud) == .mark)
        #expect(BackgroundExportDecision.action(for: .localFallback) == .retry)
        #expect(BackgroundExportDecision.action(for: .failed) == .retry)
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

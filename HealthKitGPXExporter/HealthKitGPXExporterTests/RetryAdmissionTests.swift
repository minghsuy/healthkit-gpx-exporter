import Testing
import Foundation
@testable import HealthKitGPXExporter

@MainActor
struct RetryAdmissionTests {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)
    private let day: TimeInterval = 24 * 3600

    @Test func workoutThatEndedEightDaysAgoJoinsWhenFirstSeenNow() {
        // A ride synced after a week offline: its end date is irrelevant,
        // the window starts when the app first sees it.
        let endDate = now.addingTimeInterval(-8 * day)
        #expect(endDate < now)
        #expect(RetryAdmission.firstSeen(previous: nil, now: now) == now)
    }

    @Test func workoutFirstSeenEightDaysAgoExpires() {
        #expect(RetryAdmission.firstSeen(previous: now.addingTimeInterval(-8 * day), now: now) == nil)
    }

    @Test func workoutInsideTheWindowKeepsItsFirstSeenDate() {
        let firstSeen = now.addingTimeInterval(-6 * day)
        #expect(RetryAdmission.firstSeen(previous: firstSeen, now: now) == firstSeen)
    }

    @Test func windowIsSevenDaysAndExclusive() {
        #expect(RetryAdmission.window == 7 * day)
        #expect(RetryAdmission.firstSeen(previous: now.addingTimeInterval(-7 * day), now: now) == nil)
    }
}

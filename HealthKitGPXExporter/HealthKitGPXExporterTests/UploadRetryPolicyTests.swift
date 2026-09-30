import Testing
@testable import HealthKitGPXExporter

@MainActor
struct UploadRetryPolicyTests {
    @Test(arguments: [200, 201, 204, 299])
    func successDequeues(status: Int) {
        #expect(UploadRetryPolicy.decision(for: .httpStatus(status), rejections: 3) == .done)
    }

    @Test(arguments: [400, 401, 403, 404, 409, 413, 422])
    func clientErrorCountsARejection(status: Int) {
        #expect(UploadRetryPolicy.decision(for: .httpStatus(status), rejections: 0) == .retry(rejections: 1))
    }

    @Test func clientErrorGivesUpOnTheFifthRejection() {
        #expect(UploadRetryPolicy.maxRejections == 5)
        #expect(UploadRetryPolicy.decision(for: .httpStatus(404), rejections: 3) == .retry(rejections: 4))
        #expect(UploadRetryPolicy.decision(for: .httpStatus(404), rejections: 4) == .giveUp)
    }

    @Test(arguments: [408, 429, 500, 502, 503, 304])
    func transientStatusRetriesWithoutCounting(status: Int) {
        #expect(UploadRetryPolicy.decision(for: .httpStatus(status), rejections: 4) == .retry(rejections: 4))
    }

    @Test func transportErrorRetriesWithoutCounting() {
        #expect(UploadRetryPolicy.decision(for: .transportError, rejections: 4) == .retry(rejections: 4))
    }
}

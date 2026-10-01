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

    @Test func summaryKeepsBothExportAndAnchorErrors() {
        let text = SyncSummary.text(
            baseline: false, checked: 1, exported: 0, toRetry: 1,
            lastError: "no route", anchorSaveError: "disk full"
        )

        #expect(text.hasSuffix("; last error: no route; could not save sync position: disk full"))
    }
}

import Testing
import Foundation
@testable import HealthKitGPXExporter

@MainActor
struct UploadQueueTests {
    private let start = Date(timeIntervalSince1970: 1_790_000_000)
    private let first = UUID(uuidString: "0A1B2C3D-4E5F-6071-8293-A4B5C6D7E8F9")!
    private let second = UUID(uuidString: "FFEEDDCC-4E5F-6071-8293-A4B5C6D7E8F9")!

    @Test func sameStartTimeDifferentWorkoutsGetDistinctFilenamesAndQueueEntries() {
        let exporter = FileExporter()
        let firstName = exporter.generateFilename(for: start, workoutID: first)
        let secondName = exporter.generateFilename(for: start, workoutID: second)

        #expect(firstName != secondName)
        #expect(firstName.hasPrefix("workout_"))
        #expect(firstName.hasSuffix("_0a1b2c3d.gpx"))
        #expect(secondName.hasSuffix("_ffeeddcc.gpx"))

        var queue: [PendingUpload] = []
        queue = UploadQueue.enqueuing(
            PendingUpload(ExportedGPX(workoutID: first, filename: firstName, location: .localDocuments)),
            into: queue
        )
        queue = UploadQueue.enqueuing(
            PendingUpload(ExportedGPX(workoutID: second, filename: secondName, location: .localDocuments)),
            into: queue
        )

        #expect(queue.count == 2)
        #expect(Set(queue.map(\.workoutID)) == [first, second])
    }

    @Test func reExportOfAQueuedWorkoutUpdatesItsEntry() {
        let queued = PendingUpload(workoutID: first, filename: "a.gpx", location: .localDocuments, rejections: 2)
        let reExported = PendingUpload(ExportedGPX(workoutID: first, filename: "a.gpx", location: .iCloudDrive))

        let queue = UploadQueue.enqueuing(reExported, into: [queued])

        #expect(queue == [PendingUpload(workoutID: first, filename: "a.gpx", location: .iCloudDrive, rejections: 2)])
    }

    @Test func legacyEntryWithoutWorkoutOrLocationStillDecodes() throws {
        let json = Data(#"[{"filename":"workout_2026-09-30_120600.gpx","rejections":2}]"#.utf8)

        let queue = try JSONDecoder().decode([PendingUpload].self, from: json)

        let entry = try #require(queue.first)
        #expect(entry.filename == "workout_2026-09-30_120600.gpx")
        #expect(entry.rejections == 2)
        #expect(entry.workoutID == nil)
        #expect(entry.location == nil)
        #expect(entry.queueKey == "workout_2026-09-30_120600.gpx")
    }

    @Test func entryWithLocationRoundTrips() throws {
        let entry = PendingUpload(workoutID: first, filename: "a.gpx", location: .iCloudDrive, rejections: 1)

        let decoded = try JSONDecoder().decode(PendingUpload.self, from: JSONEncoder().encode(entry))

        #expect(decoded == entry)
    }

    @Test func successRemovesTheFileFromTheFailedList() {
        let item = PendingUpload(workoutID: first, filename: "a.gpx", location: .localDocuments)

        let failed = UploadQueue.failedAfterSuccess(of: item, failed: ["a.gpx", "b.gpx"])

        #expect(failed == ["b.gpx"])
    }
}

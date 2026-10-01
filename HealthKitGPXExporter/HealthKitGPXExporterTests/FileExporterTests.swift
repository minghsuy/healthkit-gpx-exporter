import Testing
import Foundation
@testable import HealthKitGPXExporter

@MainActor
struct FileExporterTests {
    @Test func sameStartTimeDifferentWorkoutsGetDistinctFilenames() throws {
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        let first = try #require(UUID(uuidString: "0A1B2C3D-4E5F-6071-8293-A4B5C6D7E8F9"))
        let second = try #require(UUID(uuidString: "FFEEDDCC-4E5F-6071-8293-A4B5C6D7E8F9"))
        let exporter = FileExporter()

        let firstName = exporter.generateFilename(for: start, workoutID: first)
        let secondName = exporter.generateFilename(for: start, workoutID: second)

        #expect(firstName != secondName)
        #expect(firstName.hasPrefix("workout_"))
        #expect(firstName.hasSuffix("_0a1b2c3d.gpx"))
        #expect(secondName.hasSuffix("_ffeeddcc.gpx"))
        #expect(exporter.generateFilename(for: start, workoutID: first) == firstName)
    }
}

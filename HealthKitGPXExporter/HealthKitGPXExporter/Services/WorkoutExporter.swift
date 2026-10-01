import Foundation
import HealthKit

/// One workout to one GPX file in the export directory. Shared by the manual
/// export buttons and background delivery so both write identical files.
struct WorkoutExporter {
    let healthKitManager: HealthKitManager
    private let heartRateMatcher = HeartRateMatcher()
    private let gpxSerializer = GPXSerializer()
    private let fileExporter = FileExporter()

    init(healthKitManager: HealthKitManager) {
        self.healthKitManager = healthKitManager
    }

    /// Returns the exported filename, or nil when the workout has no route
    /// (yet: HealthKit can save the route after the workout itself).
    func export(_ workout: HKWorkout) async throws -> String? {
        let locations = try await healthKitManager.fetchRoute(for: workout)
        if locations.isEmpty {
            return nil
        }

        let hrSamples = try await healthKitManager.fetchHeartRateSamples(for: workout)
        let matchedData = heartRateMatcher.match(locations: locations, hrSamples: hrSamples)
        let gpxString = gpxSerializer.serialize(
            workoutDate: workout.startDate,
            matchedData: matchedData,
            metadata: healthKitManager.metadata(for: workout)
        )

        let filename = fileExporter.generateFilename(for: workout.startDate, workoutID: workout.uuid)
        try fileExporter.writeToICloud(gpxString: gpxString, filename: filename)
        return filename
    }
}

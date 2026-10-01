import Foundation
import HealthKit

/// A written GPX file and where it landed.
struct ExportResult: Equatable {
    let filename: String
    let destination: ExportDestination
}

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

    /// Returns the written file, or nil when the workout has no route (yet:
    /// HealthKit can save the route after the workout itself). The route is
    /// every HKWorkoutRoute sample of the workout, joined in time order.
    func export(_ workout: HKWorkout) async throws -> ExportResult? {
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
        let destination = try fileExporter.writeToICloud(gpxString: gpxString, filename: filename)
        return ExportResult(filename: filename, destination: destination)
    }
}

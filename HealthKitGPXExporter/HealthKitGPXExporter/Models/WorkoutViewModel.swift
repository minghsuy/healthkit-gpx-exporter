import Foundation
import Combine
import HealthKit

struct CyclingWorkout: Identifiable {
    let id: UUID
    let workout: HKWorkout
    let date: Date
    let distance: Double // meters
    let duration: TimeInterval
    let averageHeartRate: Int?
    var isSelected: Bool = false
    var isExported: Bool = false

    var formattedDate: String {
        date.formatted(date: .abbreviated, time: .shortened)
    }

    var formattedDistance: String {
        let km = distance / 1000.0
        return String(format: "%.1f km", km)
    }

    var formattedDuration: String {
        let hours = Int(duration) / 3600
        let minutes = (Int(duration) % 3600) / 60
        let seconds = Int(duration) % 60
        return String(format: "%d:%02d:%02d", hours, minutes, seconds)
    }
}

@MainActor
class WorkoutViewModel: ObservableObject {
    @Published var workouts: [CyclingWorkout] = []
    @Published var isLoading = false
    @Published var isExporting = false
    @Published var exportProgress: (current: Int, total: Int) = (0, 0)
    @Published var errorMessage: String?
    @Published var successMessage: String?
    @Published var healthKitAuthorized = false

    private let healthKitManager = HealthKitManager()
    private let heartRateMatcher = HeartRateMatcher()
    private let gpxSerializer = GPXSerializer()
    private let fileExporter = FileExporter()

    var lastExportDate: Date? {
        get { UserDefaults.standard.object(forKey: "lastExportDate") as? Date }
        set {
            UserDefaults.standard.set(newValue, forKey: "lastExportDate")
            objectWillChange.send()
        }
    }

    var newWorkoutCount: Int {
        guard let lastExport = lastExportDate else { return workouts.count }
        return workouts.filter { $0.date > lastExport }.count
    }

    var selectedCount: Int {
        workouts.filter { $0.isSelected }.count
    }

    func requestAuthorization() async {
        do {
            try await healthKitManager.requestAuthorization()
            healthKitAuthorized = true
            await fetchWorkouts()
        } catch {
            errorMessage = "HealthKit access required. Please enable in Settings."
        }
    }

    func fetchWorkouts() async {
        isLoading = true
        defer { isLoading = false }

        do {
            let hkWorkouts = try await healthKitManager.fetchCyclingWorkouts()
            var cyclingWorkouts: [CyclingWorkout] = []

            for workout in hkWorkouts {
                let avgHR = try? await healthKitManager.fetchAverageHeartRate(for: workout)
                let distance = workout.totalDistance?.doubleValue(for: .meter()) ?? 0

                cyclingWorkouts.append(CyclingWorkout(
                    id: workout.uuid,
                    workout: workout,
                    date: workout.startDate,
                    distance: distance,
                    duration: workout.duration,
                    averageHeartRate: avgHR
                ))
            }

            workouts = cyclingWorkouts
        } catch {
            errorMessage = "Failed to fetch workouts: \(error.localizedDescription)"
        }
    }

    func exportSelected() async {
        let selected = workouts.filter { $0.isSelected }
        guard !selected.isEmpty else { return }
        await exportWorkouts(selected)
    }

    func exportAllNew() async {
        let newWorkouts: [CyclingWorkout]
        if let lastExport = lastExportDate {
            newWorkouts = workouts.filter { $0.date > lastExport }
        } else {
            newWorkouts = workouts
        }
        guard !newWorkouts.isEmpty else { return }
        await exportWorkouts(newWorkouts)
    }

    private func exportWorkouts(_ workoutsToExport: [CyclingWorkout]) async {
        isExporting = true
        exportProgress = (0, workoutsToExport.count)
        var exportedCount = 0

        for cyclingWorkout in workoutsToExport {
            do {
                let locations = try await healthKitManager.fetchRoute(for: cyclingWorkout.workout)

                if locations.isEmpty {
                    exportProgress.current += 1
                    continue
                }

                let hrSamples = try await healthKitManager.fetchHeartRateSamples(for: cyclingWorkout.workout)
                let matchedData = heartRateMatcher.match(locations: locations, hrSamples: hrSamples)
                let gpxString = gpxSerializer.serialize(
                    workoutDate: cyclingWorkout.date,
                    matchedData: matchedData
                )

                let filename = fileExporter.generateFilename(for: cyclingWorkout.date)
                try fileExporter.writeToICloud(gpxString: gpxString, filename: filename)

                exportedCount += 1
                exportProgress.current += 1

                if let index = workouts.firstIndex(where: { $0.id == cyclingWorkout.id }) {
                    workouts[index].isExported = true
                    workouts[index].isSelected = false
                }
            } catch {
                errorMessage = "Failed to export workout: \(error.localizedDescription)"
            }
        }

        if exportedCount > 0 {
            lastExportDate = Date()
            let dir = (try? fileExporter.getExportDirectory().path) ?? "unknown"
            successMessage = "Exported \(exportedCount) workout\(exportedCount == 1 ? "" : "s") to:\n\(dir)"
        }

        isExporting = false
    }

    func toggleSelection(for workout: CyclingWorkout) {
        if let index = workouts.firstIndex(where: { $0.id == workout.id }) {
            workouts[index].isSelected.toggle()
        }
    }

    func resetLastExportDate() {
        UserDefaults.standard.removeObject(forKey: "lastExportDate")
        for index in workouts.indices {
            workouts[index].isExported = false
        }
    }
}

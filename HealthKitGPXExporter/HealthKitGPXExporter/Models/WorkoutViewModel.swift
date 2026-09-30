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

    // Display only ("Last Export" in Settings). Which workouts are new is
    // decided by ExportedWorkoutStore, by UUID.
    private static let lastExportDateKey = "lastExportDate"

    private let healthKitManager = HealthKitManager()
    private lazy var workoutExporter = WorkoutExporter(healthKitManager: healthKitManager)
    private let exportedStore = ExportedWorkoutStore.shared

    var lastExportDate: Date? {
        get { UserDefaults.standard.object(forKey: Self.lastExportDateKey) as? Date }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.lastExportDateKey)
            objectWillChange.send()
        }
    }

    var newWorkoutCount: Int {
        newWorkouts.count
    }

    private var newWorkouts: [CyclingWorkout] {
        let candidates = workouts.map { WorkoutCandidate(uuid: $0.id, startDate: $0.date) }
        let newIDs = Set(exportedStore.ledger.newForManualExport(candidates).map(\.uuid))
        return workouts.filter { newIDs.contains($0.id) }
    }

    var selectedCount: Int {
        workouts.filter { $0.isSelected }.count
    }

    func requestAuthorization() async {
        do {
            try await healthKitManager.requestAuthorization()
            healthKitAuthorized = true
            await fetchWorkouts()
            // The observer needs authorization to deliver; start() is
            // idempotent. sync() may export workouts the list is showing as
            // new; it does not upload, so the queue is retried here.
            BackgroundSyncManager.shared.start()
            await BackgroundSyncManager.shared.sync()
            refreshExportedFlags()
            await GPXUploader.shared.uploadPendingInBackgroundTask()
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
                    averageHeartRate: avgHR,
                    isExported: exportedStore.ledger.contains(workout.uuid)
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
        let toExport = newWorkouts
        guard !toExport.isEmpty else { return }
        await exportWorkouts(toExport, skippingExported: true)
    }

    /// `skippingExported` re-checks the export record before each workout,
    /// because a background sync can export one while this loop awaits.
    /// "Export Selected" passes false: re-exporting a chosen workout is the
    /// user's call.
    private func exportWorkouts(_ workoutsToExport: [CyclingWorkout], skippingExported: Bool = false) async {
        isExporting = true
        exportProgress = (0, workoutsToExport.count)
        var exportedCount = 0

        for cyclingWorkout in workoutsToExport {
            if skippingExported, exportedStore.ledger.contains(cyclingWorkout.id) {
                exportProgress.current += 1
                continue
            }
            do {
                guard let filename = try await workoutExporter.export(cyclingWorkout.workout) else {
                    exportProgress.current += 1
                    continue
                }

                exportedStore.markExported(
                    WorkoutCandidate(uuid: cyclingWorkout.id, startDate: cyclingWorkout.date)
                )
                GPXUploader.shared.enqueue(filename)
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
            successMessage = "Exported \(exportedCount) workout\(exportedCount == 1 ? "" : "s") to iCloud Drive."
        }

        isExporting = false
        await GPXUploader.shared.uploadPendingInBackgroundTask()
    }

    func toggleSelection(for workout: CyclingWorkout) {
        if let index = workouts.firstIndex(where: { $0.id == workout.id }) {
            workouts[index].isSelected.toggle()
        }
    }

    func resetLastExportDate() {
        UserDefaults.standard.removeObject(forKey: Self.lastExportDateKey)
        exportedStore.reset()
        for index in workouts.indices {
            workouts[index].isExported = false
        }
    }

    private func refreshExportedFlags() {
        for index in workouts.indices {
            workouts[index].isExported = exportedStore.ledger.contains(workouts[index].id)
        }
    }
}

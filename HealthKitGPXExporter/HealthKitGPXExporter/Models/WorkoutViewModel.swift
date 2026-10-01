import Foundation
import Combine
import HealthKit

/// A row in the list. Plain values only: the HKWorkout stays in the view
/// model, and "exported" is derived from the export record, never cached
/// here, so a background export shows up without a refresh.
struct CyclingWorkout: Identifiable {
    let id: UUID
    let date: Date
    let distance: Double // meters
    let duration: TimeInterval
    let averageHeartRate: Int?
    var isSelected: Bool = false

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
    // Observable: views reading isExported(_:) or newWorkoutCount re-render
    // when any path, including background sync, changes the record.
    private let exportedStore: ExportedWorkoutStore
    private var healthKitWorkouts: [UUID: HKWorkout] = [:]

    init(exportedStore: ExportedWorkoutStore = .shared) {
        self.exportedStore = exportedStore
    }

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

    /// While the export record is unreadable every workout would look new,
    /// so "Export All New" is disabled until it reads again or is reset.
    var exportHistoryUnavailable: Bool {
        exportedStore.loadError != nil
    }

    func isExported(_ workout: CyclingWorkout) -> Bool {
        exportedStore.ledger.contains(workout.id)
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
            // idempotent.
            BackgroundSyncManager.shared.start()
            await BackgroundSyncManager.shared.sync()
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
            var byID: [UUID: HKWorkout] = [:]

            for workout in hkWorkouts {
                let avgHR = try? await healthKitManager.fetchAverageHeartRate(for: workout)
                let distance = workout.totalDistance?.doubleValue(for: .meter()) ?? 0

                byID[workout.uuid] = workout
                cyclingWorkouts.append(CyclingWorkout(
                    id: workout.uuid,
                    date: workout.startDate,
                    distance: distance,
                    duration: workout.duration,
                    averageHeartRate: avgHR
                ))
            }

            healthKitWorkouts = byID
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
        guard !exportHistoryUnavailable else { return }
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
        // A Reset during this loop must not be undone by its later marks.
        let token = BackgroundSyncManager.generation.value
        var abandoned = false
        var recordSaveFailed = false
        var savedLocally = 0

        for cyclingWorkout in workoutsToExport {
            if skippingExported, exportedStore.ledger.contains(cyclingWorkout.id) {
                exportProgress.current += 1
                continue
            }
            guard let workout = healthKitWorkouts[cyclingWorkout.id] else {
                exportProgress.current += 1
                continue
            }
            do {
                // The user is present, so a local fallback counts as exported,
                // with a note below; background export retries it instead.
                guard let file = try await workoutExporter.export(workout) else {
                    exportProgress.current += 1
                    continue
                }
                if file.destination == .localFallback {
                    savedLocally += 1
                }
                guard BackgroundSyncManager.generation.isCurrent(token) else {
                    abandoned = true
                    break
                }

                if !exportedStore.markExported(
                    WorkoutCandidate(uuid: cyclingWorkout.id, startDate: cyclingWorkout.date)
                ) {
                    recordSaveFailed = true
                }
                exportedCount += 1
                exportProgress.current += 1

                if let index = workouts.firstIndex(where: { $0.id == cyclingWorkout.id }) {
                    workouts[index].isSelected = false
                }
            } catch {
                errorMessage = "Failed to export workout: \(error.localizedDescription)"
            }
        }
        // The in-loop check only follows a successful export; a Reset during
        // a run of failed exports must still void the earlier marks.
        abandoned = abandoned || !BackgroundSyncManager.generation.isCurrent(token)

        if abandoned {
            errorMessage = "Export stopped: export history was reset."
        } else if recordSaveFailed {
            // "Last Export" doubles as the v1 cutoff when the record file is
            // absent at launch, so it must not move past unrecorded exports.
            errorMessage = "Exported \(exportedCount) workout\(exportedCount == 1 ? "" : "s"), but the export record could not be saved. They may be offered again after a restart."
        } else if exportedCount > 0 {
            lastExportDate = Date()
            successMessage = savedLocally == 0
                ? "Exported \(exportedCount) workout\(exportedCount == 1 ? "" : "s") to iCloud Drive."
                : "Exported \(exportedCount) workout\(exportedCount == 1 ? "" : "s"). iCloud Drive was unavailable, so \(savedLocally) \(savedLocally == 1 ? "is" : "are") only in this iPhone's Documents folder."
        }

        isExporting = false
    }

    func toggleSelection(for workout: CyclingWorkout) {
        if let index = workouts.firstIndex(where: { $0.id == workout.id }) {
            workouts[index].isSelected.toggle()
        }
    }

    func resetLastExportDate() {
        UserDefaults.standard.removeObject(forKey: Self.lastExportDateKey)
        exportedStore.reset()
        BackgroundSyncManager.resetSyncState()
    }
}

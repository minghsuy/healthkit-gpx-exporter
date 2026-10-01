import SwiftUI

struct SettingsView: View {
    @ObservedObject var viewModel: WorkoutViewModel
    private let fileExporter = FileExporter()
    @State private var anchorUnreadable = false

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    }

    private var lastExportText: String {
        if let date = viewModel.lastExportDate {
            return date.formatted(date: .abbreviated, time: .shortened)
        }
        return "Never"
    }

    var body: some View {
        List {
            Section("Export") {
                HStack {
                    Text("Last Export")
                    Spacer()
                    Text(lastExportText)
                        .foregroundStyle(.secondary)
                }

                Button("Reset Export History", role: .destructive) {
                    viewModel.resetLastExportDate()
                }
            }

            Section("Background Sync") {
                Text(BackgroundSyncManager.shared.lastResult ?? "No background sync yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if anchorUnreadable {
                    Text("The saved sync position can't be read, so background sync is paused. Restarting keeps your export history and takes a new starting point. Rides added while paused are not exported automatically; use Export All New, or Export Selected for rides from before your last v1 export.")
                        .font(.caption)
                        .foregroundStyle(.red)
                    Button("Restart Background Sync") {
                        BackgroundSyncManager.restartSyncIfAnchorUnreadable()
                        anchorUnreadable = BackgroundSyncManager.storedAnchorState() == .unreadable
                        // Take the new starting point now rather than at the
                        // next wake, so fewer rides fall before it. Skipped
                        // while the export record is unreadable.
                        Task { await BackgroundSyncManager.shared.sync() }
                    }
                }

                if let loadError = ExportedWorkoutStore.shared.loadError {
                    Text(loadError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                if let saveError = ExportedWorkoutStore.shared.lastSaveError {
                    Text(saveError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            Section("Status") {
                HStack {
                    Text("iCloud Drive")
                    Spacer()
                    if fileExporter.isICloudAvailable {
                        Label("Connected", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        Label("Not Connected", systemImage: "xmark.circle.fill")
                            .foregroundStyle(.red)
                    }
                }

                HStack {
                    Text("HealthKit")
                    Spacer()
                    if viewModel.healthKitAuthorized {
                        Label("Authorized", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        Label("Not Authorized", systemImage: "xmark.circle.fill")
                            .foregroundStyle(.red)
                    }
                }
            }

            Section("About") {
                HStack {
                    Text("Version")
                    Spacer()
                    Text(appVersion)
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Text("Export Path")
                    Spacer()
                    Text("iCloud Drive/Bike-Ride-Analyzer/imports/")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Settings")
        .onAppear {
            anchorUnreadable = BackgroundSyncManager.storedAnchorState() == .unreadable
        }
    }
}

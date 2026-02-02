import SwiftUI

struct SettingsView: View {
    @ObservedObject var viewModel: WorkoutViewModel
    private let fileExporter = FileExporter()

    var body: some View {
        List {
            Section("Export") {
                HStack {
                    Text("Last Export")
                    Spacer()
                    if let date = viewModel.lastExportDate {
                        Text(date.formatted(date: .abbreviated, time: .shortened))
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Never")
                            .foregroundStyle(.secondary)
                    }
                }

                Button("Reset Export History", role: .destructive) {
                    viewModel.resetLastExportDate()
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
                    Text("1.0")
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
    }
}

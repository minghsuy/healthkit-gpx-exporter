import SwiftUI

struct SettingsView: View {
    @ObservedObject var viewModel: WorkoutViewModel
    private let fileExporter = FileExporter()

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

import SwiftUI

struct SettingsView: View {
    @ObservedObject var viewModel: WorkoutViewModel
    private let fileExporter = FileExporter()
    private let tokenStore = KeychainTokenStore()

    @AppStorage(UploadSettings.enabledKey) private var uploadEnabled = false
    @AppStorage(UploadSettings.serverURLKey) private var serverURL = ""
    @State private var tokenInput = ""
    @State private var hasToken = KeychainTokenStore().readToken() != nil
    @State private var tokenError: String?

    private var serverURLProblem: String? {
        do {
            _ = try UploadRequestBuilder.endpointURL(serverURL: serverURL)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

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

            Section {
                Toggle("Upload to My Server", isOn: $uploadEnabled)

                TextField("https://your-server:8420", text: $serverURL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)

                if uploadEnabled, let problem = serverURLProblem {
                    Text(problem)
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                SecureField(hasToken ? "Token saved; type to replace" : "Bearer token (optional)", text: $tokenInput)

                HStack {
                    Button("Save Token") {
                        do {
                            try tokenStore.saveToken(tokenInput)
                            tokenInput = ""
                            hasToken = true
                            tokenError = nil
                        } catch {
                            tokenError = error.localizedDescription
                        }
                    }
                    .disabled(tokenInput.isEmpty)

                    Spacer()

                    if hasToken {
                        Button("Remove Token", role: .destructive) {
                            do {
                                try tokenStore.deleteToken()
                                hasToken = false
                                tokenError = nil
                            } catch {
                                tokenError = error.localizedDescription
                            }
                        }
                    }
                }
                // Two buttons in one List row both fire on a tap unless each
                // is borderless.
                .buttonStyle(.borderless)

                if let tokenError {
                    Text(tokenError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                HStack {
                    Text("Pending Uploads")
                    Spacer()
                    Text("\(GPXUploader.shared.pending.count)")
                        .foregroundStyle(.secondary)
                }

                let failedUploads = GPXUploader.shared.failedFilenames
                if !failedUploads.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Failed Uploads (\(failedUploads.count))")
                            .foregroundStyle(.red)
                        Text("The server refused these files \(UploadRetryPolicy.maxRejections) times. They are still in the export folder.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        ForEach(failedUploads, id: \.self) { filename in
                            Text(filename)
                                .font(.caption.monospaced())
                        }
                    }
                }

                if let lastUpload = GPXUploader.shared.lastResult {
                    Text(lastUpload)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Upload")
            } footer: {
                Text("Off by default. When on, each exported GPX file is also sent to the server URL above, and only there. The token is stored in the Keychain. Nothing is sent anywhere else.")
            }

            Section("Background Sync") {
                Text(BackgroundSyncManager.shared.lastResult ?? "No background sync yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

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
    }
}

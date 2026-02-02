import SwiftUI

struct ContentView: View {
    @StateObject private var viewModel = WorkoutViewModel()

    var body: some View {
        NavigationStack {
            Group {
                if !viewModel.healthKitAuthorized {
                    authorizationView
                } else if viewModel.isLoading {
                    ProgressView("Loading workouts...")
                } else if viewModel.workouts.isEmpty {
                    ContentUnavailableView(
                        "No Cycling Workouts",
                        systemImage: "bicycle",
                        description: Text("No cycling workouts found in HealthKit.")
                    )
                } else {
                    WorkoutListView(viewModel: viewModel)
                }
            }
            .navigationTitle("GPX Exporter")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink {
                        SettingsView(viewModel: viewModel)
                    } label: {
                        Image(systemName: "gear")
                    }
                }
            }
        }
        .task {
            await viewModel.requestAuthorization()
        }
        .alert("Error", isPresented: Binding(
            get: { viewModel.errorMessage != nil },
            set: { if !$0 { viewModel.errorMessage = nil } }
        )) {
            Button("OK") { viewModel.errorMessage = nil }
        } message: {
            Text(viewModel.errorMessage ?? "")
        }
        .alert("Success", isPresented: Binding(
            get: { viewModel.successMessage != nil },
            set: { if !$0 { viewModel.successMessage = nil } }
        )) {
            Button("OK") { viewModel.successMessage = nil }
        } message: {
            Text(viewModel.successMessage ?? "")
        }
    }

    private var authorizationView: some View {
        ContentUnavailableView {
            Label("HealthKit Access", systemImage: "heart.text.square")
        } description: {
            Text("This app needs access to your cycling workouts and heart rate data to export GPX files.")
        } actions: {
            Button("Grant Access") {
                Task { await viewModel.requestAuthorization() }
            }
            .buttonStyle(.borderedProminent)
        }
    }
}

#Preview {
    ContentView()
}

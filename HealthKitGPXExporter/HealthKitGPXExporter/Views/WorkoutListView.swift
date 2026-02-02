import SwiftUI

struct WorkoutListView: View {
    @ObservedObject var viewModel: WorkoutViewModel

    var body: some View {
        ZStack {
            List {
                if viewModel.newWorkoutCount > 0 {
                    Section {
                        Button {
                            Task { await viewModel.exportAllNew() }
                        } label: {
                            Label(
                                "Export All New (\(viewModel.newWorkoutCount))",
                                systemImage: "square.and.arrow.up.on.square"
                            )
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets())
                    }
                }

                Section {
                    ForEach(viewModel.workouts) { workout in
                        WorkoutRow(workout: workout) {
                            viewModel.toggleSelection(for: workout)
                        }
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                if viewModel.selectedCount > 0 {
                    Button {
                        Task { await viewModel.exportSelected() }
                    } label: {
                        Text("Export Selected (\(viewModel.selectedCount))")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .padding()
                    .background(.ultraThinMaterial)
                }
            }

            if viewModel.isExporting {
                ExportProgressView(
                    current: viewModel.exportProgress.current,
                    total: viewModel.exportProgress.total
                )
            }
        }
    }
}

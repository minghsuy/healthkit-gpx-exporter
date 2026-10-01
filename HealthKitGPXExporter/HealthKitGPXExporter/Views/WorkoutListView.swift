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
                        .disabled(viewModel.exportHistoryUnavailable)
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets())
                    } footer: {
                        // The count is the whole history while the record is
                        // unreadable; say why the button is off.
                        if viewModel.exportHistoryUnavailable {
                            Text("Off: export history can't be read. Unlock the iPhone and reopen, or reset it in Settings.")
                        }
                    }
                }

                Section {
                    ForEach(viewModel.workouts) { workout in
                        WorkoutRow(workout: workout, isExported: viewModel.isExported(workout)) {
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

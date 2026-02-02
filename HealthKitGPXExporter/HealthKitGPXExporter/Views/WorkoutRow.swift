import SwiftUI

struct WorkoutRow: View {
    let workout: CyclingWorkout
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            HStack {
                Image(systemName: workout.isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(workout.isSelected ? .blue : .secondary)
                    .font(.title3)

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(workout.formattedDate)
                            .font(.headline)

                        Spacer()

                        if workout.isExported {
                            Label("Exported", systemImage: "checkmark")
                                .font(.caption)
                                .foregroundStyle(.green)
                        }
                    }

                    HStack(spacing: 12) {
                        Label(workout.formattedDistance, systemImage: "arrow.triangle.swap")
                        Label(workout.formattedDuration, systemImage: "clock")
                    }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                    if let hr = workout.averageHeartRate {
                        Label("\(hr) bpm avg", systemImage: "heart.fill")
                            .font(.subheadline)
                            .foregroundStyle(.red)
                    }
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(workout.isExported && !workout.isSelected ? 0.6 : 1.0)
    }
}

import SwiftUI

struct LogExerciseSheet: View {
    let exercise: PlannedExercise
    let userId: String
    let dateString: String

    @State private var calories: String
    @State private var durationMin: String
    @State private var isLogging = false
    @State private var logged = false
    @Environment(\.dismiss) private var dismiss

    init(exercise: PlannedExercise, userId: String, dateString: String) {
        self.exercise   = exercise
        self.userId     = userId
        self.dateString = dateString
        _calories       = State(initialValue: "\(exercise.caloriesBurned)")
        _durationMin    = State(initialValue: exercise.durationMin.map(String.init) ?? "")
    }

    var body: some View {
        VStack(spacing: 0) {
            // Handle bar
            RoundedRectangle(cornerRadius: 3)
                .fill(Color(hex: "D4B8A0"))
                .frame(width: 40, height: 4)
                .padding(.top, 12)
                .padding(.bottom, 20)

            VStack(alignment: .leading, spacing: 20) {
                // Title
                VStack(alignment: .leading, spacing: 4) {
                    Text("Log Exercise")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundColor(Color(hex: "3D2B1F"))
                    Text(exercise.name)
                        .font(.system(size: 15))
                        .foregroundColor(Color(hex: "B09880"))
                }

                // Volume info (read-only)
                HStack(spacing: 16) {
                    if exercise.type == "strength", let s = exercise.sets, let r = exercise.reps {
                        statBadge(label: "Sets", value: "\(s)")
                        statBadge(label: "Reps", value: "\(r)")
                        if let w = exercise.weightKg, w > 0 {
                            statBadge(label: "Weight", value: "\(Int(w)) kg")
                        }
                    } else if let d = exercise.durationMin {
                        statBadge(label: "Duration", value: "\(d) min")
                    }
                }

                Divider().background(Color(hex: "F0E6DA"))

                // Editable fields
                VStack(spacing: 14) {
                    if exercise.type == "cardio" {
                        fieldRow(label: "Duration (min)", text: $durationMin, keyboard: .numberPad)
                    }
                    fieldRow(label: "Calories burned", text: $calories, keyboard: .numberPad)
                }

                Spacer()

                // Log button
                if logged {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(Color(hex: "2A9D8F"))
                        Text("Logged!")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(Color(hex: "2A9D8F"))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Color(hex: "2A9D8F").opacity(0.1))
                    .cornerRadius(14)
                } else {
                    Button(action: logIt) {
                        Group {
                            if isLogging {
                                ProgressView().tint(.white)
                            } else {
                                Text("Log Workout")
                                    .font(.system(size: 16, weight: .semibold))
                            }
                        }
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Color(hex: "E76F51"))
                        .cornerRadius(14)
                    }
                    .disabled(isLogging)
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 32)
        }
        .background(Color(hex: "F7F3EE").ignoresSafeArea())
        .presentationDetents([.height(400)])
    }

    private func statBadge(label: String, value: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(size: 16, weight: .bold))
                .foregroundColor(Color(hex: "3D2B1F"))
            Text(label)
                .font(.system(size: 10))
                .foregroundColor(Color(hex: "B09880"))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color(hex: "F0E6DA"))
        .cornerRadius(10)
    }

    private func fieldRow(label: String, text: Binding<String>, keyboard: UIKeyboardType) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 14))
                .foregroundColor(Color(hex: "3D2B1F"))
            Spacer()
            TextField("0", text: text)
                .keyboardType(keyboard)
                .multilineTextAlignment(.trailing)
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(Color(hex: "E76F51"))
                .frame(width: 70)
                .padding(8)
                .background(Color(hex: "F0E6DA"))
                .cornerRadius(8)
        }
    }

    private func logIt() {
        isLogging = true
        let cal = Int(calories) ?? exercise.caloriesBurned
        Task {
            try? await RenaAPI.shared.logExercise(
                userId: userId,
                exerciseId: exercise.id,
                calories: cal,
                date: dateString
            )
            await MainActor.run {
                isLogging = false
                logged    = true
            }
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            await MainActor.run { dismiss() }
        }
    }
}

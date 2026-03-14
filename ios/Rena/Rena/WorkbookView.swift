import SwiftUI

struct WorkbookView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 20) {
                    WeightLogSection()
                    Spacer(minLength: 40)
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
            }
            .background(Color(hex: "F7F3EE").ignoresSafeArea())
            .navigationTitle("Workbook")
            .navigationBarTitleDisplayMode(.large)
            .scrollBounceBehavior(.always)
        }
    }
}

// MARK: - Weight log section

struct WeightLogSection: View {
    @EnvironmentObject var appState: AppState
    @State private var sliderValue: Double = 70.0
    @State private var isSaving = false
    @State private var savedConfirmation = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {

            // Header
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color(hex: "9B7EC8").opacity(0.10))
                        .frame(width: 44, height: 44)
                    Image(systemName: "scalemass")
                        .font(.system(size: 20))
                        .foregroundColor(Color(hex: "9B7EC8"))
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("WEIGHT")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(Color(hex: "B09880"))
                        .kerning(1.0)
                    Text("Log today's weight")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(Color(hex: "3D2B1F"))
                }
            }

            // Big display
            HStack(alignment: .lastTextBaseline, spacing: 6) {
                Text(String(format: "%.1f", sliderValue))
                    .font(.system(size: 64, weight: .bold, design: .rounded))
                    .foregroundColor(Color(hex: "9B7EC8"))
                    .animation(nil)
                Text("kg")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundColor(Color(hex: "B09880"))
                    .padding(.bottom, 8)
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 8)

            // Slider
            VStack(spacing: 6) {
                Slider(value: $sliderValue, in: 30...200, step: 0.5)
                    .tint(Color(hex: "9B7EC8"))
                HStack {
                    Text("30 kg")
                        .font(.system(size: 11))
                        .foregroundColor(Color(hex: "C4AFA0"))
                    Spacer()
                    Text("200 kg")
                        .font(.system(size: 11))
                        .foregroundColor(Color(hex: "C4AFA0"))
                }
            }

            // Last logged note
            if let logged = appState.todayWeightKg {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundColor(Color(hex: "9B7EC8"))
                    Text("Last logged today: \(String(format: "%.1f", logged)) kg")
                        .font(.system(size: 12))
                        .foregroundColor(Color(hex: "B09880"))
                }
            }

            // Log button
            Button {
                Task { await saveWeight() }
            } label: {
                HStack(spacing: 8) {
                    if isSaving {
                        ProgressView().tint(.white).scaleEffect(0.85)
                    } else if savedConfirmation {
                        Image(systemName: "checkmark")
                            .font(.system(size: 15, weight: .semibold))
                        Text("Saved!")
                            .font(.system(size: 16, weight: .semibold))
                    } else {
                        Image(systemName: "scalemass")
                            .font(.system(size: 15))
                        Text(appState.todayWeightKg != nil ? "Update weight" : "Log weight")
                            .font(.system(size: 16, weight: .semibold))
                    }
                }
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(savedConfirmation ? Color(hex: "2A9D8F") : Color(hex: "9B7EC8"))
                .cornerRadius(14)
                .animation(.easeInOut(duration: 0.2), value: savedConfirmation)
            }
            .disabled(isSaving)
        }
        .padding(20)
        .background(Color.white)
        .cornerRadius(18)
        .shadow(color: .black.opacity(0.05), radius: 8, y: 2)
        .onAppear {
            sliderValue = appState.todayWeightKg ?? 70.0
        }
    }

    private func saveWeight() async {
        isSaving = true
        do {
            let rounded = (sliderValue * 2).rounded() / 2
            _ = try await RenaAPI.shared.logWeight(userId: appState.userId, weightKg: rounded)
            await MainActor.run {
                appState.todayWeightKg = rounded
                isSaving = false
                savedConfirmation = true
            }
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            await MainActor.run { savedConfirmation = false }
        } catch {
            print("[Workbook] save error: \(error)")
            isSaving = false
        }
    }
}

import SwiftUI

// MARK: - Data types

enum Sex: String, CaseIterable {
    case male = "male"
    case female = "female"
    var label: String { rawValue.capitalized }
    var icon: String { self == .male ? "👨" : "👩" }
}

enum ActivityLevel: String, CaseIterable {
    case sedentary        = "sedentary"
    case lightlyActive    = "lightly_active"
    case moderatelyActive = "moderately_active"
    case veryActive       = "very_active"

    var label: String {
        switch self {
        case .sedentary:        return "Mostly sitting"
        case .lightlyActive:    return "Light exercise (1–3×/week)"
        case .moderatelyActive: return "Moderate exercise (3–5×/week)"
        case .veryActive:       return "Very active (daily intense)"
        }
    }
    var icon: String {
        switch self {
        case .sedentary:        return "🪑"
        case .lightlyActive:    return "🚶"
        case .moderatelyActive: return "🏃"
        case .veryActive:       return "🔥"
        }
    }
}

// MARK: - Main view

struct OnboardingView: View {
    @EnvironmentObject var appState: AppState

    @State private var step: Int = 1

    // Answers — name comes from Google Sign-In via appState
    @State private var sex: Sex = .male
    @State private var age: Double = 28
    @State private var heightInches: Double = 70   // 5'10" default, stored as total inches
    @State private var weightKg: Double = 70.0

    private var heightCm: Double { heightInches * 2.54 }

    private func heightDisplay(_ totalInches: Double) -> String {
        let feet = Int(totalInches) / 12
        let inches = Int(totalInches) % 12
        return "\(feet)'\(inches)\""
    }
    @State private var activity: ActivityLevel = .moderatelyActive

    @State private var isSubmitting = false
    @State private var errorMessage: String?

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(hex: "FDF6EC"), Color(hex: "F4A261")],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                // Welcome note
                VStack(spacing: 4) {
                    Text("Welcome, \(appState.name.isEmpty ? "there" : appState.name.components(separatedBy: " ").first ?? appState.name) 👋")
                        .font(.system(size: 17, weight: .semibold, design: .rounded))
                        .foregroundColor(Color(hex: "3D2B1F"))
                    Text("Just a few quick questions to personalise your experience")
                        .font(.caption)
                        .foregroundColor(Color(hex: "7C5C45"))
                        .multilineTextAlignment(.center)
                }
                .padding(.top, 48)
                .padding(.horizontal, 28)

                // Progress dots
                HStack(spacing: 8) {
                    ForEach(1..<5) { i in
                        Circle()
                            .fill(i == step ? Color(hex: "E76F51") : Color(hex: "E76F51").opacity(0.25))
                            .frame(width: i == step ? 10 : 7, height: i == step ? 10 : 7)
                            .animation(.spring(response: 0.3), value: step)
                    }
                }
                .padding(.top, 56)

                Spacer()

                // Step content
                Group {
                    switch step {
                    case 1: stepSex
                    case 2: stepAge
                    case 3: stepBody
                    default: stepActivity
                    }
                }
                .transition(.asymmetric(
                    insertion: .move(edge: .trailing).combined(with: .opacity),
                    removal: .move(edge: .leading).combined(with: .opacity)
                ))
                .padding(.horizontal, 28)

                Spacer()

                // Error
                if let errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundColor(.red)
                        .padding(.horizontal)
                        .padding(.bottom, 8)
                }

                // CTA — only show for steps that don't auto-advance
                if step == 3 {
                    Button(action: advance) {
                        if isSubmitting {
                            ProgressView().tint(.white)
                        } else {
                            Text("Almost done →")
                                .font(.headline)
                                .foregroundColor(.white)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(ctaEnabled ? Color(hex: "E76F51") : Color.gray.opacity(0.35))
                    .cornerRadius(16)
                    .disabled(!ctaEnabled || isSubmitting)
                    .padding(.horizontal, 28)
                    .padding(.bottom, 48)
                } else {
                    Color.clear.frame(height: 48 + 48)
                }
            }
        }
    }

    // MARK: - Step views

    private var stepSex: some View {
        VStack(spacing: 24) {
            prompt("I'm a…")
            HStack(spacing: 16) {
                ForEach(Sex.allCases, id: \.self) { option in
                    Button(action: {
                        sex = option
                        withAnimation { advance() }
                    }) {
                        VStack(spacing: 10) {
                            Text(option.icon).font(.system(size: 40))
                            Text(option.label).font(.headline)
                        }
                        .foregroundColor(sex == option ? .white : Color(hex: "3D2B1F"))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 28)
                        .background(
                            sex == option
                                ? Color(hex: "E76F51")
                                : Color.white.opacity(0.85)
                        )
                        .cornerRadius(18)
                    }
                }
            }
        }
    }

    private var stepAge: some View {
        VStack(spacing: 24) {
            prompt("How old are you?")
            Text("\(Int(age))")
                .font(.system(size: 80, weight: .bold, design: .rounded))
                .foregroundColor(Color(hex: "3D2B1F"))

            Slider(value: $age, in: 16...80, step: 1)
                .tint(Color(hex: "E76F51"))

            HStack {
                Text("16").font(.caption).foregroundColor(Color(hex: "7C5C45"))
                Spacer()
                Text("80").font(.caption).foregroundColor(Color(hex: "7C5C45"))
            }

            Button(action: advance) {
                Text("Next →")
                    .font(.headline)
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(Color(hex: "E76F51"))
                    .cornerRadius(16)
            }
            .padding(.top, 8)
        }
    }

    private var stepBody: some View {
        VStack(alignment: .leading, spacing: 28) {
            prompt("Tell me about\nyour body")

            // Height slider
            VStack(alignment: .leading, spacing: 10) {
                Text("HEIGHT")
                    .font(.caption)
                    .foregroundColor(Color(hex: "7C5C45"))

                Text(heightDisplay(heightInches))
                    .font(.system(size: 48, weight: .bold, design: .rounded))
                    .foregroundColor(Color(hex: "3D2B1F"))

                Slider(value: $heightInches, in: 48...84, step: 1)
                    .tint(Color(hex: "E76F51"))

                HStack {
                    Text("4'0\"").font(.caption).foregroundColor(Color(hex: "7C5C45"))
                    Spacer()
                    Text("7'0\"").font(.caption).foregroundColor(Color(hex: "7C5C45"))
                }
            }

            // Weight slider
            VStack(alignment: .leading, spacing: 10) {
                Text("WEIGHT")
                    .font(.caption)
                    .foregroundColor(Color(hex: "7C5C45"))

                HStack(alignment: .lastTextBaseline, spacing: 6) {
                    Text(String(format: "%.1f", weightKg))
                        .font(.system(size: 48, weight: .bold, design: .rounded))
                        .foregroundColor(Color(hex: "3D2B1F"))
                    Text("kg")
                        .font(.title3)
                        .foregroundColor(Color(hex: "7C5C45"))
                }

                Slider(value: $weightKg, in: 30...200, step: 0.5)
                    .tint(Color(hex: "E76F51"))

                HStack {
                    Text("30 kg").font(.caption).foregroundColor(Color(hex: "7C5C45"))
                    Spacer()
                    Text("200 kg").font(.caption).foregroundColor(Color(hex: "7C5C45"))
                }
            }
        }
    }

    private var stepActivity: some View {
        VStack(alignment: .leading, spacing: 20) {
            prompt("How active\nare you?")
            VStack(spacing: 12) {
                ForEach(ActivityLevel.allCases, id: \.self) { level in
                    Button(action: {
                        activity = level
                        withAnimation { submitOnboarding() }
                    }) {
                        HStack(spacing: 14) {
                            Text(level.icon).font(.title2)
                            Text(level.label)
                                .font(.body)
                                .foregroundColor(Color(hex: "3D2B1F"))
                            Spacer()
                            if activity == level {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(Color(hex: "E76F51"))
                            }
                        }
                        .padding(16)
                        .background(
                            activity == level
                                ? Color(hex: "E76F51").opacity(0.12)
                                : Color.white.opacity(0.85)
                        )
                        .cornerRadius(14)
                        .overlay(
                            RoundedRectangle(cornerRadius: 14)
                                .stroke(
                                    activity == level ? Color(hex: "E76F51") : Color.clear,
                                    lineWidth: 1.5
                                )
                        )
                    }
                }
            }
        }
    }

    // MARK: - Helpers

    private func prompt(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 34, weight: .bold, design: .rounded))
            .foregroundColor(Color(hex: "3D2B1F"))
            .fixedSize(horizontal: false, vertical: true)
    }

    private var ctaEnabled: Bool { true }

    private func advance() {
        withAnimation(.easeInOut(duration: 0.3)) {
            step = min(step + 1, 4)
        }
    }

    private func submitOnboarding() {
        let w = weightKg
        let h = heightCm

        isSubmitting = true
        errorMessage = nil

        Task {
            do {
                let result = try await RenaAPI.shared.onboard(
                    userId: appState.userId,
                    name: appState.name,
                    sex: sex.rawValue,
                    age: Int(age),
                    heightCm: h,
                    weightKg: w,
                    activityLevel: activity.rawValue
                )
                appState.completeOnboarding(name: result.name, caloriesTarget: result.dailyCalorieTarget)
            } catch {
                errorMessage = "Something went wrong. Please try again."
                isSubmitting = false
            }
        }
    }
}

// MARK: - Color extension

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let r = Double((int >> 16) & 0xFF) / 255
        let g = Double((int >> 8) & 0xFF) / 255
        let b = Double(int & 0xFF) / 255
        self.init(red: r, green: g, blue: b)
    }
}

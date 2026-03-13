import SwiftUI

struct OnboardingView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var voice = VoiceManager()

    @State private var goalText: String = ""
    @State private var deadlineText: String = ""
    @State private var step: Int = 0
    @State private var isListening = false

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(hex: "F9E4C8"), Color(hex: "F4A261")],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 32) {
                Spacer()

                // Logo
                VStack(spacing: 8) {
                    Text("✦")
                        .font(.system(size: 48))
                    Text("Rena")
                        .font(.system(size: 42, weight: .bold, design: .rounded))
                        .foregroundColor(Color(hex: "3D2B1F"))
                    Text("your personal health companion")
                        .font(.subheadline)
                        .foregroundColor(Color(hex: "7C5C45"))
                }

                Spacer()

                // Step content
                VStack(spacing: 20) {
                    if step == 0 {
                        VStack(spacing: 12) {
                            Text("What are you working toward?")
                                .font(.title2.bold())
                                .foregroundColor(Color(hex: "3D2B1F"))
                                .multilineTextAlignment(.center)

                            Text("Tell Rena your goal — a wedding, a trip,\na race, or simply feeling your best.")
                                .font(.subheadline)
                                .foregroundColor(Color(hex: "7C5C45"))
                                .multilineTextAlignment(.center)

                            TextField("e.g. Feel confident at Sarah's wedding", text: $goalText)
                                .padding()
                                .background(Color.white.opacity(0.8))
                                .cornerRadius(14)
                                .font(.body)
                        }
                    } else {
                        VStack(spacing: 12) {
                            Text("When is your goal date?")
                                .font(.title2.bold())
                                .foregroundColor(Color(hex: "3D2B1F"))
                                .multilineTextAlignment(.center)

                            Text("Rena will adapt your daily targets\nas your goal gets closer.")
                                .font(.subheadline)
                                .foregroundColor(Color(hex: "7C5C45"))
                                .multilineTextAlignment(.center)

                            TextField("YYYY-MM-DD  e.g. 2026-07-15", text: $deadlineText)
                                .padding()
                                .background(Color.white.opacity(0.8))
                                .cornerRadius(14)
                                .font(.body)
                                .keyboardType(.numbersAndPunctuation)
                        }
                    }
                }
                .padding(.horizontal, 28)
                .transition(.asymmetric(
                    insertion: .move(edge: .trailing).combined(with: .opacity),
                    removal: .move(edge: .leading).combined(with: .opacity)
                ))

                // CTA button
                Button(action: advance) {
                    Text(step == 0 ? "Next →" : "Start my journey")
                        .font(.headline)
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(
                            (step == 0 ? !goalText.isEmpty : !deadlineText.isEmpty)
                                ? Color(hex: "E76F51")
                                : Color.gray.opacity(0.4)
                        )
                        .cornerRadius(16)
                }
                .disabled(step == 0 ? goalText.isEmpty : deadlineText.isEmpty)
                .padding(.horizontal, 28)

                Spacer()
            }
        }
    }

    private func advance() {
        if step == 0 {
            withAnimation { step = 1 }
        } else {
            appState.completeOnboarding(goal: goalText, deadline: deadlineText)
        }
    }
}

// MARK: - Color helper

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

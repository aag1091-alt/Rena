import SwiftUI

struct HomeView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var voice = VoiceManager()

    @State private var goalImage: URL? = nil
    @State private var goalText: String = ""
    @State private var daysLeft: Int = 0
    @State private var isLoadingGoal = false
    @State private var isConnected = false

    var body: some View {
        ZStack {
            Color.white.ignoresSafeArea()

            VStack(spacing: 0) {
                // Greeting
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(greeting)
                            .font(.system(size: 15))
                            .foregroundColor(Color(hex: "7C5C45"))
                        Text(appState.name.components(separatedBy: " ").first ?? appState.name)
                            .font(.system(size: 28, weight: .bold, design: .rounded))
                            .foregroundColor(Color(hex: "3D2B1F"))
                    }
                    Spacer()
                    MiniCalorieRing()
                }
                .padding(.horizontal, 24)
                .padding(.top, 56)

                Spacer()

                // Goal card — top half
                GoalCard(imageURL: goalImage, goalText: goalText, daysLeft: daysLeft, isLoading: isLoadingGoal)
                    .padding(.horizontal, 20)

                Spacer()

                // Rena orb — bottom
                VStack(spacing: 10) {
                    Button(action: toggleVoice) {
                        ZStack {
                            Circle()
                                .fill(Color(hex: "E76F51").opacity(isPulsing ? 0.18 : 0.10))
                                .frame(width: 160, height: 160)
                                .scaleEffect(isPulsing ? 1.08 : 1.0)
                                .animation(
                                    isPulsing
                                        ? .easeInOut(duration: 0.7).repeatForever(autoreverses: true)
                                        : .default,
                                    value: isPulsing
                                )
                            Circle()
                                .fill(
                                    LinearGradient(
                                        colors: isConnected
                                            ? [Color(hex: "E76F51"), Color(hex: "F4A261")]
                                            : [Color(hex: "D4B8A0"), Color(hex: "C4A882")],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                                )
                                .frame(width: 120, height: 120)
                                .shadow(color: Color(hex: "E76F51").opacity(isConnected ? 0.35 : 0), radius: 20)
                            Text("✦")
                                .font(.system(size: 40))
                                .foregroundColor(.white)
                        }
                    }
                    Text(orbLabel)
                        .font(.subheadline)
                        .foregroundColor(Color(hex: "7C5C45"))
                        .animation(.easeInOut, value: orbLabel)
                }
                .padding(.bottom, 40)
            }
        }
        .onAppear { Task { await loadGoal() } }
        .onDisappear { if isConnected { toggleVoice() } }
    }

    // MARK: - Voice

    private func toggleVoice() {
        if isConnected {
            voice.disconnect()
            isConnected = false
        } else {
            voice.connect(userId: appState.userId)
            isConnected = true
        }
    }

    private var orbLabel: String {
        switch voice.state {
        case .connecting: return "Connecting…"
        case .listening:  return "Listening…"
        case .thinking:   return "Thinking…"
        case .speaking:   return "Rena is speaking…"
        case .error:      return "Tap to try again"
        default:          return isConnected ? "Tap to end" : "Tap to talk to Rena"
        }
    }

    private var isPulsing: Bool {
        switch voice.state {
        case .listening, .speaking: return true
        default: return false
        }
    }

    // MARK: - Goal

    private func loadGoal() async {
        isLoadingGoal = true
        guard let resp = try? await RenaAPI.shared.getGoal(userId: appState.userId) else {
            isLoadingGoal = false
            return
        }
        await MainActor.run {
            goalText = resp.goal
            daysLeft = resp.daysUntilGoal
            if let urlStr = resp.imageUrl, let url = URL(string: urlStr) {
                goalImage = url
            }
            isLoadingGoal = false
        }
    }

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        if hour < 12 { return "Good morning," }
        if hour < 17 { return "Good afternoon," }
        return "Good evening,"
    }
}

// MARK: - Mini calorie ring

struct MiniCalorieRing: View {
    @EnvironmentObject var appState: AppState
    var progress: Double { min(1.0, Double(appState.caloriesConsumed) / Double(max(appState.caloriesTarget, 1))) }

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color(hex: "E76F51").opacity(0.15), lineWidth: 6)
            Circle()
                .trim(from: 0, to: progress)
                .stroke(Color(hex: "E76F51"), style: StrokeStyle(lineWidth: 6, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.spring(), value: progress)
            VStack(spacing: 0) {
                Text("\(Int(progress * 100))%")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(Color(hex: "3D2B1F"))
                Text("cal")
                    .font(.system(size: 8))
                    .foregroundColor(Color(hex: "7C5C45"))
            }
        }
        .frame(width: 52, height: 52)
    }
}

// MARK: - Goal card

struct GoalCard: View {
    let imageURL: URL?
    let goalText: String
    let daysLeft: Int
    let isLoading: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack {
                RoundedRectangle(cornerRadius: 20)
                    .fill(
                        LinearGradient(
                            colors: [Color(hex: "FFF3E8"), Color(hex: "FFE4C4")],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(height: 180)

                if isLoading {
                    VStack(spacing: 10) {
                        ProgressView().tint(Color(hex: "E76F51"))
                        Text("Generating your goal image…")
                            .font(.caption)
                            .foregroundColor(Color(hex: "7C5C45"))
                    }
                } else if let url = imageURL {
                    AsyncImage(url: url) { image in
                        image.resizable().aspectRatio(contentMode: .fill)
                            .frame(height: 180).clipped()
                    } placeholder: {
                        ProgressView().tint(Color(hex: "E76F51"))
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 20))
                } else {
                    Image(systemName: "sparkles")
                        .font(.system(size: 40))
                        .foregroundColor(Color(hex: "E76F51").opacity(0.4))
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Working towards")
                    .font(.caption).foregroundColor(Color(hex: "7C5C45"))
                    .textCase(.uppercase).padding(.top, 14)
                Text(goalText.isEmpty ? "Set your goal" : goalText)
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                    .foregroundColor(Color(hex: "3D2B1F"))
                if daysLeft > 0 {
                    HStack(spacing: 6) {
                        Text(urgencyEmoji).font(.system(size: 14))
                        Text("\(daysLeft) days to go")
                            .font(.subheadline.weight(.semibold))
                            .foregroundColor(Color(hex: "E76F51"))
                    }
                    .padding(.top, 2)
                }
            }
            .padding(.horizontal, 4).padding(.bottom, 4)
        }
        .padding(16)
        .background(Color.white)
        .cornerRadius(24)
        .shadow(color: .black.opacity(0.06), radius: 16, y: 4)
    }

    private var urgencyEmoji: String {
        if daysLeft < 14 { return "🔥" }
        if daysLeft < 30 { return "⚡️" }
        if daysLeft < 60 { return "💪" }
        return "🌟"
    }
}

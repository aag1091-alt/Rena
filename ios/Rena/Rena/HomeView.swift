import SwiftUI

struct HomeView: View {
    @EnvironmentObject var appState: AppState
    @Binding var selectedTab: Int

    @State private var goalImage: URL? = nil
    @State private var goalText: String = ""
    @State private var daysLeft: Int = 0
    @State private var isLoadingGoal = false

    var body: some View {
        ZStack {
            Color.white.ignoresSafeArea()

            VStack(spacing: 0) {
                // Top greeting
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
                    // small calorie ring summary
                    MiniCalorieRing()
                }
                .padding(.horizontal, 24)
                .padding(.top, 56)

                Spacer()

                // Rena orb — tap to go to voice
                VStack(spacing: 12) {
                    Button(action: { selectedTab = 1 }) {
                        ZStack {
                            Circle()
                                .fill(Color(hex: "E76F51").opacity(0.12))
                                .frame(width: 160, height: 160)
                            Circle()
                                .fill(
                                    LinearGradient(
                                        colors: [Color(hex: "E76F51"), Color(hex: "F4A261")],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                                )
                                .frame(width: 120, height: 120)
                                .shadow(color: Color(hex: "E76F51").opacity(0.35), radius: 20)
                            Text("✦")
                                .font(.system(size: 40))
                                .foregroundColor(.white)
                        }
                    }
                    Text("Tap to talk to Rena")
                        .font(.subheadline)
                        .foregroundColor(Color(hex: "7C5C45"))
                }

                Spacer()

                // Goal card
                GoalCard(imageURL: goalImage, goalText: goalText, daysLeft: daysLeft, isLoading: isLoadingGoal)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 32)
            }
        }
        .onAppear { Task { await loadGoal() } }
    }

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        if hour < 12 { return "Good morning," }
        if hour < 17 { return "Good afternoon," }
        return "Good evening,"
    }

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
}

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

struct GoalCard: View {
    let imageURL: URL?
    let goalText: String
    let daysLeft: Int
    let isLoading: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Goal image
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
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(height: 180)
                            .clipped()
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

            // Goal info below image
            VStack(alignment: .leading, spacing: 6) {
                Text("Working towards")
                    .font(.caption)
                    .foregroundColor(Color(hex: "7C5C45"))
                    .textCase(.uppercase)
                    .padding(.top, 14)

                Text(goalText.isEmpty ? "Set your goal" : goalText)
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                    .foregroundColor(Color(hex: "3D2B1F"))

                if daysLeft > 0 {
                    HStack(spacing: 6) {
                        Text(urgencyEmoji)
                            .font(.system(size: 14))
                        Text("\(daysLeft) days to go")
                            .font(.subheadline.weight(.semibold))
                            .foregroundColor(Color(hex: "E76F51"))
                    }
                    .padding(.top, 2)
                }
            }
            .padding(.horizontal, 4)
            .padding(.bottom, 4)
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

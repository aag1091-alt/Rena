import SwiftUI

struct HomeView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var voice: VoiceManager

    @State private var goalText: String = ""
    @State private var goalType: String = "event"
    @State private var progressPercent: Int = 0
    @State private var progressLabel: String = ""
    @State private var daysLeft: Int = 0
    @State private var isLoadingGoal = false
    @State private var isConnected = false

    var body: some View {
        NavigationView {
        ZStack {
            Color(hex: "F7F3EE").ignoresSafeArea()

            VStack(spacing: 0) {

                // ── Greeting ───────────────────────────────────────
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(greeting)
                            .font(.system(size: 13))
                            .foregroundColor(Color(hex: "B09880"))
                        Text(appState.name.components(separatedBy: " ").first ?? appState.name)
                            .font(.system(size: 26, weight: .bold, design: .rounded))
                            .foregroundColor(Color(hex: "3D2B1F"))
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(todayDateString)
                            .font(.system(size: 13))
                            .foregroundColor(Color(hex: "B09880"))
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 56)
                .padding(.bottom, 16)

                // ── Scrollable cards ───────────────────────────────
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 12) {
                        NavigationLink(destination: GoalView()) {
                            GoalCard(
                                goalText: goalText,
                                goalType: goalType,
                                progressPercent: progressPercent,
                                progressLabel: progressLabel,
                                daysLeft: daysLeft,
                                isLoading: isLoadingGoal
                            )
                        }
                        .buttonStyle(.plain)

                        CalorieCard()

                        // ── Stats row ───────────────────────────────
                        HStack(spacing: 10) {
                            WideStatTile(
                                icon: "drop.fill",
                                value: "\(appState.waterGlasses) / 8",
                                label: "Water",
                                iconColor: Color(hex: "457B9D"),
                                progress: Double(appState.waterGlasses) / 8.0
                            )
                            WideStatTile(
                                icon: "figure.run",
                                value: appState.caloriesBurned > 0 ? "\(appState.caloriesBurned)" : "—",
                                label: "kcal burned",
                                iconColor: Color(hex: "2A9D8F"),
                                progress: nil
                            )
                            WideStatTile(
                                icon: "scalemass",
                                value: appState.todayWeightKg.map { String(format: "%.1f", $0) } ?? "—",
                                label: "kg today",
                                iconColor: Color(hex: "9B7EC8"),
                                progress: nil
                            )
                        }

                        NudgeStrip()
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 12)
                }

                // ── CC captions ────────────────────────────────────
                if isConnected && !voice.transcript.isEmpty {
                    Text(voice.transcript)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.white)
                        .multilineTextAlignment(.center)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 10)
                        .background(.black.opacity(0.62))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .padding(.horizontal, 32)
                        .padding(.bottom, 8)
                        .transition(.opacity)
                }

                // ── Rena orb ───────────────────────────────────────
                ZStack {
                    // Soft fade separating orb from scroll content
                    LinearGradient(
                        colors: [Color(hex: "F7F3EE").opacity(0), Color(hex: "F7F3EE")],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(height: 40)
                    .offset(y: -40)
                    .allowsHitTesting(false)

                    VStack(spacing: 8) {
                        Button(action: toggleVoice) {
                            ZStack {
                                Circle()
                                    .fill(Color(hex: "E76F51").opacity(isPulsing ? 0.15 : 0.08))
                                    .frame(width: 148, height: 148)
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
                                    .frame(width: 110, height: 110)
                                    .shadow(color: Color(hex: "E76F51").opacity(isConnected ? 0.3 : 0), radius: 18)
                                Text("✦")
                                    .font(.system(size: 36))
                                    .foregroundColor(.white)
                            }
                        }

                        VStack(spacing: 2) {
                            Text(orbLabel)
                                .font(.system(size: 14, weight: .medium))
                                .foregroundColor(Color(hex: "3D2B1F"))
                                .animation(.easeInOut, value: orbLabel)
                            if !isConnected {
                                Text("Tell Rena what you ate, drank or how you feel")
                                    .font(.system(size: 11))
                                    .foregroundColor(Color(hex: "B09880"))
                                    .multilineTextAlignment(.center)
                            }
                        }
                    }
                    .padding(.bottom, 44)
                }
            }
        }
        .navigationBarHidden(true)
        .onAppear { Task { await loadGoal(); await loadProgress() } }
        .onDisappear { if isConnected { toggleVoice() } }
        .onChange(of: voice.turnCount) { Task { await loadProgress() } }
        } // NavigationView
    }

    // MARK: - Voice

    private func toggleVoice() {
        if isConnected {
            voice.disconnect()
            isConnected = false
        } else {
            voice.connect(userId: appState.userId, context: "home", name: appState.name)
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
        default:          return isConnected ? "Tap to end session" : "Talk to Rena"
        }
    }

    private var isPulsing: Bool {
        switch voice.state {
        case .listening, .speaking: return true
        default: return false
        }
    }

    // MARK: - Data

    private func loadProgress() async {
        guard let resp = try? await RenaAPI.shared.getProgress(userId: appState.userId) else { return }
        await MainActor.run {
            appState.caloriesConsumed = resp.caloriesConsumed
            appState.caloriesBurned   = resp.caloriesBurned
            appState.caloriesTarget   = resp.caloriesTarget
            appState.burnRequired     = resp.burnRequired
            appState.proteinConsumedG = resp.proteinConsumedG
            appState.proteinTargetG   = resp.proteinTargetG
            appState.waterGlasses     = resp.waterGlasses
            appState.todayWeightKg    = resp.weightKg
            appState.mealsLogged      = resp.mealsLogged ?? []
            appState.workoutsLogged   = resp.workoutsLogged ?? []
        }
    }

    private func loadGoal() async {
        isLoadingGoal = true
        guard let resp = try? await RenaAPI.shared.getGoal(userId: appState.userId) else {
            isLoadingGoal = false; return
        }
        await MainActor.run {
            goalText        = resp.goal
            goalType        = resp.goalType
            progressPercent = resp.progressPercent
            progressLabel   = resp.progressLabel
            daysLeft        = resp.daysUntilGoal
            isLoadingGoal   = false
        }
    }

    private var greeting: String {
        let h = Calendar.current.component(.hour, from: Date())
        if h < 12 { return "Good morning" }
        if h < 17 { return "Good afternoon" }
        return "Good evening"
    }

    private var todayDateString: String {
        let f = DateFormatter()
        f.dateFormat = "EEE, MMM d"
        return f.string(from: Date())
    }
}

// MARK: - Goal card

struct GoalCard: View {
    @EnvironmentObject var appState: AppState
    let goalText: String
    let goalType: String
    let progressPercent: Int
    let progressLabel: String
    let daysLeft: Int
    let isLoading: Bool

    private var goalIcon: String {
        switch goalType {
        case "weight_loss":  return "scalemass"
        case "weight_gain":  return "dumbbell"
        case "fitness":      return "figure.run"
        case "habit":        return "checkmark.circle"
        default:
            let t = goalText.lowercased()
            if t.contains("wedding") || t.contains("confident") { return "star" }
            if t.contains("swim") { return "figure.pool.swim" }
            if t.contains("cycle") || t.contains("bike") { return "figure.outdoor.cycle" }
            return "figure.walk"
        }
    }

    private var goalColor: Color {
        switch goalType {
        case "weight_loss": return Color(hex: "9B7EC8")
        case "weight_gain": return Color(hex: "2A9D8F")
        case "fitness":     return Color(hex: "457B9D")
        case "habit":       return Color(hex: "E9C46A")
        default:            return Color(hex: "C47A5A")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                // Icon pill
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(goalColor.opacity(0.14))
                        .frame(width: 30, height: 30)
                    Image(systemName: goalIcon)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(goalColor)
                }
                Text("YOUR GOAL")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(Color(hex: "B09880"))
                    .kerning(1.0)
                Spacer()
                if daysLeft > 0 {
                    Text("\(daysLeft)d to go")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(goalColor)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(goalColor.opacity(0.12))
                        .cornerRadius(20)
                }
            }

            Text(isLoading ? "Loading…" : (goalText.isEmpty ? "Set your goal" : goalText))
                .font(.system(size: 19, weight: .bold, design: .rounded))
                .foregroundColor(Color(hex: "3D2B1F"))
                .fixedSize(horizontal: false, vertical: true)
                .lineLimit(2)

            if progressPercent > 0 || !progressLabel.isEmpty, goalType != "event" {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(progressLabel)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(goalColor)
                        Spacer()
                        Text("\(progressPercent)%")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(goalColor)
                    }
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 4)
                                .fill(goalColor.opacity(0.12))
                                .frame(height: 6)
                            RoundedRectangle(cornerRadius: 4)
                                .fill(goalColor)
                                .frame(width: geo.size.width * Double(progressPercent) / 100.0, height: 6)
                                .animation(.spring(), value: progressPercent)
                        }
                    }
                    .frame(height: 6)
                }
            }
        }
        .padding(18)
        .background(
            LinearGradient(
                colors: [goalColor.opacity(0.07), Color.white],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .cornerRadius(20)
        .shadow(color: .black.opacity(0.05), radius: 10, y: 3)
    }
}

// MARK: - Calorie card

struct CalorieCard: View {
    @EnvironmentObject var appState: AppState

    var netCalories: Int { appState.caloriesConsumed - appState.caloriesBurned }
    var calorieProgress: Double {
        min(1.0, Double(max(0, netCalories)) / Double(max(appState.caloriesTarget, 1)))
    }

    var body: some View {
        HStack(spacing: 20) {
            // Ring
            ZStack {
                Circle()
                    .stroke(Color(hex: "F0E6DA"), lineWidth: 10)
                    .frame(width: 88, height: 88)
                Circle()
                    .trim(from: 0, to: calorieProgress)
                    .stroke(
                        LinearGradient(
                            colors: [Color(hex: "E76F51"), Color(hex: "F4A261")],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        style: StrokeStyle(lineWidth: 10, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                    .frame(width: 88, height: 88)
                    .animation(.spring(), value: calorieProgress)
                VStack(spacing: 1) {
                    Text("\(appState.caloriesConsumed)")
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .foregroundColor(Color(hex: "3D2B1F"))
                    Text("/ \(appState.caloriesTarget)")
                        .font(.system(size: 9))
                        .foregroundColor(Color(hex: "B09880"))
                    Text("kcal")
                        .font(.system(size: 8, weight: .medium))
                        .foregroundColor(Color(hex: "C47A5A"))
                }
            }

            // Stats
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 6) {
                    Image(systemName: "fork.knife")
                        .font(.system(size: 10))
                        .foregroundColor(Color(hex: "E76F51"))
                    Text("CALORIES TODAY")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(Color(hex: "B09880"))
                        .kerning(0.8)
                }
                statRow(label: "Eaten",  value: "\(appState.caloriesConsumed) kcal", dot: Color(hex: "E76F51"))
                statRow(label: "Burned", value: "\(appState.caloriesBurned) kcal",   dot: Color(hex: "2A9D8F"))
                Divider()
                statRow(label: "Net",    value: "\(netCalories) kcal", bold: true)
            }

            Spacer(minLength: 0)
        }
        .padding(18)
        .background(Color.white)
        .cornerRadius(20)
        .shadow(color: .black.opacity(0.05), radius: 10, y: 3)
    }

    @ViewBuilder
    private func statRow(label: String, value: String, bold: Bool = false, dot: Color? = nil) -> some View {
        HStack(spacing: 6) {
            if let dot {
                Circle()
                    .fill(dot)
                    .frame(width: 6, height: 6)
            }
            Text(label)
                .font(.system(size: 12))
                .foregroundColor(Color(hex: "B09880"))
            Spacer()
            Text(value)
                .font(.system(size: 12, weight: bold ? .bold : .medium, design: .rounded))
                .foregroundColor(Color(hex: "3D2B1F"))
        }
    }
}

// MARK: - Wide stat tile

struct WideStatTile: View {
    let icon: String
    let value: String
    let label: String
    let iconColor: Color
    let progress: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(iconColor.opacity(0.12))
                    .frame(width: 32, height: 32)
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(iconColor)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(value)
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundColor(Color(hex: "3D2B1F"))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text(label)
                    .font(.system(size: 10))
                    .foregroundColor(Color(hex: "B09880"))
                    .lineLimit(1)
            }

            if let progress {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(iconColor.opacity(0.12))
                            .frame(height: 3)
                        RoundedRectangle(cornerRadius: 3)
                            .fill(iconColor)
                            .frame(width: geo.size.width * min(1, progress), height: 3)
                            .animation(.spring(), value: progress)
                    }
                }
                .frame(height: 3)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color.white)
        .cornerRadius(16)
        .shadow(color: .black.opacity(0.04), radius: 6, y: 2)
    }
}

// MARK: - Nudge strip

struct NudgeStrip: View {
    @EnvironmentObject var appState: AppState

    private var proteinRemaining: Int { max(0, appState.proteinTargetG - appState.proteinConsumedG) }
    private var waterRemaining: Int { max(0, 8 - appState.waterGlasses) }
    private var proteinPct: Double { Double(appState.proteinConsumedG) / Double(max(appState.proteinTargetG, 1)) }

    private var showProteinNudge: Bool { proteinRemaining > 0 && appState.proteinTargetG > 0 }
    private var showWaterNudge: Bool { waterRemaining > 0 }

    var body: some View {
        if showProteinNudge || showWaterNudge {
            VStack(spacing: 8) {
                if showProteinNudge {
                    NudgeBanner(
                        icon: "p.circle.fill",
                        iconColor: Color(hex: "2A9D8F"),
                        message: proteinNudgeText,
                        progress: proteinPct,
                        progressColor: Color(hex: "2A9D8F")
                    )
                }
                if showWaterNudge {
                    NudgeBanner(
                        icon: "drop.fill",
                        iconColor: Color(hex: "457B9D"),
                        message: waterNudgeText,
                        progress: Double(appState.waterGlasses) / 8.0,
                        progressColor: Color(hex: "457B9D")
                    )
                }
            }
        }
    }

    private var proteinNudgeText: String {
        let remaining = proteinRemaining
        let pct = Int(proteinPct * 100)
        if pct == 0 {
            return "You haven't hit any protein yet — aim for \(appState.proteinTargetG)g today"
        } else if remaining > 30 {
            return "\(remaining)g protein to go — add chicken, eggs or legumes to your next meal"
        } else {
            return "Almost there! Just \(remaining)g more protein to hit your \(appState.proteinTargetG)g goal"
        }
    }

    private var waterNudgeText: String {
        switch waterRemaining {
        case 7, 8: return "You haven't had any water yet today — start with a glass now"
        case 4...6: return "\(waterRemaining) more glasses of water to reach your daily goal"
        case 1...3: return "Nearly there! Just \(waterRemaining) more glass\(waterRemaining > 1 ? "es" : "") of water to go"
        default:    return "Keep drinking water!"
        }
    }
}

struct NudgeBanner: View {
    let icon: String
    let iconColor: Color
    let message: String
    let progress: Double
    let progressColor: Color

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 16))
                .foregroundColor(iconColor)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 5) {
                Text(message)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(Color(hex: "3D2B1F"))
                    .fixedSize(horizontal: false, vertical: true)

                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(progressColor.opacity(0.15))
                            .frame(height: 4)
                        RoundedRectangle(cornerRadius: 3)
                            .fill(progressColor)
                            .frame(width: geo.size.width * min(1, progress), height: 4)
                            .animation(.spring(), value: progress)
                    }
                }
                .frame(height: 4)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(progressColor.opacity(0.06))
        .cornerRadius(14)
    }
}

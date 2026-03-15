import SwiftUI

struct GoalView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var voice: VoiceManager

    @State private var goalData: GoalResponse? = nil
    @State private var isLoading = true
    @State private var isVoiceConnected = false
    @State private var isRefreshingImage = false

    var body: some View {
        ZStack {
            Color(hex: "F7F3EE").ignoresSafeArea()

            if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let goal = goalData {
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 16) {

                        // ── Vision board image ──────────────────
                        VisionBoardCard(
                            imageUrl: goal.imageUrl,
                            goalText: goal.goal,
                            isRefreshing: isRefreshingImage,
                            onRefresh: { Task { await refreshImage() } }
                        )

                        // ── Goal detail card ────────────────────
                        GoalDetailCard(goal: goal)

                        // ── Progress card ───────────────────────
                        if goal.goalType != "event" {
                            GoalProgressCard(goal: goal)
                        }

                        // ── Talk to Rena ─────────────────────────
                        GoalVoiceCard(
                            isActive: isVoiceConnected,
                            voiceState: voice.state,
                            onTap: toggleVoice
                        )

                        Spacer(minLength: 40)
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 12)
                }
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "star.slash")
                        .font(.system(size: 40))
                        .foregroundColor(Color(hex: "C4A882"))
                    Text("No goal set yet")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(Color(hex: "3D2B1F"))
                    Text("Tell Rena what you're working toward")
                        .font(.system(size: 14))
                        .foregroundColor(Color(hex: "B09880"))
                }
            }
        }
        .navigationTitle("My Journey")
        .navigationBarTitleDisplayMode(.large)
        .onAppear { Task { await loadGoal() } }
        .onDisappear { if isVoiceConnected { toggleVoice() } }
        .refreshable { await loadGoal() }
    }

    private func toggleVoice() {
        if isVoiceConnected {
            voice.disconnect()
            isVoiceConnected = false
        } else {
            let name = appState.name.components(separatedBy: " ").first ?? appState.name
            voice.connect(userId: appState.userId, context: "goal", name: name)
            isVoiceConnected = true
        }
    }

    private func loadGoal() async {
        await MainActor.run { isLoading = true }
        let data = try? await RenaAPI.shared.getGoal(userId: appState.userId)
        await MainActor.run { goalData = data; isLoading = false }
    }

    private func refreshImage() async {
        await MainActor.run { isRefreshingImage = true }
        let data = try? await RenaAPI.shared.refreshGoalImage(userId: appState.userId)
        await MainActor.run {
            if let data { goalData = data }
            isRefreshingImage = false
        }
    }
}

// MARK: - Vision board hero

struct VisionBoardCard: View {
    let imageUrl: String?
    let goalText: String
    var isRefreshing: Bool = false
    var onRefresh: (() -> Void)? = nil

    var body: some View {
        ZStack(alignment: .bottom) {
            Group {
                if let urlStr = imageUrl, let url = URL(string: urlStr) {
                    AsyncImage(url: url) { phase in
                        switch phase {
                        case .success(let image):
                            image
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                        case .failure:
                            placeholderGradient
                        default:
                            ZStack {
                                placeholderGradient
                                ProgressView().tint(.white)
                            }
                        }
                    }
                } else {
                    placeholderGradient
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 300)
            .clipped()

            // Gradient overlay
            LinearGradient(
                colors: [Color.clear, Color.black.opacity(0.6)],
                startPoint: .center,
                endPoint: .bottom
            )
            .frame(height: 180)

            // Bottom: goal text + refresh button
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("YOUR VISION")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.white.opacity(0.7))
                        .kerning(1.2)
                    Text(goalText)
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                        .lineLimit(2)
                        .shadow(radius: 4)
                }
                Spacer()
                if let onRefresh {
                    Button(action: onRefresh) {
                        ZStack {
                            Circle()
                                .fill(Color.black.opacity(0.35))
                                .frame(width: 36, height: 36)
                            if isRefreshing {
                                ProgressView()
                                    .tint(.white)
                                    .scaleEffect(0.75)
                            } else {
                                Image(systemName: "arrow.clockwise")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundColor(.white)
                            }
                        }
                    }
                    .disabled(isRefreshing)
                }
            }
            .padding(20)
        }
        .cornerRadius(22)
        .shadow(color: .black.opacity(0.12), radius: 14, y: 5)
    }

    private var placeholderGradient: some View {
        LinearGradient(
            colors: [Color(hex: "F4A261"), Color(hex: "E76F51")],
            startPoint: .topLeading, endPoint: .bottomTrailing
        )
    }
}

// MARK: - Goal detail card

struct GoalDetailCard: View {
    let goal: GoalResponse

    private var goalIcon: String {
        switch goal.goalType {
        case "weight_loss":  return "scalemass"
        case "weight_gain":  return "dumbbell"
        case "fitness":      return "figure.run"
        case "habit":        return "checkmark.circle"
        default:
            let t = goal.goal.lowercased()
            if t.contains("wedding") || t.contains("confident") { return "star" }
            if t.contains("swim") { return "figure.pool.swim" }
            return "figure.walk"
        }
    }

    private var goalColor: Color {
        switch goal.goalType {
        case "weight_loss": return Color(hex: "9B7EC8")
        case "weight_gain": return Color(hex: "2A9D8F")
        case "fitness":     return Color(hex: "457B9D")
        case "habit":       return Color(hex: "E9C46A")
        default:            return Color(hex: "E76F51")
        }
    }

    private var formattedDeadline: String {
        let fmt = DateFormatter(); fmt.dateFormat = "yyyy-MM-dd"
        guard let date = fmt.date(from: goal.deadline) else { return goal.deadline }
        fmt.dateFormat = "MMMM d, yyyy"
        return fmt.string(from: date)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 9)
                        .fill(goalColor.opacity(0.14))
                        .frame(width: 36, height: 36)
                    Image(systemName: goalIcon)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(goalColor)
                }
                Text("GOAL")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(Color(hex: "B09880"))
                    .kerning(1.0)
                Spacer()
                if goal.daysUntilGoal > 0 {
                    HStack(spacing: 4) {
                        Image(systemName: "calendar")
                            .font(.system(size: 10))
                        Text("\(goal.daysUntilGoal) days left")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .foregroundColor(goalColor)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(goalColor.opacity(0.12))
                    .cornerRadius(20)
                }
            }

            Text(goal.goal)
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .foregroundColor(Color(hex: "3D2B1F"))
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 6) {
                Image(systemName: "flag.fill")
                    .font(.system(size: 10))
                    .foregroundColor(Color(hex: "B09880"))
                Text(formattedDeadline)
                    .font(.system(size: 12))
                    .foregroundColor(Color(hex: "B09880"))
            }
        }
        .padding(18)
        .background(
            LinearGradient(
                colors: [goalColor.opacity(0.07), Color.white],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
        )
        .cornerRadius(20)
        .shadow(color: .black.opacity(0.05), radius: 10, y: 3)
    }
}

// MARK: - Goal progress card

struct GoalProgressCard: View {
    let goal: GoalResponse

    private var progressColor: Color {
        switch goal.goalType {
        case "weight_loss": return Color(hex: "9B7EC8")
        case "weight_gain": return Color(hex: "2A9D8F")
        case "fitness":     return Color(hex: "457B9D")
        default:            return Color(hex: "E76F51")
        }
    }

    private var unitLabel: String { goal.unit.isEmpty ? "" : goal.unit }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 7)
                        .fill(progressColor.opacity(0.12))
                        .frame(width: 26, height: 26)
                    Image(systemName: "chart.line.uptrend.xyaxis")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(progressColor)
                }
                Text("PROGRESS")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(Color(hex: "B09880"))
                    .kerning(1.0)
                Spacer()
                Text("\(goal.progressPercent)%")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(progressColor)
            }

            // Progress bar
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 5)
                        .fill(progressColor.opacity(0.12))
                        .frame(height: 10)
                    RoundedRectangle(cornerRadius: 5)
                        .fill(LinearGradient(
                            colors: [progressColor, progressColor.opacity(0.7)],
                            startPoint: .leading, endPoint: .trailing
                        ))
                        .frame(width: geo.size.width * Double(goal.progressPercent) / 100.0, height: 10)
                        .animation(.spring(), value: goal.progressPercent)
                }
            }
            .frame(height: 10)

            if !goal.progressLabel.isEmpty {
                Text(goal.progressLabel)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(progressColor)
            }

            // Start / Now / Target
            HStack(spacing: 0) {
                statColumn(label: "Started", value: formattedValue(goal.startValue), sub: unitLabel)
                Divider().frame(height: 44)
                statColumn(label: "Now", value: formattedValue(goal.currentValue), sub: unitLabel, highlight: progressColor)
                Divider().frame(height: 44)
                statColumn(label: "Target", value: formattedValue(goal.targetValue), sub: unitLabel)
            }
        }
        .padding(18)
        .background(Color.white)
        .cornerRadius(20)
        .shadow(color: .black.opacity(0.05), radius: 10, y: 3)
    }

    @ViewBuilder
    private func statColumn(label: String, value: String, sub: String, highlight: Color? = nil) -> some View {
        VStack(spacing: 3) {
            Text(label)
                .font(.system(size: 10))
                .foregroundColor(Color(hex: "B09880"))
            Text(value)
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .foregroundColor(highlight ?? Color(hex: "3D2B1F"))
            if !sub.isEmpty {
                Text(sub)
                    .font(.system(size: 10))
                    .foregroundColor(Color(hex: "B09880"))
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func formattedValue(_ v: Double) -> String {
        v == v.rounded() ? "\(Int(v))" : String(format: "%.1f", v)
    }
}

// MARK: - Voice card

struct GoalVoiceCard: View {
    let isActive: Bool
    let voiceState: VoiceState
    let onTap: () -> Void

    private var stateLabel: String {
        if !isActive { return "Talk to Rena about your goal" }
        switch voiceState {
        case .connecting: return "Connecting…"
        case .listening:  return "Listening…"
        case .thinking:   return "Thinking…"
        case .speaking:   return "Rena is speaking…"
        default:          return "Tap to end"
        }
    }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(isActive ? Color.white.opacity(0.25) : Color(hex: "E76F51").opacity(0.12))
                        .frame(width: 36, height: 36)
                    Image(systemName: isActive ? "waveform" : "waveform")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(isActive ? .white : Color(hex: "E76F51"))
                        .symbolEffect(.variableColor.iterative, isActive: isActive)
                }
                Text(stateLabel)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(isActive ? .white : Color(hex: "E76F51"))
                Spacer()
                if isActive {
                    Text("Tap to end")
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.7))
                }
            }
            .padding(16)
            .background(
                isActive
                    ? AnyView(LinearGradient(colors: [Color(hex: "E76F51"), Color(hex: "F4A261")], startPoint: .leading, endPoint: .trailing))
                    : AnyView(Color.white)
            )
            .cornerRadius(18)
            .shadow(color: isActive ? Color(hex: "E76F51").opacity(0.3) : Color.black.opacity(0.05), radius: 10, y: 3)
            .animation(.easeInOut(duration: 0.2), value: isActive)
        }
        .buttonStyle(.plain)
    }
}

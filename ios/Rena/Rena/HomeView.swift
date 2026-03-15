import SwiftUI

struct HomeView: View {
    @Binding var selectedTab: Int
    @Binding var showRena: Bool

    @EnvironmentObject var appState: AppState
    @EnvironmentObject var voice: VoiceManager

    @State private var goalData: GoalResponse? = nil
    @State private var isLoadingGoal = false
    @State private var insight: String = ""
    @State private var isInsightLoading = false
    @State private var showWeightSheet = false
    @State private var waterPulse = false

    var body: some View {
        NavigationView {
        ZStack {
            Color(hex: "F7F3EE").ignoresSafeArea()

            VStack(spacing: 0) {

                AppHeader()

                // ── Scrollable cards ───────────────────────────────
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 12) {

                        // ── Quick log row ──────────────────────────
                        QuickLogRow(
                            onMeal:    { selectedTab = 3 },
                            onWater:   { Task { await addWater() } },
                            onWeight:  { showWeightSheet = true },
                            onWorkout: { selectedTab = 2 },
                            waterGlasses: appState.waterGlasses,
                            waterPulse: waterPulse
                        )

                        GoalCard(goal: goalData, isLoading: isLoadingGoal)

                        DayCalorieBreakdownCard(
                            caloriesConsumed: appState.caloriesConsumed,
                            caloriesBurned: appState.caloriesBurned,
                            caloriesTarget: appState.caloriesTarget,
                            burnRequired: appState.burnRequired
                        )

                        // ── Protein + water stats bar ──────────────
                        DailyStatsBar(
                            proteinConsumed: appState.proteinConsumedG,
                            proteinTarget: appState.proteinTargetG,
                            water: appState.waterGlasses,
                            onAddWater: { Task { await addWater() } }
                        )

                        DaySoFarCard(insight: insight, isLoading: isInsightLoading, isToday: true)
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 12)
                }
            }
        }
        .navigationBarHidden(true)
        .onAppear { Task { await loadGoal(); await loadProgress(); await loadInsight() } }
        .onChange(of: voice.turnCount) { Task { await loadProgress(); await loadInsight() } }
        .sheet(isPresented: $showWeightSheet) {
            LogWeightSheet(isPresented: $showWeightSheet) { kg in
                Task { await saveWeight(kg) }
            }
        }
        } // NavigationView
    }

    // MARK: - Actions

    private func addWater() async {
        let newTotal = (try? await RenaAPI.shared.logWater(userId: appState.userId)) ?? (appState.waterGlasses + 1)
        await MainActor.run {
            appState.waterGlasses = newTotal
            withAnimation(.spring(response: 0.3, dampingFraction: 0.5)) { waterPulse = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { waterPulse = false }
        }
    }

    private func saveWeight(_ kg: Double) async {
        _ = try? await RenaAPI.shared.logWeight(userId: appState.userId, weightKg: kg)
        await MainActor.run { appState.todayWeightKg = kg }
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
        let resp = try? await RenaAPI.shared.getGoal(userId: appState.userId)
        await MainActor.run { goalData = resp; isLoadingGoal = false }
    }

    private func loadInsight() async {
        await MainActor.run { isInsightLoading = true }
        let result = try? await RenaAPI.shared.getWorkbookInsight(userId: appState.userId, date: nil)
        await MainActor.run {
            insight = result?.insight ?? ""
            isInsightLoading = false
        }
    }

}

// MARK: - Quick Log Row

struct QuickLogRow: View {
    let onMeal: () -> Void
    let onWater: () -> Void
    let onWeight: () -> Void
    let onWorkout: () -> Void
    let waterGlasses: Int
    let waterPulse: Bool

    var body: some View {
        HStack(spacing: 10) {
            QuickLogPill(icon: "camera.viewfinder", label: "Log Meal",
                         color: Color(hex: "E76F51"), action: onMeal)
            QuickLogPill(icon: "drop.fill",
                         label: "\(waterGlasses)/8",
                         color: Color(hex: "457B9D"),
                         action: onWater,
                         pulse: waterPulse)
            QuickLogPill(icon: "scalemass", label: "Weight",
                         color: Color(hex: "9B7EC8"), action: onWeight)
            QuickLogPill(icon: "figure.run", label: "Workout",
                         color: Color(hex: "2A9D8F"), action: onWorkout)
        }
    }
}

struct QuickLogPill: View {
    let icon: String
    let label: String
    let color: Color
    let action: () -> Void
    var pulse: Bool = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(color.opacity(0.13))
                        .frame(width: 44, height: 44)
                    Image(systemName: icon)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(color)
                }
                .scaleEffect(pulse ? 1.18 : 1.0)
                Text(label)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Color(hex: "5C3D2E"))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(Color.white)
            .cornerRadius(14)
            .shadow(color: .black.opacity(0.04), radius: 5, y: 2)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Daily Stats Bar (protein + water)

struct DailyStatsBar: View {
    let proteinConsumed: Int
    let proteinTarget: Int
    let water: Int
    let onAddWater: () -> Void

    private var proteinPct: Double { min(1.0, Double(proteinConsumed) / Double(max(proteinTarget, 1))) }
    private var waterPct: Double { min(1.0, Double(water) / 8.0) }

    var body: some View {
        HStack(spacing: 12) {
            // Protein
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 5) {
                    Image(systemName: "p.circle.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(Color(hex: "2A9D8F"))
                    Text("PROTEIN")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(Color(hex: "B09880"))
                        .kerning(0.8)
                    Spacer()
                    Text("\(proteinConsumed)/\(proteinTarget)g")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundColor(Color(hex: "2A9D8F"))
                }
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 3).fill(Color(hex: "2A9D8F").opacity(0.12)).frame(height: 5)
                        RoundedRectangle(cornerRadius: 3).fill(Color(hex: "2A9D8F"))
                            .frame(width: geo.size.width * proteinPct, height: 5)
                            .animation(.spring(), value: proteinPct)
                    }
                }
                .frame(height: 5)
            }
            .frame(maxWidth: .infinity)
            .padding(12)
            .background(Color.white)
            .cornerRadius(14)
            .shadow(color: .black.opacity(0.04), radius: 5, y: 2)

            // Water — tappable to add a glass
            Button(action: onAddWater) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 5) {
                        Image(systemName: "drop.fill")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(Color(hex: "457B9D"))
                        Text("WATER")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundColor(Color(hex: "B09880"))
                            .kerning(0.8)
                        Spacer()
                        Text("\(water)/8")
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                            .foregroundColor(Color(hex: "457B9D"))
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 13))
                            .foregroundColor(Color(hex: "457B9D").opacity(0.7))
                    }
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 3).fill(Color(hex: "457B9D").opacity(0.12)).frame(height: 5)
                            RoundedRectangle(cornerRadius: 3).fill(Color(hex: "457B9D"))
                                .frame(width: geo.size.width * waterPct, height: 5)
                                .animation(.spring(), value: waterPct)
                        }
                    }
                    .frame(height: 5)
                }
                .frame(maxWidth: .infinity)
                .padding(12)
                .background(Color.white)
                .cornerRadius(14)
                .shadow(color: .black.opacity(0.04), radius: 5, y: 2)
            }
            .buttonStyle(.plain)
        }
    }
}

// MARK: - Log Weight Sheet

struct LogWeightSheet: View {
    @Binding var isPresented: Bool
    let onSave: (Double) -> Void

    @EnvironmentObject var appState: AppState
    @State private var weightText: String = ""
    @FocusState private var isFocused: Bool

    private var parsedWeight: Double? { Double(weightText.replacingOccurrences(of: ",", with: ".")) }

    var body: some View {
        VStack(spacing: 0) {
            // Handle
            RoundedRectangle(cornerRadius: 3)
                .fill(Color(hex: "D4B8A0"))
                .frame(width: 36, height: 4)
                .padding(.top, 12)
                .padding(.bottom, 20)

            Text("Log Weight")
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .foregroundColor(Color(hex: "3D2B1F"))

            if let current = appState.todayWeightKg {
                Text("Last logged: \(String(format: "%.1f", current)) kg")
                    .font(.system(size: 13))
                    .foregroundColor(Color(hex: "B09880"))
                    .padding(.top, 4)
            }

            Spacer().frame(height: 32)

            // Big weight input
            HStack(alignment: .lastTextBaseline, spacing: 6) {
                TextField(String(format: "%.1f", appState.todayWeightKg ?? 70.0), text: $weightText)
                    .font(.system(size: 56, weight: .bold, design: .rounded))
                    .foregroundColor(Color(hex: "3D2B1F"))
                    .multilineTextAlignment(.center)
                    .keyboardType(.decimalPad)
                    .focused($isFocused)
                    .frame(maxWidth: 180)
                Text("kg")
                    .font(.system(size: 24, weight: .medium))
                    .foregroundColor(Color(hex: "B09880"))
            }
            .padding(.vertical, 24)
            .padding(.horizontal, 32)
            .background(Color(hex: "F7F3EE"))
            .cornerRadius(20)
            .padding(.horizontal, 32)

            Spacer().frame(height: 28)

            Button {
                if let kg = parsedWeight, kg > 20, kg < 300 {
                    onSave(kg)
                    isPresented = false
                }
            } label: {
                Text("Save Weight")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(
                        parsedWeight != nil
                            ? Color(hex: "9B7EC8")
                            : Color(hex: "D4B8A0")
                    )
                    .cornerRadius(16)
            }
            .disabled(parsedWeight == nil)
            .padding(.horizontal, 32)

            Button("Cancel") { isPresented = false }
                .font(.system(size: 14))
                .foregroundColor(Color(hex: "B09880"))
                .padding(.top, 14)
                .padding(.bottom, 32)
        }
        .background(Color.white)
        .presentationDetents([.height(420)])
        .presentationDragIndicator(.hidden)
        .onAppear { isFocused = true }
    }
}

// MARK: - Shared app header (used on all main tabs)

struct AppHeader: View {
    @EnvironmentObject var appState: AppState

    private var greeting: String {
        let h = Calendar.current.component(.hour, from: Date())
        if h < 12 { return "Good morning" }
        if h < 17 { return "Good afternoon" }
        return "Good evening"
    }

    private var dateString: String {
        let f = DateFormatter()
        f.dateFormat = "EEE, MMM d"
        return f.string(from: Date())
    }

    var body: some View {
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
            Text(dateString)
                .font(.system(size: 13))
                .foregroundColor(Color(hex: "B09880"))
        }
        .padding(.horizontal, 24)
        .padding(.top, 56)
        .padding(.bottom, 16)
    }
}

// MARK: - Goal card

struct GoalCard: View {
    let goal: GoalResponse?
    let isLoading: Bool

    private var goalType: String   { goal?.goalType ?? "event" }
    private var goalText: String   { goal?.goal ?? "" }
    private var daysLeft: Int      { goal?.daysUntilGoal ?? 0 }
    private var pct: Int           { goal?.progressPercent ?? 0 }
    private var label: String      { goal?.progressLabel ?? "" }
    private var showProgress: Bool { goalType != "event" && goal != nil }

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

            // ── Header ──────────────────────────────────────────────
            HStack(spacing: 10) {
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

            // ── Goal text ────────────────────────────────────────────
            Text(isLoading ? "Loading…" : (goalText.isEmpty ? "Set your goal" : goalText))
                .font(.system(size: 19, weight: .bold, design: .rounded))
                .foregroundColor(Color(hex: "3D2B1F"))
                .fixedSize(horizontal: false, vertical: true)
                .lineLimit(2)

            // ── Progress ─────────────────────────────────────────────
            if showProgress {
                VStack(alignment: .leading, spacing: 10) {
                    // Bar + percentage
                    HStack(spacing: 8) {
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(goalColor.opacity(0.12))
                                    .frame(height: 7)
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(goalColor)
                                    .frame(width: geo.size.width * Double(pct) / 100.0, height: 7)
                                    .animation(.spring(), value: pct)
                            }
                        }
                        .frame(height: 7)
                        Text("\(pct)%")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(goalColor)
                            .frame(width: 36, alignment: .trailing)
                    }

                    // Start / Now / Target
                    if let g = goal, g.targetValue > 0 {
                        HStack(spacing: 0) {
                            statCol(label: "Started", value: fmtVal(g.startValue), unit: g.unit)
                            Divider().frame(height: 34)
                            statCol(label: "Now",     value: fmtVal(g.currentValue), unit: g.unit, color: goalColor)
                            Divider().frame(height: 34)
                            statCol(label: "Target",  value: fmtVal(g.targetValue), unit: g.unit)
                        }
                    }

                    if !label.isEmpty {
                        Text(label)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(goalColor)
                    }
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

    private func statCol(label: String, value: String, unit: String, color: Color? = nil) -> some View {
        VStack(spacing: 2) {
            Text(label)
                .font(.system(size: 9))
                .foregroundColor(Color(hex: "B09880"))
            HStack(alignment: .lastTextBaseline, spacing: 2) {
                Text(value)
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .foregroundColor(color ?? Color(hex: "3D2B1F"))
                if !unit.isEmpty {
                    Text(unit)
                        .font(.system(size: 9))
                        .foregroundColor(Color(hex: "B09880"))
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func fmtVal(_ v: Double) -> String {
        v == v.rounded() ? "\(Int(v))" : String(format: "%.1f", v)
    }
}

// MARK: - Calorie card (unused but kept for reference)

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

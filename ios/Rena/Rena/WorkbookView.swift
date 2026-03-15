import SwiftUI

struct WorkbookView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var voice: VoiceManager

    @State private var selectedDate = Date()
    @State private var dayData: ProgressResponse? = nil
    @State private var insight: String = ""
    @State private var activity: String = ""
    @State private var isLoading = false
    @State private var activeContext: String? = nil
    @State private var isVoiceConnected = false
    @State private var workoutPlan: PlannedWorkout? = nil
    @State private var isGeneratingPlan = false
    @State private var logSheet: PlannedExercise? = nil
    @State private var videoSheet: PlannedExercise? = nil

    private var isToday: Bool { Calendar.current.isDateInToday(selectedDate) }

    private var displayMeals: [MealEntry]    { dayData?.mealsLogged    ?? (isToday ? appState.mealsLogged    : []) }
    private var displayWorkouts: [WorkoutEntry] { dayData?.workoutsLogged ?? (isToday ? appState.workoutsLogged : []) }
    private var displayConsumed: Int  { dayData?.caloriesConsumed ?? (isToday ? appState.caloriesConsumed : 0) }
    private var displayTarget: Int    { dayData?.caloriesTarget   ?? (isToday ? appState.caloriesTarget   : 1800) }
    private var displayBurned: Int    { dayData?.caloriesBurned   ?? (isToday ? appState.caloriesBurned   : 0) }

    private var hour: Int { Calendar.current.component(.hour, from: Date()) }
    private var isMorning: Bool  { isToday && hour >= 5  && hour < 12 }
    private var isEvening: Bool  { isToday && hour >= 17 }

    private var dateString: String {
        let fmt = DateFormatter(); fmt.dateFormat = "yyyy-MM-dd"
        fmt.timeZone = TimeZone(identifier: "UTC")
        return fmt.string(from: selectedDate)
    }
    private var dateLabel: String {
        if isToday { return "Today" }
        if Calendar.current.isDateInYesterday(selectedDate) { return "Yesterday" }
        let fmt = DateFormatter(); fmt.dateFormat = "EEE, MMM d"
        return fmt.string(from: selectedDate)
    }
    private var greeting: String {
        if !isToday { return dateLabel }
        if isMorning { return "Good morning" }
        if isEvening { return "Good evening" }
        return "Good afternoon"
    }

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 16) {

                    // ── Date navigation ────────────────────────────
                    HStack(spacing: 16) {
                        Button {
                            selectedDate = Calendar.current.date(byAdding: .day, value: -1, to: selectedDate)!
                            Task { await loadDay() }
                        } label: {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundColor(Color(hex: "E76F51"))
                        }
                        Spacer()
                        Text(dateLabel)
                            .font(.system(size: 17, weight: .bold))
                            .foregroundColor(Color(hex: "3D2B1F"))
                            .contentTransition(.numericText())
                            .animation(.spring(duration: 0.2), value: dateLabel)
                        Spacer()
                        Button {
                            selectedDate = Calendar.current.date(byAdding: .day, value: 1, to: selectedDate)!
                            Task { await loadDay() }
                        } label: {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundColor(isToday ? Color(hex: "D4B8A0") : Color(hex: "E76F51"))
                        }
                        .disabled(isToday)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(Color.white)
                    .cornerRadius(16)
                    .shadow(color: .black.opacity(0.04), radius: 6, y: 2)

                    // ── Header ─────────────────────────────────────
                    WorkbookHeader(
                        greeting: greeting,
                        name: appState.name.components(separatedBy: " ").first ?? appState.name,
                        isMorning: isMorning,
                        isEvening: isEvening,
                        caloriesConsumed: displayConsumed,
                        caloriesTarget: displayTarget,
                        caloriesBurned: displayBurned
                    )

                    // ── Day insight (AI) ───────────────────────────
                    DaySoFarCard(
                        insight: insight,
                        isLoading: isLoading,
                        isToday: isToday
                    )

                    // ── Voice cards — today only ───────────────────
                    if isToday {
                        WorkbookVoiceCard(
                            icon: "figure.run",
                            iconColor: Color(hex: "2A9D8F"),
                            title: "Today's Workout",
                            subtitle: "Let Rena suggest a workout tailored to your goal",
                            buttonLabel: "Plan with Rena",
                            isActive: activeContext == "workout_plan" && isVoiceConnected,
                            voiceState: activeContext == "workout_plan" ? voice.state : .idle,
                            onTap: { toggleVoice(context: "workout_plan") }
                        )
                        if isEvening {
                            WorkbookVoiceCard(
                                icon: "moon.stars.fill",
                                iconColor: Color(hex: "9B7EC8"),
                                title: "Plan Tomorrow",
                                subtitle: "Review today with Rena and set tomorrow's targets",
                                buttonLabel: "Plan with Rena",
                                isActive: activeContext == "plan_tomorrow" && isVoiceConnected,
                                voiceState: activeContext == "plan_tomorrow" ? voice.state : .idle,
                                onTap: { toggleVoice(context: "plan_tomorrow") }
                            )
                        }
                    }

                    // ── Planned workout — today only ───────────────
                    if isToday {
                        PlannedWorkoutCard(
                            plan: workoutPlan,
                            isGenerating: isGeneratingPlan,
                            onGenerate: { Task { await generatePlan() } },
                            onToggleComplete: { ex in Task { await toggleComplete(ex) } },
                            onPlay: { ex in videoSheet = ex },
                            onLog: { ex in logSheet = ex }
                        )
                    }

                    // ── Activity summary ───────────────────────────
                    TodayActivityCard(
                        aiSummary: activity,
                        isLoading: isLoading,
                        meals: displayMeals,
                        workouts: displayWorkouts
                    )

                    Spacer(minLength: 40)
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
            }
            .background(Color(hex: "F7F3EE").ignoresSafeArea())
            .navigationTitle("Workbook")
            .navigationBarTitleDisplayMode(.large)
            .scrollBounceBehavior(.always)
            .refreshable { await loadDay() }
            .onAppear { Task { await loadDay() } }
            .onDisappear { if isVoiceConnected { endVoice() } }
            .onChange(of: voice.turnCount) { if isToday { Task { await loadDay() } } }
            .sheet(item: $logSheet) { ex in
                LogExerciseSheet(exercise: ex, userId: appState.userId, dateString: dateString)
            }
            .sheet(item: $videoSheet) { ex in
                ExerciseVideoSheet(exercise: ex)
            }
        }
    }

    // MARK: - Voice

    private func toggleVoice(context: String) {
        if isVoiceConnected && activeContext == context {
            endVoice()
        } else {
            if isVoiceConnected { endVoice() }
            activeContext = context
            let name = appState.name.components(separatedBy: " ").first ?? appState.name
            voice.connect(userId: appState.userId, context: context, name: name)
            isVoiceConnected = true
        }
    }

    private func endVoice() {
        voice.disconnect()
        isVoiceConnected = false
        activeContext = nil
    }

    // MARK: - Workout Plan

    private func generatePlan() async {
        await MainActor.run { isGeneratingPlan = true }
        let plan = try? await RenaAPI.shared.generateWorkoutPlan(userId: appState.userId)
        await MainActor.run { workoutPlan = plan; isGeneratingPlan = false }
    }

    private func toggleComplete(_ exercise: PlannedExercise) async {
        try? await RenaAPI.shared.toggleExerciseComplete(
            userId: appState.userId, exerciseId: exercise.id, date: dateString)
        let plan = try? await RenaAPI.shared.getWorkoutPlan(userId: appState.userId, date: dateString)
        await MainActor.run { workoutPlan = plan }
    }

    // MARK: - Data

    private func loadDay() async {
        await MainActor.run { isLoading = true; insight = ""; activity = "" }
        let date = isToday ? nil : dateString
        async let progressTask = RenaAPI.shared.getProgress(userId: appState.userId, date: dateString)
        async let insightTask  = RenaAPI.shared.getWorkbookInsight(userId: appState.userId, date: date)
        async let planTask     = RenaAPI.shared.getWorkoutPlan(userId: appState.userId, date: isToday ? nil : dateString)
        let progress = try? await progressTask
        let result   = try? await insightTask
        let plan     = try? await planTask
        await MainActor.run {
            dayData     = progress
            workoutPlan = plan
            if let r = result {
                insight  = r.insight
                activity = r.activity
            }
            isLoading = false
        }
    }
}

// MARK: - Header card

struct WorkbookHeader: View {
    let greeting: String
    let name: String
    let isMorning: Bool
    let isEvening: Bool
    let caloriesConsumed: Int
    let caloriesTarget: Int
    let caloriesBurned: Int

    private var netCalories: Int { caloriesConsumed - caloriesBurned }
    private var remaining: Int   { max(0, caloriesTarget - netCalories) }
    private var progress: Double { min(1.0, Double(max(0, netCalories)) / Double(max(caloriesTarget, 1))) }

    private var phaseIcon: String {
        if isMorning { return "sun.rise.fill" }
        if isEvening { return "moon.fill" }
        return "sun.max.fill"
    }
    private var phaseColor: Color {
        if isMorning { return Color(hex: "F4A261") }
        if isEvening { return Color(hex: "9B7EC8") }
        return Color(hex: "E9C46A")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: phaseIcon)
                    .font(.system(size: 18))
                    .foregroundColor(phaseColor)
                VStack(alignment: .leading, spacing: 1) {
                    Text(greeting)
                        .font(.system(size: 13))
                        .foregroundColor(Color(hex: "B09880"))
                    Text(name)
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                        .foregroundColor(Color(hex: "3D2B1F"))
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 1) {
                    Text("\(remaining)")
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                        .foregroundColor(Color(hex: "E76F51"))
                    Text("kcal left")
                        .font(.system(size: 10))
                        .foregroundColor(Color(hex: "B09880"))
                }
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 5).fill(Color(hex: "F0E6DA")).frame(height: 8)
                    RoundedRectangle(cornerRadius: 5)
                        .fill(LinearGradient(colors: [Color(hex: "E76F51"), Color(hex: "F4A261")],
                                             startPoint: .leading, endPoint: .trailing))
                        .frame(width: geo.size.width * progress, height: 8)
                        .animation(.spring(), value: progress)
                }
            }
            .frame(height: 8)

            HStack {
                Label("\(caloriesConsumed) eaten", systemImage: "fork.knife")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(Color(hex: "E76F51"))
                Spacer()
                Label("\(caloriesBurned) burned", systemImage: "figure.run")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(Color(hex: "2A9D8F"))
                Spacer()
                Label("\(caloriesTarget) target", systemImage: "target")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(Color(hex: "B09880"))
            }
        }
        .padding(18)
        .background(Color.white)
        .cornerRadius(18)
        .shadow(color: .black.opacity(0.05), radius: 8, y: 2)
    }
}

// MARK: - Day So Far (AI insight)

struct DaySoFarCard: View {
    let insight: String
    let isLoading: Bool
    var isToday: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .font(.system(size: 14))
                    .foregroundColor(Color(hex: "E76F51"))
                Text(isToday ? "DAY SO FAR" : "DAY RECAP")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(Color(hex: "B09880"))
                    .kerning(1.0)
            }

            if isLoading {
                HStack(spacing: 8) {
                    ProgressView().scaleEffect(0.8)
                    Text("Rena is reading your day…")
                        .font(.system(size: 14))
                        .foregroundColor(Color(hex: "B09880"))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
            } else if insight.isEmpty {
                Text(isToday
                     ? "Start logging meals and workouts — Rena will give you a read on your day."
                     : "No data logged for this day.")
                    .font(.system(size: 14))
                    .foregroundColor(Color(hex: "B09880"))
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(insight)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(Color(hex: "3D2B1F"))
                    .fixedSize(horizontal: false, vertical: true)
                    .lineSpacing(3)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 18)
                .fill(Color(hex: "FFF8F2"))
                .overlay(
                    RoundedRectangle(cornerRadius: 18)
                        .stroke(Color(hex: "F4C9A8"), lineWidth: 1)
                )
        )
    }
}

// MARK: - Today's activity (food + workout as friendly text)

struct TodayActivityCard: View {
    let aiSummary: String
    let isLoading: Bool
    let meals: [MealEntry]
    let workouts: [WorkoutEntry]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "list.bullet.rectangle")
                    .font(.system(size: 13))
                    .foregroundColor(Color(hex: "E76F51"))
                Text("TODAY'S ACTIVITY")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(Color(hex: "B09880"))
                    .kerning(1.0)
            }

            if isLoading {
                HStack(spacing: 8) {
                    ProgressView().scaleEffect(0.8)
                    Text("Summarising your day…")
                        .font(.system(size: 14))
                        .foregroundColor(Color(hex: "B09880"))
                }
            } else if !aiSummary.isEmpty {
                Text(aiSummary)
                    .font(.system(size: 15))
                    .foregroundColor(Color(hex: "3D2B1F"))
                    .fixedSize(horizontal: false, vertical: true)
                    .lineSpacing(3)
            } else {
                Text(fallback)
                    .font(.system(size: 14))
                    .foregroundColor(Color(hex: "B09880"))
                    .fixedSize(horizontal: false, vertical: true)
                    .lineSpacing(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(Color.white)
        .cornerRadius(18)
        .shadow(color: .black.opacity(0.05), radius: 8, y: 2)
    }

    private var fallback: String {
        if meals.isEmpty && workouts.isEmpty {
            return "Nothing logged yet — tell Rena what you've eaten or how you moved today."
        }
        if workouts.isEmpty {
            return "You've logged \(meals.count) meal\(meals.count > 1 ? "s" : "") today. No workouts yet."
        }
        return "You've logged \(meals.count) meal\(meals.count > 1 ? "s" : "") and \(workouts.count) workout\(workouts.count > 1 ? "s" : "") today."
    }
}

// MARK: - Planned Workout Card

struct PlannedWorkoutCard: View {
    let plan: PlannedWorkout?
    let isGenerating: Bool
    let onGenerate: () -> Void
    let onToggleComplete: (PlannedExercise) -> Void
    let onPlay: (PlannedExercise) -> Void
    let onLog: (PlannedExercise) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "dumbbell.fill")
                    .font(.system(size: 13))
                    .foregroundColor(Color(hex: "2A9D8F"))
                Text("TODAY'S WORKOUT PLAN")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(Color(hex: "B09880"))
                    .kerning(1.0)
                Spacer()
                if plan != nil {
                    Button(action: onGenerate) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 13))
                            .foregroundColor(Color(hex: "B09880"))
                    }
                }
            }

            if isGenerating {
                HStack(spacing: 8) {
                    ProgressView().scaleEffect(0.8)
                    Text("Generating your workout…")
                        .font(.system(size: 14))
                        .foregroundColor(Color(hex: "B09880"))
                }
                .padding(.vertical, 4)
            } else if let plan {
                // Plan summary
                HStack(spacing: 12) {
                    Label(plan.name, systemImage: "figure.strengthtraining.traditional")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(Color(hex: "3D2B1F"))
                    Spacer()
                    Text("\(plan.totalDurationMin) min")
                        .font(.system(size: 12))
                        .foregroundColor(Color(hex: "B09880"))
                    Text("·")
                        .foregroundColor(Color(hex: "D4B8A0"))
                    Text("\(plan.totalCalories) kcal")
                        .font(.system(size: 12))
                        .foregroundColor(Color(hex: "B09880"))
                }

                Divider().background(Color(hex: "F0E6DA"))

                // Exercise rows
                VStack(spacing: 0) {
                    ForEach(plan.exercises) { exercise in
                        ExerciseRow(
                            exercise: exercise,
                            onToggleComplete: { onToggleComplete(exercise) },
                            onPlay: { onPlay(exercise) },
                            onLog: { onLog(exercise) }
                        )
                        if exercise.id != plan.exercises.last?.id {
                            Divider().background(Color(hex: "F5EEE8")).padding(.leading, 36)
                        }
                    }
                }
            } else {
                VStack(spacing: 10) {
                    Text("No workout planned yet. Let Rena create one based on your goal, or generate one now.")
                        .font(.system(size: 14))
                        .foregroundColor(Color(hex: "B09880"))
                        .fixedSize(horizontal: false, vertical: true)

                    Button(action: onGenerate) {
                        Label("Generate Today's Workout", systemImage: "sparkles")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(Color(hex: "2A9D8F"))
                            .cornerRadius(12)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(Color.white)
        .cornerRadius(18)
        .shadow(color: .black.opacity(0.05), radius: 8, y: 2)
    }
}

struct ExerciseRow: View {
    let exercise: PlannedExercise
    let onToggleComplete: () -> Void
    let onPlay: () -> Void
    let onLog: () -> Void

    private var volumeLabel: String {
        if exercise.type == "cardio", let d = exercise.durationMin {
            return "\(d) min"
        } else if let s = exercise.sets, let r = exercise.reps {
            return "\(s) × \(r)"
        }
        return ""
    }

    var body: some View {
        HStack(spacing: 10) {
            // Checkbox
            Button(action: onToggleComplete) {
                Image(systemName: exercise.completed ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20))
                    .foregroundColor(exercise.completed ? Color(hex: "2A9D8F") : Color(hex: "D4B8A0"))
            }
            .buttonStyle(.plain)

            // Name + volume
            VStack(alignment: .leading, spacing: 2) {
                Text(exercise.name)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(exercise.completed ? Color(hex: "B09880") : Color(hex: "3D2B1F"))
                    .strikethrough(exercise.completed)
                HStack(spacing: 6) {
                    Text(volumeLabel)
                        .font(.system(size: 12))
                        .foregroundColor(Color(hex: "B09880"))
                    if let muscles = exercise.targetMuscles, !muscles.isEmpty {
                        Text("·")
                            .foregroundColor(Color(hex: "D4B8A0"))
                        Text(muscles.split(separator: ",").prefix(2).joined(separator: ", "))
                            .font(.system(size: 11))
                            .foregroundColor(Color(hex: "C0A898"))
                            .lineLimit(1)
                    }
                }
            }

            Spacer()

            // Calories
            Text("\(exercise.caloriesBurned) kcal")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(Color(hex: "B09880"))

            // Play button
            Button(action: onPlay) {
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 26))
                    .foregroundColor(Color(hex: "2A9D8F"))
            }
            .buttonStyle(.plain)

            // Log button
            Button(action: onLog) {
                Text("Log")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color(hex: "E76F51"))
                    .cornerRadius(8)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }
}

// MARK: - Voice action card (workout plan / plan tomorrow)

struct WorkbookVoiceCard: View {
    let icon: String
    let iconColor: Color
    let title: String
    let subtitle: String
    let buttonLabel: String
    let isActive: Bool
    let voiceState: VoiceState
    let onTap: () -> Void

    private var stateLabel: String {
        switch voiceState {
        case .connecting:          return "Connecting…"
        case .listening:           return "Listening…"
        case .thinking:            return "Thinking…"
        case .speaking:            return "Rena is speaking…"
        case .error(let m):        return "Error: \(m)"
        default:                   return isActive ? "Tap to end" : buttonLabel
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(iconColor.opacity(0.12))
                        .frame(width: 40, height: 40)
                    Image(systemName: icon)
                        .font(.system(size: 17))
                        .foregroundColor(iconColor)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 15, weight: .bold))
                        .foregroundColor(Color(hex: "3D2B1F"))
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundColor(Color(hex: "B09880"))
                }
                Spacer()
            }

            Button(action: onTap) {
                HStack(spacing: 8) {
                    if isActive {
                        Circle()
                            .fill(iconColor)
                            .frame(width: 8, height: 8)
                    } else {
                        Image(systemName: "waveform")
                            .font(.system(size: 13))
                    }
                    Text(stateLabel)
                        .font(.system(size: 14, weight: .semibold))
                }
                .foregroundColor(isActive ? .white : iconColor)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(isActive ? iconColor : iconColor.opacity(0.1))
                .cornerRadius(12)
                .animation(.easeInOut(duration: 0.2), value: isActive)
            }
        }
        .padding(18)
        .background(Color.white)
        .cornerRadius(18)
        .shadow(color: .black.opacity(0.05), radius: 8, y: 2)
    }
}

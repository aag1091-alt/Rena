import SwiftUI

struct WorkbookView: View {
    @Binding var showRena: Bool
    @Binding var renaContext: String?

    @EnvironmentObject var appState: AppState
    @EnvironmentObject var voice: VoiceManager

    @State private var selectedDate = Date()
    @State private var dayData: ProgressResponse? = nil
    @State private var insight: String = ""
    @State private var activity: String = ""
    @State private var isLoading = false
    @State private var workoutPlan: PlannedWorkout? = nil
    @State private var mealPlan: PlannedMealPlan? = nil
    @State private var isGeneratingPlan = false
    @State private var logSheet: PlannedExercise? = nil
    @State private var videoSheet: PlannedExercise? = nil
    @State private var logMealSheet: PlannedMeal? = nil

    private var isToday:    Bool { Calendar.current.isDateInToday(selectedDate) }
    private var isTomorrow: Bool { Calendar.current.isDateInTomorrow(selectedDate) }

    private var displayMeals: [MealEntry]       { dayData?.mealsLogged    ?? (isToday ? appState.mealsLogged    : []) }
    private var displayWorkouts: [WorkoutEntry] { dayData?.workoutsLogged ?? (isToday ? appState.workoutsLogged : []) }
    private var displayConsumed: Int  { dayData?.caloriesConsumed ?? (isToday ? appState.caloriesConsumed : 0) }
    private var displayTarget: Int    { dayData?.caloriesTarget   ?? (isToday ? appState.caloriesTarget   : 1800) }
    private var displayBurned: Int    { dayData?.caloriesBurned   ?? (isToday ? appState.caloriesBurned   : 0) }

    private var hour: Int { Calendar.current.component(.hour, from: Date()) }
    private var isMorning: Bool { isToday && hour >= 5  && hour < 12 }
    private var isEvening: Bool { isToday && hour >= 17 }

    private var dateString: String {
        let fmt = DateFormatter(); fmt.dateFormat = "yyyy-MM-dd"
        fmt.timeZone = TimeZone(identifier: "UTC")
        return fmt.string(from: selectedDate)
    }
    private var dateLabel: String {
        if isToday     { return "Today" }
        if isTomorrow  { return "Tomorrow" }
        if Calendar.current.isDateInYesterday(selectedDate) { return "Yesterday" }
        let fmt = DateFormatter(); fmt.dateFormat = "EEE, MMM d"
        return fmt.string(from: selectedDate)
    }
    var body: some View {
        NavigationView {
            ZStack {
                Color(hex: "F7F3EE").ignoresSafeArea()
                VStack(spacing: 0) {
                    AppHeader()
                    ScrollView {
                VStack(spacing: 14) {

                    // ── Date navigator ──────────────────────────────
                    HStack(spacing: 0) {
                        Button {
                            selectedDate = Calendar.current.date(byAdding: .day, value: -1, to: selectedDate)!
                            Task { await loadDay() }
                        } label: {
                            ZStack {
                                Circle()
                                    .fill(Color(hex: "E76F51").opacity(0.10))
                                    .frame(width: 36, height: 36)
                                Image(systemName: "chevron.left")
                                    .font(.system(size: 13, weight: .bold))
                                    .foregroundColor(Color(hex: "E76F51"))
                            }
                        }

                        Spacer()

                        HStack(spacing: 6) {
                            if isToday {
                                Circle()
                                    .fill(Color(hex: "E76F51"))
                                    .frame(width: 6, height: 6)
                            }
                            Text(dateLabel)
                                .font(.system(size: 17, weight: .bold, design: .rounded))
                                .foregroundColor(Color(hex: "3D2B1F"))
                                .contentTransition(.numericText())
                                .animation(.spring(duration: 0.2), value: dateLabel)
                        }

                        Spacer()

                        Button {
                            selectedDate = Calendar.current.date(byAdding: .day, value: 1, to: selectedDate)!
                            Task { await loadDay() }
                        } label: {
                            ZStack {
                                Circle()
                                    .fill(isTomorrow ? Color(hex: "B09880").opacity(0.08) : Color(hex: "E76F51").opacity(0.10))
                                    .frame(width: 36, height: 36)
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 13, weight: .bold))
                                    .foregroundColor(isTomorrow ? Color(hex: "C4A882") : Color(hex: "E76F51"))
                            }
                        }
                        .disabled(isTomorrow)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(Color.white)
                    .cornerRadius(18)
                    .shadow(color: .black.opacity(0.04), radius: 6, y: 2)

                    // ── Header card ─────────────────────────────────
                    WorkbookHeader(
                        isMorning: isMorning,
                        isEvening: isEvening,
                        caloriesConsumed: displayConsumed,
                        caloriesTarget: displayTarget,
                        caloriesBurned: displayBurned,
                        isToday: isToday
                    )

                    // ── Day Recap (AI) — past dates only (not today, not tomorrow) ──
                    if !isToday && !isTomorrow {
                        DaySoFarCard(insight: insight, isLoading: isLoading, isToday: false)
                    }

                    // ── Workout plan — today + tomorrow ─────────────
                    if isToday || isTomorrow {
                        WorkoutPlanSection(
                            plan: workoutPlan,
                            isGenerating: isGeneratingPlan,
                            isInteractive: isToday,
                            sectionTitle: isTomorrow ? "TOMORROW'S WORKOUT" : "TODAY'S WORKOUT",
                            onPlanWithRena:   { renaContext = isTomorrow ? "plan_tomorrow" : "workout_plan"; showRena = true },
                            onOpenRena:       { renaContext = "update_workout_plan"; showRena = true },
                            onRegenerate:     { Task { await generatePlan() } },
                            onDelete:         { Task { await deletePlan() } },
                            onToggleComplete: { ex in Task { await toggleComplete(ex) } },
                            onPlay:           { ex in videoSheet = ex },
                            onLog:            { ex in logSheet = ex }
                        )
                    }

                    // ── Meal plan — today + tomorrow ─────────────────
                    if isToday || isTomorrow {
                        MealPlanSection(
                            plan: mealPlan,
                            isInteractive: isToday,
                            sectionTitle: isTomorrow ? "TOMORROW'S MEALS" : "TODAY'S MEALS",
                            onPlanWithRena: { renaContext = isTomorrow ? "plan_tomorrow" : "meal_plan"; showRena = true },
                            onDelete:       { Task { await deleteMealPlanAction() } },
                            onWatch:        { meal in logMealSheet = meal },
                            onLog:          { meal in Task { await logMeal(meal) } }
                        )
                    }

                    // ── Plan Tomorrow — always visible on today ──────
                    if isToday {
                        WorkbookVoiceCard(
                            icon: "moon.stars.fill",
                            iconColor: Color(hex: "9B7EC8"),
                            title: "Plan Tomorrow",
                            subtitle: "Review today with Rena and set tomorrow's targets",
                            onTap: { renaContext = "plan_tomorrow"; showRena = true }
                        )
                    }

                    // ── Activity summary — not shown for tomorrow ────
                    if !isTomorrow {
                        TodayActivityCard(
                            aiSummary: activity,
                            isLoading: isLoading,
                            meals: displayMeals,
                            workouts: displayWorkouts,
                            isToday: isToday
                        )
                    }

                    Spacer(minLength: 40)
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
            }
            .scrollBounceBehavior(.always)
            .refreshable { await loadDay() }
            .onAppear { Task { await loadDay() } }
            .onChange(of: voice.turnCount) { if isToday { Task { await loadDay() } } }
            .sheet(item: $logSheet) { ex in
                LogExerciseSheet(exercise: ex, userId: appState.userId, dateString: dateString)
            }
            .sheet(item: $videoSheet) { ex in
                ExerciseVideoSheet(exercise: ex)
            }
            .sheet(item: $logMealSheet) { meal in
                MealYouTubeSheet(meal: meal)
            }
                } // VStack
            } // ZStack
            .navigationBarHidden(true)
        }
    }

    // MARK: - Workout plan

    private func generatePlan() async {
        await MainActor.run { isGeneratingPlan = true }
        let plan = try? await RenaAPI.shared.generateWorkoutPlan(userId: appState.userId)
        await MainActor.run { workoutPlan = plan; isGeneratingPlan = false }
    }

    private func deletePlan() async {
        try? await RenaAPI.shared.deleteWorkoutPlan(userId: appState.userId)
        await MainActor.run { workoutPlan = nil }
    }

    private func deleteMealPlanAction() async {
        try? await RenaAPI.shared.deleteMealPlan(userId: appState.userId, date: isTomorrow ? tomorrowDateString : nil)
        await MainActor.run { mealPlan = nil }
    }

    private func logMeal(_ meal: PlannedMeal) async {
        try? await RenaAPI.shared.logMealFromPlan(userId: appState.userId, mealId: meal.id, date: isToday ? nil : dateString)
        let plan = try? await RenaAPI.shared.getMealPlan(userId: appState.userId, date: isToday ? nil : dateString)
        await MainActor.run { mealPlan = plan }
    }

    private var tomorrowDateString: String {
        let fmt = DateFormatter(); fmt.dateFormat = "yyyy-MM-dd"
        fmt.timeZone = TimeZone(identifier: "UTC")
        return fmt.string(from: Calendar.current.date(byAdding: .day, value: 1, to: Date())!)
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
        let date = (isToday || isTomorrow) ? nil : dateString
        async let progressTask  = RenaAPI.shared.getProgress(userId: appState.userId, date: dateString)
        async let insightTask   = RenaAPI.shared.getWorkbookInsight(userId: appState.userId, date: date)
        async let planTask      = RenaAPI.shared.getWorkoutPlan(userId: appState.userId, date: dateString)
        async let mealPlanTask  = RenaAPI.shared.getMealPlan(userId: appState.userId, date: dateString)
        let progress = try? await progressTask
        let result   = try? await insightTask
        let plan     = try? await planTask
        let mPlan    = try? await mealPlanTask
        await MainActor.run {
            dayData     = progress
            workoutPlan = plan
            mealPlan    = mPlan
            if let r = result { insight = r.insight; activity = r.activity }
            isLoading = false
        }
    }
}

// MARK: - Header card

struct WorkbookHeader: View {
    let isMorning: Bool
    let isEvening: Bool
    let caloriesConsumed: Int
    let caloriesTarget: Int
    let caloriesBurned: Int
    var isToday: Bool = true

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
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text(isToday ? "TODAY'S CALORIES" : "DAY'S CALORIES")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(Color(hex: "B09880"))
                        .kerning(1.0)
                    HStack(alignment: .lastTextBaseline, spacing: 4) {
                        Text("\(remaining)")
                            .font(.system(size: 26, weight: .bold, design: .rounded))
                            .foregroundColor(Color(hex: "E76F51"))
                        Text("kcal remaining")
                            .font(.system(size: 12))
                            .foregroundColor(Color(hex: "B09880"))
                    }
                }
                Spacer()
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(phaseColor.opacity(0.14))
                        .frame(width: 38, height: 38)
                    Image(systemName: phaseIcon)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(phaseColor)
                }
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 5)
                        .fill(Color(hex: "F0E6DA"))
                        .frame(height: 8)
                    RoundedRectangle(cornerRadius: 5)
                        .fill(LinearGradient(
                            colors: [Color(hex: "E76F51"), Color(hex: "F4A261")],
                            startPoint: .leading, endPoint: .trailing
                        ))
                        .frame(width: geo.size.width * progress, height: 8)
                        .animation(.spring(), value: progress)
                }
            }
            .frame(height: 8)

            HStack(spacing: 0) {
                caloriePill(icon: "fork.knife",  value: "\(caloriesConsumed)", label: "eaten",  color: Color(hex: "E76F51"))
                Spacer()
                caloriePill(icon: "figure.run",  value: "\(caloriesBurned)",  label: "burned", color: Color(hex: "2A9D8F"))
                Spacer()
                caloriePill(icon: "target",      value: "\(caloriesTarget)",  label: "target", color: Color(hex: "B09880"))
            }
        }
        .padding(18)
        .background(Color.white)
        .cornerRadius(18)
        .shadow(color: .black.opacity(0.05), radius: 8, y: 2)
    }

    @ViewBuilder
    private func caloriePill(icon: String, value: String, label: String, color: Color) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(color)
            Text("\(value) \(label)")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(Color(hex: "5C3D2E"))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(color.opacity(0.08))
        .cornerRadius(20)
    }
}

// MARK: - Day So Far / Day Recap (AI insight)

struct DaySoFarCard: View {
    let insight: String
    let isLoading: Bool
    var isToday: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 7)
                        .fill(Color(hex: "E76F51").opacity(0.12))
                        .frame(width: 26, height: 26)
                    Image(systemName: "sparkles")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(Color(hex: "E76F51"))
                }
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
                    .lineSpacing(4)
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

// MARK: - Activity summary (food + workout as friendly text)

struct TodayActivityCard: View {
    let aiSummary: String
    let isLoading: Bool
    let meals: [MealEntry]
    let workouts: [WorkoutEntry]
    var isToday: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 7)
                        .fill(Color(hex: "457B9D").opacity(0.12))
                        .frame(width: 26, height: 26)
                    Image(systemName: "list.bullet.rectangle")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(Color(hex: "457B9D"))
                }
                Text(isToday ? "TODAY'S ACTIVITY" : "DAY'S ACTIVITY")
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
                    .lineSpacing(4)
            } else {
                Text(fallback)
                    .font(.system(size: 14))
                    .foregroundColor(Color(hex: "B09880"))
                    .fixedSize(horizontal: false, vertical: true)
                    .lineSpacing(2)
            }

            // Quick meal/workout count chips
            if !meals.isEmpty || !workouts.isEmpty {
                HStack(spacing: 8) {
                    if !meals.isEmpty {
                        activityChip(
                            icon: "fork.knife",
                            label: "\(meals.count) meal\(meals.count == 1 ? "" : "s")",
                            color: Color(hex: "E76F51")
                        )
                    }
                    if !workouts.isEmpty {
                        activityChip(
                            icon: "figure.run",
                            label: "\(workouts.count) workout\(workouts.count == 1 ? "" : "s")",
                            color: Color(hex: "2A9D8F")
                        )
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

    @ViewBuilder
    private func activityChip(icon: String, label: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(color)
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(color)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(color.opacity(0.08))
        .cornerRadius(20)
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

// MARK: - Unified Workout Plan Section

struct WorkoutPlanSection: View {
    let plan: PlannedWorkout?
    let isGenerating: Bool
    var isInteractive: Bool = true
    var sectionTitle: String = "TODAY'S WORKOUT"
    let onPlanWithRena: () -> Void
    let onOpenRena: () -> Void
    let onRegenerate: () -> Void
    let onDelete: () -> Void
    let onToggleComplete: (PlannedExercise) -> Void
    let onPlay: (PlannedExercise) -> Void
    let onLog: (PlannedExercise) -> Void

    private let suggestions = ["Swap an exercise", "Make it harder", "Add more cardio", "Make it shorter", "Upper body focus", "No equipment"]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {

            // Header
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color(hex: "2A9D8F").opacity(0.12))
                        .frame(width: 30, height: 30)
                    Image(systemName: "dumbbell.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(Color(hex: "2A9D8F"))
                }
                Text(sectionTitle)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(Color(hex: "B09880"))
                    .kerning(1.0)
                Spacer()
                if plan != nil {
                    HStack(spacing: 12) {
                        Button(action: onRegenerate) {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 13))
                                .foregroundColor(Color(hex: "B09880"))
                        }
                        Button(action: onDelete) {
                            Image(systemName: "xmark")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(Color(hex: "B09880"))
                        }
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
                // Plan meta
                HStack(spacing: 8) {
                    Label(plan.name, systemImage: "figure.strengthtraining.traditional")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(Color(hex: "3D2B1F"))
                    Spacer()
                    Text("\(plan.totalDurationMin) min")
                        .font(.system(size: 11))
                        .foregroundColor(Color(hex: "B09880"))
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Color(hex: "F0E6DA"))
                        .cornerRadius(10)
                    Text("\(plan.totalCalories) kcal")
                        .font(.system(size: 11))
                        .foregroundColor(Color(hex: "B09880"))
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Color(hex: "F0E6DA"))
                        .cornerRadius(10)
                }

                Divider().background(Color(hex: "F0E6DA"))

                VStack(spacing: 0) {
                    ForEach(plan.exercises) { exercise in
                        ExerciseRow(
                            exercise: exercise,
                            isInteractive: isInteractive,
                            onToggleComplete: { onToggleComplete(exercise) },
                            onPlay: { onPlay(exercise) },
                            onLog: { onLog(exercise) }
                        )
                        if exercise.id != plan.exercises.last?.id {
                            Divider().background(Color(hex: "F5EEE8")).padding(.leading, 40)
                        }
                    }
                }

                Divider().background(Color(hex: "F0E6DA"))

                if isInteractive { updateSection }

            } else {
                // No plan yet
                VStack(spacing: 12) {
                    Text("No workout plan yet.")
                        .font(.system(size: 14))
                        .foregroundColor(Color(hex: "B09880"))
                        .fixedSize(horizontal: false, vertical: true)

                    renaActionButton(
                        label: "Plan with Rena",
                        subtitle: isInteractive ? "Rena will build today's workout for you" : "Rena will plan tomorrow's workout",
                        action: onPlanWithRena
                    )
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(Color.white)
        .cornerRadius(18)
        .shadow(color: .black.opacity(0.05), radius: 8, y: 2)
    }

    // MARK: - Sub-views

    private var updateSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(suggestions, id: \.self) { s in
                        Text(s)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(Color(hex: "9B7EC8"))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(Color(hex: "9B7EC8").opacity(0.10))
                            .cornerRadius(12)
                            .onTapGesture { onOpenRena() }
                    }
                }
            }

            renaActionButton(
                label: "Update with Rena",
                subtitle: "Swap exercises, adjust intensity, or change focus",
                action: onOpenRena
            )
        }
    }

    private func renaActionButton(label: String, subtitle: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(LinearGradient(
                            colors: [Color(hex: "E76F51"), Color(hex: "F4A261")],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        ))
                        .frame(width: 40, height: 40)
                        .shadow(color: Color(hex: "E76F51").opacity(0.3), radius: 8, y: 3)
                    Image(systemName: "sparkles")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.white)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(label)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(Color(hex: "3D2B1F"))
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundColor(Color(hex: "B09880"))
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(Color(hex: "C4A882"))
            }
            .padding(14)
            .background(Color(hex: "FFF8F2"))
            .cornerRadius(14)
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color(hex: "F4C9A8"), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Exercise row

struct ExerciseRow: View {
    let exercise: PlannedExercise
    var isInteractive: Bool = true
    let onToggleComplete: () -> Void
    let onPlay: () -> Void
    let onLog: () -> Void

    private var volumeLabel: String {
        if exercise.type == "cardio", let d = exercise.durationMin { return "\(d) min" }
        if let s = exercise.sets, let r = exercise.reps { return "\(s) × \(r)" }
        return ""
    }

    var body: some View {
        HStack(spacing: 10) {
            Button(action: isInteractive ? onToggleComplete : {}) {
                Image(systemName: exercise.completed ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 22))
                    .foregroundColor(exercise.completed ? Color(hex: "2A9D8F") : Color(hex: "D4B8A0"))
                    .opacity(isInteractive ? 1.0 : 0.4)
            }
            .buttonStyle(.plain)
            .disabled(!isInteractive)

            VStack(alignment: .leading, spacing: 2) {
                Text(exercise.name)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(exercise.completed ? Color(hex: "B09880") : Color(hex: "3D2B1F"))
                    .strikethrough(exercise.completed)
                HStack(spacing: 6) {
                    if !volumeLabel.isEmpty {
                        Text(volumeLabel)
                            .font(.system(size: 11))
                            .foregroundColor(Color(hex: "B09880"))
                    }
                    if let muscles = exercise.targetMuscles, !muscles.isEmpty {
                        if !volumeLabel.isEmpty {
                            Text("·").foregroundColor(Color(hex: "D4B8A0")).font(.system(size: 11))
                        }
                        Text(muscles.split(separator: ",").prefix(2).joined(separator: ", "))
                            .font(.system(size: 11))
                            .foregroundColor(Color(hex: "C0A898"))
                            .lineLimit(1)
                    }
                }
            }

            Spacer()

            Text("\(exercise.caloriesBurned) kcal")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(Color(hex: "B09880"))

            Button(action: onPlay) {
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 28))
                    .foregroundColor(Color(hex: "2A9D8F"))
            }
            .buttonStyle(.plain)

            if isInteractive {
                Button(action: exercise.logged ? {} : onLog) {
                    Text(exercise.logged ? "Logged" : "Log")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(exercise.logged ? Color(hex: "B09880") : .white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(exercise.logged ? Color(hex: "F0E6DA") : Color(hex: "E76F51"))
                        .cornerRadius(8)
                }
                .buttonStyle(.plain)
                .disabled(exercise.logged)
            }
        }
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }
}

// MARK: - Voice action card (Plan Tomorrow)

struct WorkbookVoiceCard: View {
    let icon: String
    let iconColor: Color
    let title: String
    let subtitle: String
    let onTap: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(iconColor.opacity(0.12))
                        .frame(width: 40, height: 40)
                    Image(systemName: icon)
                        .font(.system(size: 17, weight: .semibold))
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
                HStack(spacing: 12) {
                    ZStack {
                        Circle()
                            .fill(LinearGradient(
                                colors: [Color(hex: "E76F51"), Color(hex: "F4A261")],
                                startPoint: .topLeading, endPoint: .bottomTrailing
                            ))
                            .frame(width: 40, height: 40)
                            .shadow(color: Color(hex: "E76F51").opacity(0.3), radius: 8, y: 3)
                        Image(systemName: "sparkles")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(.white)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Plan with Rena")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(Color(hex: "3D2B1F"))
                        Text("Rena will review today and plan tomorrow")
                            .font(.system(size: 11))
                            .foregroundColor(Color(hex: "B09880"))
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(Color(hex: "C4A882"))
                }
                .padding(14)
                .background(Color(hex: "FFF8F2"))
                .cornerRadius(14)
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color(hex: "F4C9A8"), lineWidth: 1))
            }
            .buttonStyle(.plain)
        }
        .padding(18)
        .background(Color.white)
        .cornerRadius(18)
        .shadow(color: .black.opacity(0.05), radius: 8, y: 2)
    }
}

// MARK: - Meal Plan Section

struct MealPlanSection: View {
    let plan: PlannedMealPlan?
    var isInteractive: Bool = true
    var sectionTitle: String = "TODAY'S MEALS"
    let onPlanWithRena: () -> Void
    let onDelete: () -> Void
    let onWatch: (PlannedMeal) -> Void
    let onLog: (PlannedMeal) -> Void

    private let mealColor = Color(hex: "F4A261")

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {

            // Header
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(mealColor.opacity(0.12))
                        .frame(width: 30, height: 30)
                    Image(systemName: "fork.knife")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(mealColor)
                }
                Text(sectionTitle)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(Color(hex: "B09880"))
                    .kerning(1.0)
                Spacer()
                if plan != nil {
                    Button(action: onDelete) {
                        Image(systemName: "xmark")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(Color(hex: "B09880"))
                    }
                }
            }

            if let plan {
                // Summary
                HStack(spacing: 8) {
                    Label("\(plan.meals.count) meals", systemImage: "list.bullet")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(Color(hex: "3D2B1F"))
                    Spacer()
                    Text("\(plan.totalCalories) kcal")
                        .font(.system(size: 11))
                        .foregroundColor(Color(hex: "B09880"))
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Color(hex: "F0E6DA"))
                        .cornerRadius(10)
                }

                if !plan.notes.isEmpty {
                    Text(plan.notes)
                        .font(.system(size: 12))
                        .foregroundColor(Color(hex: "B09880"))
                        .fixedSize(horizontal: false, vertical: true)
                }

                Divider().background(Color(hex: "F0E6DA"))

                VStack(spacing: 0) {
                    ForEach(plan.meals) { meal in
                        PlannedMealRow(
                            meal: meal,
                            isInteractive: isInteractive,
                            onWatch: { onWatch(meal) },
                            onLog:   { onLog(meal) }
                        )
                        if meal.id != plan.meals.last?.id {
                            Divider().background(Color(hex: "F5EEE8")).padding(.leading, 40)
                        }
                    }
                }

            } else {
                VStack(spacing: 12) {
                    Text("No meal plan yet.")
                        .font(.system(size: 14))
                        .foregroundColor(Color(hex: "B09880"))
                        .fixedSize(horizontal: false, vertical: true)

                    mealPlanButton
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(Color.white)
        .cornerRadius(18)
        .shadow(color: .black.opacity(0.05), radius: 8, y: 2)
    }

    private var mealPlanButton: some View {
        Button(action: onPlanWithRena) {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(LinearGradient(
                            colors: [Color(hex: "E76F51"), Color(hex: "F4A261")],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        ))
                        .frame(width: 40, height: 40)
                        .shadow(color: Color(hex: "E76F51").opacity(0.3), radius: 8, y: 3)
                    Image(systemName: "sparkles")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.white)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Plan with Rena")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(Color(hex: "3D2B1F"))
                    Text(isInteractive ? "Rena will plan today's meals" : "Rena will plan tomorrow's meals")
                        .font(.system(size: 11))
                        .foregroundColor(Color(hex: "B09880"))
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(Color(hex: "C4A882"))
            }
            .padding(14)
            .background(Color(hex: "FFF8F2"))
            .cornerRadius(14)
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color(hex: "F4C9A8"), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Meal Row

struct PlannedMealRow: View {
    let meal: PlannedMeal
    var isInteractive: Bool = true
    let onWatch: () -> Void
    let onLog: () -> Void

    private var mealTypeColor: Color {
        switch meal.mealType {
        case "breakfast": return Color(hex: "F4A261")
        case "lunch":     return Color(hex: "2A9D8F")
        case "dinner":    return Color(hex: "457B9D")
        default:          return Color(hex: "9B7EC8")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                // Meal type badge
                Text(meal.mealType.capitalized)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(mealTypeColor)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(mealTypeColor.opacity(0.12))
                    .cornerRadius(6)

                Text(meal.name)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(Color(hex: "3D2B1F"))
                    .lineLimit(1)

                Spacer()

                Text("\(meal.calories) kcal")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(Color(hex: "B09880"))
            }

            if !meal.description.isEmpty {
                Text(meal.description)
                    .font(.system(size: 12))
                    .foregroundColor(Color(hex: "7A6055"))
                    .fixedSize(horizontal: false, vertical: true)
                    .lineLimit(2)
            }

            // Cook time + macros
            HStack(spacing: 8) {
                HStack(spacing: 3) {
                    Image(systemName: "clock")
                        .font(.system(size: 10))
                        .foregroundColor(Color(hex: "B09880"))
                    Text("\(meal.cookTimeMin) min")
                        .font(.system(size: 11))
                        .foregroundColor(Color(hex: "B09880"))
                }

                Spacer()

                macroPill(value: meal.proteinG, label: "P", color: Color(hex: "2A9D8F"))
                macroPill(value: meal.carbsG,   label: "C", color: Color(hex: "E9C46A"))
                macroPill(value: meal.fatG,     label: "F", color: Color(hex: "E76F51"))
            }

            // Action buttons
            HStack(spacing: 8) {
                // Watch button — always active
                Button(action: onWatch) {
                    HStack(spacing: 4) {
                        Image(systemName: "play.circle.fill")
                            .font(.system(size: 13))
                        Text("Watch")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .foregroundColor(Color(hex: "457B9D"))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color(hex: "457B9D").opacity(0.10))
                    .cornerRadius(8)
                }
                .buttonStyle(.plain)

                Spacer()

                // Log button — today only, once per meal
                if isInteractive {
                    Button(action: meal.logged ? {} : onLog) {
                        Text(meal.logged ? "Logged" : "Log")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(meal.logged ? Color(hex: "B09880") : .white)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(meal.logged ? Color(hex: "F0E6DA") : Color(hex: "E76F51"))
                            .cornerRadius(8)
                    }
                    .buttonStyle(.plain)
                    .disabled(meal.logged)
                }
            }
        }
        .padding(.vertical, 10)
    }

    private func macroPill(value: Int, label: String, color: Color) -> some View {
        HStack(spacing: 2) {
            Text(label)
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(color)
            Text("\(value)g")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(Color(hex: "5C3D2E"))
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(color.opacity(0.10))
        .cornerRadius(6)
    }
}

// MARK: - Meal YouTube Sheet

struct MealYouTubeSheet: View {
    let meal: PlannedMeal
    @Environment(\.dismiss) var dismiss

    var body: some View {
        VStack(spacing: 20) {
            HStack {
                Text(meal.name)
                    .font(.system(size: 18, weight: .bold))
                    .foregroundColor(Color(hex: "3D2B1F"))
                Spacer()
                Button(action: { dismiss() }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 24))
                        .foregroundColor(Color(hex: "C4A882"))
                }
            }
            .padding(.top, 4)

            VStack(spacing: 10) {
                Image(systemName: "play.rectangle.fill")
                    .font(.system(size: 60))
                    .foregroundColor(Color(hex: "FF0000").opacity(0.85))

                Text("Watch on YouTube")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(Color(hex: "3D2B1F"))

                Text("Find a cooking guide for \"\(meal.name)\"")
                    .font(.system(size: 13))
                    .foregroundColor(Color(hex: "B09880"))
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(24)
            .background(Color(hex: "F7F3EE"))
            .cornerRadius(16)

            Button(action: openYouTube) {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.up.right.square.fill")
                    Text("Open YouTube")
                }
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(Color(hex: "FF0000").opacity(0.85))
                .cornerRadius(14)
            }

            Spacer()
        }
        .padding(20)
        .background(Color.white)
    }

    private func openYouTube() {
        let encoded = meal.youtubeQuery.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? meal.name
        let urlStr = "https://www.youtube.com/results?search_query=\(encoded)"
        if let url = URL(string: urlStr) {
            UIApplication.shared.open(url)
        }
        dismiss()
    }
}

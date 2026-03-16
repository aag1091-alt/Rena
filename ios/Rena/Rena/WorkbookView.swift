import SwiftUI
import WebKit

struct WorkbookView: View {
    @Binding var showRena: Bool
    @Binding var renaContext: String?

    @EnvironmentObject var appState: AppState
    @EnvironmentObject var voice: VoiceManager

    @State private var selectedDate = Date()
    @State private var isLoading = false
    @State private var planNote: String = ""
    @State private var workoutPlan: PlannedWorkout? = nil
    @State private var mealPlan: PlannedMealPlan? = nil
    @State private var isGeneratingPlan = false
    @State private var logSheet: PlannedExercise? = nil
    @State private var videoSheet: PlannedExercise? = nil
    @State private var logMealSheet: PlannedMeal? = nil

    private var isToday:       Bool { Calendar.current.isDateInToday(selectedDate) }
    private var isTomorrow:    Bool { Calendar.current.isDateInTomorrow(selectedDate) }
    private var isPast:        Bool { !isToday && !isTomorrow }
    private var isInteractive: Bool { !isPast }

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
                                Circle().fill(Color(hex: "E76F51").opacity(0.10)).frame(width: 36, height: 36)
                                Image(systemName: "chevron.left")
                                    .font(.system(size: 13, weight: .bold)).foregroundColor(Color(hex: "E76F51"))
                            }
                        }
                        Spacer()
                        HStack(spacing: 6) {
                            if isLoading {
                                ProgressView().scaleEffect(0.7)
                            } else if isToday {
                                Circle().fill(Color(hex: "E76F51")).frame(width: 6, height: 6)
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
                    .padding(.horizontal, 16).padding(.vertical, 12)
                    .background(Color.white).cornerRadius(18)
                    .shadow(color: .black.opacity(0.04), radius: 6, y: 2)

                    // ── Plan card (all dates) ────────────────────────
                    if !isPast || !planNote.isEmpty {
                        DayPlanCard(
                            note: planNote,
                            isReadOnly: isPast,
                            onDelete: planNote.isEmpty ? nil : { Task { await deletePlanNote() } },
                            onTap: { renaContext = "plan:\(dateString)"; showRena = true }
                        )
                    }

                    // ── Workout ──────────────────────────────────────
                    if !isPast || workoutPlan != nil {
                        WorkoutPlanSection(
                            plan: workoutPlan, isGenerating: isGeneratingPlan,
                            isInteractive: isInteractive, readOnly: isPast,
                            sectionTitle: "WORKOUT",
                            onPlanWithRena:   { renaContext = "workout_plan:\(dateString)"; showRena = true },
                            onOpenRena:       { renaContext = "update_workout_plan:\(dateString)"; showRena = true },
                            onRegenerate:     { Task { await generatePlan() } },
                            onDelete:         { Task { await deletePlan() } },
                            onToggleComplete: { ex in Task { await toggleComplete(ex) } },
                            onPlay:           { ex in videoSheet = ex },
                            onLog:            { ex in logSheet = ex }
                        )
                    }

                    // ── Meals ────────────────────────────────────────
                    if !isPast || mealPlan != nil {
                        MealPlanSection(
                            plan: mealPlan, isInteractive: isInteractive,
                            readOnly: isPast, sectionTitle: "MEALS",
                            onPlanWithRena:   { renaContext = "meal_plan:\(dateString)"; showRena = true },
                            onUpdateWithRena: { renaContext = "update_meal_plan:\(dateString)"; showRena = true },
                            onDelete:         { Task { await deleteMealPlanAction() } },
                            onWatch:          { meal in logMealSheet = meal },
                            onLog:            { meal in Task { await logMeal(meal) } }
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
            .onChange(of: voice.turnCount) { if !isPast { Task { await loadDay() } } }
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

    // MARK: - Actions

    private func generatePlan() async {
        await MainActor.run { isGeneratingPlan = true }
        let plan = try? await RenaAPI.shared.generateWorkoutPlan(userId: appState.userId, date: dateString)
        await MainActor.run {
            workoutPlan = plan
            isGeneratingPlan = false
        }
    }

    private func deletePlan() async {
        try? await RenaAPI.shared.deleteWorkoutPlan(userId: appState.userId, date: dateString)
        await MainActor.run { workoutPlan = nil }
    }

    private func deleteMealPlanAction() async {
        try? await RenaAPI.shared.deleteMealPlan(userId: appState.userId, date: dateString)
        await MainActor.run { mealPlan = nil }
    }

    private func logMeal(_ meal: PlannedMeal) async {
        try? await RenaAPI.shared.logMealFromPlan(userId: appState.userId, mealId: meal.id, date: dateString)
        let plan = try? await RenaAPI.shared.getMealPlan(userId: appState.userId, date: dateString)
        await MainActor.run { mealPlan = plan }
    }

    private func deletePlanNote() async {
        try? await RenaAPI.shared.deleteTomorrowPlan(userId: appState.userId, date: dateString)
        await MainActor.run { planNote = "" }
    }

    private func toggleComplete(_ exercise: PlannedExercise) async {
        try? await RenaAPI.shared.toggleExerciseComplete(
            userId: appState.userId, exerciseId: exercise.id, date: dateString)
        let plan = try? await RenaAPI.shared.getWorkoutPlan(userId: appState.userId, date: dateString)
        await MainActor.run { workoutPlan = plan }
    }

    // MARK: - Data

    private func loadDay() async {
        await MainActor.run { isLoading = true; planNote = "" }
        let d = dateString
        async let planTask     = RenaAPI.shared.getWorkoutPlan(userId: appState.userId, date: d)
        async let mealPlanTask = RenaAPI.shared.getMealPlan(userId: appState.userId, date: d)
        async let noteTask     = RenaAPI.shared.getTomorrowPlan(userId: appState.userId, date: d)
        let plan  = try? await planTask
        let mPlan = try? await mealPlanTask
        let note  = try? await noteTask
        await MainActor.run {
            workoutPlan = plan
            mealPlan    = mPlan
            planNote    = note ?? ""
            isLoading   = false
        }
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

// MARK: - Unified Workout Plan Section

struct WorkoutPlanSection: View {
    let plan: PlannedWorkout?
    let isGenerating: Bool
    var isInteractive: Bool = true
    var readOnly: Bool = false
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
                if plan != nil && !readOnly {
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

                    if !readOnly {
                        renaActionButton(
                            label: "Plan with Rena",
                            subtitle: isInteractive ? "Rena will build today's workout for you" : "Rena will plan tomorrow's workout",
                            action: onPlanWithRena
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

// MARK: - Day Plan Card

struct DayPlanCard: View {
    let note: String
    let isReadOnly: Bool
    var onDelete: (() -> Void)? = nil
    let onTap: () -> Void

    private let accent = Color(hex: "9B7EC8")

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(accent.opacity(0.12))
                        .frame(width: 40, height: 40)
                    Image(systemName: note.isEmpty ? "moon.stars.fill" : "text.quote")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(accent)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(note.isEmpty ? "Plan" : "Plan, Summarised by Rena")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundColor(Color(hex: "3D2B1F"))
                    Text(note.isEmpty ? "Talk to Rena to set your focus" : "Tap below to update with Rena")
                        .font(.system(size: 12))
                        .foregroundColor(Color(hex: "B09880"))
                }
                Spacer()
                if let onDelete {
                    Button(action: onDelete) {
                        Image(systemName: "trash")
                            .font(.system(size: 13))
                            .foregroundColor(Color(hex: "C4A882"))
                    }
                    .buttonStyle(.plain)
                }
            }

            if !note.isEmpty {
                Text(note)
                    .font(.system(size: 13))
                    .foregroundColor(Color(hex: "5C4033"))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(accent.opacity(0.07))
                    .cornerRadius(10)
            }

            if !isReadOnly {
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
                            Text(note.isEmpty ? "Plan with Rena" : "Update Plan")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundColor(Color(hex: "3D2B1F"))
                            Text(note.isEmpty ? "Set your focus for the day" : "Chat with Rena to refine your plan")
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
    var readOnly: Bool = false
    var sectionTitle: String = "TODAY'S MEALS"
    let onPlanWithRena: () -> Void
    let onUpdateWithRena: () -> Void
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
                if plan != nil && !readOnly {
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

                if isInteractive {
                    Divider().background(Color(hex: "F0E6DA"))
                    renaActionButton(
                        label: "Update with Rena",
                        subtitle: "Swap meals, adjust calories, or change preferences",
                        action: onUpdateWithRena
                    )
                }

            } else {
                VStack(spacing: 12) {
                    Text("No meal plan yet.")
                        .font(.system(size: 14))
                        .foregroundColor(Color(hex: "B09880"))
                        .fixedSize(horizontal: false, vertical: true)

                    if !readOnly { mealPlanButton }
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
        renaActionButton(
            label: "Plan with Rena",
            subtitle: isInteractive ? "Rena will plan today's meals" : "Rena will plan for this day",
            action: onPlanWithRena
        )
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

// MARK: - YouTube WebView

struct YouTubeWebView: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

// MARK: - Meal YouTube Sheet

struct MealYouTubeSheet: View {
    let meal: PlannedMeal
    @Environment(\.dismiss) var dismiss

    private var searchURL: URL? {
        let encoded = meal.youtubeQuery.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? meal.name
        return URL(string: "https://m.youtube.com/results?search_query=\(encoded)")
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(meal.name)
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(Color(hex: "3D2B1F"))
                        .lineLimit(1)
                    Text("Cooking videos")
                        .font(.system(size: 11))
                        .foregroundColor(Color(hex: "B09880"))
                }
                Spacer()
                Button(action: { dismiss() }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 26))
                        .foregroundColor(Color(hex: "C4A882"))
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Color.white)

            Divider()

            if let url = searchURL {
                YouTubeWebView(url: url)
            } else {
                Spacer()
                Text("Could not load YouTube")
                    .foregroundColor(Color(hex: "B09880"))
                Spacer()
            }
        }
        .background(Color.white)
    }
}

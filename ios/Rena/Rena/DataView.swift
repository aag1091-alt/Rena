import SwiftUI

struct DataView: View {
    @EnvironmentObject var appState: AppState
    @State private var selectedDate = Date()
    @State private var dayData: ProgressResponse? = nil
    @State private var isLoading = false

    private var isToday: Bool {
        Calendar.current.isDateInToday(selectedDate)
    }

    private var dateLabel: String {
        if isToday { return "Today" }
        if Calendar.current.isDateInYesterday(selectedDate) { return "Yesterday" }
        let fmt = DateFormatter()
        fmt.dateFormat = "EEE, MMM d"
        return fmt.string(from: selectedDate)
    }

    private var dateString: String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        return fmt.string(from: selectedDate)
    }

    // Data to display — today uses appState, historical uses dayData
    private var displayCaloriesConsumed: Int { dayData?.caloriesConsumed ?? (isToday ? appState.caloriesConsumed : 0) }
    private var displayCaloriesBurned: Int   { dayData?.caloriesBurned   ?? (isToday ? appState.caloriesBurned   : 0) }
    private var displayCaloriesTarget: Int   { dayData?.caloriesTarget   ?? (isToday ? appState.caloriesTarget   : 1800) }
    private var displayBurnRequired: Int     { dayData?.burnRequired     ?? (isToday ? appState.burnRequired     : 0) }
    private var displayProteinConsumed: Int  { dayData?.proteinConsumedG ?? (isToday ? appState.proteinConsumedG : 0) }
    private var displayProteinTarget: Int    { dayData?.proteinTargetG   ?? (isToday ? appState.proteinTargetG   : 120) }
    private var displayWater: Int            { dayData?.waterGlasses     ?? (isToday ? appState.waterGlasses     : 0) }
    private var displayWeightKg: Double?     { dayData?.weightKg         ?? (isToday ? appState.todayWeightKg   : nil) }
    private var displayMeals: [MealEntry]    { dayData?.mealsLogged      ?? (isToday ? appState.mealsLogged     : []) }
    private var displayWorkouts: [WorkoutEntry] { dayData?.workoutsLogged ?? (isToday ? appState.workoutsLogged : []) }

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 16) {

                    // Date navigation
                    HStack(spacing: 16) {
                        Button {
                            selectedDate = Calendar.current.date(byAdding: .day, value: -1, to: selectedDate)!
                            Task { await loadData() }
                        } label: {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundColor(Color(hex: "E76F51"))
                        }

                        Spacer()

                        VStack(spacing: 2) {
                            Text(dateLabel)
                                .font(.system(size: 17, weight: .bold))
                                .foregroundColor(Color(hex: "3D2B1F"))
                            if !isToday {
                                Text(dateString)
                                    .font(.system(size: 11))
                                    .foregroundColor(Color(hex: "B09880"))
                            }
                        }
                        .contentTransition(.numericText())
                        .animation(.spring(duration: 0.2), value: dateLabel)

                        Spacer()

                        Button {
                            selectedDate = Calendar.current.date(byAdding: .day, value: 1, to: selectedDate)!
                            Task { await loadData() }
                        } label: {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundColor(isToday ? Color(hex: "D4B8A0") : Color(hex: "E76F51"))
                        }
                        .disabled(isToday)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 12)
                    .background(Color.white)
                    .cornerRadius(16)
                    .shadow(color: .black.opacity(0.04), radius: 6, y: 2)

                    if isLoading {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 40)
                    } else {
                        DayWeightCard(weightKg: displayWeightKg)
                        DaySummaryRow(
                            caloriesConsumed: displayCaloriesConsumed,
                            caloriesBurned: displayCaloriesBurned,
                            caloriesTarget: displayCaloriesTarget,
                            water: displayWater
                        )
                        DayCalorieBreakdownCard(
                            caloriesConsumed: displayCaloriesConsumed,
                            caloriesBurned: displayCaloriesBurned,
                            caloriesTarget: displayCaloriesTarget,
                            burnRequired: displayBurnRequired
                        )
                        DayFoodLog(meals: displayMeals)
                        DayWorkoutLog(workouts: displayWorkouts)
                    }

                    Spacer(minLength: 40)
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
            }
            .background(Color(hex: "F7F3EE").ignoresSafeArea())
            .navigationTitle("History")
            .navigationBarTitleDisplayMode(.large)
            .scrollBounceBehavior(.always)
            .refreshable { await loadData() }
            .onAppear { Task { await loadData() } }
        }
    }

    private func loadData() async {
        await MainActor.run { isLoading = true }
        do {
            let resp = try await RenaAPI.shared.getProgress(userId: appState.userId, date: dateString)
            await MainActor.run {
                dayData = resp
                isLoading = false
                if isToday {
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
        } catch {
            await MainActor.run { isLoading = false }
            print("[DataView] loadData error: \(error)")
        }
    }
}

// MARK: - Day-scoped subviews (take data as params, not from appState)

struct DayWeightCard: View {
    let weightKg: Double?
    var body: some View {
        HStack(spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(hex: "9B7EC8").opacity(0.10))
                    .frame(width: 44, height: 44)
                Image(systemName: "scalemass")
                    .font(.system(size: 20))
                    .foregroundColor(Color(hex: "9B7EC8"))
            }
            VStack(alignment: .leading, spacing: 3) {
                Text("WEIGHT")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(Color(hex: "B09880"))
                    .kerning(1.0)
                if let w = weightKg {
                    HStack(alignment: .lastTextBaseline, spacing: 4) {
                        Text(String(format: "%.1f", w))
                            .font(.system(size: 26, weight: .bold, design: .rounded))
                            .foregroundColor(Color(hex: "9B7EC8"))
                        Text("kg").font(.system(size: 13)).foregroundColor(Color(hex: "B09880"))
                    }
                } else {
                    Text("Not logged").font(.system(size: 15, weight: .medium)).foregroundColor(Color(hex: "B09880"))
                }
            }
            Spacer()
        }
        .padding(18)
        .background(Color.white)
        .cornerRadius(18)
        .shadow(color: .black.opacity(0.05), radius: 8, y: 2)
    }
}

struct DaySummaryRow: View {
    let caloriesConsumed: Int
    let caloriesBurned: Int
    let caloriesTarget: Int
    let water: Int

    var netCalories: Int { caloriesConsumed - caloriesBurned }
    var remaining: Int { max(0, caloriesTarget - netCalories) }

    var body: some View {
        HStack(spacing: 12) {
            SummaryTile(icon: "flame.fill", iconColor: Color(hex: "E76F51"),
                        value: "\(netCalories)", unit: "kcal", label: "Net calories",
                        sub: "\(remaining) remaining")
            SummaryTile(icon: "drop.fill", iconColor: Color(hex: "457B9D"),
                        value: "\(water)", unit: "/ 8", label: "Water",
                        sub: water >= 8 ? "Goal reached!" : "\(8 - water) more to go")
            SummaryTile(icon: "fork.knife", iconColor: Color(hex: "E9C46A"),
                        value: "\(caloriesConsumed)", unit: "kcal", label: "Eaten",
                        sub: "\(caloriesBurned) burned")
        }
    }
}

struct DayCalorieBreakdownCard: View {
    let caloriesConsumed: Int
    let caloriesBurned: Int
    let caloriesTarget: Int
    let burnRequired: Int

    var netCalories: Int { caloriesConsumed - caloriesBurned }
    var progress: Double { min(1.0, Double(max(0, netCalories)) / Double(max(caloriesTarget, 1))) }

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("CALORIES").font(.system(size: 10, weight: .semibold)).foregroundColor(Color(hex: "B09880")).kerning(1.0)
                    Text("Daily breakdown").font(.system(size: 16, weight: .bold)).foregroundColor(Color(hex: "3D2B1F"))
                }
                Spacer()
                if burnRequired > 0 {
                    Label("Burn \(burnRequired) kcal", systemImage: "flame.fill")
                        .font(.system(size: 11, weight: .semibold)).foregroundColor(Color(hex: "E76F51"))
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(Color(hex: "E76F51").opacity(0.1)).cornerRadius(20)
                } else if caloriesConsumed > 0 {
                    Label("On track", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 11, weight: .semibold)).foregroundColor(Color(hex: "2A9D8F"))
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(Color(hex: "2A9D8F").opacity(0.1)).cornerRadius(20)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 6).fill(Color(hex: "F0E6DA")).frame(height: 10)
                        RoundedRectangle(cornerRadius: 6)
                            .fill(LinearGradient(colors: [Color(hex: "E76F51"), Color(hex: "F4A261")], startPoint: .leading, endPoint: .trailing))
                            .frame(width: geo.size.width * progress, height: 10)
                            .animation(.spring(), value: progress)
                    }
                }.frame(height: 10)
                HStack {
                    Text("0").font(.system(size: 10)).foregroundColor(Color(hex: "B09880"))
                    Spacer()
                    Text("\(caloriesTarget) kcal target").font(.system(size: 10)).foregroundColor(Color(hex: "B09880"))
                }
            }
            HStack(spacing: 0) {
                CalorieStat(label: "Eaten", value: "\(caloriesConsumed)", color: Color(hex: "E76F51"), icon: "fork.knife")
                Divider().frame(height: 40)
                CalorieStat(label: "Exercise burned", value: "\(caloriesBurned)", color: Color(hex: "2A9D8F"), icon: "figure.run")
                Divider().frame(height: 40)
                CalorieStat(label: "Remaining", value: "\(max(0, caloriesTarget - netCalories))", color: Color(hex: "457B9D"), icon: "target")
            }
        }
        .padding(18)
        .background(Color.white)
        .cornerRadius(18)
        .shadow(color: .black.opacity(0.05), radius: 8, y: 2)
    }
}

struct DayFoodLog: View {
    let meals: [MealEntry]
    @State private var expanded = false
    var totalCalories: Int { meals.reduce(0) { $0 + $1.calories } }

    var body: some View {
        VStack(spacing: 0) {
            Button(action: { withAnimation(.spring(response: 0.35)) { expanded.toggle() } }) {
                HStack(spacing: 10) {
                    Image(systemName: "fork.knife").font(.system(size: 13)).foregroundColor(Color(hex: "E76F51"))
                    VStack(alignment: .leading, spacing: 1) {
                        Text("FOOD LOG").font(.system(size: 10, weight: .semibold)).foregroundColor(Color(hex: "B09880")).kerning(1.0)
                        Text("Meals logged").font(.system(size: 15, weight: .bold)).foregroundColor(Color(hex: "3D2B1F"))
                    }
                    Spacer()
                    if totalCalories > 0 {
                        Text("\(totalCalories) kcal").font(.system(size: 13, weight: .bold)).foregroundColor(Color(hex: "E76F51"))
                    }
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 12, weight: .semibold)).foregroundColor(Color(hex: "B09880")).padding(.leading, 4)
                }
                .padding(18)
            }
            .buttonStyle(.plain)

            if expanded {
                if meals.isEmpty {
                    Text("Nothing logged").font(.subheadline).foregroundColor(Color(hex: "B09880"))
                        .frame(maxWidth: .infinity).padding(.vertical, 20)
                } else {
                    Divider().padding(.horizontal, 18)
                    ForEach(meals) { meal in
                        MealRow(meal: meal).padding(.horizontal, 18)
                        if meal.id != meals.last?.id { Divider().padding(.horizontal, 18) }
                    }
                    .padding(.bottom, 8)
                }
            }
        }
        .background(Color.white).cornerRadius(18).shadow(color: .black.opacity(0.05), radius: 8, y: 2).clipped()
    }
}

struct DayWorkoutLog: View {
    let workouts: [WorkoutEntry]
    @State private var expanded = false
    var totalBurned: Int { workouts.reduce(0) { $0 + $1.caloriesBurned } }

    var body: some View {
        VStack(spacing: 0) {
            Button(action: { withAnimation(.spring(response: 0.35)) { expanded.toggle() } }) {
                HStack(spacing: 10) {
                    Image(systemName: "figure.run").font(.system(size: 13)).foregroundColor(Color(hex: "2A9D8F"))
                    VStack(alignment: .leading, spacing: 1) {
                        Text("WORKOUTS").font(.system(size: 10, weight: .semibold)).foregroundColor(Color(hex: "B09880")).kerning(1.0)
                        Text("Exercise").font(.system(size: 15, weight: .bold)).foregroundColor(Color(hex: "3D2B1F"))
                    }
                    Spacer()
                    if totalBurned > 0 {
                        Text("\(totalBurned) kcal burned").font(.system(size: 13, weight: .bold)).foregroundColor(Color(hex: "2A9D8F"))
                    }
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 12, weight: .semibold)).foregroundColor(Color(hex: "B09880")).padding(.leading, 4)
                }
                .padding(18)
            }
            .buttonStyle(.plain)

            if expanded {
                if workouts.isEmpty {
                    Text("No workouts logged").font(.subheadline).foregroundColor(Color(hex: "B09880"))
                        .frame(maxWidth: .infinity).padding(.vertical, 20)
                } else {
                    Divider().padding(.horizontal, 18)
                    ForEach(workouts) { workout in
                        WorkoutRow(workout: workout).padding(.horizontal, 18)
                        if workout.id != workouts.last?.id { Divider().padding(.horizontal, 18) }
                    }
                    .padding(.bottom, 8)
                }
            }
        }
        .background(Color.white).cornerRadius(18).shadow(color: .black.opacity(0.05), radius: 8, y: 2).clipped()
    }
}

// MARK: - Summary row (3 glanceable tiles)

struct SummaryRow: View {
    @EnvironmentObject var appState: AppState

    var netCalories: Int { appState.caloriesConsumed - appState.caloriesBurned }
    var remaining: Int { max(0, appState.caloriesTarget - netCalories) }

    var body: some View {
        HStack(spacing: 12) {
            SummaryTile(
                icon: "flame.fill",
                iconColor: Color(hex: "E76F51"),
                value: "\(netCalories)",
                unit: "kcal",
                label: "Net calories",
                sub: "\(remaining) remaining"
            )
            SummaryTile(
                icon: "drop.fill",
                iconColor: Color(hex: "457B9D"),
                value: "\(appState.waterGlasses)",
                unit: "/ 8",
                label: "Water today",
                sub: appState.waterGlasses >= 8 ? "Goal reached!" : "\(8 - appState.waterGlasses) more to go"
            )
            SummaryTile(
                icon: "scalemass",
                iconColor: Color(hex: "9B7EC8"),
                value: appState.todayWeightKg.map { String(format: "%.1f", $0) } ?? "—",
                unit: appState.todayWeightKg != nil ? "kg" : "",
                label: "Weight",
                sub: appState.todayWeightKg != nil ? "Logged today" : "Tell Rena"
            )
        }
    }
}

struct SummaryTile: View {
    let icon: String
    let iconColor: Color
    let value: String
    let unit: String
    let label: String
    let sub: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 15))
                .foregroundColor(iconColor)

            HStack(alignment: .lastTextBaseline, spacing: 3) {
                Text(value)
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .foregroundColor(Color(hex: "3D2B1F"))
                if !unit.isEmpty {
                    Text(unit)
                        .font(.system(size: 11))
                        .foregroundColor(Color(hex: "B09880"))
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(Color(hex: "3D2B1F"))
                Text(sub)
                    .font(.system(size: 10))
                    .foregroundColor(Color(hex: "B09880"))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color.white)
        .cornerRadius(16)
        .shadow(color: .black.opacity(0.04), radius: 6, y: 2)
    }
}

// MARK: - Calorie breakdown card

struct CalorieBreakdownCard: View {
    @EnvironmentObject var appState: AppState

    var netCalories: Int { appState.caloriesConsumed - appState.caloriesBurned }
    var progress: Double { min(1.0, Double(max(0, netCalories)) / Double(max(appState.caloriesTarget, 1))) }

    var body: some View {
        VStack(spacing: 16) {

            // Header
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("CALORIES")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(Color(hex: "B09880"))
                        .kerning(1.0)
                    Text("Daily breakdown")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(Color(hex: "3D2B1F"))
                }
                Spacer()
                // Status badge
                if appState.burnRequired > 0 {
                    Label("Burn \(appState.burnRequired) kcal", systemImage: "flame.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(Color(hex: "E76F51"))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Color(hex: "E76F51").opacity(0.1))
                        .cornerRadius(20)
                } else if appState.caloriesConsumed > 0 {
                    Label("On track", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(Color(hex: "2A9D8F"))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Color(hex: "2A9D8F").opacity(0.1))
                        .cornerRadius(20)
                }
            }

            // Progress bar
            VStack(alignment: .leading, spacing: 6) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color(hex: "F0E6DA"))
                            .frame(height: 10)
                        RoundedRectangle(cornerRadius: 6)
                            .fill(LinearGradient(
                                colors: [Color(hex: "E76F51"), Color(hex: "F4A261")],
                                startPoint: .leading, endPoint: .trailing))
                            .frame(width: geo.size.width * progress, height: 10)
                            .animation(.spring(), value: progress)
                    }
                }
                .frame(height: 10)

                HStack {
                    Text("0")
                        .font(.system(size: 10))
                        .foregroundColor(Color(hex: "B09880"))
                    Spacer()
                    Text("\(appState.caloriesTarget) kcal target")
                        .font(.system(size: 10))
                        .foregroundColor(Color(hex: "B09880"))
                }
            }

            // Three stats
            HStack(spacing: 0) {
                CalorieStat(
                    label: "Eaten",
                    value: "\(appState.caloriesConsumed)",
                    color: Color(hex: "E76F51"),
                    icon: "fork.knife"
                )
                Divider().frame(height: 40)
                CalorieStat(
                    label: "Exercise burned",
                    value: "\(appState.caloriesBurned)",
                    color: Color(hex: "2A9D8F"),
                    icon: "figure.run"
                )
                Divider().frame(height: 40)
                CalorieStat(
                    label: "Remaining",
                    value: "\(max(0, appState.caloriesTarget - netCalories))",
                    color: Color(hex: "457B9D"),
                    icon: "target"
                )
            }
        }
        .padding(18)
        .background(Color.white)
        .cornerRadius(18)
        .shadow(color: .black.opacity(0.05), radius: 8, y: 2)
    }
}

struct CalorieStat: View {
    let label: String
    let value: String
    let color: Color
    let icon: String

    var body: some View {
        VStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 13))
                .foregroundColor(color)
            Text(value)
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .foregroundColor(Color(hex: "3D2B1F"))
            Text(label)
                .font(.system(size: 10))
                .foregroundColor(Color(hex: "B09880"))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Collapsible wrappers

struct CollapsibleFoodLog: View {
    @State private var expanded = false
    @EnvironmentObject var appState: AppState

    var totalCalories: Int { appState.mealsLogged.reduce(0) { $0 + $1.calories } }

    var body: some View {
        VStack(spacing: 0) {
            // Tappable header
            Button(action: { withAnimation(.spring(response: 0.35)) { expanded.toggle() } }) {
                HStack(spacing: 10) {
                    Image(systemName: "fork.knife")
                        .font(.system(size: 13))
                        .foregroundColor(Color(hex: "E76F51"))
                    VStack(alignment: .leading, spacing: 1) {
                        Text("FOOD LOG")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(Color(hex: "B09880"))
                            .kerning(1.0)
                        Text("What you've eaten today")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundColor(Color(hex: "3D2B1F"))
                    }
                    Spacer()
                    if totalCalories > 0 {
                        Text("\(totalCalories) kcal")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundColor(Color(hex: "E76F51"))
                    }
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(Color(hex: "B09880"))
                        .padding(.leading, 4)
                }
                .padding(18)
            }
            .buttonStyle(.plain)

            if expanded {
                if appState.mealsLogged.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "fork.knife")
                            .font(.system(size: 32))
                            .foregroundColor(Color(hex: "E8D5C4"))
                        Text("Nothing logged yet")
                            .font(.subheadline.weight(.medium))
                            .foregroundColor(Color(hex: "B09880"))
                        Text("Tell Rena what you ate and she'll log it with calories and macros")
                            .font(.caption)
                            .foregroundColor(Color(hex: "C4AFA0"))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 20)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 20)
                    .padding(.bottom, 4)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                } else {
                    Divider().padding(.horizontal, 18)
                    ForEach(appState.mealsLogged) { meal in
                        MealRow(meal: meal).padding(.horizontal, 18)
                        if meal.id != appState.mealsLogged.last?.id {
                            Divider().padding(.horizontal, 18)
                        }
                    }
                    .padding(.bottom, 8)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        }
        .background(Color.white)
        .cornerRadius(18)
        .shadow(color: .black.opacity(0.05), radius: 8, y: 2)
        .clipped()
    }
}

struct CollapsibleWorkoutLog: View {
    @State private var expanded = false
    @EnvironmentObject var appState: AppState

    var totalBurned: Int { appState.workoutsLogged.reduce(0) { $0 + $1.caloriesBurned } }

    var body: some View {
        VStack(spacing: 0) {
            Button(action: { withAnimation(.spring(response: 0.35)) { expanded.toggle() } }) {
                HStack(spacing: 10) {
                    Image(systemName: "figure.run")
                        .font(.system(size: 13))
                        .foregroundColor(Color(hex: "2A9D8F"))
                    VStack(alignment: .leading, spacing: 1) {
                        Text("WORKOUTS")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(Color(hex: "B09880"))
                            .kerning(1.0)
                        Text("Exercise today")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundColor(Color(hex: "3D2B1F"))
                    }
                    Spacer()
                    if totalBurned > 0 {
                        Text("\(totalBurned) kcal burned")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundColor(Color(hex: "2A9D8F"))
                    }
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(Color(hex: "B09880"))
                        .padding(.leading, 4)
                }
                .padding(18)
            }
            .buttonStyle(.plain)

            if expanded {
                if appState.workoutsLogged.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "figure.run")
                            .font(.system(size: 32))
                            .foregroundColor(Color(hex: "C8E6E2"))
                        Text("No workouts logged yet")
                            .font(.subheadline.weight(.medium))
                            .foregroundColor(Color(hex: "B09880"))
                        Text("Tell Rena about your workout and she'll estimate calories burned")
                            .font(.caption)
                            .foregroundColor(Color(hex: "C4AFA0"))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 20)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 20)
                    .padding(.bottom, 4)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                } else {
                    Divider().padding(.horizontal, 18)
                    ForEach(appState.workoutsLogged) { workout in
                        WorkoutRow(workout: workout).padding(.horizontal, 18)
                        if workout.id != appState.workoutsLogged.last?.id {
                            Divider().padding(.horizontal, 18)
                        }
                    }
                    .padding(.bottom, 8)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        }
        .background(Color.white)
        .cornerRadius(18)
        .shadow(color: .black.opacity(0.05), radius: 8, y: 2)
        .clipped()
    }
}

// MARK: - Food log

struct FoodLogCard: View {
    @EnvironmentObject var appState: AppState

    var totalCalories: Int { appState.mealsLogged.reduce(0) { $0 + $1.calories } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Section header
            HStack {
                HStack(spacing: 8) {
                    Image(systemName: "fork.knife")
                        .font(.system(size: 13))
                        .foregroundColor(Color(hex: "E76F51"))
                    VStack(alignment: .leading, spacing: 1) {
                        Text("FOOD LOG")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(Color(hex: "B09880"))
                            .kerning(1.0)
                        Text("What you've eaten today")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundColor(Color(hex: "3D2B1F"))
                    }
                }
                Spacer()
                if totalCalories > 0 {
                    Text("\(totalCalories) kcal")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(Color(hex: "E76F51"))
                }
            }
            .padding(18)

            if appState.mealsLogged.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "fork.knife")
                        .font(.system(size: 32))
                        .foregroundColor(Color(hex: "E8D5C4"))
                    Text("Nothing logged yet")
                        .font(.subheadline.weight(.medium))
                        .foregroundColor(Color(hex: "B09880"))
                    Text("Tell Rena what you ate and she'll log it with calories and macros")
                        .font(.caption)
                        .foregroundColor(Color(hex: "C4AFA0"))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 20)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
                .padding(.bottom, 4)
            } else {
                Divider().padding(.horizontal, 18)
                ForEach(appState.mealsLogged) { meal in
                    MealRow(meal: meal)
                        .padding(.horizontal, 18)
                    if meal.id != appState.mealsLogged.last?.id {
                        Divider().padding(.horizontal, 18)
                    }
                }
                .padding(.bottom, 8)
            }
        }
        .background(Color.white)
        .cornerRadius(18)
        .shadow(color: .black.opacity(0.05), radius: 8, y: 2)
    }
}

struct MealRow: View {
    let meal: MealEntry

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 5) {
                Text(meal.name)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(Color(hex: "3D2B1F"))
                HStack(spacing: 6) {
                    MacroPill(label: "Protein", value: meal.proteinG, unit: "g", color: Color(hex: "2A9D8F"))
                    MacroPill(label: "Carbs",   value: meal.carbsG,   unit: "g", color: Color(hex: "457B9D"))
                    MacroPill(label: "Fat",     value: meal.fatG,     unit: "g", color: Color(hex: "E9C46A"))
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 1) {
                Text("\(meal.calories)")
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                    .foregroundColor(Color(hex: "E76F51"))
                Text("kcal")
                    .font(.system(size: 10))
                    .foregroundColor(Color(hex: "B09880"))
            }
        }
        .padding(.vertical, 12)
    }
}

struct MacroPill: View {
    let label: String
    let value: Int
    let unit: String
    let color: Color

    var body: some View {
        HStack(spacing: 2) {
            Text(label)
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(color)
            Text("\(value)\(unit)")
                .font(.system(size: 9))
                .foregroundColor(Color(hex: "7C5C45"))
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(color.opacity(0.1))
        .cornerRadius(6)
    }
}

// MARK: - Workout log

struct WorkoutLogCard: View {
    @EnvironmentObject var appState: AppState

    var totalBurned: Int { appState.workoutsLogged.reduce(0) { $0 + $1.caloriesBurned } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Section header
            HStack {
                HStack(spacing: 8) {
                    Image(systemName: "figure.run")
                        .font(.system(size: 13))
                        .foregroundColor(Color(hex: "2A9D8F"))
                    VStack(alignment: .leading, spacing: 1) {
                        Text("WORKOUTS")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(Color(hex: "B09880"))
                            .kerning(1.0)
                        Text("Exercise today")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundColor(Color(hex: "3D2B1F"))
                    }
                }
                Spacer()
                if totalBurned > 0 {
                    Text("\(totalBurned) kcal burned")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(Color(hex: "2A9D8F"))
                }
            }
            .padding(18)

            if appState.workoutsLogged.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "figure.run")
                        .font(.system(size: 32))
                        .foregroundColor(Color(hex: "C8E6E2"))
                    Text("No workouts logged yet")
                        .font(.subheadline.weight(.medium))
                        .foregroundColor(Color(hex: "B09880"))
                    Text("Tell Rena about your workout and she'll estimate calories burned")
                        .font(.caption)
                        .foregroundColor(Color(hex: "C4AFA0"))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 20)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
                .padding(.bottom, 4)
            } else {
                Divider().padding(.horizontal, 18)
                ForEach(appState.workoutsLogged) { workout in
                    WorkoutRow(workout: workout)
                        .padding(.horizontal, 18)
                    if workout.id != appState.workoutsLogged.last?.id {
                        Divider().padding(.horizontal, 18)
                    }
                }
                .padding(.bottom, 8)
            }
        }
        .background(Color.white)
        .cornerRadius(18)
        .shadow(color: .black.opacity(0.05), radius: 8, y: 2)
    }
}

struct WorkoutRow: View {
    let workout: WorkoutEntry

    var workoutIcon: String {
        let t = workout.type.lowercased()
        if t.contains("run") || t.contains("jog") { return "figure.run" }
        if t.contains("walk") { return "figure.walk" }
        if t.contains("swim") { return "figure.pool.swim" }
        if t.contains("bike") || t.contains("cycl") { return "figure.outdoor.cycle" }
        if t.contains("yoga") || t.contains("stretch") { return "figure.yoga" }
        if t.contains("gym") || t.contains("lift") || t.contains("weight") { return "dumbbell.fill" }
        if t.contains("hiit") || t.contains("circuit") { return "bolt.heart.fill" }
        return "figure.mixed.cardio"
    }

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color(hex: "2A9D8F").opacity(0.10))
                    .frame(width: 40, height: 40)
                Image(systemName: workoutIcon)
                    .font(.system(size: 16))
                    .foregroundColor(Color(hex: "2A9D8F"))
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(workout.type.capitalized)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(Color(hex: "3D2B1F"))
                Text("\(workout.durationMin) min")
                    .font(.system(size: 12))
                    .foregroundColor(Color(hex: "B09880"))
            }

            Spacer()

            if workout.caloriesBurned > 0 {
                VStack(alignment: .trailing, spacing: 1) {
                    Text("−\(workout.caloriesBurned)")
                        .font(.system(size: 17, weight: .bold, design: .rounded))
                        .foregroundColor(Color(hex: "2A9D8F"))
                    Text("kcal")
                        .font(.system(size: 10))
                        .foregroundColor(Color(hex: "B09880"))
                }
            }
        }
        .padding(.vertical, 12)
    }
}

// MARK: - Weight card (display only — log via Workbook tab)

struct WeightCard: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        HStack(spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(hex: "9B7EC8").opacity(0.10))
                    .frame(width: 44, height: 44)
                Image(systemName: "scalemass")
                    .font(.system(size: 20))
                    .foregroundColor(Color(hex: "9B7EC8"))
            }

            VStack(alignment: .leading, spacing: 3) {
                Text("TODAY'S WEIGHT")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(Color(hex: "B09880"))
                    .kerning(1.0)
                if let w = appState.todayWeightKg {
                    HStack(alignment: .lastTextBaseline, spacing: 4) {
                        Text(String(format: "%.1f", w))
                            .font(.system(size: 26, weight: .bold, design: .rounded))
                            .foregroundColor(Color(hex: "9B7EC8"))
                        Text("kg")
                            .font(.system(size: 13))
                            .foregroundColor(Color(hex: "B09880"))
                    }
                } else {
                    Text("Not logged yet")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(Color(hex: "B09880"))
                    Text("Log it in the Workbook tab")
                        .font(.system(size: 11))
                        .foregroundColor(Color(hex: "C4AFA0"))
                }
            }

            Spacer()
        }
        .padding(18)
        .background(Color.white)
        .cornerRadius(18)
        .shadow(color: .black.opacity(0.05), radius: 8, y: 2)
    }
}

// MARK: - Water card (kept for compatibility / DataView internal use)

struct WaterCard: View {
    @EnvironmentObject var appState: AppState
    private let target = 8

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Water").font(.headline).foregroundColor(Color(hex: "3D2B1F"))
                Spacer()
                Text("\(appState.waterGlasses) of \(target) glasses")
                    .font(.subheadline).foregroundColor(Color(hex: "7C5C45"))
            }
            HStack(spacing: 8) {
                ForEach(0..<target, id: \.self) { i in
                    Image(systemName: i < appState.waterGlasses ? "drop.fill" : "drop")
                        .font(.title2)
                        .foregroundColor(i < appState.waterGlasses ? Color(hex: "457B9D") : Color(hex: "D0C4B8"))
                        .animation(.spring(response: 0.3), value: appState.waterGlasses)
                }
            }
        }
        .padding(16)
        .background(Color.white)
        .cornerRadius(18)
        .shadow(color: .black.opacity(0.05), radius: 8, y: 2)
    }
}

// MARK: - Kept for compatibility

struct StatPill: View {
    let label: String
    let value: String
    let color: Color
    var body: some View {
        VStack(spacing: 2) {
            Text(value).font(.system(size: 18, weight: .bold, design: .rounded)).foregroundColor(color)
            Text(label).font(.caption).foregroundColor(Color(hex: "7C5C45"))
        }
    }
}

struct StatRing: View {
    let value: Int; let total: Int; let label: String; let color: Color
    var progress: Double { min(1.0, Double(value) / Double(max(total, 1))) }
    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                Circle().stroke(color.opacity(0.15), lineWidth: 10)
                Circle().trim(from: 0, to: progress)
                    .stroke(color, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                    .rotationEffect(.degrees(-90)).animation(.spring(), value: progress)
                VStack(spacing: 0) {
                    Text("\(value)").font(.system(size: 18, weight: .bold, design: .rounded)).foregroundColor(Color(hex: "3D2B1F"))
                    Text("/ \(total)").font(.caption2).foregroundColor(Color(hex: "7C5C45"))
                }
            }.frame(width: 90, height: 90)
            Text(label).font(.caption.bold()).foregroundColor(Color(hex: "7C5C45"))
        }.frame(maxWidth: .infinity)
    }
}

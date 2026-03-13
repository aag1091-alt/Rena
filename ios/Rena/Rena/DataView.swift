import SwiftUI

struct DataView: View {
    @EnvironmentObject var appState: AppState
    @State private var isRefreshing = false

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 16) {
                    CalorieSummaryCard()
                    WaterCard()
                    FoodLogCard()
                    Spacer(minLength: 40)
                }
                // Note: Scan food will be added back as a feature later
                .padding(.horizontal, 16)
                .padding(.top, 8)
            }
            .background(Color(hex: "F7F3EE").ignoresSafeArea())
            .navigationTitle("Today")
            .navigationBarTitleDisplayMode(.large)
            .scrollBounceBehavior(.always)
            .refreshable { await refreshProgress() }
            .onAppear { Task { await refreshProgress() } }
        }
    }

    private func refreshProgress() async {
        guard let resp = try? await RenaAPI.shared.getProgress(userId: appState.userId) else { return }
        await MainActor.run {
            appState.caloriesConsumed = resp.caloriesConsumed
            appState.caloriesTarget   = resp.caloriesTarget
            appState.waterGlasses     = resp.waterGlasses
            appState.mealsLogged      = resp.mealsLogged ?? []
        }
    }
}

// MARK: - Calorie summary

struct CalorieSummaryCard: View {
    @EnvironmentObject var appState: AppState

    var progress: Double { min(1.0, Double(appState.caloriesConsumed) / Double(max(appState.caloriesTarget, 1))) }

    var body: some View {
        VStack(spacing: 14) {
            HStack {
                Text("Calories").font(.headline).foregroundColor(Color(hex: "3D2B1F"))
                Spacer()
                Text("\(appState.caloriesConsumed) / \(appState.caloriesTarget) kcal")
                    .font(.subheadline).foregroundColor(Color(hex: "7C5C45"))
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 6).fill(Color(hex: "F0E6DA")).frame(height: 12)
                    RoundedRectangle(cornerRadius: 6)
                        .fill(LinearGradient(colors: [Color(hex: "E76F51"), Color(hex: "F4A261")],
                                            startPoint: .leading, endPoint: .trailing))
                        .frame(width: geo.size.width * progress, height: 12)
                        .animation(.spring(), value: progress)
                }
            }
            .frame(height: 12)

            HStack {
                StatPill(label: "Remaining", value: "\(max(0, appState.caloriesTarget - appState.caloriesConsumed))", color: Color(hex: "2A9D8F"))
                Spacer()
                StatPill(label: "Consumed", value: "\(appState.caloriesConsumed)", color: Color(hex: "E76F51"))
            }
        }
        .padding(16)
        .background(Color.white)
        .cornerRadius(18)
        .shadow(color: .black.opacity(0.05), radius: 8, y: 2)
    }
}

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

// MARK: - Water tracker

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

            if appState.waterGlasses == 0 {
                Text("Tell Rena when you drink — she'll track it for you")
                    .font(.caption).foregroundColor(Color(hex: "7C5C45").opacity(0.7))
            }
        }
        .padding(16)
        .background(Color.white)
        .cornerRadius(18)
        .shadow(color: .black.opacity(0.05), radius: 8, y: 2)
    }
}

// MARK: - Food log

struct FoodLogCard: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Food Log").font(.headline).foregroundColor(Color(hex: "3D2B1F"))
                Spacer()
                Text("Today").font(.caption).foregroundColor(Color(hex: "7C5C45"))
            }

            if appState.mealsLogged.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "fork.knife").font(.largeTitle)
                        .foregroundColor(Color(hex: "E76F51").opacity(0.3))
                    Text("Nothing logged yet")
                        .font(.subheadline).foregroundColor(Color(hex: "7C5C45"))
                    Text("Tell Rena what you ate or scan a meal")
                        .font(.caption).foregroundColor(Color(hex: "7C5C45").opacity(0.7))
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)
            } else {
                VStack(spacing: 1) {
                    ForEach(appState.mealsLogged) { meal in
                        MealRow(meal: meal)
                        if meal.id != appState.mealsLogged.last?.id {
                            Divider().padding(.leading, 4)
                        }
                    }
                }
            }
        }
        .padding(16)
        .background(Color.white)
        .cornerRadius(18)
        .shadow(color: .black.opacity(0.05), radius: 8, y: 2)
    }
}

struct MealRow: View {
    let meal: MealEntry

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(Color(hex: "E76F51").opacity(0.12))
                .frame(width: 40, height: 40)
                .overlay(
                    Image(systemName: "fork.knife")
                        .font(.system(size: 16))
                        .foregroundColor(Color(hex: "E76F51"))
                )

            VStack(alignment: .leading, spacing: 3) {
                Text(meal.name)
                    .font(.subheadline.weight(.medium))
                    .foregroundColor(Color(hex: "3D2B1F"))
                HStack(spacing: 8) {
                    MacroPill(label: "P", value: meal.proteinG, color: Color(hex: "2A9D8F"))
                    MacroPill(label: "C", value: meal.carbsG,   color: Color(hex: "457B9D"))
                    MacroPill(label: "F", value: meal.fatG,     color: Color(hex: "E9C46A"))
                }
            }

            Spacer()

            Text("\(meal.calories)")
                .font(.system(size: 16, weight: .bold, design: .rounded))
                .foregroundColor(Color(hex: "E76F51"))
            + Text(" kcal")
                .font(.caption)
                .foregroundColor(Color(hex: "7C5C45"))
        }
        .padding(.vertical, 8)
    }
}

struct MacroPill: View {
    let label: String
    let value: Int
    let color: Color

    var body: some View {
        HStack(spacing: 3) {
            Text(label).font(.caption2.weight(.bold)).foregroundColor(color)
            Text("\(value)g").font(.caption2).foregroundColor(Color(hex: "7C5C45"))
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(color.opacity(0.1))
        .cornerRadius(6)
    }
}

// MARK: - Scan entry point

struct ScanEntryCard: View {
    var body: some View {
        NavigationLink(destination: ScanView()) {
            HStack(spacing: 14) {
                Circle()
                    .fill(Color(hex: "E76F51").opacity(0.1))
                    .frame(width: 44, height: 44)
                    .overlay(
                        Image(systemName: "camera.fill")
                            .font(.system(size: 18))
                            .foregroundColor(Color(hex: "E76F51"))
                    )
                VStack(alignment: .leading, spacing: 2) {
                    Text("Scan a meal").font(.headline).foregroundColor(Color(hex: "3D2B1F"))
                    Text("Point your camera at food to log it")
                        .font(.caption).foregroundColor(Color(hex: "7C5C45"))
                }
                Spacer()
                Image(systemName: "chevron.right").foregroundColor(Color(hex: "7C5C45"))
            }
            .padding(16)
            .background(Color.white)
            .cornerRadius(18)
            .shadow(color: .black.opacity(0.05), radius: 8, y: 2)
        }
    }
}

// MARK: - Stat ring (kept for compatibility)

struct StatRing: View {
    let value: Int
    let total: Int
    let label: String
    let color: Color

    var progress: Double { min(1.0, Double(value) / Double(max(total, 1))) }

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                Circle().stroke(color.opacity(0.15), lineWidth: 10)
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(color, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.spring(), value: progress)
                VStack(spacing: 0) {
                    Text("\(value)")
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                        .foregroundColor(Color(hex: "3D2B1F"))
                    Text("/ \(total)")
                        .font(.caption2).foregroundColor(Color(hex: "7C5C45"))
                }
            }
            .frame(width: 90, height: 90)
            Text(label).font(.caption.bold()).foregroundColor(Color(hex: "7C5C45"))
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Visual journey + Daily targets (kept for DataView use)

struct VisualJourneyCard: View {
    @EnvironmentObject var appState: AppState
    @State private var isGenerating = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Your Journey").font(.headline).foregroundColor(Color(hex: "3D2B1F"))
                Spacer()
                Button { Task { await generateVisual() } } label: {
                    if isGenerating { ProgressView().scaleEffect(0.8) }
                    else { Image(systemName: "arrow.clockwise").foregroundColor(Color(hex: "E76F51")) }
                }
            }
            if let url = appState.visualJourneyURL {
                AsyncImage(url: url) { image in
                    image.resizable().aspectRatio(contentMode: .fill)
                        .frame(maxWidth: .infinity).frame(height: 200).clipped().cornerRadius(12)
                } placeholder: {
                    RoundedRectangle(cornerRadius: 12).fill(Color(hex: "F4E4D0")).frame(height: 200).overlay(ProgressView())
                }
            } else {
                Button { Task { await generateVisual() } } label: {
                    RoundedRectangle(cornerRadius: 12).fill(Color(hex: "F4E4D0")).frame(height: 200)
                        .overlay(VStack(spacing: 8) {
                            Image(systemName: "sparkles").font(.largeTitle).foregroundColor(Color(hex: "E76F51"))
                            Text("Generate your vision").font(.subheadline).foregroundColor(Color(hex: "7C5C45"))
                        })
                }
            }
        }
        .padding().background(Color.white).cornerRadius(16)
        .shadow(color: .black.opacity(0.04), radius: 8, y: 2)
    }

    private func generateVisual() async {
        isGenerating = true
        defer { isGenerating = false }
        guard let resp = try? await RenaAPI.shared.getVisualJourney(userId: appState.userId),
              let urlStr = resp.imageUrl, let url = URL(string: urlStr) else { return }
        await MainActor.run { appState.visualJourneyURL = url }
    }
}

struct DailyTargetsCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Quick Log").font(.headline).foregroundColor(Color(hex: "3D2B1F"))
            HStack(spacing: 12) {
                QuickLogButton(icon: "drop.fill",    label: "Water",   color: Color(hex: "457B9D")) {}
                QuickLogButton(icon: "figure.walk",  label: "Workout", color: Color(hex: "2A9D8F")) {}
                QuickLogButton(icon: "fork.knife",   label: "Meal",    color: Color(hex: "E76F51")) {}
            }
        }
        .padding().background(Color.white).cornerRadius(16)
        .shadow(color: .black.opacity(0.04), radius: 8, y: 2)
    }
}

struct QuickLogButton: View {
    let icon: String
    let label: String
    let color: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: icon).font(.title2).foregroundColor(color)
                Text(label).font(.caption.bold()).foregroundColor(Color(hex: "3D2B1F"))
            }
            .frame(maxWidth: .infinity).padding(.vertical, 14)
            .background(color.opacity(0.1)).cornerRadius(12)
        }
    }
}

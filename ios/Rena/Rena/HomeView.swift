import SwiftUI

struct HomeView: View {
    @EnvironmentObject var appState: AppState
    @State private var isLoadingImage = false

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 24) {

                    // Goal header
                    GoalHeaderView()

                    // Visual journey
                    VisualJourneyCard()

                    // Progress rings
                    ProgressSummaryCard()

                    // Daily targets
                    DailyTargetsCard()

                    Spacer(minLength: 32)
                }
                .padding(.horizontal)
                .frame(maxWidth: .infinity)
            }
            .background(Color(hex: "FDF6EE").ignoresSafeArea())
            .navigationTitle("Today")
            .navigationBarTitleDisplayMode(.large)
            .scrollBounceBehavior(.always)
            .onAppear { Task { await refreshProgress() } }
        }
    }

    private func refreshProgress() async {
        guard let resp = try? await RenaAPI.shared.getProgress(userId: appState.userId) else { return }
        await MainActor.run {
            appState.caloriesConsumed = resp.caloriesConsumed
            appState.caloriesTarget = resp.caloriesTarget
            appState.waterGlasses = resp.waterGlasses
        }
    }
}

// MARK: - Subviews

struct GoalHeaderView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Working toward")
                .font(.caption)
                .foregroundColor(Color(hex: "7C5C45"))
            Text(appState.goal.isEmpty ? "Set your goal" : appState.goal)
                .font(.title3.bold())
                .foregroundColor(Color(hex: "3D2B1F"))
            if let days = appState.daysUntilDeadline {
                Text("\(days) days to go")
                    .font(.caption)
                    .foregroundColor(Color(hex: "E76F51"))
                    .fontWeight(.semibold)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color.white)
        .cornerRadius(16)
        .shadow(color: .black.opacity(0.04), radius: 8, y: 2)
    }
}

struct VisualJourneyCard: View {
    @EnvironmentObject var appState: AppState
    @State private var isGenerating = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Your Journey")
                    .font(.headline)
                    .foregroundColor(Color(hex: "3D2B1F"))
                Spacer()
                Button {
                    Task { await generateVisual() }
                } label: {
                    if isGenerating {
                        ProgressView().scaleEffect(0.8)
                    } else {
                        Image(systemName: "arrow.clockwise")
                            .foregroundColor(Color(hex: "E76F51"))
                    }
                }
            }

            if let url = appState.visualJourneyURL {
                AsyncImage(url: url) { image in
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(maxWidth: .infinity)
                        .frame(height: 200)
                        .clipped()
                        .cornerRadius(12)
                } placeholder: {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color(hex: "F4E4D0"))
                        .frame(height: 200)
                        .overlay(ProgressView())
                }
            } else {
                Button {
                    Task { await generateVisual() }
                } label: {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color(hex: "F4E4D0"))
                        .frame(height: 200)
                        .overlay(
                            VStack(spacing: 8) {
                                Image(systemName: "sparkles")
                                    .font(.largeTitle)
                                    .foregroundColor(Color(hex: "E76F51"))
                                Text("Generate your vision")
                                    .font(.subheadline)
                                    .foregroundColor(Color(hex: "7C5C45"))
                            }
                        )
                }
            }

            // Progress bar
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Today's progress")
                        .font(.caption)
                        .foregroundColor(Color(hex: "7C5C45"))
                    Spacer()
                    Text("\(Int(appState.progressPercent * 100))%")
                        .font(.caption.bold())
                        .foregroundColor(Color(hex: "E76F51"))
                }
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color(hex: "F4E4D0"))
                            .frame(height: 8)
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color(hex: "E76F51"))
                            .frame(width: geo.size.width * appState.progressPercent, height: 8)
                            .animation(.spring(), value: appState.progressPercent)
                    }
                }
                .frame(height: 8)
            }
        }
        .padding()
        .background(Color.white)
        .cornerRadius(16)
        .shadow(color: .black.opacity(0.04), radius: 8, y: 2)
    }

    private func generateVisual() async {
        isGenerating = true
        defer { isGenerating = false }
        guard let resp = try? await RenaAPI.shared.getVisualJourney(userId: appState.userId),
              let urlStr = resp.imageUrl,
              let url = URL(string: urlStr) else { return }
        await MainActor.run { appState.visualJourneyURL = url }
    }
}

struct ProgressSummaryCard: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        HStack(spacing: 16) {
            StatRing(
                value: appState.caloriesConsumed,
                total: appState.caloriesTarget,
                label: "Calories",
                color: Color(hex: "E76F51")
            )
            StatRing(
                value: appState.waterGlasses,
                total: 8,
                label: "Water",
                color: Color(hex: "457B9D")
            )
        }
        .padding()
        .background(Color.white)
        .cornerRadius(16)
        .shadow(color: .black.opacity(0.04), radius: 8, y: 2)
    }
}

struct StatRing: View {
    let value: Int
    let total: Int
    let label: String
    let color: Color

    var progress: Double { min(1.0, Double(value) / Double(max(total, 1))) }

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                Circle()
                    .stroke(color.opacity(0.15), lineWidth: 10)
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
                        .font(.caption2)
                        .foregroundColor(Color(hex: "7C5C45"))
                }
            }
            .frame(width: 90, height: 90)
            Text(label)
                .font(.caption.bold())
                .foregroundColor(Color(hex: "7C5C45"))
        }
        .frame(maxWidth: .infinity)
    }
}

struct DailyTargetsCard: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Quick Log")
                .font(.headline)
                .foregroundColor(Color(hex: "3D2B1F"))

            HStack(spacing: 12) {
                QuickLogButton(icon: "drop.fill", label: "Water", color: Color(hex: "457B9D")) {
                    // handled by Rena voice or tap
                }
                QuickLogButton(icon: "figure.walk", label: "Workout", color: Color(hex: "2A9D8F")) {
                    // handled by Rena voice or tap
                }
                QuickLogButton(icon: "fork.knife", label: "Meal", color: Color(hex: "E76F51")) {
                    // handled by Rena voice or tap
                }
            }
        }
        .padding()
        .background(Color.white)
        .cornerRadius(16)
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
                Image(systemName: icon)
                    .font(.title2)
                    .foregroundColor(color)
                Text(label)
                    .font(.caption.bold())
                    .foregroundColor(Color(hex: "3D2B1F"))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(color.opacity(0.1))
            .cornerRadius(12)
        }
    }
}

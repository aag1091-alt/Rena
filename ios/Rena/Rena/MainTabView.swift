import SwiftUI

struct MainTabView: View {
    @EnvironmentObject var appState: AppState
    @State private var selectedTab = 0

    var body: some View {
        TabView(selection: $selectedTab) {
            HomeView(selectedTab: $selectedTab)
                .tabItem { Label("Home", systemImage: "house.fill") }
                .tag(0)

            VoiceView()
                .tabItem { Label("Rena", systemImage: "waveform.circle.fill") }
                .tag(1)

            DataView()
                .tabItem { Label("Data", systemImage: "chart.bar.fill") }
                .tag(2)

            // DEV ONLY — remove before submission
            VStack(spacing: 20) {
                Text("Dev Tools").font(.headline)
                Button(role: .destructive) {
                    Task {
                        try? await RenaAPI.shared.devReset(userId: appState.userId)
                        appState.signOut()
                    }
                } label: {
                    Label("Reset onboarding", systemImage: "arrow.counterclockwise")
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.red.opacity(0.1))
                        .cornerRadius(12)
                }
                .padding(.horizontal)
            }
            .tabItem { Label("Dev", systemImage: "wrench.fill") }
            .tag(3)
        }
        .accentColor(Color(hex: "E76F51"))
    }
}

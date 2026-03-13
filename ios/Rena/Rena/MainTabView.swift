import SwiftUI

struct MainTabView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        TabView {
            HomeView()
                .tabItem { Label("Home", systemImage: "house.fill") }

            DataView()
                .tabItem { Label("Data", systemImage: "chart.bar.fill") }

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
        }
        .accentColor(Color(hex: "E76F51"))
    }
}

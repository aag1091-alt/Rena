import SwiftUI

struct MainTabView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        TabView {
            HomeView()
                .tabItem { Label("Home", systemImage: "house.fill") }

            DataView()
                .tabItem { Label("Data", systemImage: "chart.bar.fill") }

            ScanView()
                .tabItem { Label("Log Food", systemImage: "camera.fill") }

            WorkbookView()
                .tabItem { Label("Workbook", systemImage: "note.text") }

            // DEV — remove before App Store submission
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

                Button {
                    Task {
                        try? await RenaAPI.shared.devSeed(userId: appState.userId)
                    }
                } label: {
                    Label("Seed test data (7 days)", systemImage: "flask.fill")
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.blue.opacity(0.1))
                        .cornerRadius(12)
                }
                .padding(.horizontal)
            }
            .tabItem { Label("Dev", systemImage: "wrench.fill") }
        }
        .accentColor(Color(hex: "E76F51"))
    }
}

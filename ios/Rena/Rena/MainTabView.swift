import SwiftUI

struct MainTabView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        TabView {
            HomeView()
                .tabItem {
                    Label("Home", systemImage: "house.fill")
                }

            VoiceView()
                .tabItem {
                    Label("Rena", systemImage: "waveform.circle.fill")
                }

            ScanView()
                .tabItem {
                    Label("Scan", systemImage: "camera.fill")
                }

            // DEV ONLY — remove before submission
            VStack(spacing: 20) {
                Text("Dev Tools").font(.headline)
                Button(role: .destructive) {
                    appState.signOut()
                } label: {
                    Label("Reset onboarding", systemImage: "arrow.counterclockwise")
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.red.opacity(0.1))
                        .cornerRadius(12)
                }
                .padding(.horizontal)
            }
            .tabItem {
                Label("Dev", systemImage: "wrench.fill")
            }
        }
        .accentColor(Color(hex: "E76F51"))
    }
}

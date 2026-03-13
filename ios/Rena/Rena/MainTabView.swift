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
        }
        .accentColor(Color(hex: "E76F51"))
    }
}

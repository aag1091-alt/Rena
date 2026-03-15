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
        }
        .accentColor(Color(hex: "E76F51"))
    }
}

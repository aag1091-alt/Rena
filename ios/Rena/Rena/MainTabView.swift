import SwiftUI

struct MainTabView: View {
    @EnvironmentObject var appState: AppState

    @State private var selectedTab = 0
    @State private var showRena = false
    @State private var renaContext: String? = nil
    @State private var devTapCount = 0

    var body: some View {
ZStack(alignment: .bottom) {

            // ── Tab content ───────────────────────────────────────
            TabView(selection: $selectedTab) {
                HomeView().tag(0)
                DataView().tag(1)
                WorkbookView(showRena: $showRena, renaContext: $renaContext).tag(2)
                ScanView().tag(3)
                devView.tag(4)
            }
            .accentColor(Color(hex: "E76F51"))
            // Hide the default tab bar — we draw our own below
            .toolbar(.hidden, for: .tabBar)
            // Pad content so it doesn't hide under the custom tab bar
            .safeAreaInset(edge: .bottom) {
                Color.clear.frame(height: 74)
            }

            // ── Rena overlay ──────────────────────────────────────
            if showRena {
                RenaOverlay(selectedTab: selectedTab, isShowing: $showRena, pendingContext: renaContext)
                    .transition(.opacity)
                    .zIndex(1)
                    .onChange(of: showRena) { if !showRena { renaContext = nil } }
            }

            // ── Custom tab bar ────────────────────────────────────
            CustomTabBar(selectedTab: $selectedTab, showRena: $showRena, currentTab: selectedTab)
                .id(selectedTab)
                .zIndex(2)
        }
        .ignoresSafeArea(edges: .bottom)
    }

    // MARK: - Dev tab (hidden — access by tapping app version 5× in Settings)

    private var devView: some View {
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
                Task { try? await RenaAPI.shared.devSeed(userId: appState.userId) }
            } label: {
                Label("Seed test data (7 days)", systemImage: "flask.fill")
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.blue.opacity(0.1))
                    .cornerRadius(12)
            }
            .padding(.horizontal)
        }
    }
}

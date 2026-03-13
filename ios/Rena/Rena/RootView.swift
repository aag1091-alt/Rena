import SwiftUI

struct RootView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        Group {
            if !appState.isSignedIn {
                RenaIntroView()
            } else if !appState.isOnboarded {
                OnboardingView()
            } else {
                MainTabView()
            }
        }
        .animation(.easeInOut(duration: 0.35), value: appState.isSignedIn)
        .animation(.easeInOut(duration: 0.35), value: appState.isOnboarded)
    }
}

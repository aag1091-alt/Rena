import AuthenticationServices
import SwiftUI

struct RenaIntroView: View {
    @EnvironmentObject var appState: AppState

    @State private var logoScale: CGFloat = 0.7
    @State private var contentOpacity: Double = 0
    @State private var isSigningIn = false
    @State private var errorMessage: String?

    @StateObject private var voice = VoiceManager()

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(hex: "FDF6EC"), Color(hex: "F4A261")],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer()

                // Logo + name
                VStack(spacing: 12) {
                    Text("✦")
                        .font(.system(size: 72))
                        .scaleEffect(logoScale)
                        .animation(.spring(response: 0.7, dampingFraction: 0.6), value: logoScale)

                    Text("Rena")
                        .font(.system(size: 56, weight: .bold, design: .rounded))
                        .foregroundColor(Color(hex: "3D2B1F"))

                    Text("Your personal health companion")
                        .font(.subheadline)
                        .foregroundColor(Color(hex: "7C5C45"))
                }
                .opacity(contentOpacity)

                Spacer()

                // Sign-in section
                VStack(spacing: 16) {
                    if let errorMessage {
                        Text(errorMessage)
                            .font(.caption)
                            .foregroundColor(.red)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                    }

                    Button(action: handleSignIn) {
                        HStack(spacing: 10) {
                            Image(systemName: isSigningIn ? "ellipsis" : "person.circle.fill")
                                .font(.title3)
                                .symbolEffect(.bounce, isActive: isSigningIn)
                            Text(isSigningIn ? "Signing in…" : "Continue with Google")
                                .font(.headline)
                        }
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(
                            isSigningIn
                                ? Color(hex: "E76F51").opacity(0.6)
                                : Color(hex: "E76F51")
                        )
                        .cornerRadius(16)
                    }
                    .disabled(isSigningIn)

                    Text("By continuing you agree to our Terms & Privacy Policy")
                        .font(.caption2)
                        .foregroundColor(Color(hex: "7C5C45").opacity(0.7))
                        .multilineTextAlignment(.center)
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 52)
                .opacity(contentOpacity)
            }
        }
        .onAppear {
            withAnimation(.easeOut(duration: 0.9)) {
                logoScale = 1.0
                contentOpacity = 1.0
            }
            speakIntro()
        }
        .onDisappear {
            voice.disconnect()
        }
    }

    private func speakIntro() {
        voice.connectGreetOnly(
            prompt: """
            You are on the welcome screen of Rena. \
            A new user just opened the app for the first time. \
            Give a warm, natural greeting — introduce yourself as Rena, \
            their personal health companion, and tell them you're excited to help them reach their goals. \
            Keep it conversational, friendly, and under 20 seconds. Do not ask any questions yet.
            """
        )
    }

    private func handleSignIn() {
        isSigningIn = true
        errorMessage = nil
        Task {
            do {
                let user = try await GoogleSignInManager.shared.signIn()
                appState.signIn(userId: user.id, email: user.email, name: user.name)
            } catch ASWebAuthenticationSessionError.canceledLogin {
                // User cancelled — no error shown
            } catch {
                errorMessage = "Sign in failed. Please try again."
            }
            isSigningIn = false
        }
    }
}

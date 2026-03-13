import SwiftUI

struct VoiceView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var voice = VoiceManager()
    @State private var isConnected = false

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(hex: "FDF6EE"), Color(hex: "F9E4C8")],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: 40) {
                Spacer()

                // Status label
                Text(statusText)
                    .font(.subheadline)
                    .foregroundColor(Color(hex: "7C5C45"))
                    .animation(.easeInOut, value: statusText)

                // Orb
                ZStack {
                    // Outer pulse
                    Circle()
                        .fill(Color(hex: "E76F51").opacity(isPulsing ? 0.15 : 0))
                        .frame(width: 180, height: 180)
                        .scaleEffect(isPulsing ? 1.3 : 1.0)
                        .animation(
                            isPulsing
                                ? .easeInOut(duration: 0.8).repeatForever(autoreverses: true)
                                : .default,
                            value: isPulsing
                        )

                    // Inner orb
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: isConnected
                                    ? [Color(hex: "E76F51"), Color(hex: "F4A261")]
                                    : [Color(hex: "D4B8A0"), Color(hex: "C4A882")],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 140, height: 140)
                        .shadow(color: Color(hex: "E76F51").opacity(0.4), radius: isConnected ? 20 : 0)

                    Text("✦")
                        .font(.system(size: 44))
                        .foregroundColor(.white)
                }
                .onTapGesture { toggleConnection() }

                Text(isConnected ? "Tap to end" : "Tap to talk to Rena")
                    .font(.caption)
                    .foregroundColor(Color(hex: "7C5C45"))

                // Last response
                if !voice.lastResponse.isEmpty {
                    Text(voice.lastResponse)
                        .font(.body)
                        .foregroundColor(Color(hex: "3D2B1F"))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                        .padding()
                        .background(Color.white.opacity(0.8))
                        .cornerRadius(16)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }

                Spacer()
            }
        }
    }

    private var statusText: String {
        switch voice.state {
        case .idle: return isConnected ? "" : "Tap the orb to start"
        case .connecting: return "Connecting to Rena..."
        case .listening: return "Listening..."
        case .thinking: return "Rena is thinking..."
        case .speaking: return "Rena is speaking..."
        case .error(let msg): return "Error: \(msg)"
        }
    }

    private var isPulsing: Bool {
        switch voice.state {
        case .listening, .speaking: return true
        default: return false
        }
    }

    private func toggleConnection() {
        if isConnected {
            voice.disconnect()
            isConnected = false
        } else {
            voice.connect(userId: appState.userId)
            isConnected = true
        }
    }
}

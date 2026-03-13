import SwiftUI

struct GoalOnboardingView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var voice = VoiceManager()

    @State private var isConnected = false
    @State private var goalDetected = false
    @State private var detectedGoal = ""
    @State private var detectedDeadline = ""
    @State private var pollTimer: Timer?

    private var greetPrompt: String {
        """
        You are having a focused goal-setting conversation with \(appState.name.components(separatedBy: " ").first ?? appState.name).
        Your ONLY job right now is to understand their health goal and set it.
        Start by warmly asking what they are working toward — a wedding, a trip, a race, \
        losing weight, feeling better, anything.
        Then ask when their target date is (month and year is fine, you can fill in an exact date).
        Once you have the goal and a date, call the set_goal tool immediately to save it.
        After calling set_goal, say something like: "Perfect, I've locked that in! Let's get to work."
        Stay completely focused — do not discuss meals, calories, or anything else yet.
        """
    }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(hex: "FDF6EE"), Color(hex: "F9E4C8")],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                // Header
                VStack(spacing: 6) {
                    Text("Set your goal")
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .foregroundColor(Color(hex: "3D2B1F"))
                    Text("Tell Rena what you're working toward")
                        .font(.subheadline)
                        .foregroundColor(Color(hex: "7C5C45"))
                }
                .padding(.top, 60)

                Spacer()

                // Status
                Text(statusText)
                    .font(.subheadline)
                    .foregroundColor(Color(hex: "7C5C45"))
                    .animation(.easeInOut, value: statusText)

                Spacer().frame(height: 24)

                // Orb
                ZStack {
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

                Spacer().frame(height: 16)

                Text(isConnected ? "Tap to end" : "Tap to start")
                    .font(.caption)
                    .foregroundColor(Color(hex: "7C5C45"))
                    .onTapGesture { toggleConnection() }

                Spacer()

                Spacer()

                // Goal confirmation card — appears once goal is detected
                if goalDetected {
                    VStack(spacing: 16) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Your goal")
                                .font(.caption)
                                .foregroundColor(Color(hex: "7C5C45"))
                                .textCase(.uppercase)
                            Text(detectedGoal)
                                .font(.system(size: 18, weight: .semibold, design: .rounded))
                                .foregroundColor(Color(hex: "3D2B1F"))
                            if detectedDeadline != "Not set" && !detectedDeadline.isEmpty {
                                Text(formattedDeadline(detectedDeadline))
                                    .font(.subheadline)
                                    .foregroundColor(Color(hex: "7C5C45"))
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                        .background(Color.white.opacity(0.9))
                        .cornerRadius(16)

                        HStack(spacing: 12) {
                            Button(action: resetGoal) {
                                Text("Change")
                                    .font(.subheadline.weight(.medium))
                                    .foregroundColor(Color(hex: "E76F51"))
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 14)
                                    .background(Color(hex: "E76F51").opacity(0.1))
                                    .cornerRadius(14)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 14)
                                            .stroke(Color(hex: "E76F51").opacity(0.4), lineWidth: 1)
                                    )
                            }
                            Button(action: confirmGoal) {
                                Text("Looks good →")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundColor(.white)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 14)
                                    .background(Color(hex: "E76F51"))
                                    .cornerRadius(14)
                            }
                        }
                    }
                    .padding(.horizontal, 28)
                    .padding(.bottom, 40)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                } else {
                    Color.clear.frame(height: 130)
                }
            }
        }
        .onAppear {
            // Auto-connect so Rena starts the conversation immediately
            toggleConnection()
        }
        .onDisappear {
            stopPolling()
            voice.disconnect()
        }
    }

    // MARK: - Actions

    private func toggleConnection() {
        if isConnected {
            voice.disconnect()
            isConnected = false
            stopPolling()
        } else {
            voice.connect(userId: appState.userId, greetPrompt: greetPrompt)
            isConnected = true
            startPolling()
        }
    }

    private func confirmGoal() {
        stopPolling()
        voice.disconnect()
        appState.goalDetected(goal: detectedGoal, deadline: detectedDeadline)
    }

    private func resetGoal() {
        withAnimation {
            goalDetected = false
            detectedGoal = ""
            detectedDeadline = ""
        }
        // Tell Rena to ask again
        voice.sendText("The user wants to change their goal. Please ask them again what they want to work toward and when.")
        startPolling()
    }

    private func formattedDeadline(_ iso: String) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        guard let date = formatter.date(from: iso) else { return iso }
        formatter.dateFormat = "MMMM d, yyyy"
        return "📅 " + formatter.string(from: date)
    }

    // MARK: - Poll /progress for goal detection

    private func startPolling() {
        pollTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { _ in
            Task { await checkForGoal() }
        }
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    @MainActor
    private func checkForGoal() async {
        guard !goalDetected else { return }
        do {
            let progress = try await RenaAPI.shared.getProgress(userId: appState.userId)
            if progress.goal != "Not set" && !progress.goal.isEmpty {
                detectedGoal = progress.goal
                detectedDeadline = progress.deadline
                withAnimation(.spring(response: 0.5)) {
                    goalDetected = true
                }
                stopPolling() // Stop polling — user now confirms or resets
            }
        } catch {
            // Silent — keep polling
        }
    }

    // MARK: - Helpers

    private var statusText: String {
        switch voice.state {
        case .idle:        return isConnected ? "" : "Tap the orb to start"
        case .connecting:  return "Connecting to Rena..."
        case .listening:   return "Listening..."
        case .thinking:    return "Rena is thinking..."
        case .speaking:    return "Rena is speaking..."
        case .error(let m): return "Error: \(m)"
        }
    }

    private var isPulsing: Bool {
        switch voice.state {
        case .listening, .speaking: return true
        default: return false
        }
    }
}

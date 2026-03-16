import SwiftUI

// MARK: - Context hints

struct RenaHint: Identifiable {
    let id = UUID()
    let icon: String
    let label: String
    let color: Color
}

private let defaultHints: [RenaHint] = [
    RenaHint(icon: "fork.knife",  label: "Log food",     color: Color(hex: "E76F51")),
    RenaHint(icon: "drop.fill",   label: "Log water",    color: Color(hex: "457B9D")),
    RenaHint(icon: "figure.run",  label: "Log exercise", color: Color(hex: "2A9D8F")),
    RenaHint(icon: "scalemass",   label: "Log weight",   color: Color(hex: "9B7EC8")),
]

func renaHints(for tab: Int) -> [RenaHint] {
    switch tab {
    case 1: // Data
        return [
            RenaHint(icon: "fork.knife.circle",   label: "Remove food log",    color: Color(hex: "E76F51")),
            RenaHint(icon: "figure.run.circle",   label: "Remove exercise",    color: Color(hex: "2A9D8F")),
            RenaHint(icon: "drop.circle",         label: "Remove water entry", color: Color(hex: "457B9D")),
        ] + defaultHints
    case 2: // Workbook
        return [
            RenaHint(icon: "dumbbell.fill",   label: "Plan my workout",    color: Color(hex: "2A9D8F")),
            RenaHint(icon: "pencil.circle",   label: "Update workout",     color: Color(hex: "457B9D")),
        ] + defaultHints
    default:
        return defaultHints
    }
}

private func voiceContext(for tab: Int) -> String {
    switch tab {
    case 2: return "update_workout_plan"
    default: return "home"
    }
}


// MARK: - Thinking animation

struct ThinkingDotsView: View {
    @State private var animate = false

    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .fill(Color.white)
                    .frame(width: 6, height: 6)
                    .offset(y: animate ? -5 : 5)
                    .animation(
                        .easeInOut(duration: 0.38)
                            .repeatForever(autoreverses: true)
                            .delay(Double(i) * 0.13),
                        value: animate
                    )
            }
        }
        .onAppear { animate = true }
        .onDisappear { animate = false }
    }
}

// MARK: - Hint chip

struct RenaHintChip: View {
    let hint: RenaHint

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: hint.icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(hint.color)
            Text(hint.label)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(Color(hex: "3D2B1F"))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(hint.color.opacity(0.09))
        .cornerRadius(12)
    }
}

// MARK: - Rena overlay

struct RenaOverlay: View {
    let selectedTab: Int
    @Binding var isShowing: Bool
    var pendingContext: String? = nil   // set by callers that want a specific context

    @EnvironmentObject var appState: AppState
    @EnvironmentObject var voice: VoiceManager

    @State private var isVoiceActive = false
    @State private var cardVisible = false

    private var hints: [RenaHint] { renaHints(for: selectedTab) }
    private var openingContext: String { pendingContext ?? voiceContext(for: selectedTab) }

    var body: some View {
        ZStack(alignment: .bottom) {
            // Dimmed backdrop — non-interactive so scroll gestures reach content below
            Color.black.opacity(0.38)
                .ignoresSafeArea()
                .allowsHitTesting(false)

            VStack(spacing: 0) {
                // ── Hint + voice card ────────────────────────────
                VStack(alignment: .leading, spacing: 16) {

                    Text("What can I help with?")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(Color(hex: "B09880"))
                        .kerning(1.0)

                    // Hint chips — 2 per row
                    LazyVGrid(
                        columns: [GridItem(.flexible()), GridItem(.flexible())],
                        spacing: 10
                    ) {
                        ForEach(Array(hints.prefix(6).enumerated()), id: \.element.id) { i, hint in
                            RenaHintChip(hint: hint)
                                .scaleEffect(cardVisible ? 1 : 0.82)
                                .opacity(cardVisible ? 1 : 0)
                                .animation(
                                    .spring(response: 0.4, dampingFraction: 0.65)
                                        .delay(0.06 + Double(i) * 0.045),
                                    value: cardVisible
                                )
                        }
                    }

                    // Transcript while active
                    if isVoiceActive, !voice.transcript.isEmpty {
                        Text(voice.transcript)
                            .font(.system(size: 14))
                            .foregroundColor(Color(hex: "3D2B1F"))
                            .lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(12)
                            .background(Color(hex: "FFF8F2"))
                            .cornerRadius(12)
                            .transition(.opacity.combined(with: .scale(scale: 0.96)))
                    }

                    // Talk to Rena button
                    Button(action: toggleVoice) {
                        HStack(spacing: 12) {
                            ZStack {
                                Circle()
                                    .fill(isVoiceActive
                                        ? Color.white.opacity(0.25)
                                        : Color(hex: "E76F51").opacity(0.13))
                                    .frame(width: 40, height: 40)
                                if case .thinking = voice.state {
                                    ThinkingDotsView()
                                } else {
                                    Image(systemName: "waveform")
                                        .font(.system(size: 15, weight: .semibold))
                                        .foregroundColor(isVoiceActive ? .white : Color(hex: "E76F51"))
                                        .symbolEffect(.variableColor.iterative, isActive: isVoiceActive)
                                }
                            }
                            VStack(alignment: .leading, spacing: 2) {
                                Text(isVoiceActive ? voiceStateLabel : "Talk to Rena")
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundColor(isVoiceActive ? .white : Color(hex: "E76F51"))
                                if !isVoiceActive {
                                    Text("Speak naturally — log, update, ask anything")
                                        .font(.system(size: 11))
                                        .foregroundColor(Color(hex: "B09880"))
                                }
                            }
                            Spacer()
                            if isVoiceActive {
                                Text("Tap to end")
                                    .font(.system(size: 11))
                                    .foregroundColor(.white.opacity(0.75))
                            }
                        }
                        .padding(16)
                        .background(
                            isVoiceActive
                                ? AnyView(LinearGradient(
                                    colors: [Color(hex: "E76F51"), Color(hex: "F4A261")],
                                    startPoint: .leading, endPoint: .trailing))
                                : AnyView(Color(hex: "FFF8F2"))
                        )
                        .cornerRadius(18)
                        .shadow(
                            color: isVoiceActive
                                ? Color(hex: "E76F51").opacity(0.35)
                                : Color.black.opacity(0.05),
                            radius: 12, y: 4
                        )
                        .animation(.easeInOut(duration: 0.22), value: isVoiceActive)
                    }
                    .buttonStyle(.plain)
                }
                .padding(20)
                .background(Color.white)
                .cornerRadius(28)
                .shadow(color: .black.opacity(0.14), radius: 28, y: -6)
                .padding(.horizontal, 16)
                .offset(y: cardVisible ? 0 : 52)
                .opacity(cardVisible ? 1 : 0)
                .animation(.spring(response: 0.42, dampingFraction: 0.76), value: cardVisible)

                // Space so card sits above the Rena button + tab bar
                Color.clear.frame(height: 96)
            }
        }
        .onAppear {
            withAnimation { cardVisible = true }
            // Auto-start voice as soon as overlay opens
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                let name = appState.name.components(separatedBy: " ").first ?? appState.name
                voice.connect(userId: appState.userId, context: openingContext, name: name)
                isVoiceActive = true
            }
        }
        .onChange(of: selectedTab) { _ in dismiss() }
        .onChange(of: isShowing) { showing in
            if !showing && isVoiceActive {
                voice.disconnect()
                isVoiceActive = false
            }
        }
        .onDisappear {
            if isVoiceActive { voice.disconnect(); isVoiceActive = false }
        }
    }

    // MARK: - Helpers

    private var voiceStateLabel: String {
        if !voice.toolStatus.isEmpty { return voice.toolStatus }
        switch voice.state {
        case .connecting: return "Connecting…"
        case .listening:  return "Listening…"
        case .thinking:   return "Thinking…"
        case .speaking:   return "Rena is speaking…"
        default:          return "Tap to end"
        }
    }

    private func toggleVoice() {
        if isVoiceActive {
            voice.disconnect()
            isVoiceActive = false
        } else {
            let name = appState.name.components(separatedBy: " ").first ?? appState.name
            voice.connect(userId: appState.userId, context: openingContext, name: name)
            isVoiceActive = true
        }
    }

    private func dismiss() {
        if isVoiceActive { voice.disconnect(); isVoiceActive = false }
        withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) { cardVisible = false }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.28) { isShowing = false }
    }
}

// MARK: - Custom tab bar

struct CustomTabBar: View {
    @Binding var selectedTab: Int
    @Binding var showRena: Bool
    let currentTab: Int

    private var bottomInset: CGFloat {
        (UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?.windows.first?.safeAreaInsets.bottom) ?? 0
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            // Background pill
            Color.white
                .frame(height: 56 + bottomInset)
                .shadow(color: .black.opacity(0.07), radius: 16, y: -4)

            HStack(spacing: 0) {
                // ── Home ──
                Button {
                    selectedTab = 0; if showRena { showRena = false }
                } label: {
                    tabLabel(icon: "house.fill", text: "Home", active: currentTab == 0)
                }.buttonStyle(.plain)

                // ── History ──
                Button {
                    selectedTab = 1; if showRena { showRena = false }
                } label: {
                    tabLabel(icon: "chart.bar.fill", text: "History", active: currentTab == 1)
                }.buttonStyle(.plain)

                // ── Rena (elevated center button) ──
                Button { showRena.toggle() } label: {
                    VStack(spacing: 3) {
                        ZStack {
                            Circle()
                                .fill(showRena
                                    ? AnyShapeStyle(Color(hex: "E76F51"))
                                    : AnyShapeStyle(LinearGradient(
                                        colors: [Color(hex: "E76F51"), Color(hex: "F4A261")],
                                        startPoint: .topLeading, endPoint: .bottomTrailing
                                    ))
                                )
                                .frame(width: 52, height: 52)
                                .shadow(color: Color(hex: "E76F51").opacity(0.4), radius: 10, y: 4)
                            Image(systemName: showRena ? "xmark" : "sparkles")
                                .font(.system(size: 20, weight: .semibold))
                                .foregroundColor(.white)
                        }
                        .offset(y: -12)
                        Text("Rena")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(showRena ? Color(hex: "E76F51") : Color(hex: "C4A882"))
                            .offset(y: -8)
                    }
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                }.buttonStyle(.plain)

                // ── Scan ──
                Button {
                    selectedTab = 3; if showRena { showRena = false }
                } label: {
                    tabLabel(icon: "camera.fill", text: "Scan", active: currentTab == 3)
                }.buttonStyle(.plain)

                // ── Workbook ──
                Button {
                    selectedTab = 2; if showRena { showRena = false }
                } label: {
                    tabLabel(icon: "note.text", text: "Workbook", active: currentTab == 2)
                }.buttonStyle(.plain)
            }
            .padding(.horizontal, 8)
            .frame(height: 56)
            .padding(.bottom, bottomInset)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 56 + bottomInset)
    }

    private func tabLabel(icon: String, text: String, active: Bool) -> some View {
        VStack(spacing: 3) {
            Image(systemName: icon)
                .font(.system(size: 19, weight: active ? .semibold : .regular))
                .foregroundColor(active ? Color(hex: "E76F51") : Color(hex: "C4A882"))
            Text(text)
                .font(.system(size: 10, weight: active ? .semibold : .regular))
                .foregroundColor(active ? Color(hex: "E76F51") : Color(hex: "C4A882"))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(active ? Color(hex: "E76F51").opacity(0.10) : Color.clear)
        )
        .frame(maxWidth: .infinity)
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }
}

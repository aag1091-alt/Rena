import SwiftUI
import AVKit
import AVFoundation

struct ExerciseVideoSheet: View {
    let exercise: PlannedExercise

    @State private var player: AVPlayer? = nil
    @State private var status: String = "loading"   // "loading" | "generating" | "ready" | "error"
    @State private var jobId: String? = nil
    @State private var errorMessage: String = ""
    @State private var pollTimer: Timer? = nil
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            // Handle bar
            RoundedRectangle(cornerRadius: 3)
                .fill(Color(hex: "D4B8A0"))
                .frame(width: 40, height: 4)
                .padding(.top, 12)
                .padding(.bottom, 16)

            // Header
            VStack(alignment: .leading, spacing: 4) {
                Text(exercise.name)
                    .font(.system(size: 20, weight: .bold))
                    .foregroundColor(Color(hex: "3D2B1F"))
                if let muscles = exercise.targetMuscles, !muscles.isEmpty {
                    Text(muscles.capitalized)
                        .font(.system(size: 13))
                        .foregroundColor(Color(hex: "B09880"))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.bottom, 16)

            // Video area
            ZStack {
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color(hex: "1A1A1A"))
                    .aspectRatio(9/16, contentMode: .fit)
                    .padding(.horizontal, 20)

                if let player, status == "ready" {
                    VideoPlayer(player: player)
                        .aspectRatio(9/16, contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                        .padding(.horizontal, 20)
                } else {
                    VStack(spacing: 14) {
                        if status == "loading" || status == "generating" {
                            ProgressView()
                                .scaleEffect(1.4)
                                .tint(.white)
                            Text(status == "generating" ? "Generating exercise video…\nThis may take up to 60 seconds." : "Loading…")
                                .font(.system(size: 14))
                                .foregroundColor(.white.opacity(0.7))
                                .multilineTextAlignment(.center)
                        } else if status == "error" {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 36))
                                .foregroundColor(Color(hex: "E76F51"))
                            Text(errorMessage.isEmpty ? "Video unavailable" : errorMessage)
                                .font(.system(size: 13))
                                .foregroundColor(.white.opacity(0.7))
                                .multilineTextAlignment(.center)
                        }
                    }
                }
            }

            Spacer()

            // Info row
            HStack(spacing: 20) {
                exerciseStat(
                    icon: exercise.type == "cardio" ? "clock.fill" : "repeat",
                    label: volumeLabel,
                    color: Color(hex: "2A9D8F")
                )
                exerciseStat(
                    icon: "flame.fill",
                    label: "\(exercise.caloriesBurned) kcal",
                    color: Color(hex: "E76F51")
                )
                if let muscles = exercise.targetMuscles {
                    exerciseStat(
                        icon: "figure.arms.open",
                        label: muscles.split(separator: ",").prefix(2).map(String.init).joined(separator: ", "),
                        color: Color(hex: "9B7EC8")
                    )
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 24)
        }
        .background(Color(hex: "F7F3EE").ignoresSafeArea())
        .onAppear { fetchVideo() }
        .onDisappear {
            pollTimer?.invalidate()
            player?.pause()
        }
    }

    private var volumeLabel: String {
        if exercise.type == "cardio", let d = exercise.durationMin { return "\(d) min" }
        if let s = exercise.sets, let r = exercise.reps { return "\(s) × \(r)" }
        return ""
    }

    private func exerciseStat(icon: String, label: String, color: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundColor(color)
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(Color(hex: "3D2B1F"))
                .lineLimit(1)
        }
    }

    private func fetchVideo() {
        // Allow audio even when ringer/silent switch is on
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        try? AVAudioSession.sharedInstance().setActive(true)
        Task {
            do {
                let result = try await RenaAPI.shared.getExerciseVideo(
                    exerciseName: exercise.name,
                    targetMuscles: exercise.targetMuscles ?? ""
                )
                await handleVideoStatus(result)
            } catch {
                await MainActor.run { status = "error"; errorMessage = error.localizedDescription }
            }
        }
    }

    private func handleVideoStatus(_ vs: VideoStatus) async {
        if vs.status == "ready" || vs.status == "done", let url = vs.videoUrl {
            await MainActor.run {
                status = "ready"
                player = AVPlayer(url: URL(string: url)!)
                player?.play()
                // Loop
                NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime,
                    object: player?.currentItem, queue: .main) { _ in
                    player?.seek(to: .zero)
                    player?.play()
                }
            }
        } else if vs.status == "generating", let jid = vs.jobId {
            await MainActor.run { status = "generating"; jobId = jid }
            startPolling(jobId: jid)
        } else if vs.status == "error" {
            await MainActor.run { status = "error"; errorMessage = vs.message ?? "Generation failed" }
        }
    }

    private func startPolling(jobId: String) {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { timer in
            Task {
                do {
                    let vs = try await RenaAPI.shared.pollExerciseVideoStatus(jobId: jobId)
                    if vs.status != "generating" {
                        timer.invalidate()
                        await handleVideoStatus(vs)
                    }
                } catch {
                    timer.invalidate()
                    await MainActor.run { status = "error"; errorMessage = error.localizedDescription }
                }
            }
        }
    }
}

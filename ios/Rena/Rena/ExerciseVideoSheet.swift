import SwiftUI
import AVKit
import AVFoundation

struct ExerciseVideoSheet: View {
    let exercise: PlannedExercise

    @State private var player: AVQueuePlayer? = nil
    @State private var playerLooper: AVPlayerLooper? = nil
    @State private var status: String = "loading"   // "loading" | "ready" | "error"
    @State private var errorMessage: String = ""
    @State private var youtubeURL: URL? = nil
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
                        if status == "loading" {
                            ProgressView()
                                .scaleEffect(1.4)
                                .tint(.white)
                            Text("Loading…")
                                .font(.system(size: 14))
                                .foregroundColor(.white.opacity(0.7))
                        } else if status == "error" {
                            Image(systemName: "play.rectangle.fill")
                                .font(.system(size: 36))
                                .foregroundColor(Color(hex: "E76F51"))
                            Text("No video available")
                                .font(.system(size: 13))
                                .foregroundColor(.white.opacity(0.7))
                            if let url = youtubeURL {
                                Link("Watch on YouTube →", destination: url)
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundColor(Color(hex: "F4A261"))
                                    .padding(.top, 4)
                            }
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
            playerLooper = nil
            player?.pause()
            player = nil
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

    // Known pre-generated videos in GCS — add new keys as more are generated
    private static let knownVideos: [String: String] = [
        "bodyweight_squats": "https://storage.googleapis.com/rena-assets/exercise_videos/bodyweight_squats.mp4",
        "glute_bridges":     "https://storage.googleapis.com/rena-assets/exercise_videos/glute_bridges.mp4",
        "plank":             "https://storage.googleapis.com/rena-assets/exercise_videos/plank.mp4",
        "walking_lunges":    "https://storage.googleapis.com/rena-assets/exercise_videos/walking_lunges.mp4",
    ]

    private func fetchVideo() {
        // Allow audio even when ringer/silent switch is on
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        try? AVAudioSession.sharedInstance().setActive(true)

        let key = exercise.name
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "_")

        if let urlStr = Self.knownVideos[key], let videoURL = URL(string: urlStr) {
            let item = AVPlayerItem(url: videoURL)
            let queuePlayer = AVQueuePlayer()
            playerLooper = AVPlayerLooper(player: queuePlayer, templateItem: item)
            player = queuePlayer
            status = "ready"
            queuePlayer.play()
        } else {
            // No pre-generated video — show YouTube link (never trigger generation)
            let q = "\(exercise.name) exercise tutorial"
                .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
            youtubeURL = URL(string: "https://m.youtube.com/results?search_query=\(q)")
            status = "error"
        }
    }
}

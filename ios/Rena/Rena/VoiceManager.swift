import Foundation
import AVFoundation
import Combine

enum VoiceState {
    case idle
    case connecting
    case listening
    case thinking
    case speaking
    case error(String)
}

class VoiceManager: NSObject, ObservableObject {
    @Published var state: VoiceState = .idle
    @Published var transcript: String = ""
    @Published var lastResponse: String = ""

    private var webSocket: URLSessionWebSocketTask?
    private var audioEngine = AVAudioEngine()
    private var audioPlayer = AVAudioPlayerNode()
    private var playerFormat: AVAudioFormat?
    private let session = URLSession(configuration: .default)

    func connect(userId: String, greetPrompt: String? = nil) {
        state = .connecting
        AVAudioApplication.requestRecordPermission { [weak self] granted in
            guard let self else { return }
            guard granted else {
                DispatchQueue.main.async { self.state = .error("Microphone access denied") }
                return
            }
            let url = URL(string: "\(kBaseURL.replacingOccurrences(of: "http", with: "ws"))/ws/\(userId)")!
            self.webSocket = self.session.webSocketTask(with: url)
            self.webSocket?.resume()
            DispatchQueue.main.async { self.state = .listening }
            self.receiveLoop()
            self.startAudioCapture()
            if let prompt = greetPrompt {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    self.sendText(prompt)
                }
            }
        }
    }

    /// Connects without mic capture — Rena speaks, user just listens.
    /// Used on the intro/welcome screen before sign-in.
    func connectGreetOnly(prompt: String) {
        state = .connecting
        let guestId = "guest-\(UUID().uuidString)"
        let url = URL(string: "\(kBaseURL.replacingOccurrences(of: "http", with: "ws"))/ws/\(guestId)")!

        let avSession = AVAudioSession.sharedInstance()
        try? avSession.setCategory(.playback, mode: .default)
        try? avSession.setActive(true)

        setupPlaybackOnly()

        webSocket = session.webSocketTask(with: url)
        webSocket?.resume()
        DispatchQueue.main.async { self.state = .listening }
        receiveLoop()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            self.sendText(prompt)
        }
    }

    func disconnect() {
        webSocket?.cancel(with: .normalClosure, reason: nil)
        webSocket = nil
        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
        state = .idle
    }

    func sendText(_ text: String) {
        let msg = ["type": "text_input", "text": text]
        guard let data = try? JSONSerialization.data(withJSONObject: msg),
              let str = String(data: data, encoding: .utf8) else { return }
        webSocket?.send(.string(str)) { _ in }
        state = .thinking
    }

    // MARK: - Playback-only setup (no mic)

    private func setupPlaybackOnly() {
        playerFormat = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                     sampleRate: 24000,
                                     channels: 1,
                                     interleaved: true)
        audioEngine.attach(audioPlayer)
        if let pf = playerFormat {
            audioEngine.connect(audioPlayer, to: audioEngine.mainMixerNode, format: pf)
        }
        if !audioEngine.isRunning {
            try? audioEngine.start()
        }
    }

    // MARK: - Audio capture

    private func startAudioCapture() {
        // AVAudioSession must be configured before engine setup
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playAndRecord, mode: .voiceChat, options: .defaultToSpeaker)
        try? session.setActive(true)

        let inputNode = audioEngine.inputNode
        // Use the input node's native hardware format — no forced format on tap
        let hwFormat = inputNode.inputFormat(forBus: 0)

        // Setup playback node
        audioEngine.attach(audioPlayer)
        playerFormat = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                      sampleRate: 24000,
                                      channels: 1,
                                      interleaved: true)
        if let pf = playerFormat {
            audioEngine.connect(audioPlayer, to: audioEngine.mainMixerNode, format: pf)
        }

        // Converter: hardware format → 16kHz PCM16 mono (what Gemini expects)
        let targetFormat = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                         sampleRate: 16000,
                                         channels: 1,
                                         interleaved: true)!
        guard let converter = AVAudioConverter(from: hwFormat, to: targetFormat) else {
            print("[audio] failed to create converter from \(hwFormat) to 16kHz")
            return
        }

        // Install tap with nil format — uses hardware native format automatically
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: nil) { [weak self] buffer, _ in
            guard let self else { return }
            let ratio = 16000.0 / buffer.format.sampleRate
            let outFrames = AVAudioFrameCount(max(1, Double(buffer.frameLength) * ratio))
            guard let converted = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outFrames) else { return }
            var error: NSError?
            converter.convert(to: converted, error: &error) { _, status in
                status.pointee = .haveData
                return buffer
            }
            guard error == nil, let data = converted.toData() else { return }
            self.webSocket?.send(.data(data)) { _ in }
        }

        if !audioEngine.isRunning {
            try? audioEngine.start()
        }
    }

    // MARK: - Receive loop

    private func receiveLoop() {
        webSocket?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let msg):
                switch msg {
                case .data(let audioData):
                    self.playAudio(audioData)
                    DispatchQueue.main.async { self.state = .speaking }
                case .string(let text):
                    if let json = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] {
                        if json["type"] as? String == "turn_complete" {
                            DispatchQueue.main.async { self.state = .listening }
                        } else if let t = json["text"] as? String {
                            DispatchQueue.main.async {
                                self.lastResponse = t
                                self.state = .listening
                            }
                        }
                    }
                @unknown default: break
                }
                self.receiveLoop()
            case .failure:
                DispatchQueue.main.async { self.state = .idle }
            }
        }
    }

    // MARK: - Audio playback

    private func playAudio(_ data: Data) {
        guard let format = playerFormat else { return }
        let frameCount = UInt32(data.count) / format.streamDescription.pointee.mBytesPerFrame
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { return }
        buffer.frameLength = frameCount
        data.withUnsafeBytes { ptr in
            if let base = ptr.baseAddress {
                memcpy(buffer.int16ChannelData![0], base, data.count)
            }
        }
        if !audioPlayer.isPlaying { audioPlayer.play() }
        audioPlayer.scheduleBuffer(buffer, completionHandler: nil)
    }
}

// MARK: - AVAudioPCMBuffer helper

extension AVAudioPCMBuffer {
    func toData() -> Data? {
        guard let int16Data = int16ChannelData else { return nil }
        let byteCount = Int(frameLength) * 2
        return Data(bytes: int16Data[0], count: byteCount)
    }
}

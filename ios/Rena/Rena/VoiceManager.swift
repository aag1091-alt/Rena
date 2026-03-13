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

    func connect(userId: String) {
        state = .connecting
        let url = URL(string: "\(kBaseURL.replacingOccurrences(of: "http", with: "ws"))/ws/\(userId)")!
        webSocket = session.webSocketTask(with: url)
        webSocket?.resume()
        state = .listening
        receiveLoop()
        startAudioCapture()
    }

    func disconnect() {
        webSocket?.cancel(with: .normalClosure, reason: nil)
        webSocket = nil
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

    // MARK: - Audio capture

    private func startAudioCapture() {
        let inputNode = audioEngine.inputNode
        let format = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                   sampleRate: 16000,
                                   channels: 1,
                                   interleaved: true)!

        // Setup output for playback
        audioEngine.attach(audioPlayer)
        playerFormat = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                      sampleRate: 24000,
                                      channels: 1,
                                      interleaved: true)
        if let pf = playerFormat {
            audioEngine.connect(audioPlayer, to: audioEngine.mainMixerNode, format: pf)
        }

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            guard let self, let data = buffer.toData() else { return }
            self.webSocket?.send(.data(data)) { _ in }
        }

        try? AVAudioSession.sharedInstance().setCategory(.playAndRecord, mode: .voiceChat, options: .defaultToSpeaker)
        try? AVAudioSession.sharedInstance().setActive(true)
        try? audioEngine.start()
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

import Foundation
import AVFoundation
import Combine
import SwiftUI

enum VoiceState: Equatable {
    case idle
    case connecting
    case listening
    case thinking
    case speaking
    case error(String)
}

/// Shared voice manager — one instance for the whole app lifetime.
/// The audio engine starts once and never stops, eliminating interruptions
/// caused by session-category switches between screens.
class VoiceManager: NSObject, ObservableObject {
    @Published var state: VoiceState = .idle
    @Published var transcript: String = ""
    @Published var lastResponse: String = ""
    @Published var toolStatus: String = ""
    /// Increments on every turn_complete — observe to refresh data after Rena logs something.
    @Published var turnCount: Int = 0

    private var webSocket: URLSessionWebSocketTask?
    private let urlSession = URLSession(configuration: .default)
    private let audioEngine = AVAudioEngine()
    private let audioPlayer = AVAudioPlayerNode()
    private var playerFormat: AVAudioFormat?
    private var micTapInstalled = false
    private var thinkingWorkItem: DispatchWorkItem?

    override init() {
        super.init()
    }

    // MARK: - Engine (lazy start — called when first connection is made, never stopped after)

    private func ensureEngineRunning() {
        guard !audioEngine.isRunning else { return }

        let avSession = AVAudioSession.sharedInstance()
        try? avSession.setCategory(.playAndRecord, mode: .voiceChat,
                                   options: [.defaultToSpeaker, .allowBluetooth])
        try? avSession.setActive(true)

        if playerFormat == nil {
            playerFormat = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                         sampleRate: 24000, channels: 1, interleaved: true)
            audioEngine.attach(audioPlayer)
            if let pf = playerFormat {
                audioEngine.connect(audioPlayer, to: audioEngine.mainMixerNode, format: pf)
            }
        }

        audioEngine.prepare()
        do {
            try audioEngine.start()
        } catch {
            // engine start failure is non-fatal; will retry on playback
        }
    }

    // MARK: - Connect (full duplex: mic + speaker)

    func connect(userId: String, context: String? = nil, name: String? = nil) {
        disconnectWebSocket()
        state = .connecting

        AVAudioApplication.requestRecordPermission { [weak self] granted in
            guard let self else { return }
            guard granted else {
                DispatchQueue.main.async { self.state = .error("Microphone access denied") }
                return
            }
            DispatchQueue.main.async {
                // Install tap first — accessing inputNode may reconfigure + stop the engine.
                // Then ensure engine is running after the reconfiguration settles.
                self.installMicTapIfNeeded()
                self.ensureEngineRunning()
                self.openWebSocket(userId: userId, context: context, name: name)
                self.state = .listening
            }
        }
    }

    // MARK: - Connect (playback only — intro screen, no mic)

    func connectGreetOnly() {
        disconnectWebSocket()
        ensureEngineRunning()
        state = .connecting
        let guestId = "guest-\(UUID().uuidString)"
        openWebSocket(userId: guestId, context: "intro", name: nil)
        DispatchQueue.main.async { self.state = .listening }
    }

    // MARK: - Disconnect (WebSocket only — engine stays alive)

    func disconnect() {
        thinkingWorkItem?.cancel()
        thinkingWorkItem = nil
        disconnectWebSocket()
        state = .idle
        transcript = ""
        toolStatus = ""
    }

    func sendText(_ text: String) {
        let msg = ["type": "text_input", "text": text]
        guard let data = try? JSONSerialization.data(withJSONObject: msg),
              let str = String(data: data, encoding: .utf8) else { return }
        webSocket?.send(.string(str)) { _ in }
        state = .thinking
    }

    // MARK: - Private helpers

    private func disconnectWebSocket() {
        if let ws = webSocket {
            let msg = URLSessionWebSocketTask.Message.string(#"{"type":"end_session"}"#)
            ws.send(msg) { _ in }
            ws.cancel(with: .normalClosure, reason: nil)
        }
        webSocket = nil
    }

    private func openWebSocket(userId: String, context: String?, name: String?) {
        let wsBase = kBaseURL.replacingOccurrences(of: "http", with: "ws")
        var components = URLComponents(string: "\(wsBase)/ws/\(userId)")!
        let tz = TimeZone.current.identifier
        var queryItems: [URLQueryItem] = [URLQueryItem(name: "tz", value: tz)]
        if let context { queryItems.append(URLQueryItem(name: "context", value: context)) }
        if let name    { queryItems.append(URLQueryItem(name: "name",    value: name))    }
        components.queryItems = queryItems

        guard let wsURL = components.url else {
            DispatchQueue.main.async { self.state = .error("Invalid server URL") }
            return
        }
        webSocket = urlSession.webSocketTask(with: wsURL)
        webSocket?.resume()
        receiveLoop()
    }

    private func installMicTapIfNeeded() {
        guard !micTapInstalled else { return }

        micTapInstalled = true
        let targetFormat = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                         sampleRate: 16000, channels: 1, interleaved: true)!
        // Converter is created lazily on the first real buffer — avoids the 0.0Hz
        // sample rate that inputNode reports before the hardware finishes initializing.
        var converter: AVAudioConverter?
        var micChunkCount = 0

        audioEngine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: nil) { [weak self] buffer, _ in
            guard let self else { return }
            if case .speaking = self.state { return }

            // Build converter from the first real buffer format
            if converter == nil {
                guard buffer.format.sampleRate > 0,
                      let c = AVAudioConverter(from: buffer.format, to: targetFormat) else {
                            return
                }
                converter = c
            }
            guard let converter else { return }

            let ratio = 16000.0 / buffer.format.sampleRate
            let outFrames = AVAudioFrameCount(max(1, Double(buffer.frameLength) * ratio))
            guard let converted = AVAudioPCMBuffer(pcmFormat: targetFormat,
                                                   frameCapacity: outFrames) else { return }
            var error: NSError?
            converter.convert(to: converted, error: &error) { _, status in
                status.pointee = .haveData
                return buffer
            }
            guard error == nil, let data = converted.toData() else { return }
            micChunkCount += 1
            self.webSocket?.send(.data(data)) { _ in }

            // After 500 ms of silence from the server, assume Gemini is processing → show thinking
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.thinkingWorkItem?.cancel()
                let item = DispatchWorkItem { [weak self] in
                    guard let self else { return }
                    if case .listening = self.state { self.state = .thinking }
                }
                self.thinkingWorkItem = item
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: item)
            }
        }
    }

    // MARK: - Receive loop

    private func receiveLoop() {
        guard let ws = webSocket else { return }
        ws.receive { [weak self] result in
            guard let self, self.webSocket === ws else { return }  // ignore if already disconnected/replaced
            switch result {
            case .success(let msg):
                switch msg {
                case .data(let audioData):
                    self.playAudio(audioData)
                    DispatchQueue.main.async {
                        self.thinkingWorkItem?.cancel()
                        self.thinkingWorkItem = nil
                        self.toolStatus = ""
                        self.state = .speaking
                    }
                case .string(let text):
                    if let json = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] {
                        let msgType = json["type"] as? String
                        if msgType == "tool_status", let message = json["message"] as? String {
                            DispatchQueue.main.async {
                                self.toolStatus = message
                                self.state = .thinking
                            }
                        } else if msgType == "turn_complete" {
                            DispatchQueue.main.async {
                                self.thinkingWorkItem?.cancel()
                                self.thinkingWorkItem = nil
                                self.toolStatus = ""
                                self.state = .listening
                                self.turnCount += 1
                                // Fade out CC captions after a short pause
                                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                                    withAnimation(.easeOut(duration: 0.4)) { self.transcript = "" }
                                }
                            }
                        } else if msgType == "transcript", let t = json["text"] as? String, !t.isEmpty {
                            DispatchQueue.main.async {
                                withAnimation(.easeIn(duration: 0.15)) { self.transcript = t }
                            }
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
                DispatchQueue.main.async {
                    self.thinkingWorkItem?.cancel()
                    self.thinkingWorkItem = nil
                    self.toolStatus = ""
                    self.transcript = ""
                    self.state = .error("Connection lost")
                }
            }
        }
    }

    // MARK: - Playback

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
        if !audioEngine.isRunning {
            try? AVAudioSession.sharedInstance().setActive(true)
            do {
                try audioEngine.start()
            } catch {
                return
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

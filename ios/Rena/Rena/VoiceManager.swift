import Foundation
import AVFoundation
import Combine
import SwiftUI
import os.log

private let vlog = Logger(subsystem: "com.rena.app", category: "Voice")

enum VoiceState: Equatable {
    case idle
    case connecting
    case listening
    case thinking
    case speaking
    case error(String)
}

/// Shared voice manager — one instance for the whole app lifetime.
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

    /// Incremented on every disconnect. Stale DispatchQueue.main.async blocks
    /// capture this value and bail if it has changed by the time they execute.
    private var sessionVersion: Int = 0

    /// Set at the start of connect(); cleared immediately by disconnect() so a
    /// pending AVAudioApplication.requestRecordPermission callback self-aborts
    /// rather than opening a ghost WebSocket after the session was already torn down.
    private var pendingConnectID: UUID?

    override init() {
        super.init()
        // Re-start the engine whenever iOS reconfigures the audio graph
        // (e.g. headphones plugged in, phone call ends, sample-rate change).
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleEngineConfigChange),
            name: .AVAudioEngineConfigurationChange,
            object: audioEngine
        )
    }

    @objc private func handleEngineConfigChange(_ notification: Notification) {
        // iOS stopped the engine due to a hardware reconfiguration (e.g. headphones,
        // phone call, sample-rate change). Just restart it — DO NOT touch the tap.
        // The tap survives engine stops; reinstalling it would crash ("already has a tap").
        vlog.warning("AVAudioEngineConfigurationChange fired")
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.audioEngine.isRunning else { return }
            vlog.info("Engine not running after config change — restarting")
            self.ensureEngineRunning()
        }
    }

    // MARK: - Engine setup

    private func activateVoiceChatSession() {
        // Set voiceChat mode so the HW sample rate is locked to 16 kHz BEFORE
        // installMicTapIfNeeded() accesses inputNode. The tap is installed with
        // format:nil (= current HW format), so the session mode must be set first
        // to avoid an HW-format mismatch (-10868) if the mode is changed later.
        let s = AVAudioSession.sharedInstance()
        do {
            try s.setCategory(.playAndRecord, mode: .voiceChat,
                              options: [.defaultToSpeaker, .allowBluetooth])
            try s.setActive(true)
            vlog.info("AVAudioSession set: voiceChat, HW sample rate = \(s.sampleRate) Hz")
        } catch {
            vlog.error("AVAudioSession setup failed: \(error)")
        }
    }

    private func ensureEngineRunning() {
        guard !audioEngine.isRunning else {
            vlog.debug("ensureEngineRunning: already running")
            return
        }

        // Session must be active (voiceChat mode) before we start the engine.
        let s = AVAudioSession.sharedInstance()
        try? s.setCategory(.playAndRecord, mode: .voiceChat,
                           options: [.defaultToSpeaker, .allowBluetooth])
        try? s.setActive(true)

        if playerFormat == nil {
            playerFormat = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                         sampleRate: 24000, channels: 1, interleaved: true)
            audioEngine.attach(audioPlayer)
            if let pf = playerFormat {
                audioEngine.connect(audioPlayer, to: audioEngine.mainMixerNode, format: pf)
                vlog.info("AudioPlayer attached and connected at 24 kHz Int16")
            }
        }

        audioEngine.prepare()
        do {
            try audioEngine.start()
            vlog.info("AudioEngine started, isRunning=\(self.audioEngine.isRunning)")
        } catch {
            vlog.error("AudioEngine.start() failed: \(error)")
        }
    }

    // MARK: - Connect (full duplex: mic + speaker)

    func connect(userId: String, context: String? = nil, name: String? = nil) {
        vlog.info("connect() userId=\(userId) context=\(context ?? "nil")")
        disconnectWebSocket()
        state = .connecting

        let connectID = UUID()
        pendingConnectID = connectID

        AVAudioApplication.requestRecordPermission { [weak self] granted in
            guard let self else { return }
            vlog.info("Microphone permission: \(granted)")
            guard granted else {
                DispatchQueue.main.async { self.state = .error("Microphone access denied") }
                return
            }
            DispatchQueue.main.async {
                guard self.pendingConnectID == connectID else {
                    vlog.info("connect() aborted — session was disconnected while waiting for permission")
                    return
                }

                // Step 1: Set voiceChat mode FIRST so HW = 16 kHz before tap install.
                //         The tap uses format:nil (= current HW format), so this must
                //         happen before inputNode is accessed.
                self.activateVoiceChatSession()

                // Step 2: Install tap — accessing inputNode may reconfigure + stop the engine.
                //         That is expected; ensureEngineRunning() (step 3) handles the restart.
                self.installMicTapIfNeeded()

                // Step 3: Start engine AFTER any reconfiguration from inputNode access has settled.
                self.ensureEngineRunning()

                // Step 4: Open WebSocket — audio flows once the server sends its opening prompt.
                self.openWebSocket(userId: userId, context: context, name: name)
                self.state = .listening
                vlog.info("connect() complete — engine=\(self.audioEngine.isRunning) state=listening")
            }
        }
    }

    // MARK: - Connect (playback only — intro screen, no mic)

    func connectGreetOnly() {
        vlog.info("connectGreetOnly()")
        disconnectWebSocket()
        activateVoiceChatSession()
        ensureEngineRunning()
        state = .connecting
        let guestId = "guest-\(UUID().uuidString)"
        openWebSocket(userId: guestId, context: "intro", name: nil)
        DispatchQueue.main.async { self.state = .listening }
    }

    // MARK: - Disconnect (WebSocket only — engine stays alive)

    func disconnect() {
        vlog.info("disconnect() — sessionVersion \(self.sessionVersion) → \(self.sessionVersion + 1)")
        pendingConnectID = nil        // abort any in-flight permission callback
        thinkingWorkItem?.cancel()
        thinkingWorkItem = nil
        sessionVersion += 1          // invalidate all stale main-queue state writes
        fadeOutAndStop()             // graceful audio cut — no click
        disconnectWebSocket()
        state = .idle
        transcript = ""
        toolStatus = ""
    }

    private func fadeOutAndStop() {
        guard audioPlayer.isPlaying else { return }
        audioPlayer.volume = 0
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            self?.audioPlayer.stop()
            self?.audioPlayer.volume = 1
        }
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
        webSocket?.cancel(with: .normalClosure, reason: nil)
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
            vlog.error("openWebSocket: invalid URL")
            DispatchQueue.main.async { self.state = .error("Invalid server URL") }
            return
        }
        vlog.info("openWebSocket: \(wsURL)")
        webSocket = urlSession.webSocketTask(with: wsURL)
        webSocket?.resume()
        receiveLoop()
    }

    private func installMicTapIfNeeded() {
        guard !micTapInstalled else {
            vlog.debug("installMicTapIfNeeded: tap already installed")
            return
        }

        micTapInstalled = true
        vlog.info("installMicTapIfNeeded: installing tap on inputNode")

        let targetFormat = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                         sampleRate: 16000, channels: 1, interleaved: true)!
        var converter: AVAudioConverter?
        var firstBuffer = true

        audioEngine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: nil) { [weak self] buffer, _ in
            guard let self else { return }
            if case .speaking = self.state { return }

            // Build converter lazily on the first real buffer
            if converter == nil {
                guard buffer.format.sampleRate > 0 else {
                    vlog.warning("Tap: buffer has 0 Hz sample rate, skipping")
                    return
                }
                guard let c = AVAudioConverter(from: buffer.format, to: targetFormat) else {
                    vlog.error("Tap: failed to create converter from \(buffer.format.sampleRate) Hz → 16000 Hz")
                    return
                }
                converter = c
                vlog.info("Tap: converter created — HW=\(buffer.format.sampleRate) Hz → 16000 Hz")
            }

            if firstBuffer {
                firstBuffer = false
                vlog.info("Tap: first audio buffer received, format=\(buffer.format.sampleRate) Hz frames=\(buffer.frameLength)")
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
            self.webSocket?.send(.data(data)) { _ in }

            let v = self.sessionVersion
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.thinkingWorkItem?.cancel()
                let item = DispatchWorkItem { [weak self] in
                    guard let self, self.sessionVersion == v else { return }
                    if case .listening = self.state { self.state = .thinking }
                }
                self.thinkingWorkItem = item
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: item)
            }
        }
        vlog.info("installMicTapIfNeeded: tap installed, engine isRunning=\(self.audioEngine.isRunning)")
    }

    // MARK: - Receive loop

    private func receiveLoop() {
        guard let ws = webSocket else { return }
        ws.receive { [weak self] result in
            guard let self, self.webSocket === ws else { return }
            let v = self.sessionVersion
            switch result {
            case .success(let msg):
                switch msg {
                case .data(let audioData):
                    vlog.debug("WS: received audio \(audioData.count) bytes")
                    self.playAudio(audioData)
                    DispatchQueue.main.async {
                        guard self.sessionVersion == v else { return }
                        self.thinkingWorkItem?.cancel()
                        self.thinkingWorkItem = nil
                        self.toolStatus = ""
                        self.state = .speaking
                    }
                case .string(let text):
                    if let json = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] {
                        let msgType = json["type"] as? String
                        vlog.debug("WS: received text type=\(msgType ?? "unknown")")
                        if msgType == "tool_status", let message = json["message"] as? String {
                            vlog.info("WS: tool_status → \(message)")
                            DispatchQueue.main.async {
                                guard self.sessionVersion == v else { return }
                                self.toolStatus = message
                                self.state = .thinking
                            }
                        } else if msgType == "turn_complete" {
                            vlog.info("WS: turn_complete received")
                            DispatchQueue.main.async {
                                guard self.sessionVersion == v else { return }
                                self.thinkingWorkItem?.cancel()
                                self.thinkingWorkItem = nil
                                self.toolStatus = ""
                                self.state = .listening
                                self.turnCount += 1
                                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                                    guard let self, self.sessionVersion == v else { return }
                                    withAnimation(.easeOut(duration: 0.4)) { self.transcript = "" }
                                }
                            }
                        } else if msgType == "transcript", let t = json["text"] as? String, !t.isEmpty {
                            vlog.info("WS: transcript → \(t)")
                            DispatchQueue.main.async {
                                guard self.sessionVersion == v else { return }
                                withAnimation(.easeIn(duration: 0.15)) { self.transcript = t }
                            }
                        } else if let t = json["text"] as? String {
                            DispatchQueue.main.async {
                                guard self.sessionVersion == v else { return }
                                self.lastResponse = t
                                self.state = .listening
                            }
                        }
                    }
                @unknown default: break
                }
                self.receiveLoop()
            case .failure(let error):
                vlog.error("WS: receive failure — \(error)")
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
        guard let format = playerFormat else {
            vlog.error("playAudio: playerFormat is nil")
            return
        }
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
            vlog.warning("playAudio: engine not running — attempting restart")
            try? AVAudioSession.sharedInstance().setActive(true)
            do {
                try audioEngine.start()
                vlog.info("playAudio: engine restarted, isRunning=\(self.audioEngine.isRunning)")
            } catch {
                vlog.error("playAudio: engine restart failed — \(error)")
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

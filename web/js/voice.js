// VoiceManager — mirrors VoiceManager.swift
// Streams PCM mic audio over WebSocket to Rena backend and plays back responses.

class VoiceManager extends EventTarget {
  constructor() {
    super();
    this.ws           = null;
    this.audioCtx     = null;
    this.workletNode  = null;
    this.micStream    = null;
    this.nextPlayTime = 0;
    this.state        = "idle"; // idle | connecting | listening | thinking | speaking | error
    this.transcript   = "";
    this.toolStatus   = "";
  }

  // ── Connect ───────────────────────────────────────────────────────────────

  async connect(userId, context = "home", name = "") {
    this.disconnect();
    this._setState("connecting");

    try {
      // Mic permission + AudioContext at 16kHz for sending
      this.micStream = await navigator.mediaDevices.getUserMedia({ audio: true, video: false });
      this.audioCtx  = new AudioContext({ sampleRate: 16000 });

      await this.audioCtx.audioWorklet.addModule("worklet/audio-processor.js");
      const source = this.audioCtx.createMediaStreamSource(this.micStream);
      this.workletNode = new AudioWorkletNode(this.audioCtx, "rena-audio-processor");
      source.connect(this.workletNode);

      this.workletNode.port.onmessage = (e) => {
        if (this.ws?.readyState === WebSocket.OPEN && this.state !== "speaking") {
          this.ws.send(e.data);
        }
      };

      // Open WebSocket
      const tz  = Intl.DateTimeFormat().resolvedOptions().timeZone;
      const url = `${CONFIG.WS_BASE}/ws/${encodeURIComponent(userId)}?context=${encodeURIComponent(context)}&name=${encodeURIComponent(name)}&tz=${encodeURIComponent(tz)}`;
      this.ws = new WebSocket(url);
      this.ws.binaryType = "arraybuffer";

      this.ws.onopen    = () => this._setState("listening");
      this.ws.onclose   = () => { if (this.state !== "idle") this._setState("idle"); };
      this.ws.onerror   = () => this._setState("error");
      this.ws.onmessage = (e) => this._handleMessage(e);

    } catch (err) {
      console.error("VoiceManager connect error:", err);
      this._setState("error");
    }
  }

  disconnect() {
    if (this.ws?.readyState === WebSocket.OPEN) {
      this.ws.send(JSON.stringify({ type: "end_session" }));
    }
    this.ws?.close();
    this.ws = null;
    this.workletNode?.disconnect();
    this.workletNode = null;
    this.micStream?.getTracks().forEach(t => t.stop());
    this.micStream = null;
    if (this.audioCtx?.state !== "closed") this.audioCtx?.close();
    this.audioCtx    = null;
    this.nextPlayTime = 0;
    this.transcript   = "";
    this.toolStatus   = "";
    this._setState("idle");
  }

  sendText(text) {
    if (this.ws?.readyState === WebSocket.OPEN) {
      this.ws.send(JSON.stringify({ type: "text_input", text }));
      this._setState("thinking");
    }
  }

  // ── Internal ──────────────────────────────────────────────────────────────

  _handleMessage(e) {
    if (e.data instanceof ArrayBuffer) {
      this._playChunk(e.data);
      if (this.toolStatus) {
        this.toolStatus = "";
        this.dispatchEvent(new CustomEvent("transcriptchange", { detail: "" }));
      }
      this._setState("speaking");
      return;
    }
    try {
      const msg = JSON.parse(e.data);
      if (msg.type === "tool_status") {
        this.toolStatus = msg.message || "";
        this._setState("thinking");
      } else if (msg.type === "turn_complete") {
        this.toolStatus = "";
        this.transcript = "";
        this._setState("listening");
        this.dispatchEvent(new CustomEvent("transcriptchange", { detail: "" }));
        this.dispatchEvent(new CustomEvent("turncomplete"));
      } else if (msg.type === "transcript" && msg.text) {
        this.transcript = msg.text;
        this.dispatchEvent(new CustomEvent("transcriptchange", { detail: msg.text }));
      }
    } catch (_) {}
  }

  _playChunk(buffer) {
    // Decode Int16 PCM @ 24000 Hz and schedule playback
    if (!this.audioCtx || this.audioCtx.state === "closed") return;
    if (this.audioCtx.state === "suspended") this.audioCtx.resume();

    const int16    = new Int16Array(buffer);
    const float32  = new Float32Array(int16.length);
    for (let i = 0; i < int16.length; i++) float32[i] = int16[i] / 32768.0;

    // Need a separate playback context at 24kHz
    if (!this._playCtx) {
      this._playCtx = new AudioContext({ sampleRate: 24000 });
    }
    if (this._playCtx.state === "suspended") this._playCtx.resume();

    const audioBuf = this._playCtx.createBuffer(1, float32.length, 24000);
    audioBuf.copyToChannel(float32, 0);

    const src = this._playCtx.createBufferSource();
    src.buffer = audioBuf;
    src.connect(this._playCtx.destination);

    const now   = this._playCtx.currentTime;
    const start = Math.max(now, this.nextPlayTime);
    src.start(start);
    this.nextPlayTime = start + audioBuf.duration;
  }

  _setState(state) {
    this.state = state;
    this.dispatchEvent(new CustomEvent("statechange", { detail: state }));
  }
}

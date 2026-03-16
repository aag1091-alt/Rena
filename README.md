# Rena — Personal Health Companion

AI-powered health companion. Log meals, track workouts, plan your days, and stay on track toward your goals through natural voice conversation.

---

## Ways to experience the app

### Option 1 — Xcode Simulator (recommended for full experience)

The full app runs on the iOS Simulator in Xcode. Voice, camera, and all features work.

**Requirements**
- macOS 13 or later
- Xcode 15 or later ([download from the Mac App Store](https://apps.apple.com/app/xcode/id497799835))

**Steps**

1. Clone the repo
   ```bash
   git clone https://github.com/aag1091-alt/Rena.git
   cd Rena/ios/Rena
   ```

2. Open the project in Xcode
   ```bash
   open Rena.xcodeproj
   ```

3. Select a simulator target — **iPhone 15 Pro** or **iPhone 16** recommended — from the device picker in the toolbar.

4. Press **⌘R** (or the ▶ Run button) to build and launch.

5. The app connects to the live backend on Cloud Run — no local server setup needed.

> **Microphone in Simulator:** The simulator uses your Mac's microphone. When prompted for microphone permission, click Allow. Make sure your Mac mic is not muted.

> **Camera in Simulator:** The simulator doesn't have a real camera. Use **Device → Photos** in the Xcode menu to add test images, or use the photo library picker in the Scan tab.

---

### Option 2 — Physical iPhone

If you have an Apple Developer account:

1. Connect your iPhone via USB
2. Select your device in the Xcode device picker
3. Trust the developer certificate on the device (**Settings → General → VPN & Device Management**)
4. Press **⌘R** to build and run

This gives the full native experience including real camera and microphone.

---

### Option 3 — REST API (no iOS required)

The backend is live and fully accessible. You can hit any endpoint directly:

```
Base URL: https://rena-agent-[hash]-uc.a.run.app
```

Key endpoints to explore:
```bash
# Seed 7 days of test data for a user
POST /dev/seed/{user_id}

# Get today's progress
GET /progress/{user_id}

# Get a workout plan
GET /workout-plan/{user_id}

# Get a meal plan
GET /meal-plan/{user_id}

# Get workbook insight
GET /workbook/insight/{user_id}
```

---

## Project structure

```
rena/
├── agent/          # Python backend (FastAPI + Google ADK)
│   ├── main.py     # FastAPI app + REST endpoints
│   ├── rena/
│   │   ├── agent.py    # ADK agent definition + tools list
│   │   ├── voice.py    # WebSocket handler + Gemini Live session
│   │   └── tools.py    # All agent tools (log, plan, scan, etc.)
│   └── seed_prompts.py # Push voice context prompts to Firestore
│
├── ios/Rena/       # SwiftUI iOS app
│   └── Rena/
│       ├── VoiceManager.swift   # WebSocket + AVAudioEngine
│       ├── RenaButton.swift     # Voice overlay + tab bar
│       └── ...
│
└── architecture.md  # Full system architecture
```

---

## Running the backend locally

```bash
cd agent
python3 -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt

# Copy and fill in your credentials
cp .env.example .env

uvicorn main:app --reload --port 8080
```

Then update `kBaseURL` in the iOS app to point to `http://localhost:8080`.

---

## A note on the web app question

The backend is fully platform-agnostic — any client that can open a WebSocket and stream PCM audio can talk to Rena. A web app (PWA) is technically feasible:

- **Voice** — browser `getUserMedia` can capture mic audio and stream it over WebSocket. Latency and quality are slightly worse than native but workable.
- **Camera / scan** — `<input type="file" capture>` works in mobile Safari for photo uploads.
- **What you'd lose** — fine-grained PCM audio control, seamless exercise video looping, and background audio. The REST-based features (plans, history, insights) would work identically.

A web frontend isn't built yet, but the backend is ready for it.

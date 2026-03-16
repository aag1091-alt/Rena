# Rena — Personal Health Companion

AI-powered health companion. Log meals, track workouts, plan your days, and stay on track toward your goals through natural voice conversation.

---

## Ways to experience the app

### Option 1 — Web App (easiest, no install required)

A full Progressive Web App (PWA) is live and ready to use — no Xcode, no install needed.

**URL:** https://rena-490107-f0f28.web.app

Features available in the web app:
- Voice conversation with Rena (log meals, workouts, weight)
- Home dashboard — daily progress, food log, workout log
- History view — scroll back through past days
- Plan / Workbook — view and manage workout and meal plans, with delete buttons
- Food scan — upload a photo to identify food and estimate calories
- Settings — profile, log out, developer seed/reset tools

> **Voice:** Tap the Rena orb and allow microphone access when prompted. Works in Chrome and Safari on desktop and mobile.

---

### Option 2 — Xcode Simulator (recommended for full native experience)

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

### Option 3 — Physical iPhone

If you have an Apple Developer account:

1. Connect your iPhone via USB
2. Select your device in the Xcode device picker
3. Trust the developer certificate on the device (**Settings → General → VPN & Device Management**)
4. Press **⌘R** to build and run

This gives the full native experience including real camera and microphone.

---

### Option 4 — REST API (no client required)

The backend is live and fully accessible. You can hit any endpoint directly:

```
Base URL: https://rena-agent-879054433521.us-central1.run.app
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

## AI-generated exercise videos

Rena includes AI-generated video demonstrations for a selection of exercises. These videos are pre-generated and served directly from Google Cloud Storage — no cost is incurred on playback.

**Exercises with AI-generated videos:**

| Exercise | Video |
|---|---|
| Bodyweight Squats | [view](https://storage.googleapis.com/rena-assets/exercise_videos/bodyweight_squats.mp4) |
| Glute Bridges | [view](https://storage.googleapis.com/rena-assets/exercise_videos/glute_bridges.mp4) |
| Plank | [view](https://storage.googleapis.com/rena-assets/exercise_videos/plank.mp4) |
| Walking Lunges | [view](https://storage.googleapis.com/rena-assets/exercise_videos/walking_lunges.mp4) |

For all other exercises the ▶ button opens a YouTube search instead.

### How to test the video feature

1. Open the web app at https://rena-490107-f0f28.web.app (or run the iOS app)
2. Go to the **Plan** tab
3. Tap the Rena orb and say: *"Add a plank to my workout plan for today"*
4. After Rena responds, the Plan tab will refresh and show the workout
5. Tap the **▶** button next to Plank — the AI-generated video will open directly
6. Try adding **Bodyweight Squats**, **Glute Bridges**, or **Walking Lunges** to see their videos too
7. Any other exercise (e.g. "Add push-ups") will show a YouTube search link instead

This behaviour is identical on both the **web app** and **iOS app**.

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
├── web/            # Progressive Web App (PWA)
│   ├── index.html
│   ├── js/         # app.js, api.js, voice.js, config.js
│   ├── css/        # app.css
│   └── sw.js       # Service worker (offline + cache)
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

Then update `kBaseURL` in `ios/Rena/Rena/RenaAPI.swift` and `API_BASE` in `web/js/config.js` to point to `http://localhost:8080`.

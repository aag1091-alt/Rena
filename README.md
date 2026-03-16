# Rena — Personal Health Companion

AI-powered health companion. Log meals, track workouts, plan your days, and stay on track toward your goals through natural voice conversation.

---

## Ways to experience the app

### Option 1 — Xcode Simulator ★ Recommended for judging

The primary client is the native iOS app — this is the intended experience and the best way to evaluate the product. Voice quality, animations, camera, and the exercise video player are all significantly better than the web companion.

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

### Option 3 — Web App (quick preview, no install)

A PWA companion is live at https://rena-490107-f0f28.web.app — it mirrors the iOS app's screens and was built rapidly as a secondary access point. **It has not been thoroughly tested** and is provided for convenience rather than as a primary evaluation surface. Use the iOS app for judging.

Features available: voice, home dashboard, history, plan/workbook, food scan, settings.

> **Voice:** Tap the Rena orb and allow microphone access. Works in Chrome and Safari.

---

### Option 4 — REST API (no client required)

The backend is live and fully accessible:

```
Base URL: https://rena-agent-879054433521.us-central1.run.app
```

Key endpoints:
```bash
POST /dev/seed/{user_id}       # Seed 7 days of test data
GET  /progress/{user_id}       # Today's progress
GET  /workout-plan/{user_id}   # Workout plan
GET  /meal-plan/{user_id}      # Meal plan
GET  /workbook/insight/{user_id}  # Workbook insight
```

---

## AI-generated exercise videos

Rena includes AI-generated video demonstrations for a selection of exercises, served directly from Google Cloud Storage.

**Exercises with AI-generated videos:**

| Exercise | Video |
|---|---|
| Bodyweight Squats | [view](https://storage.googleapis.com/rena-assets/exercise_videos/bodyweight_squats.mp4) |
| Glute Bridges | [view](https://storage.googleapis.com/rena-assets/exercise_videos/glute_bridges.mp4) |
| Plank | [view](https://storage.googleapis.com/rena-assets/exercise_videos/plank.mp4) |
| Walking Lunges | [view](https://storage.googleapis.com/rena-assets/exercise_videos/walking_lunges.mp4) |

For all other exercises the ▶ button opens a YouTube search instead.

### How to test the video feature

1. Open the iOS app (or web app at https://rena-490107-f0f28.web.app)
2. Go to the **Plan** tab
3. Tap the Rena orb and say: *"Add a plank to my workout plan for today"*
4. After Rena responds, the Plan tab refreshes and shows the workout
5. Tap the **▶** button next to Plank — the AI-generated video opens directly
6. Try **Bodyweight Squats**, **Glute Bridges**, or **Walking Lunges** for their videos too
7. Any other exercise (e.g. "Add push-ups") opens a YouTube search instead

This behaviour is identical on both iOS and the web app.

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
├── ios/Rena/       # SwiftUI iOS app (primary client)
│   └── Rena/
│       ├── VoiceManager.swift   # WebSocket + AVAudioEngine
│       ├── RenaButton.swift     # Voice overlay + tab bar
│       └── ...
│
├── web/            # PWA companion (secondary)
│   ├── index.html
│   ├── js/         # app.js, api.js, voice.js, config.js
│   ├── css/        # app.css
│   └── sw.js       # Service worker
│
└── architecture.md  # Full system architecture
```

---

## Running the backend locally

```bash
cd agent
python3 -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt

cp .env.example .env  # fill in credentials

uvicorn main:app --reload --port 8080
```

Then update `kBaseURL` in `ios/Rena/Rena/RenaAPI.swift` and `API_BASE` in `web/js/config.js` to point to `http://localhost:8080`.

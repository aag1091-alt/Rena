# Rena — Personal Health Companion

AI-powered health companion. Log meals, track workouts, plan your days, and stay on track toward your goals through natural voice conversation.

---

## Ways to experience the app

### Option 1 — Physical iPhone ★ Recommended for judging

The primary client is the native iOS app on a real device — this is the intended experience and the best way to evaluate the product. Voice, camera, and the exercise video player all require a physical device to work properly.

**Requirements**
- An iPhone running iOS 16 or later
- macOS with Xcode 15 or later ([download from the Mac App Store](https://apps.apple.com/app/xcode/id497799835))
- An Apple Developer account

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

3. Connect your iPhone via USB and select it in the Xcode device picker.

4. Trust the developer certificate on the device: **Settings → General → VPN & Device Management**.

5. Press **⌘R** (or the ▶ Run button) to build and run.

6. The app connects to the live backend on Cloud Run — no local server setup needed.

---

### Option 2 — Web App (quick preview, no install)

A PWA companion is live at https://rena-490107-f0f28.web.app — it mirrors the iOS app's screens and was built rapidly as a secondary access point. **It has not been thoroughly tested** and is provided for convenience rather than as a primary evaluation surface. Use the iOS app for judging.

Features available: voice, home dashboard, history, plan/workbook, food scan, settings.

> **Voice:** Tap the Rena orb and allow microphone access. Works in Chrome and Safari.

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
3. Tap the Rena orb and say one of the following — each has an AI-generated video:
   - *"Add a plank to my workout plan for today"*
   - *"Add bodyweight squats to my workout plan for today"*
   - *"Add glute bridges to my workout plan for today"*
   - *"Add walking lunges to my workout plan for today"*
4. After Rena responds, the Plan tab refreshes and shows the exercise
5. Tap the **▶** button — the AI-generated video plays directly (no YouTube redirect)
6. Any other exercise (e.g. *"Add push-ups"*) will open a YouTube search instead

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
├── ios/Rena/       # SwiftUI iOS app (primary client — physical iPhone recommended)
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

# Rena — Architecture

## System Overview

```
┌─────────────────────────────────────────────────────┐
│                   iOS App (SwiftUI)                  │
│                                                      │
│  ┌──────────┐  ┌──────────┐  ┌────────────────────┐ │
│  │  Voice   │  │  Camera  │  │   Visual Journey   │ │
│  │   UI     │  │ Gallery  │  │   (Goal Screen)    │ │
│  └────┬─────┘  └────┬─────┘  └────────┬───────────┘ │
└───────┼─────────────┼─────────────────┼─────────────┘
        │ WebSocket   │ REST            │ REST
        │ (audio)     │ (images)        │ (images)
┌───────▼─────────────▼─────────────────▼─────────────┐
│              Rena Agent (Cloud Run)                   │
│                                                       │
│  ┌─────────────────────────────────────────────────┐ │
│  │           Gemini ADK — Agent Core               │ │
│  │                                                 │ │
│  │  Tools:                                         │ │
│  │  • set_goal        • log_meal                   │ │
│  │  • get_progress    • scan_image                 │ │
│  │  • log_workout     • update_visual_journey      │ │
│  └──────────────┬──────────────────────────────────┘ │
└─────────────────┼────────────────────────────────────┘
                  │
     ┌────────────┼──────────┐
     ▼            ▼          ▼
┌─────────┐ ┌──────────────┐ ┌───────────────┐
│Firestore│ │ Gemini APIs  │ │ Cloud Storage │
│         │ │              │ │               │
│ • users │ │ • Live API   │ │ (vision board │
│ • logs  │ │ • Vision     │ │  images)      │
│ • goals │ │ • Image Gen  │ └───────────────┘
│ • visual│ └──────────────┘
└─────────┘
```

---

## Components

### 1. iOS App (SwiftUI)
Thin client — handles UI and streams data to the agent. All AI logic lives in the backend.

**Screens:**
- **Onboarding** — form-based profile setup, then voice goal-setting with Rena
- **Home** — goal countdown, daily progress ring, calorie/water/workout stats, voice orb
- **Voice** — dedicated full-screen live conversation with Rena
- **Log Food** — camera snap or gallery pick with per-item calorie adjustment
- **Data** — historical daily logs with macro breakdown

**Key iOS capabilities used:**
- `AVFoundation` — real-time audio capture + playback for voice
- `PhotosUI` — gallery access for passive food photo scanning
- `AVCaptureSession` — live camera for food/barcode scanning
- `URLSessionWebSocketTask` — WebSocket connection for voice streaming

---

### 2. Rena Agent (Python + Gemini ADK)
Hosted on Cloud Run. The brain of the app.

**Framework:** Python + Google Agent Development Kit (ADK)
**API layer:** FastAPI
**Real-time voice:** WebSocket → proxies to Gemini Live API (bidi-streaming)

#### Agent Tools

| Tool | Description | Services used |
|------|-------------|---------------|
| `set_goal` | Save user goal + deadline, generate initial vision board | Firestore, Gemini Image Gen |
| `log_meal` | Log a meal from text description or image | Gemini Vision, Firestore |
| `log_water` | Track daily water intake | Firestore |
| `log_workout` | Log workout + auto-calculate calories burned (MET table) | Firestore |
| `log_weight` | Record today's weight | Firestore |
| `scan_image` | Identify food in a photo, return nutrition estimate | Gemini Vision |
| `correct_scan` | Recalculate nutrition from user's voice correction | Gemini Vision, Firestore |
| `get_progress` | Get today's calories, macros, water, goal % | Firestore |
| `update_visual_journey` | Regenerate vision board at new progress level | Gemini Image Gen, Cloud Storage |

#### API Endpoints

| Method | Endpoint | Purpose |
|--------|----------|---------|
| `WS` | `/ws/{user_id}` | Real-time voice conversation (Gemini Live) |
| `POST` | `/onboard` | Create user profile, calculate calorie target |
| `POST` | `/scan` | Analyze food image from camera or gallery |
| `GET` | `/progress/{user_id}` | Daily progress summary |
| `GET` | `/goal/{user_id}` | Goal details with generated vision board image |
| `POST` | `/log/meal` | Log a meal manually |
| `POST` | `/log/weight` | Log today's weight |
| `POST` | `/visual_journey` | Generate / update visual journey image |
| `GET` | `/pending_correction/{user_id}` | Poll for voice-corrected scan result |

---

### 3. Firestore Schema

```
users/
  {userId}/
    profile:
      goal: "Feel confident at Sarah's wedding"
      deadline: "2026-07-15"
      daily_calorie_target: 1800
      dietary_restrictions: []
      created_at: timestamp

    logs/
      {date}/
        meals: [{ name, calories, macros, source, timestamp }]
        water: { glasses: 6 }
        workouts: [{ type, duration_min, calories_burned }]

    progress/
      {date}/
        calories_consumed: 1200
        calories_target: 1800
        completion_percent: 67
        streak_days: 4

    visual_journey/
      {version}/
        image_url: "gs://rena-bucket/..."
        progress_percent: 67
        generated_at: timestamp
```

---

### 4. Google Cloud Services

| Service | Role |
|---------|------|
| **Cloud Run** | Hosts the Rena agent — auto-scales, serverless |
| **Firestore** | All user data — goals, logs, progress, visual states |
| **Cloud Storage** | Vision board images generated by Gemini |
| **Gemini Live API** | Real-time voice conversation (bidi-streaming) |
| **Gemini Vision** | Food recognition from camera + gallery photos |
| **Gemini Image Gen** | Visual journey evolution |

---

## Data Flow — Key User Journeys

### Voice Check-in (Morning Brief)
```
User speaks → iOS captures audio →
WebSocket stream → Cloud Run →
Gemini Live API (bidi) →
Agent reads Firestore (progress, goal) →
Agent responds with personalized brief →
Audio streamed back → iOS plays response
```

### Food Photo from Gallery
```
iOS detects new food photo in gallery →
Sends image to POST /scan →
Gemini Vision identifies food →
Agent estimates calories/macros →
Asks user to confirm →
Logs to Firestore on confirm
```

### Visual Journey Update
```
Progress hits milestone (25%, 50%, 75%, 100%) →
Agent calls update_visual_journey tool →
Gemini Image Gen creates evolved version of goal image →
Stores in Cloud Storage →
URL saved to Firestore →
iOS fetches and animates transition
```

---

## Build Plan (3 days)

### Day 1 — March 13 (today)
- [ ] Set up Python project + Gemini ADK in `agent/`
- [ ] Firestore schema + Cloud Run config
- [ ] `set_goal` and `get_progress` tools working
- [ ] Basic WebSocket voice endpoint proxying Gemini Live

### Day 2 — March 14
- [ ] `scan_image` + `log_meal` tools (Gemini Vision)
- [ ] `log_workout` + `log_water` + `log_weight` tools
- [ ] iOS app: onboarding screen + voice UI
- [ ] iOS ↔ agent connection working end to end

### Day 3 — March 15
- [ ] `update_visual_journey` tool (Gemini Image Gen)
- [ ] iOS: goal screen with visual journey display
- [ ] iOS: gallery scan flow
- [ ] Deploy to Cloud Run
- [ ] Record demo video

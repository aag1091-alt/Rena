# Rena — Architecture

## System Overview

```
┌──────────────────────────────────────────────────────────────┐
│                      iOS App (SwiftUI)                        │
│                                                               │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌─────────────┐  │
│  │  Voice   │  │  Camera  │  │ Workbook │  │    Goal /   │  │
│  │   UI     │  │ Gallery  │  │  + Plan  │  │   Journey   │  │
│  └────┬─────┘  └────┬─────┘  └────┬─────┘  └──────┬──────┘  │
└───────┼─────────────┼─────────────┼────────────────┼─────────┘
        │ WebSocket   │ REST        │ REST           │ REST
        │ (audio)     │ (images)    │ (plan/video)   │ (goal)
┌───────▼─────────────▼─────────────▼────────────────▼─────────┐
│                   Rena Agent (Cloud Run)                       │
│                                                               │
│  ┌────────────────────────────────────────────────────────┐   │
│  │               Gemini ADK — Agent Core                  │   │
│  │  Tools:                                                │   │
│  │  • set_goal              • log_meal                    │   │
│  │  • get_progress          • scan_image                  │   │
│  │  • log_workout           • log_water / log_weight      │   │
│  │  • generate_workout_plan • get_recent_workouts         │   │
│  └─────────────────────────┬──────────────────────────────┘   │
│                             │                                  │
│  ┌──────────────────────────┼──────────────────────────────┐   │
│  │      REST Endpoints      │                              │   │
│  │  GET/POST /workout-plan  │  GET /exercise/video/{name}  │   │
│  │  PATCH …/exercise/complete  GET /exercise/video/status  │   │
│  │  POST …/exercise/log     │  GET /workbook/insight       │   │
│  └──────────────────────────┴──────────────────────────────┘   │
└───────────────────────────┬───────────────────────────────────┘
                            │
          ┌─────────────────┼──────────────────────┐
          ▼                 ▼                       ▼
┌──────────────┐  ┌──────────────────────┐  ┌──────────────────┐
│  Firestore   │  │     Gemini APIs       │  │  Cloud Storage   │
│              │  │                      │  │  rena-assets/    │
│ • users      │  │ • Live API (voice)   │  │                  │
│ • logs       │  │ • 2.5 Flash (agent)  │  │ exercise_videos/ │
│ • goals      │  │ • Flash Vision       │  │   {slug}.mp4     │
│ • workout_   │  │ • Veo 2 (video gen)  │  │                  │
│   plans      │  │ • Imagen (journey)   │  │ vision_journey/  │
│ • exercise_  │  │                      │  │   images         │
│   video_jobs │  └──────────────────────┘  └──────────────────┘
└──────────────┘
          │
┌─────────▼───────────┐
│  Google Cloud TTS   │
│  en-US-Neural2-F    │
│  (Rena's voice for  │
│   exercise videos)  │
└─────────────────────┘
```

---

## Components

### 1. iOS App (SwiftUI)
Thin client — handles UI and streams data to the agent. All AI logic lives in the backend.

**Screens:**
- **Onboarding** — form-based profile setup, then voice goal-setting with Rena
- **Home** — goal countdown, daily progress ring, calorie/water/workout stats, voice orb
- **Workbook** — daily hub: AI day summary, unified workout plan section, logged activity
- **Goal / Visual Journey** — vision board that evolves as the user hits milestones
- **Dev tab** — reset onboarding, seed 7 days of test data

**Key iOS capabilities:**
- `AVFoundation` / `AVAudioEngine` — real-time audio capture + playback for voice
- `AVQueuePlayer` + `AVPlayerLooper` — seamless looping of exercise coaching videos
- `AVAudioSession.setCategory(.playback)` — audio plays through silent switch
- `PhotosUI` — gallery access for passive food photo scanning
- `URLSessionWebSocketTask` — WebSocket connection for voice streaming

---

### 2. Rena Agent (Python + Gemini ADK)
Hosted on Cloud Run. The brain of the app.

**Framework:** Python + Google Agent Development Kit (ADK)
**API layer:** FastAPI
**Real-time voice:** WebSocket → Gemini Live API (bidi-streaming)

#### Agent Tools

| Tool | Description | Services used |
|------|-------------|---------------|
| `set_goal` | Save user goal + deadline, generate initial vision board | Firestore, Gemini Image Gen |
| `log_meal` | Log a meal from text description | Gemini, Firestore |
| `log_water` | Track daily water intake | Firestore |
| `log_workout` | Log workout + auto-calculate calories burned (MET table) | Firestore |
| `log_weight` | Record today's weight | Firestore |
| `scan_image` | Identify food in a photo, return nutrition estimate | Gemini Vision |
| `get_progress` | Get today's calories, macros, water, goal % | Firestore |
| `generate_workout_plan` | Gemini-powered personalised workout for today | Gemini, Firestore |
| `get_recent_workouts` | Past 14 days of logged workouts for plan context | Firestore |

#### REST Endpoints

| Method | Endpoint | Purpose |
|--------|----------|---------|
| `WS` | `/ws/{user_id}` | Real-time voice conversation (Gemini Live) |
| `POST` | `/onboard` | Create user profile, calculate calorie target |
| `POST` | `/scan` | Analyze food image |
| `GET` | `/progress/{user_id}` | Daily progress summary |
| `GET` | `/goal/{user_id}` | Goal details with visual journey image |
| `GET` | `/workbook/insight/{user_id}` | AI-generated day-so-far summary |
| `GET` | `/workout-plan/{user_id}` | Fetch saved plan for a date |
| `POST` | `/workout-plan/{user_id}` | Generate + save today's plan |
| `PATCH` | `/workout-plan/{user_id}/exercise/{id}/complete` | Toggle exercise done |
| `POST` | `/workout-plan/{user_id}/exercise/{id}/log` | Log exercise to workouts |
| `GET` | `/exercise/video/{name}` | Start / return cached Veo 2 video |
| `GET` | `/exercise/video/status/{job_id}` | Poll video generation status |
| `DELETE` | `/dev/reset/{user_id}` | DEV — wipe all user data |
| `POST` | `/dev/seed/{user_id}` | DEV — seed 7 days of test data |

---

### 3. Exercise Video Pipeline

The most complex subsystem. Generates an AI coaching video per exercise with real voiceover, cached in GCS.

```
1. SCRIPT GENERATION (Gemini 2.5 Flash)
   Real trainer coaching cues — body setup, movement feel, breath cue.
   Safety filters OFF so anatomical terms (glutes, etc.) pass through.

2. TRAINER GENDER
   Random male/female for visual variety.

3. VEO 2 PROMPT
   Exercise + target muscles + gender + script as movement direction.
   "No text, subtitles, captions, or overlays on screen."

4. VEO 2 JOB SUBMITTED (async)
   Returns {status: "generating", job_id} to iOS immediately.
   Job stored in Firestore: exercise_video_jobs/{job_id}

5. IOS POLLS /exercise/video/status/{job_id} every 5s

6. COACHING AUDIO (Google Cloud TTS)
   Script → en-US-Neural2-F (Rena's voice) → MP3

7. FFMPEG MUX
   Veo video + TTS audio → single .mp4

8. GCS UPLOAD
   gs://rena-assets/exercise_videos/{slug}.mp4
   Public, cached forever — same exercise never regenerates.

9. IOS PLAYBACK
   AVQueuePlayer + AVPlayerLooper — seamless loop, no double audio.
```

---

### 4. Firestore Schema

```
users/
  {userId}/
    profile:
      name, sex, age, height_cm, weight_kg, activity_level
      daily_calorie_target, created_at

    logs/
      {date}/
        meals:    [{ name, calories, protein_g, carbs_g, fat_g, logged_at }]
        water:    { glasses: 6 }
        workouts: [{ type, duration_min, calories_burned, logged_at }]
        weight:   { kg: 85.5 }

    workout_plans/
      {date}/
        id, name, date, total_duration_min
        exercises: [{
          id, name, type (strength|cardio),
          sets?, reps?, weight_kg?, duration_min?,
          calories_burned, target_muscles, completed
        }]

goals/
  {userId}/
    goal, goal_type, direction, unit
    start_value, target_value, deadline
    daily_calorie_target, image_url

exercise_video_jobs/
  {job_id}/
    slug, exercise_name, target_muscles
    script, trainer_gender
    operation_name (Veo operation)
    status (generating | done | error)
    attempt, created_at
```

---

### 5. Google Cloud Services

| Service | Role |
|---------|------|
| **Cloud Run** | Hosts the Rena agent — auto-scales, serverless |
| **Firestore** | All user data — goals, logs, plans, video jobs |
| **Cloud Storage** (`rena-assets`) | Exercise videos + vision board images |
| **Gemini Live API** | Real-time voice conversation (bidi-streaming) |
| **Gemini 2.5 Flash** | Agent reasoning, workout plans, coaching scripts, day insights |
| **Gemini Vision** | Food recognition from photos |
| **Veo 2** | AI exercise demonstration videos |
| **Imagen** | Visual journey goal images |
| **Cloud TTS** | Rena's coaching voiceover (`en-US-Neural2-F`) |

---

## Data Flow — Key User Journeys

### Voice Workout Planning
```
User taps "Plan with Rena" →
Voice session opens with workout_plan context →
Rena calls get_recent_workouts →
  Has history → acknowledges + calls generate_workout_plan
  No history  → asks 2 questions → calls generate_workout_plan →
Plan saved to Firestore workout_plans/{date} →
iOS loadDay() fetches plan → WorkoutPlanSection renders exercises →
User can tap "Update with Rena" + suggestion chips to refine
```

### Exercise Video
```
User taps ▶ on exercise →
ExerciseVideoSheet opens →
GET /exercise/video/{name} →
  Cached in GCS → return {status: ready, video_url} → play immediately
  Not cached    → generate script → pick gender → submit Veo job →
                  return {status: generating, job_id} →
iOS polls every 5s →
Veo finishes → TTS coaching audio generated → ffmpeg mux →
Upload to GCS → return {status: done, video_url} →
AVQueuePlayer plays + loops seamlessly
```

### Morning Voice Check-in
```
User speaks → iOS captures PCM audio →
WebSocket stream → Cloud Run →
Gemini Live API (bidi) →
Agent calls get_progress → reads Firestore →
Responds with personalised day brief →
Audio streamed back → iOS plays response
```

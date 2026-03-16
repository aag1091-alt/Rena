# Rena — Architecture

## System Overview

```
┌──────────────────────────────────────────────────────────────────┐
│                        iOS App (SwiftUI)                          │
│                                                                   │
│  ┌──────────┐  ┌──────────┐  ┌────────────┐  ┌───────────────┐  │
│  │  Home    │  │ History  │  │    Plan    │  │  Scan/Camera  │  │
│  │          │  │ Workbook │  │  Workout + │  │               │  │
│  │          │  │ Insights │  │  Meal Plan │  │               │  │
│  └────┬─────┘  └────┬─────┘  └─────┬──────┘  └──────┬────────┘  │
└───────┼─────────────┼──────────────┼─────────────────┼───────────┘
        │ WebSocket   │ REST         │ REST            │ REST
        │ (audio)     │ (insights)   │ (plans/video)   │ (scan/log)
┌───────▼─────────────▼──────────────▼─────────────────▼───────────┐
│                      Rena Agent (Cloud Run)                        │
│                                                                    │
│  ┌──────────────────────────────────────────────────────────────┐  │
│  │                  Gemini ADK — Agent Core                     │  │
│  │  Voice tools:                    Plan tools:                 │  │
│  │  • log_meal / delete_meal        • generate_workout_plan     │  │
│  │  • log_water / remove_water      • generate_meal_plan        │  │
│  │  • log_workout / delete_workout  • get_meal_plan             │  │
│  │  • log_weight                    • log_meal_from_plan        │  │
│  │  • scan_image                    • log_exercise_from_plan    │  │
│  │  • get_progress                  • save_tomorrow_plan_note   │  │
│  │  • set_goal                      • get_recent_workouts       │  │
│  └──────────────────────────────────────────────────────────────┘  │
│                                                                    │
│  ┌──────────────────────────────────────────────────────────────┐  │
│  │  Context prompt system                                       │  │
│  │  • Prompts stored in Firestore (prompts/{context_key})       │  │
│  │  • Injected at session start with [RENA MEMORY] block        │  │
│  │  • Per-tab contexts: home, history, scan, workout_plan,      │  │
│  │    update_workout_plan, meal_plan, plan, goal, intro         │  │
│  │  • tool_status WS messages → live save indicators on iOS     │  │
│  └──────────────────────────────────────────────────────────────┘  │
│                                                                    │
│  REST Endpoints:                                                   │
│  WS  /ws/{user_id}              POST /onboard                     │
│  GET /progress/{user_id}        POST /scan                        │
│  GET /goal/{user_id}            GET  /workbook/insight/{user_id}  │
│  GET/POST/DELETE /workout-plan  GET/POST/DELETE /meal-plan        │
│  PATCH …/exercise/complete      POST …/exercise/log               │
│  GET /exercise/video/{name}     GET /exercise/video/status/{id}   │
│  GET/POST/DELETE /tomorrow-plan GET /morning-nudge/{user_id}      │
│  DELETE /dev/reset/{user_id}    POST /dev/seed/{user_id}          │
└───────────────────────────┬────────────────────────────────────────┘
                            │
          ┌─────────────────┼─────────────────────┐
          ▼                 ▼                      ▼
┌──────────────────┐  ┌─────────────────────┐  ┌──────────────────┐
│    Firestore     │  │    Gemini APIs       │  │  Cloud Storage   │
│                  │  │                     │  │  rena-assets/    │
│ users/           │  │ • Live API (voice)  │  │                  │
│   logs/          │  │ • 2.5 Flash         │  │ exercise_videos/ │
│   workout_plans/ │  │ • Flash Vision      │  │   {slug}.mp4     │
│   meal_plans/    │  │ • Veo 2             │  │                  │
│   tomorrow_plans │  │ • Imagen            │  │ vision_journey/  │
│ goals/           │  └─────────────────────┘  └──────────────────┘
│ prompts/         │
│ workbook_insights│        ▼
│ exercise_video_  │  ┌─────────────────────┐
│   jobs/          │  │  Google Cloud TTS   │
│ morning_nudges/  │  │  en-US-Neural2-F    │
└──────────────────┘  │  (exercise videos)  │
                      └─────────────────────┘
```

---

## Components

### 1. iOS App (SwiftUI)

Thin client — all AI logic lives in the backend. The app streams audio and renders data.

**Tabs:**
- **Home** — goal countdown, daily progress ring, calorie/water/workout stats
- **History / Workbook** — scrollable day log, AI-generated day insight + activity summary
- **Plan** — workout plan + meal plan side by side; tomorrow planning with Rena
- **Scan** — camera + photo library for food scanning; per-item calorie sliders

**Key capabilities:**
- `AVAudioEngine` — real-time PCM capture (16 kHz, mono) + playback, engine never stopped between sessions
- `AVQueuePlayer` + `AVPlayerLooper` — seamless looping of exercise coaching videos
- `URLSessionWebSocketTask` — WebSocket for voice streaming + `tool_status` messages
- `PhotosUI` — gallery access for food photo scanning
- Per-tab voice context — each tab opens a Rena session with a specific prompt and context

**Real-time save indicators:**
When a tool runs, the backend sends `{"type": "tool_status", "message": "Logging your meal…"}` over the WebSocket. `VoiceManager` sets `toolStatus` and the voice overlay button switches label in real time — users see `"Building your workout plan…"` or `"Saving your plan…"` rather than a silent wait.

---

### 2. Rena Agent (Python + Gemini ADK)

**Framework:** Python + Google ADK
**API layer:** FastAPI on Cloud Run
**Voice:** WebSocket → Gemini Live API (bidi-streaming, native audio)
**Model:** `gemini-2.5-flash-native-audio-latest` with `thinking_budget=0`

`thinking_budget=0` is injected via a monkey-patch on `Gemini.connect()` — ADK's standard config path silently drops `thinking_config` before it reaches the Live API, so the patch intercepts it directly.

#### Agent Tools

| Tool | Description |
|------|-------------|
| `set_goal` | Save goal + deadline, generate vision board image |
| `get_progress` | Today's calories, macros, water, workouts, goal % |
| `log_meal` / `delete_meal` / `update_meal` | Log or correct a meal |
| `log_water` / `remove_water` | Track water intake |
| `log_workout` / `delete_workout` | Log workout, auto-calc calories via MET table |
| `log_weight` | Record today's weight |
| `scan_image` | Identify food in photo, return per-item nutrition |
| `generate_workout_plan` | Gemini-powered plan using goal + recent history |
| `generate_meal_plan` | Full day of meals calibrated to calorie/protein targets |
| `get_meal_plan` | Fetch saved meal plan for a date |
| `log_meal_from_plan` | Log a planned meal into daily log |
| `log_exercise_from_plan` | Log a planned exercise into workout log |
| `get_recent_workouts` | Past 14 days of workouts for plan context |
| `save_tomorrow_plan_note` | Save planning session summary as morning nudge |

#### Context Prompt System

Prompts stored in Firestore `prompts/{context_key}` — fetched with a 1-minute cache, updated without redeploy. Every session opens with a `[RENA MEMORY]` block (goal, today's stats, recent meals, workouts, weight trend, past session notes) so Rena always has full context before the user speaks.

---

### 3. Exercise Video Pipeline

```
1. SCRIPT (Gemini 2.5 Flash)
   Coaching cues: setup, movement feel, breath. Safety filters BLOCK_NONE
   so anatomical terms pass through.

2. TRAINER GENDER
   Random male/female per generation for visual variety.

3. VEO 2 JOB SUBMITTED
   Prompt: exercise name + target muscles + gender + script as direction.
   "No text, subtitles, captions or overlays on screen."
   Returns {status: generating, job_id} immediately.
   Job stored in Firestore exercise_video_jobs/{job_id}.

4. iOS POLLS /exercise/video/status/{job_id} every 5s

5. VOICEOVER (Google Cloud TTS — en-US-Neural2-F)
   Veo 2 generates silent video. Rather than trying to match a trainer
   voice, we use Rena's own voice (Neural2-F) for the coaching audio —
   the same voice the user has been talking to throughout the app.

6. FFMPEG MUX
   Veo video + TTS audio → single .mp4

7. GCS UPLOAD + CACHE
   gs://rena-assets/exercise_videos/{slug}.mp4
   Same exercise never regenerates.

8. iOS PLAYBACK
   AVQueuePlayer + AVPlayerLooper — seamless loop, no double-audio.
```

---

### 4. Firestore Schema

```
users/{userId}/
  profile:        name, sex, age, height_cm, weight_kg, activity_level,
                  daily_calorie_target, protein_target_g, timezone, created_at

  logs/{date}/    meals:    [{ name, calories, protein_g, carbs_g, fat_g, logged_at }]
                  workouts: [{ type, duration_min, calories_burned, logged_at }]
                  water_glasses: int
                  weight_kg: float

  workout_plans/{date}/
                  id, name, date, total_duration_min
                  exercises: [{ id, name, type, sets?, reps?, weight_kg?,
                                duration_min?, calories_burned, target_muscles,
                                completed, logged }]

  meal_plans/{date}/
                  id, date, total_calories, notes
                  meals: [{ id, meal_type, name, description, cook_time_min,
                             calories, protein_g, carbs_g, fat_g,
                             youtube_query, logged }]

  tomorrow_plans/{date}/
                  summary, date, created_at, updated_at

  morning_nudges/{date}/
                  nudge (cached, generated once per day)

goals/{userId}/   goal, goal_type, direction, unit,
                  start_value, target_value, deadline,
                  daily_calorie_target, image_url

prompts/{context_key}/
                  text (editable without redeploy)

workbook_insights/{userId}/days/{date}/
                  insight, activity, generated_at

exercise_video_jobs/{job_id}/
                  slug, exercise_name, target_muscles, script, trainer_gender,
                  operation_name, status, created_at
```

---

### 5. Google Cloud Services

| Service | Role |
|---------|------|
| **Cloud Run** | Hosts the Rena agent — serverless, min 1 instance to avoid cold-start voice drops |
| **Firestore** | All user data — logs, plans, goals, prompts, insights, video jobs |
| **Cloud Storage** (`rena-assets`) | Exercise videos + vision board images |
| **Gemini Live API** | Real-time voice (bidi-streaming, native audio) |
| **Gemini 2.5 Flash** | Agent reasoning, plan generation, coaching scripts, day insights |
| **Gemini Flash Vision** | Food recognition from photos |
| **Veo 2** | AI exercise demonstration videos |
| **Imagen** | Visual journey goal images |
| **Cloud TTS** (`en-US-Neural2-F`) | Rena's coaching voiceover for exercise videos |

---

## Key Data Flows

### Voice session (any tab)
```
User taps Rena button →
iOS opens WebSocket /ws/{user_id}?context={tab}&name={name} →
Backend fetches [RENA MEMORY] + prompt from Firestore →
Injects as opening message into Gemini Live session →
User speaks → PCM audio streamed over WS →
ADK routes to Gemini Live → intent detected → tool called →
Backend emits tool_status WS message → iOS shows save indicator →
Tool writes to Firestore → Gemini responds →
Audio chunks streamed back → iOS AVAudioEngine plays
```

### Tomorrow planning → morning nudge
```
User taps "Plan tomorrow" →
Voice session (plan context) →
Rena asks about commitments, workout preference, food →
Calls generate_workout_plan and/or generate_meal_plan →
Calls save_tomorrow_plan_note(summary) →
Next morning: GET /morning-nudge/{user_id} →
Gemini generates nudge from saved summary →
Cached in morning_nudges/{today} → displayed on home screen
```

### Exercise video
```
User taps ▶ on exercise →
GET /exercise/video/{name} →
  Cached → return {status: ready, video_url} → play immediately
  Not cached → generate script → pick gender → submit Veo 2 job →
               return {status: generating, job_id} →
iOS polls /exercise/video/status/{job_id} every 5s →
Veo finishes → TTS voiceover generated → ffmpeg mux →
Upload to GCS → {status: done, video_url} →
AVQueuePlayer + AVPlayerLooper plays seamlessly
```

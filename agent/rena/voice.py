"""
WebSocket endpoint for real-time voice conversation with Rena.

Flow:
  iOS app  --[audio bytes]--> WebSocket --> Gemini Live API --> ADK agent tools
  iOS app <--[audio bytes]--  WebSocket <-- Gemini Live API <-- ADK agent response
"""

import asyncio
import json
import time
import traceback
import warnings
from datetime import datetime, timezone

import sentry_sdk

from dotenv import load_dotenv
from fastapi import WebSocket, WebSocketDisconnect
from google.adk.agents.live_request_queue import LiveRequestQueue
from google.adk.agents.run_config import RunConfig
from google.adk.runners import Runner
from google.adk.sessions import InMemorySessionService
from google.genai import errors as genai_errors
from google.genai import types as genai_types

# Suppress ADK's internal Pydantic warning — it sets response_modalities as a string
# internally even when we pass the enum; the warning is cosmetic and doesn't affect behavior.
warnings.filterwarnings("ignore", message=".*Pydantic serializer warnings.*", category=UserWarning)

load_dotenv()

session_service = InMemorySessionService()
APP_NAME = "rena"

# Sessions kept alive after disconnect so Gemini can resume them on reconnect.
# Keyed by user_id → session_id.
_active_sessions: dict[str, str] = {}

# Rich context cache — avoids blocking session start with Firestore reads.
# Keyed by user_id → (context_text, timestamp).
_context_cache: dict[str, tuple[str, float]] = {}
_CONTEXT_CACHE_TTL = 600  # 10 minutes

RUN_CONFIG = RunConfig(
    response_modalities=[genai_types.Modality.AUDIO],
    speech_config=genai_types.SpeechConfig(
        voice_config=genai_types.VoiceConfig(
            prebuilt_voice_config=genai_types.PrebuiltVoiceConfig(voice_name="Aoede")
        )
    ),
)


# Context-specific opening prompts injected together with user_id so there
# is exactly ONE message trigger → ONE agent response at session start.
_CONTEXT_PROMPTS = {
    "intro": (
        "You are on the welcome screen of Rena. "
        "Introduce yourself warmly as Rena, their personal health companion. "
        "Tell them you're excited to help them reach their health goals. "
        "Ask them to sign in with the 'Continue with Google' button on screen. "
        "Keep it under 20 seconds and do not ask any questions beyond signing in."
    ),
    "goal": (
        "You already know their current weight from [current_weight_kg:X] in this message — use it to calculate target_value directly. "
        "SPEAK OUT LOUD NOW: Say 'Hi {name}!' then ask: 'What are you working toward — losing weight, building fitness, training for an event, or something else?' "
        "When they answer: "
        "- Weight goal: if they give an amount or target (e.g. 'lose 5kg', 'get to 75kg'), compute target_value from their current weight and ask only for the deadline. "
        "  If they say just 'lose weight' with no amount, ask 'What weight are you aiming for?' then ask for the deadline. "
        "  Never ask for their current weight — you already have it. "
        "- Other goals: ask for deadline if not given. "
        "Call set_goal as soon as you have everything. Keep it to 2–3 exchanges."
    ),
    "home": (
        "SPEAK OUT LOUD NOW: Say 'Hi {name}! What would you like to do today?' "
        "Keep it short and friendly — one sentence."
    ),
    "workout_plan": (
        "SPEAK OUT LOUD NOW. First call get_recent_workouts with the user's user_id to check their workout history. "
        "TWO paths: "
        "(A) They HAVE recent workouts: acknowledge it in one warm sentence (e.g. 'Looks like you've been hitting the gym a lot this week!'), "
        "then immediately call generate_workout_plan to build today's plan — no questions needed. "
        "Describe the plan in 1-2 sentences and ask: 'Does that work, or want me to tweak anything?' "
        "(B) They have NO recent workouts: ask 2 quick questions only — "
        "'Do you have access to a gym or working out at home?' then 'Any specific muscle group or goal for today?' "
        "Then call generate_workout_plan and describe the plan. "
        "Keep the whole exchange to 3-4 turns max."
    ),
    "update_workout_plan": (
        "SPEAK OUT LOUD NOW. The user wants to change their workout plan. "
        "Listen to what they want — swap an exercise, adjust intensity, more cardio, shorter session, etc. "
        "Call generate_workout_plan right away to create a fresh updated plan. "
        "Describe the key change in one sentence and end with a short motivating line. "
        "Keep it to 2 turns max."
    ),
    "plan_tomorrow": (
        "SPEAK OUT LOUD NOW: Say 'Let's plan tomorrow, {name}!' "
        "Briefly mention one thing that went well today (use [current_weight_kg] or calories if available). "
        "Ask: 'Any events or schedule constraints tomorrow I should know about?' "
        "Based on their answer, suggest a calorie target and whether to include a workout. "
        "Keep it to 2-3 exchanges total — warm and practical."
    ),
}


async def _build_rich_context_text(user_id: str, name: str) -> str:
    """
    Fetch user state and recent session notes, return a compact text block
    to prepend to every session opening so Rena always knows who she's talking to.
    """
    from rena.tools import get_rich_context
    try:
        ctx = await asyncio.to_thread(get_rich_context, user_id)
        p = ctx["progress"]
        lines = [f"[RENA MEMORY — {name.upper()}]"]

        # Goal
        goal = p.get("goal", "Not set")
        deadline = p.get("deadline", "Not set")
        if goal and goal != "Not set":
            lines.append(f"Goal: {goal} by {deadline}.")

        # Today's snapshot
        lines.append(
            f"Today so far: {p['calories_consumed']}/{p['calories_target']} kcal eaten, "
            f"{p['calories_burned']} kcal burned, "
            f"{p['water_glasses']}/8 glasses water, "
            f"protein {p['protein_consumed_g']}g/{p['protein_target_g']}g."
        )
        if p.get("meals_logged"):
            names = [m["name"] for m in p["meals_logged"]]
            lines.append(f"Meals today: {', '.join(names)}.")
        if p.get("workouts_logged"):
            wk = [f"{w['type']} {w.get('duration_min',0)}min" for w in p["workouts_logged"]]
            lines.append(f"Workouts today: {', '.join(wk)}.")

        # Weight trend
        if ctx["weight_trend"]:
            latest = ctx["weight_trend"][0]
            lines.append(f"Latest weight: {latest['weight_kg']} kg ({latest['date']}).")

        # Workout history
        if ctx["workout_summary"]:
            lines.append(ctx["workout_summary"])

        # Session memory
        notes = ctx.get("session_notes", [])
        if notes:
            lines.append("Recent sessions:")
            for n in notes:
                lines.append(f"  • {n['note']}")

        return "\n".join(lines)
    except Exception:
        return ""


async def _get_context_for_user(user_id: str, name: str) -> str:
    """Return rich context from cache if fresh; otherwise fetch and cache it."""
    cached = _context_cache.get(user_id)
    if cached:
        text, ts = cached
        if time.time() - ts < _CONTEXT_CACHE_TTL:
            return text
    text = await _build_rich_context_text(user_id, name)
    _context_cache[user_id] = (text, time.time())
    return text


async def _refresh_context_cache(user_id: str, name: str):
    """Rebuild the context cache in the background after a session ends."""
    try:
        text = await _build_rich_context_text(user_id, name)
        _context_cache[user_id] = (text, time.time())
    except Exception:
        pass


async def _save_session_note_async(user_id: str, context: str, name: str):
    """Generate a brief summary of the session and save it to Firestore."""
    from rena.tools import get_progress, save_session_note, _get_text_client
    try:
        progress = await asyncio.to_thread(get_progress, user_id)
        today = datetime.now(timezone.utc).date().isoformat()

        context_labels = {
            "home":                "general chat / logging food or water",
            "workout_plan":        "planning a new workout",
            "update_workout_plan": "updating their workout plan",
            "plan_tomorrow":       "planning tomorrow's nutrition and activity",
        }
        label = context_labels.get(context, context)

        meals = progress.get("meals_logged", [])
        workouts = progress.get("workouts_logged", [])
        prompt = (
            "Write one sentence (max 20 words) as a memory note for a health AI. "
            f"The user just finished a voice session about: {label}. "
            f"Data after session: {progress['calories_consumed']}/{progress['calories_target']} kcal, "
            f"{len(meals)} meals logged ({', '.join(m['name'] for m in meals) or 'none'}), "
            f"{len(workouts)} workouts logged. "
            "Be factual, past tense, start with 'User'. "
            "Example: 'User planned a 45-min strength session and asked to avoid leg exercises.'"
        )
        client = _get_text_client()
        resp = await asyncio.to_thread(
            client.models.generate_content, model="gemini-2.0-flash", contents=prompt
        )
        note = f"[{today}] {resp.text.strip()}"
        await asyncio.to_thread(save_session_note, user_id, context, note)
    except Exception:
        pass


async def handle_voice(websocket: WebSocket, user_id: str,
                       context: str | None = None, name: str | None = None):
    from .agent import root_agent

    await websocket.accept()

    # Reuse existing session if available (enables transparent resumption on reconnect).
    # New context (e.g. switching screens) always gets a fresh session.
    existing_session_id = _active_sessions.get(user_id) if not context else None
    if existing_session_id:
        session = await session_service.get_session(
            app_name=APP_NAME, user_id=user_id, session_id=existing_session_id
        )
        if session is None:
            session = await session_service.create_session(app_name=APP_NAME, user_id=user_id)
    else:
        session = await session_service.create_session(app_name=APP_NAME, user_id=user_id)

    _active_sessions[user_id] = session.id

    runner = Runner(
        app_name=APP_NAME,
        agent=root_agent,
        session_service=session_service,
    )

    live_queue = LiveRequestQueue()
    ws_closed = False

    # Inject user_id + optional opening prompt as ONE combined message so the
    # agent has a single trigger → single response with no double-greeting.
    async def inject_opening():
        await asyncio.sleep(0.2)
        from rena.tools import _user_ref, generate_workout_plan
        try:
            profile = _user_ref(user_id).get().to_dict() or {}
            weight_kg = profile.get("weight_kg")
            text = f"[user_id:{user_id}]" + (f"[current_weight_kg:{weight_kg}]" if weight_kg else "")
        except Exception:
            text = f"[user_id:{user_id}]"

        # Prepend rich context for all non-onboarding sessions so Rena always
        # knows today's state, recent activity, and past conversation notes.
        if context not in ("intro", "goal", None):
            rich = await _get_context_for_user(user_id, name or "there")
            if rich:
                text = f"{text}\n{rich}"

        if context == "workout_plan":
            # Pre-generate the plan here so there is no blocking tool call during the
            # live voice session. Rena receives the finished plan in the opening message
            # and can describe it immediately — no generate_workout_plan call needed.
            try:
                plan = await asyncio.to_thread(generate_workout_plan, user_id)
                exercise_lines = "; ".join(
                    f"{ex['name']} ({ex['duration_min']} min, ~{ex.get('calories_burned', 0)} kcal)"
                    if ex.get("duration_min")
                    else f"{ex['name']} ({ex.get('sets', '')}×{ex.get('reps', '')}, ~{ex.get('calories_burned', 0)} kcal)"
                    for ex in plan.get("exercises", [])
                )
                plan_summary = (
                    f"{plan['name']}, {plan.get('total_duration_min', 0)} min total. "
                    f"Exercises: {exercise_lines}."
                )
                prompt = (
                    f"SPEAK OUT LOUD NOW. A workout plan has already been generated and saved for {name or 'them'}. "
                    f"Here it is: {plan_summary} "
                    "Describe it warmly in 1-2 sentences and ask: 'Does that work for you, or want me to tweak anything?' "
                    "Do NOT call generate_workout_plan — the plan is already saved."
                )
            except Exception as e:
                sentry_sdk.capture_exception(e)
                prompt = _CONTEXT_PROMPTS["workout_plan"].replace("{name}", name or "there")
            text = f"{text}\n{prompt}"
        elif context and context in _CONTEXT_PROMPTS:
            prompt = _CONTEXT_PROMPTS[context].replace("{name}", name or "there")
            text = f"{text}\n{prompt}"

        live_queue.send_content(
            genai_types.Content(
                role="user",
                parts=[genai_types.Part(text=text)],
            )
        )

    asyncio.create_task(inject_opening())

    async def send_to_client():
        nonlocal ws_closed
        try:
            async for event in runner.run_live(
                user_id=user_id,
                session_id=session.id,
                live_request_queue=live_queue,
                run_config=RUN_CONFIG,
            ):
                if ws_closed:
                    break
                if event.content and event.content.parts:
                    for part in event.content.parts:
                        # Skip thought parts (thinking_budget=0 prevents most, but guard anyway)
                        if getattr(part, "thought", False):
                            continue
                        if part.inline_data:
                            await websocket.send_bytes(part.inline_data.data)
                        elif part.text:
                            await websocket.send_text(
                                json.dumps({"type": "text", "text": part.text})
                            )
                if event.output_transcription and event.output_transcription.text:
                    cc = event.output_transcription.text.strip()
                    if cc and not ws_closed:
                        await websocket.send_text(
                            json.dumps({"type": "transcript", "text": cc})
                        )
                if event.turn_complete and not ws_closed:
                    await websocket.send_text(json.dumps({"type": "turn_complete"}))
        except genai_errors.APIError as e:
            # 1000 = Gemini closed cleanly because we closed live_queue after iOS disconnect
            if e.status_code != 1000:
                traceback.print_exc()
                sentry_sdk.capture_exception(e)
        except Exception as e:
            if not ws_closed:
                traceback.print_exc()
                sentry_sdk.capture_exception(e)
        finally:
            live_queue.close()

    async def recv_from_client():
        nonlocal ws_closed
        try:
            while True:
                message = await websocket.receive()

                # Starlette sends a disconnect dict instead of raising WebSocketDisconnect
                if message.get("type") == "websocket.disconnect":
                    break

                if "bytes" in message:
                    # Raw PCM audio from iOS — use send_realtime for audio chunks
                    live_queue.send_realtime(
                        genai_types.Blob(
                            data=message["bytes"],
                            mime_type="audio/pcm;rate=16000",
                        )
                    )

                elif "text" in message:
                    try:
                        data = json.loads(message["text"])
                    except json.JSONDecodeError:
                        continue
                    if data.get("type") == "text_input":
                        # Text input fallback for testing without mic
                        live_queue.send_content(
                            genai_types.Content(
                                role="user",
                                parts=[genai_types.Part(text=data["text"])],
                            )
                        )
        except WebSocketDisconnect:
            pass
        except Exception as e:
            traceback.print_exc()
            sentry_sdk.capture_exception(e)
        finally:
            ws_closed = True
            live_queue.close()
            # Save a session note and refresh the context cache after every real
            # interaction (not onboarding) — both run in the background.
            if context not in ("intro", "goal", None):
                asyncio.create_task(_save_session_note_async(user_id, context, name or "there"))
                asyncio.create_task(_refresh_context_cache(user_id, name or "there"))

    send_task = asyncio.create_task(send_to_client())
    recv_task = asyncio.create_task(recv_from_client())

    await asyncio.gather(send_task, recv_task, return_exceptions=True)

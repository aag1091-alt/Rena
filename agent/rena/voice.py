"""
WebSocket endpoint for real-time voice conversation with Rena.

Flow:
  iOS app  --[audio bytes]--> WebSocket --> Gemini Live API --> ADK agent tools
  iOS app <--[audio bytes]--  WebSocket <-- Gemini Live API <-- ADK agent response
"""

import asyncio
import contextlib
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

# ── Fix: ADK's google_llm.py copies tools from llm_request.config to live_connect_config
# but silently drops thinking_config, so thinking_budget=0 set on the Agent is never
# sent to the Gemini Live API. The model defaults to full thinking, producing silent
# audio turns that hang the UI.
# Patch GoogleLLM.connect() — the last step before the actual API call — to copy
# thinking_config from llm_request.config into live_connect_config right before connecting.
from google.adk.models import google_llm as _google_llm  # noqa: E402

_orig_google_llm_connect = _google_llm.GoogleLLM.connect

@contextlib.asynccontextmanager
async def _patched_google_llm_connect(self, llm_request):
    if (
        llm_request.live_connect_config is not None
        and llm_request.config is not None
        and getattr(llm_request.config, "thinking_config", None) is not None
    ):
        llm_request.live_connect_config.thinking_config = llm_request.config.thinking_config
    async with _orig_google_llm_connect(self, llm_request) as conn:
        yield conn

_google_llm.GoogleLLM.connect = _patched_google_llm_connect

session_service = InMemorySessionService()
APP_NAME = "rena"

# Sessions kept alive after disconnect so Gemini can resume them on reconnect.
# Keyed by user_id → session_id.
_active_sessions: dict[str, str] = {}

# Rich context cache — avoids blocking session start with Firestore reads.
# Keyed by user_id → (context_text, timestamp).
_context_cache: dict[str, tuple[str, float]] = {}
_CONTEXT_CACHE_TTL = 600  # 10 minutes

# Tracks when we last injected the morning nudge into a home-context session.
# Keyed by user_id → epoch seconds. Prevents repeating within 1 hour.
_nudge_said_at: dict[str, float] = {}

# Prompt cache — fetched from Firestore, refreshed every 5 minutes.
# Keyed by context_key → (prompt_text, timestamp).
_prompt_cache: dict[str, tuple[str, float]] = {}
_PROMPT_CACHE_TTL = 60  # 1 minute (lower during development)

# Per-session tool-status queues.
# Keyed by user_id → (asyncio.Queue, asyncio.AbstractEventLoop)
# Tools call _emit_tool_status to push a banner; status_forwarder drains it.
_status_queues: dict[str, tuple[asyncio.Queue, asyncio.AbstractEventLoop]] = {}


def _get_prompt(context_key: str) -> str:
    """
    Return the prompt for a given context key.
    Checks Firestore first (with 5-minute cache), falls back to _CONTEXT_PROMPTS.
    """
    from rena.tools import db
    cached = _prompt_cache.get(context_key)
    if cached:
        text, ts = cached
        if time.time() - ts < _PROMPT_CACHE_TTL:
            return text
    try:
        doc = db.collection("prompts").document(context_key).get()
        if doc.exists:
            text = (doc.to_dict() or {}).get("text", "")
            if text:
                _prompt_cache[context_key] = (text, time.time())
                return text
    except Exception:
        pass
    return _CONTEXT_PROMPTS.get(context_key, "")


RUN_CONFIG = RunConfig(
    response_modalities=[genai_types.Modality.AUDIO],
    output_audio_transcription=genai_types.AudioTranscriptionConfig(),
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
        "STRICT RULES — follow these exactly, never deviate: "
        "1. If they say 'lose weight' or 'losing weight' with NO specific target: SPEAK OUT LOUD immediately — say 'Great! What weight are you aiming for?' Do NOT call any tool yet. "
        "2. Once you have the target weight (e.g. '75kg', 'lose 10kg'): compute target_value and SPEAK OUT LOUD — ask 'And when would you like to reach that by?' Do NOT call any tool yet. "
        "3. Once you have BOTH target weight AND deadline: THEN call set_goal. "
        "4. For non-weight goals (fitness/habit/event): ask only for deadline if missing, then call set_goal. "
        "Never ask for their current weight — you already have it. "
        "Do NOT call get_progress or any other tool during this flow. Keep it to 2–3 exchanges."
    ),
    "home": (
        "SPEAK OUT LOUD NOW. Speak at a calm, natural pace — never rush. "
        "Start with a warm, personal greeting for {name}. "
        "Then give a brief 1–2 sentence snapshot of their day so far using [RENA MEMORY]: "
        "mention calories eaten vs target, whether they've worked out, and water intake. "
        "Be specific — use the actual numbers (e.g. 'You've had 650 of your 2000 calories'). "
        "End with: 'What would you like to do?' "
        "Keep the whole opening under 20 seconds."
    ),
    "workout_plan": (
        "SPEAK OUT LOUD NOW. Speak at a calm, natural pace throughout — never rush. "
        "Open with one sentence about {name}'s recent workout pattern from [RENA MEMORY] "
        "(e.g. 'You've been doing a lot of cardio lately' or 'You haven't trained since Tuesday'). "
        "Then ask 2 quick questions to personalise {day_label}'s workout: "
        "First: 'Do you have access to a gym, or are you working out at home?' "
        "Then: 'Any specific muscle group or goal?' "
        "Once they've answered both, call generate_workout_plan with for_date=[workout_date]. In the notes parameter combine: "
        "(1) their gym/home preference, (2) their muscle group focus, and "
        "(3) a one-sentence summary of their recent workout pattern from your memory. "
        "Describe the plan in 1-2 sentences and ask: 'Does that work for you, or want me to tweak anything?' "
        "Keep the whole exchange to 3-4 turns max."
    ),
    "update_workout_plan": (
        "SPEAK OUT LOUD NOW. Speak at a calm, natural pace throughout — never rush. "
        "Open with one sentence referencing {day_label}'s planned workout from [RENA MEMORY] "
        "(e.g. 'You've got a 40-minute strength session lined up'). "
        "Then ask what they'd like to change: 'What would you like to tweak?' — "
        "they might want to swap an exercise, adjust intensity, add cardio, shorten the session, etc. "
        "Once you understand what they want, call generate_workout_plan with for_date=[workout_date] "
        "and their request in the notes parameter along with a one-sentence summary of their recent workout history. "
        "Describe the key change in one sentence and end with a short motivating line. "
        "Keep it to 2-3 turns max."
    ),
    "meal_plan": (
        "SPEAK OUT LOUD NOW. Speak at a calm, natural pace throughout — never rush. "
        "Open with one sentence about {name}'s recent meal patterns from [RENA MEMORY] — "
        "reference what they've been eating lately (from 'Recent meals') or their calorie intake. "
        "Do NOT mention workouts. "
        "Then ask 2 quick questions to plan {day_label}'s meals: "
        "First: 'What food or ingredients do you have at home?' "
        "Then: 'Any dietary preferences or things you want to avoid?' "
        "Once they've answered both, call generate_meal_plan with for_date=[meal_date]. "
        "In the notes parameter combine their available ingredients and preferences. "
        "Summarise the meal plan in 2-3 sentences — highlight the best meal and total calories. "
        "Keep the whole exchange to 3 turns max."
    ),
    "update_meal_plan": (
        "SPEAK OUT LOUD NOW. Speak at a calm, natural pace throughout — never rush. "
        "Open with one sentence referencing {day_label}'s planned meals from [RENA MEMORY] "
        "(e.g. 'You've got chicken stir fry and oats lined up'). "
        "Then ask what they'd like to change: 'What would you like to swap or adjust?' — "
        "they might want a different meal, lighter calories, different cuisine, fewer dishes, etc. "
        "Once you understand what they want, call generate_meal_plan with for_date=[meal_date] "
        "and their requested changes in the notes parameter. "
        "Summarise the key change in one sentence and highlight the updated total calories. "
        "Keep it to 2-3 turns max."
    ),
    "plan": (
        "SPEAK OUT LOUD NOW. Speak at a calm, natural pace — never rush. "
        "Open with one sentence about {name}'s recent progress from [RENA MEMORY] "
        "(e.g. mention a recent workout streak, calorie trend, or last session note). "
        "Then say 'Let\\'s plan {day_label}!' and follow this exact flow, asking ONE question at a time: "
        "1. Ask: 'Any events or commitments {day_label} I should know about?' — wait for answer. "
        "2. Ask: 'What do you want to focus on — eating well, a workout, both, or just rest?' — wait for answer. "
        "3. If they mentioned a workout (or 'both'): ask 'Will you be at the gym or working out at home?' — wait. "
        "   Then ask: 'Any specific muscle group or goal?' — wait for answer. "
        "4. If they mentioned eating well or cooking at home (or 'both'): ask 'What food or ingredients do you have at home?' — wait. "
        "   Skip this if they said eating out, takeaway, or restaurant. "
        "Once you have all the answers, decide which tools to call: "
        "- Call generate_workout_plan(user_id, notes=<gym/home + muscle focus + history>, for_date=[plan_date]) "
        "  ONLY if user plans to work out (skip for rest days or 'no workout'). "
        "- Call generate_meal_plan(user_id, notes=<ingredients + preferences>, for_date=[plan_date]) "
        "  ONLY if user plans to cook/eat at home (skip if eating out). "
        "- If neither plan is needed, acknowledge warmly — e.g. 'Sounds like a relaxing day, enjoy the break!' "
        "Always end by calling save_tomorrow_plan_note(user_id, summary=<1-2 sentences of what was discussed>, for_date=[plan_date]). "
        "Summarise any generated plans warmly in 3-4 sentences — workout first, then meals."
    ),
    "scan": (
        "SPEAK OUT LOUD NOW: Say one short encouraging line to {name} — "
        "e.g. 'Go ahead, take a photo of your food and I'll log it for you!' "
        "Keep it to one sentence. The user is about to use the camera."
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

        # Meal history
        if ctx.get("meal_summary"):
            lines.append(ctx["meal_summary"])

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

        if context and ":" in context:
            base_ctx = context.split(":", 1)[0]
        else:
            base_ctx = context
        context_labels = {
            "home":                "general chat / logging food or water",
            "workout_plan":        "planning a workout",
            "update_workout_plan": "updating their workout plan",
            "meal_plan":           "planning meals",
            "update_meal_plan":    "updating their meal plan",
            "plan":                "planning a day's nutrition and activity",
            "scan":                "logging food by photo",
        }
        label = context_labels.get(base_ctx, base_ctx)

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

    # Per-session tool-status queue — tools push messages here, status_forwarder sends them.
    loop = asyncio.get_running_loop()
    status_q: asyncio.Queue = asyncio.Queue()
    _status_queues[user_id] = (status_q, loop)

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
        from rena.tools import _user_ref, get_morning_nudge
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

        # Parse dated context formats: "plan:<date>" and "meal_plan:<date>".
        # base_context is used for prompt lookup; the date / day_label are injected into the prompt.
        base_context = context
        plan_date = None
        day_label = None
        if context and context.startswith("plan:"):
            _, plan_date = context.split(":", 1)
            base_context = "plan"
            today_str = datetime.now(timezone.utc).date().isoformat()
            day_label = "today" if plan_date == today_str else "tomorrow"
            text = f"{text}\n[plan_date:{plan_date}]"
        elif context and context.startswith("meal_plan:"):
            _, plan_date = context.split(":", 1)
            base_context = "meal_plan"
            today_str = datetime.now(timezone.utc).date().isoformat()
            day_label = "today" if plan_date == today_str else "tomorrow"
            text = f"{text}\n[meal_date:{plan_date}]"
        elif context and context.startswith("update_meal_plan:"):
            _, plan_date = context.split(":", 1)
            base_context = "update_meal_plan"
            today_str = datetime.now(timezone.utc).date().isoformat()
            day_label = "today" if plan_date == today_str else "tomorrow"
            text = f"{text}\n[meal_date:{plan_date}]"
        elif context and context.startswith("workout_plan:"):
            _, plan_date = context.split(":", 1)
            base_context = "workout_plan"
            today_str = datetime.now(timezone.utc).date().isoformat()
            day_label = "today" if plan_date == today_str else "tomorrow"
            text = f"{text}\n[workout_date:{plan_date}]"
        elif context and context.startswith("update_workout_plan:"):
            _, plan_date = context.split(":", 1)
            base_context = "update_workout_plan"
            today_str = datetime.now(timezone.utc).date().isoformat()
            day_label = "today" if plan_date == today_str else "tomorrow"
            text = f"{text}\n[workout_date:{plan_date}]"

        # For home context, inject today's plan_tomorrow nudge (once per hour max).
        if context == "home":
            last_said = _nudge_said_at.get(user_id, 0)
            if time.time() - last_said > 3600:
                try:
                    nudge_data = await asyncio.to_thread(get_morning_nudge, user_id)
                    if nudge_data.get("has_nudge"):
                        nudge_text = nudge_data["nudge"]
                        text = f"{text}\n[TODAY_NUDGE: {nudge_text}]"
                        _nudge_said_at[user_id] = time.time()
                except Exception:
                    pass

        if context:
            prompt = _get_prompt(base_context).replace("{name}", name or "there")
            if day_label:
                prompt = prompt.replace("{day_label}", day_label)
            if prompt:
                # For home context with a nudge, add instruction to mention it briefly
                if context == "home" and user_id in _nudge_said_at and time.time() - _nudge_said_at[user_id] < 5:
                    prompt = (
                        prompt.rstrip() + " If there is a [TODAY_NUDGE] in this message, "
                        "weave it naturally into your greeting in one short sentence."
                    )
                text = f"{text}\n{prompt}"

        live_queue.send_content(
            genai_types.Content(
                role="user",
                parts=[genai_types.Part(text=text)],
            )
        )

    asyncio.create_task(inject_opening())

    # Exception type names that mean "iOS already closed the socket" — safe to ignore.
    _SILENT_CLOSE = {"ConnectionClosedOK", "ClientDisconnected", "WebSocketDisconnect"}

    async def _safe_send_bytes(data: bytes) -> bool:
        """Send bytes; return False and set ws_closed if the socket is gone."""
        nonlocal ws_closed
        try:
            await websocket.send_bytes(data)
            return True
        except Exception:
            ws_closed = True
            return False

    async def _safe_send_text(payload: str) -> bool:
        """Send text; return False and set ws_closed if the socket is gone."""
        nonlocal ws_closed
        try:
            await websocket.send_text(payload)
            return True
        except Exception:
            ws_closed = True
            return False

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
                            if not await _safe_send_bytes(part.inline_data.data):
                                return
                        elif part.text:
                            if not await _safe_send_text(
                                json.dumps({"type": "text", "text": part.text})
                            ):
                                return
                if event.output_transcription and event.output_transcription.text:
                    cc = event.output_transcription.text.strip()
                    if cc and not ws_closed:
                        if not await _safe_send_text(
                            json.dumps({"type": "transcript", "text": cc})
                        ):
                            return
                if event.turn_complete and not ws_closed:
                    await _safe_send_text(json.dumps({"type": "turn_complete"}))
        except genai_errors.APIError as e:
            # 1000 = Gemini closed cleanly because we closed live_queue after iOS disconnect
            if e.status_code != 1000:
                traceback.print_exc()
                sentry_sdk.capture_exception(e)
        except Exception as e:
            ename = type(e).__name__
            if ename in _SILENT_CLOSE or ws_closed:
                pass  # Normal iOS disconnect — not an error
            elif ename == "ConnectionClosedError" and "1008" in str(e):
                # Stale Gemini session (server restart / session expired).
                # Clear cache so the next connect starts a fresh session.
                _active_sessions.pop(user_id, None)
            else:
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

    async def status_forwarder():
        """Drain per-session tool-status queue and forward to WebSocket."""
        nonlocal ws_closed
        while not ws_closed:
            try:
                msg = await asyncio.wait_for(status_q.get(), timeout=0.3)
                if not ws_closed:
                    await _safe_send_text(
                        json.dumps({"type": "tool_status", "message": msg})
                    )
            except asyncio.TimeoutError:
                pass

    send_task   = asyncio.create_task(send_to_client())
    recv_task   = asyncio.create_task(recv_from_client())
    status_task = asyncio.create_task(status_forwarder())

    try:
        await asyncio.gather(send_task, recv_task, return_exceptions=True)
    finally:
        status_task.cancel()
        _status_queues.pop(user_id, None)

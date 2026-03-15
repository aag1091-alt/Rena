"""
WebSocket endpoint for real-time voice conversation with Rena.

Flow:
  iOS app  --[audio bytes]--> WebSocket --> Gemini Live API --> ADK agent tools
  iOS app <--[audio bytes]--  WebSocket <-- Gemini Live API <-- ADK agent response
"""

import asyncio
import json
import traceback
import warnings

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
}


async def handle_voice(websocket: WebSocket, user_id: str,
                       context: str | None = None, name: str | None = None):
    from .agent import root_agent

    await websocket.accept()
    print(f"[voice] connected: {user_id} context={context}")

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
            print(f"[voice] resuming session {session.id} for {user_id}")
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
        # Inject user_id + current weight so the agent can calculate absolute
        # target weights without asking the user for their current weight.
        from rena.tools import _user_ref
        try:
            profile = _user_ref(user_id).get().to_dict() or {}
            weight_kg = profile.get("weight_kg")
            text = f"[user_id:{user_id}]" + (f"[current_weight_kg:{weight_kg}]" if weight_kg else "")
        except Exception:
            text = f"[user_id:{user_id}]"
        if context and context in _CONTEXT_PROMPTS:
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
                            print(f"[voice] sending audio: {len(part.inline_data.data)} bytes → {user_id}")
                            await websocket.send_bytes(part.inline_data.data)
                        elif part.text:
                            print(f"[voice] sending text: {part.text[:80]!r} → {user_id}")
                            await websocket.send_text(
                                json.dumps({"type": "text", "text": part.text})
                            )
                if event.output_transcription and event.output_transcription.text:
                    cc = event.output_transcription.text.strip()
                    if cc and not ws_closed:
                        print(f"[voice] cc: {cc[:60]!r} → {user_id}")
                        await websocket.send_text(
                            json.dumps({"type": "transcript", "text": cc})
                        )
                if event.turn_complete and not ws_closed:
                    print(f"[voice] turn_complete → {user_id}")
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
                    print(f"[voice] disconnected: {user_id}")
                    break

                if "bytes" in message:
                    # Raw PCM audio from iOS — use send_realtime for audio chunks
                    print(f"[voice] recv audio: {len(message['bytes'])} bytes ← {user_id}")
                    live_queue.send_realtime(
                        genai_types.Blob(
                            data=message["bytes"],
                            mime_type="audio/pcm;rate=16000",
                        )
                    )

                elif "text" in message:
                    try:
                        data = json.loads(message["text"])
                    except json.JSONDecodeError as e:
                        print(f"[voice] invalid JSON from client: {e}")
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
            print(f"[voice] disconnected: {user_id}")
        except Exception as e:
            traceback.print_exc()
            sentry_sdk.capture_exception(e)
        finally:
            ws_closed = True
            live_queue.close()

    send_task = asyncio.create_task(send_to_client())
    recv_task = asyncio.create_task(recv_from_client())

    await asyncio.gather(send_task, recv_task, return_exceptions=True)
    print(f"[voice] session ended: {user_id}")

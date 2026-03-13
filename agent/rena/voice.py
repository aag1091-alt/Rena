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

RUN_CONFIG = RunConfig(
    response_modalities=[genai_types.Modality.AUDIO],
    speech_config=genai_types.SpeechConfig(
        voice_config=genai_types.VoiceConfig(
            prebuilt_voice_config=genai_types.PrebuiltVoiceConfig(voice_name="Aoede")
        )
    ),
)


async def handle_voice(websocket: WebSocket, user_id: str):
    from .agent import root_agent

    await websocket.accept()
    print(f"[voice] connected: {user_id}")

    session = await session_service.create_session(
        app_name=APP_NAME,
        user_id=user_id,
    )

    runner = Runner(
        app_name=APP_NAME,
        agent=root_agent,
        session_service=session_service,
    )

    live_queue = LiveRequestQueue()
    ws_closed = False

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
                        if part.inline_data:
                            await websocket.send_bytes(part.inline_data.data)
                        elif part.text:
                            await websocket.send_text(
                                json.dumps({"type": "text", "text": part.text})
                            )
                if event.turn_complete and not ws_closed:
                    await websocket.send_text(json.dumps({"type": "turn_complete"}))
        except genai_errors.APIError as e:
            # 1000 = Gemini closed cleanly because we closed live_queue after iOS disconnect
            if e.status_code != 1000:
                traceback.print_exc()
        except Exception:
            if not ws_closed:
                traceback.print_exc()
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
                    live_queue.send_realtime(
                        genai_types.Blob(
                            data=message["bytes"],
                            mime_type="audio/pcm;rate=16000",
                        )
                    )

                elif "text" in message:
                    data = json.loads(message["text"])
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
        except Exception:
            traceback.print_exc()
        finally:
            ws_closed = True
            live_queue.close()

    send_task = asyncio.create_task(send_to_client())
    recv_task = asyncio.create_task(recv_from_client())

    await asyncio.gather(send_task, recv_task, return_exceptions=True)
    print(f"[voice] session ended: {user_id}")

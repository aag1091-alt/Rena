"""
WebSocket endpoint for real-time voice conversation with Rena.

Flow:
  iOS app  --[audio bytes]--> WebSocket --> Gemini Live API --> ADK agent tools
  iOS app <--[audio bytes]--  WebSocket <-- Gemini Live API <-- ADK agent response
"""

import asyncio
import json
import os
import traceback

from dotenv import load_dotenv
from fastapi import WebSocket, WebSocketDisconnect
from google.adk.agents.live_request_queue import LiveRequestQueue
from google.adk.runners import Runner
from google.adk.sessions import InMemorySessionService
from google.genai import types as genai_types

load_dotenv()

# In-memory sessions (fine for demo; swap for Firestore-backed in production)
session_service = InMemorySessionService()

APP_NAME = "rena"

# Audio config — 16kHz PCM16 matches iOS AVAudioEngine default
AUDIO_INPUT_CONFIG = genai_types.LiveConnectConfig(
    response_modalities=["AUDIO"],
    speech_config=genai_types.SpeechConfig(
        voice_config=genai_types.VoiceConfig(
            prebuilt_voice_config=genai_types.PrebuiltVoiceConfig(voice_name="Aoede")
        )
    ),
)


async def handle_voice(websocket: WebSocket, user_id: str):
    """
    Manages a full voice session for one user connection.
    Spawns two concurrent tasks:
      - send_task: reads audio/text from Gemini and forwards to iOS
      - recv_task: reads audio from iOS and forwards to Gemini
    """
    from .agent import root_agent

    await websocket.accept()
    print(f"[voice] connected: {user_id}")

    # Create or reuse a session for this user
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

    async def send_to_client():
        """Read events from Gemini and send audio/text back to iOS."""
        try:
            async for event in runner.run_live(
                user_id=user_id,
                session_id=session.id,
                live_connect_config=AUDIO_INPUT_CONFIG,
                live_request_queue=live_queue,
            ):
                if event.content and event.content.parts:
                    for part in event.content.parts:
                        if part.inline_data:
                            # Audio chunk — send as binary
                            await websocket.send_bytes(part.inline_data.data)
                        elif part.text:
                            # Text (tool output / transcript) — send as JSON
                            await websocket.send_text(
                                json.dumps({"type": "text", "text": part.text})
                            )
                if event.turn_complete:
                    await websocket.send_text(json.dumps({"type": "turn_complete"}))
        except Exception:
            traceback.print_exc()
        finally:
            live_queue.close()

    async def recv_from_client():
        """Read audio from iOS and push into Gemini."""
        try:
            while True:
                message = await websocket.receive()

                if "bytes" in message:
                    # Raw PCM audio from iOS microphone
                    live_queue.send_nowait(
                        genai_types.LiveClientRealtimeInput(
                            media_chunks=[
                                genai_types.Blob(
                                    data=message["bytes"],
                                    mime_type="audio/pcm;rate=16000",
                                )
                            ]
                        )
                    )

                elif "text" in message:
                    # Control messages from iOS (e.g. user_id context)
                    data = json.loads(message["text"])
                    if data.get("type") == "text_input":
                        # Allow text input for testing without a mic
                        live_queue.send_nowait(
                            genai_types.LiveClientContent(
                                turns=[genai_types.Content(
                                    role="user",
                                    parts=[genai_types.Part(text=data["text"])],
                                )],
                                turn_complete=True,
                            )
                        )
        except WebSocketDisconnect:
            print(f"[voice] disconnected: {user_id}")
        except Exception:
            traceback.print_exc()
        finally:
            live_queue.close()

    # Run both tasks concurrently
    send_task = asyncio.create_task(send_to_client())
    recv_task = asyncio.create_task(recv_from_client())

    await asyncio.gather(send_task, recv_task, return_exceptions=True)
    print(f"[voice] session ended: {user_id}")

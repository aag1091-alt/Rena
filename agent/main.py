import os
from dotenv import load_dotenv
from fastapi import FastAPI, WebSocket
from rena.voice import handle_voice

load_dotenv()

app = FastAPI(title="Rena Agent API")


@app.get("/health")
async def health():
    return {"status": "ok", "agent": "rena"}


@app.websocket("/ws/{user_id}")
async def voice_endpoint(websocket: WebSocket, user_id: str):
    """Real-time voice conversation with Rena via Gemini Live API."""
    await handle_voice(websocket, user_id)

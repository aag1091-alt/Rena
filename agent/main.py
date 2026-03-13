import os
from dotenv import load_dotenv
from fastapi import FastAPI, WebSocket
from pydantic import BaseModel
from rena.voice import handle_voice
from rena.tools import scan_image, log_meal

load_dotenv()

app = FastAPI(title="Rena Agent API")


class ScanRequest(BaseModel):
    user_id: str
    image_base64: str
    mime_type: str = "image/jpeg"
    auto_log: bool = False  # if True, log the meal automatically after scanning


@app.get("/health")
async def health():
    return {"status": "ok", "agent": "rena"}


@app.post("/scan")
async def scan_food(req: ScanRequest):
    """Identify food in a photo and optionally log it."""
    result = scan_image(req.user_id, req.image_base64, req.mime_type)
    if req.auto_log and result.get("identified"):
        log_meal(
            req.user_id,
            result["description"],
            result["total_calories"],
            protein_g=result["total_protein_g"],
            carbs_g=result["total_carbs_g"],
            fat_g=result["total_fat_g"],
        )
        result["logged"] = True
    return result


@app.websocket("/ws/{user_id}")
async def voice_endpoint(websocket: WebSocket, user_id: str):
    """Real-time voice conversation with Rena via Gemini Live API."""
    await handle_voice(websocket, user_id)

import os
from dotenv import load_dotenv
from fastapi import FastAPI, WebSocket, HTTPException
from pydantic import BaseModel
from rena.voice import handle_voice
from rena.tools import scan_image, log_meal, get_progress, update_visual_journey, create_profile, reset_user

load_dotenv()

app = FastAPI(title="Rena Agent API")


class ScanRequest(BaseModel):
    user_id: str
    image_base64: str
    mime_type: str = "image/jpeg"
    auto_log: bool = False  # if True, log the meal automatically after scanning


class OnboardRequest(BaseModel):
    user_id: str
    name: str
    sex: str            # "male" | "female"
    age: int
    height_cm: float
    weight_kg: float
    activity_level: str  # sedentary | lightly_active | moderately_active | very_active


@app.post("/onboard")
async def onboard(req: OnboardRequest):
    """Create user profile and calculate personalised calorie target."""
    if not req.user_id or req.user_id.strip() == "":
        raise HTTPException(status_code=400, detail="user_id is required")
    return create_profile(
        user_id=req.user_id,
        name=req.name,
        sex=req.sex,
        age=req.age,
        height_cm=req.height_cm,
        weight_kg=req.weight_kg,
        activity_level=req.activity_level,
    )


@app.delete("/dev/reset/{user_id}")
async def dev_reset(user_id: str):
    """DEV ONLY — wipe all Firestore data for a user to re-test onboarding."""
    if not user_id or user_id.strip() == "":
        raise HTTPException(status_code=400, detail="user_id is required")
    return reset_user(user_id)


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


@app.get("/progress/{user_id}")
async def progress(user_id: str):
    """Get today's progress for the iOS home screen."""
    if not user_id or user_id.strip() == "":
        raise HTTPException(status_code=400, detail="user_id is required")
    return get_progress(user_id)


class VisualJourneyRequest(BaseModel):
    user_id: str


@app.post("/visual_journey")
async def visual_journey(req: VisualJourneyRequest):
    """Generate/update the visual journey image."""
    if not req.user_id or req.user_id.strip() == "":
        raise HTTPException(status_code=400, detail="user_id is required")
    return update_visual_journey(req.user_id)


@app.websocket("/ws/{user_id}")
async def voice_endpoint(websocket: WebSocket, user_id: str):
    """Real-time voice conversation with Rena via Gemini Live API."""
    await handle_voice(websocket, user_id)

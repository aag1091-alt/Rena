import os
from dotenv import load_dotenv
from fastapi import FastAPI, WebSocket, HTTPException
from pydantic import BaseModel
from rena.voice import handle_voice
from rena.tools import scan_image, log_meal, log_weight, get_progress, get_goal, update_visual_journey, create_profile, reset_user, correct_scan

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


@app.post("/dev/seed/{user_id}")
async def dev_seed(user_id: str):
    """DEV ONLY — seed 7 days of test data for UI testing."""
    from rena.tools import seed_test_data
    return seed_test_data(user_id)


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
async def progress(user_id: str, date: str = None):
    """Get progress for a given date (YYYY-MM-DD) or today if omitted."""
    if not user_id or user_id.strip() == "":
        raise HTTPException(status_code=400, detail="user_id is required")
    return get_progress(user_id, for_date=date)


class VisualJourneyRequest(BaseModel):
    user_id: str


@app.post("/visual_journey")
async def visual_journey(req: VisualJourneyRequest):
    """Generate/update the visual journey image."""
    if not req.user_id or req.user_id.strip() == "":
        raise HTTPException(status_code=400, detail="user_id is required")
    return update_visual_journey(req.user_id)


@app.get("/goal/{user_id}")
async def goal_endpoint(user_id: str):
    """Get the user's current goal with generated image."""
    if not user_id or user_id.strip() == "":
        raise HTTPException(status_code=400, detail="user_id is required")
    return get_goal(user_id)


class LogMealRequest(BaseModel):
    user_id: str
    name: str
    calories: int
    protein_g: int = 0
    carbs_g: int = 0
    fat_g: int = 0


@app.post("/log/meal")
async def log_meal_endpoint(req: LogMealRequest):
    """Log a meal directly from the app (e.g. after adjusting scan results)."""
    if not req.user_id:
        raise HTTPException(status_code=400, detail="user_id is required")
    return log_meal(req.user_id, req.name, req.calories, req.protein_g, req.carbs_g, req.fat_g)


class LogWeightRequest(BaseModel):
    user_id: str
    weight_kg: float


@app.post("/log/weight")
async def log_weight_endpoint(req: LogWeightRequest):
    """Log today's weight directly from the app slider."""
    if not req.user_id:
        raise HTTPException(status_code=400, detail="user_id is required")
    return log_weight(req.user_id, req.weight_kg)


class ScanCorrectRequest(BaseModel):
    user_id: str
    description: str
    correction: str


@app.post("/scan/correct")
async def scan_correct(req: ScanCorrectRequest):
    """Recalculate nutrition for a food given a user correction (direct call)."""
    return correct_scan(req.user_id, req.description, req.correction)


@app.get("/pending_correction/{user_id}")
async def pending_correction(user_id: str):
    """Poll for a scan correction result written by the voice agent. Clears after reading."""
    from rena.tools import _user_ref
    doc_ref = _user_ref(user_id).collection("pending").document("scan_correction")
    doc = doc_ref.get()
    if not doc.exists:
        return {"ready": False}
    data = doc.to_dict()
    doc_ref.delete()
    return {"ready": True, "result": data.get("result", {})}


@app.websocket("/ws/{user_id}")
async def voice_endpoint(websocket: WebSocket, user_id: str,
                         context: str | None = None, name: str | None = None):
    """Real-time voice conversation with Rena via Gemini Live API."""
    await handle_voice(websocket, user_id, context=context, name=name)

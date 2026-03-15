import asyncio
import os
import sentry_sdk
from dotenv import load_dotenv
from fastapi import FastAPI, WebSocket, HTTPException
from pydantic import BaseModel
from rena.voice import handle_voice
from rena.tools import scan_image, log_meal, log_weight, get_progress, get_goal, create_profile, reset_user

load_dotenv()

sentry_sdk.init(
    dsn=os.getenv("SENTRY_DSN"),
    traces_sample_rate=1.0,
    send_default_pii=True,
)

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



@app.get("/workbook/insight/{user_id}")
async def workbook_insight(user_id: str):
    """Generate a brief AI interpretation of today's progress for the Workbook tab."""
    from datetime import datetime, timezone
    from google import genai as _genai
    from rena.tools import _get_genai_client

    if not user_id or user_id.strip() == "":
        raise HTTPException(status_code=400, detail="user_id is required")

    p = get_progress(user_id)
    hour = datetime.now(timezone.utc).hour
    time_of_day = "morning" if hour < 12 else ("evening" if hour >= 17 else "afternoon")

    meals = p.get("meals_logged") or []
    workouts = p.get("workouts_logged") or []
    consumed = p.get("calories_consumed", 0)
    target = p.get("calories_target", 2000)
    burned = p.get("calories_burned", 0)
    protein = p.get("protein_consumed_g", 0)
    protein_target = p.get("protein_target_g", 120)
    water = p.get("water_glasses", 0)

    meals_detail = ", ".join(
        f"{m['name']} ({m.get('calories', 0)} kcal)" for m in meals
    ) if meals else "nothing logged yet"

    workouts_detail = ", ".join(
        f"{w['type']} {w.get('duration_min', 0)} min ({w.get('calories_burned', 0)} kcal burned)"
        for w in workouts
    ) if workouts else "no workouts logged"

    insight_prompt = (
        f"You are Rena, a warm health companion. Write exactly 2 short sentences "
        f"interpreting this person's {time_of_day} so far. Be specific, encouraging, and end with one actionable tip. "
        f"No markdown, no bullet points.\n\n"
        f"Calories: {consumed}/{target} consumed, {burned} burned. "
        f"Protein: {protein}g/{protein_target}g. Water: {water}/8 glasses."
    )

    activity_prompt = (
        f"You are Rena. Write 1-2 warm, natural sentences summarising what this person ate and how they moved today. "
        f"Sound like a friend, not a food diary. No markdown, no lists.\n\n"
        f"Food today: {meals_detail}.\n"
        f"Exercise today: {workouts_detail}."
    )

    client = _get_genai_client()
    insight_resp, activity_resp = await asyncio.gather(
        asyncio.to_thread(client.models.generate_content, model="gemini-2.5-flash", contents=insight_prompt),
        asyncio.to_thread(client.models.generate_content, model="gemini-2.5-flash", contents=activity_prompt),
    )
    return {
        "insight": insight_resp.text.strip(),
        "activity": activity_resp.text.strip(),
    }


@app.websocket("/ws/{user_id}")
async def voice_endpoint(websocket: WebSocket, user_id: str,
                         context: str | None = None, name: str | None = None):
    """Real-time voice conversation with Rena via Gemini Live API."""
    await handle_voice(websocket, user_id, context=context, name=name)

import asyncio
import os
import sentry_sdk
from dotenv import load_dotenv
from fastapi import FastAPI, WebSocket, HTTPException
from pydantic import BaseModel
from rena.voice import handle_voice
from rena.tools import (
    scan_image, log_meal, log_weight, get_progress, get_goal, create_profile, reset_user,
    get_workout_plan, generate_workout_plan, toggle_exercise_complete, log_exercise_from_plan,
    get_exercise_video, get_exercise_video_status,
)

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
async def workbook_insight(user_id: str, date: str = None):
    """Generate AI insight + activity summary for the Workbook tab. Accepts optional date (YYYY-MM-DD)."""
    from datetime import datetime, timezone, date as date_type
    from rena.tools import _get_genai_client

    if not user_id or user_id.strip() == "":
        raise HTTPException(status_code=400, detail="user_id is required")

    p = get_progress(user_id, for_date=date)
    today_str = datetime.now(timezone.utc).date().isoformat()
    is_today = (date is None) or (date == today_str)
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
    ) if meals else "nothing logged"

    workouts_detail = ", ".join(
        f"{w['type']} {w.get('duration_min', 0)} min ({w.get('calories_burned', 0)} kcal burned)"
        for w in workouts
    ) if workouts else "no workouts"

    if is_today:
        insight_prompt = (
            f"You are Rena, a warm health companion. Write exactly 2 short sentences "
            f"interpreting this person's {time_of_day} so far. Be specific, encouraging, and end with one actionable tip. "
            f"No markdown, no bullet points.\n\n"
            f"Calories: {consumed}/{target} consumed, {burned} burned. "
            f"Protein: {protein}g/{protein_target}g. Water: {water}/8 glasses."
        )
    else:
        insight_prompt = (
            f"You are Rena, a warm health companion. Write exactly 2 short sentences "
            f"reflecting on this person's day on {date}. Be warm and encouraging — note what went well "
            f"and one thing to carry forward. No markdown, no bullet points.\n\n"
            f"Calories: {consumed}/{target} eaten, {burned} burned. "
            f"Protein: {protein}g/{protein_target}g. Water: {water}/8 glasses."
        )

    activity_prompt = (
        f"You are Rena. Write 1-2 warm, natural sentences summarising what this person ate and how they moved "
        f"{'today' if is_today else 'on this day'}. Sound like a friend, not a food diary. No markdown, no lists.\n\n"
        f"Food: {meals_detail}.\n"
        f"Exercise: {workouts_detail}."
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


@app.get("/workout-plan/{user_id}")
async def get_workout_plan_endpoint(user_id: str, date: str = None):
    """Get the saved workout plan for a user on a given date (defaults to today)."""
    if not user_id:
        raise HTTPException(status_code=400, detail="user_id is required")
    plan = get_workout_plan(user_id, for_date=date)
    if plan is None:
        return {}
    return plan


@app.post("/workout-plan/{user_id}")
async def generate_workout_plan_endpoint(user_id: str):
    """Generate and save a Gemini-powered workout plan for today."""
    if not user_id:
        raise HTTPException(status_code=400, detail="user_id is required")
    return generate_workout_plan(user_id)


@app.patch("/workout-plan/{user_id}/exercise/{exercise_id}/complete")
async def toggle_complete_endpoint(user_id: str, exercise_id: str, date: str = None):
    """Toggle the completed flag on a planned exercise (no workout log entry)."""
    return toggle_exercise_complete(user_id, exercise_id, for_date=date)


class LogExerciseRequest(BaseModel):
    calories_override: int = None
    date: str = None


@app.post("/workout-plan/{user_id}/exercise/{exercise_id}/log")
async def log_exercise_endpoint(user_id: str, exercise_id: str, req: LogExerciseRequest = None):
    """Log a planned exercise into the workout log."""
    if not user_id:
        raise HTTPException(status_code=400, detail="user_id is required")
    r = req or LogExerciseRequest()
    return log_exercise_from_plan(user_id, exercise_id, for_date=r.date, calories_override=r.calories_override)


@app.get("/exercise/video/{exercise_name}")
async def exercise_video_endpoint(exercise_name: str, target_muscles: str = ""):
    """Return cached video URL or kick off a Veo 2 generation job."""
    try:
        return get_exercise_video(exercise_name, target_muscles)
    except Exception as e:
        return {"status": "error", "message": str(e)}


@app.get("/exercise/video/status/{job_id}")
async def exercise_video_status_endpoint(job_id: str):
    """Poll the status of a Veo 2 video generation job."""
    try:
        return get_exercise_video_status(job_id)
    except Exception as e:
        return {"status": "error", "message": str(e)}


@app.websocket("/ws/{user_id}")
async def voice_endpoint(websocket: WebSocket, user_id: str,
                         context: str | None = None, name: str | None = None):
    """Real-time voice conversation with Rena via Gemini Live API."""
    await handle_voice(websocket, user_id, context=context, name=name)

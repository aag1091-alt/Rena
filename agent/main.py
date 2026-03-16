import asyncio
import os
import sentry_sdk
from dotenv import load_dotenv
from fastapi import FastAPI, WebSocket, HTTPException
from pydantic import BaseModel
from rena.voice import handle_voice
from rena.tools import (
    scan_image, log_meal, log_water, log_weight, get_progress, get_goal, create_profile, reset_user,
    get_workout_plan, generate_workout_plan, delete_workout_plan, toggle_exercise_complete, log_exercise_from_plan,
    get_exercise_video, get_exercise_video_status, get_morning_nudge,
    get_meal_plan, delete_meal_plan, log_meal_from_plan,
    get_tomorrow_plan, save_tomorrow_plan_note, delete_tomorrow_plan_note,
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
    timezone: str = "UTC"  # IANA timezone e.g. "Asia/Kolkata"


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
        timezone_id=req.timezone,
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
    """Get the user's current goal and progress."""
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


class LogWaterRequest(BaseModel):
    user_id: str
    glasses: int = 1


@app.post("/log/water")
async def log_water_endpoint(req: LogWaterRequest):
    """Log glasses of water directly from the app."""
    if not req.user_id:
        raise HTTPException(status_code=400, detail="user_id is required")
    return log_water(req.user_id, req.glasses)


@app.get("/workbook/insight/{user_id}")
async def workbook_insight(user_id: str, date: str = None):
    """Generate AI insight + activity summary for the Workbook tab. Accepts optional date (YYYY-MM-DD).
    Caches in Firestore: today refreshes after 1 hour, past days are saved once and never regenerated."""
    from datetime import datetime, timezone
    from rena.tools import _get_text_client, db

    if not user_id or user_id.strip() == "":
        raise HTTPException(status_code=400, detail="user_id is required")

    from rena.tools import _local_today
    today_str = _local_today(user_id)
    target_date = date or today_str
    is_today = (target_date == today_str)

    # ── Check cache ──────────────────────────────────────────────────────────
    cache_ref = db.collection("workbook_insights").document(user_id).collection("days").document(target_date)
    cached = cache_ref.get().to_dict()

    if cached:
        if not is_today:
            # Past day: return once-saved cache forever
            return {"insight": cached["insight"], "activity": cached["activity"]}
        # Today: return cache if fresher than 1 hour
        generated_at = cached.get("generated_at")
        if generated_at:
            age_seconds = (datetime.now(timezone.utc) - generated_at).total_seconds()
            if age_seconds < 3600:
                return {"insight": cached["insight"], "activity": cached["activity"]}

    # ── Generate ─────────────────────────────────────────────────────────────
    p = get_progress(user_id, for_date=date)
    from rena.tools import _get_user_timezone
    import zoneinfo as _zi
    _tz_str = _get_user_timezone(user_id)
    try:
        _tz = _zi.ZoneInfo(_tz_str)
    except Exception:
        _tz = timezone.utc
    hour = datetime.now(_tz).hour
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
            f"reflecting on this person's day on {target_date}. Be warm and encouraging — note what went well "
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

    client = _get_text_client()
    insight_resp, activity_resp = await asyncio.gather(
        asyncio.to_thread(client.models.generate_content, model="gemini-2.5-flash", contents=insight_prompt),
        asyncio.to_thread(client.models.generate_content, model="gemini-2.5-flash", contents=activity_prompt),
    )

    insight_text  = insight_resp.text.strip()
    activity_text = activity_resp.text.strip()

    # ── Save to cache ────────────────────────────────────────────────────────
    cache_ref.set({
        "insight":      insight_text,
        "activity":     activity_text,
        "generated_at": datetime.now(timezone.utc),
    })

    return {"insight": insight_text, "activity": activity_text}


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
async def generate_workout_plan_endpoint(user_id: str, date: str = None):
    """Generate and save a Gemini-powered workout plan for the given date (defaults to today)."""
    if not user_id:
        raise HTTPException(status_code=400, detail="user_id is required")
    return generate_workout_plan(user_id, for_date=date)


@app.delete("/workout-plan/{user_id}")
async def delete_workout_plan_endpoint(user_id: str, date: str = None):
    """Delete the saved workout plan for today (or a given date)."""
    if not user_id:
        raise HTTPException(status_code=400, detail="user_id is required")
    return delete_workout_plan(user_id, for_date=date)


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


@app.get("/meal-plan/{user_id}")
async def get_meal_plan_endpoint(user_id: str, date: str = None):
    """Get the saved meal plan for a user on a given date (defaults to today)."""
    if not user_id:
        raise HTTPException(status_code=400, detail="user_id is required")
    plan = get_meal_plan(user_id, for_date=date)
    if plan is None:
        return {}
    return plan


@app.delete("/meal-plan/{user_id}")
async def delete_meal_plan_endpoint(user_id: str, date: str = None):
    """Delete the saved meal plan for a given date."""
    if not user_id:
        raise HTTPException(status_code=400, detail="user_id is required")
    return delete_meal_plan(user_id, for_date=date)


class LogMealFromPlanRequest(BaseModel):
    date: str = None


@app.post("/meal-plan/{user_id}/meal/{meal_id}/log")
async def log_meal_from_plan_endpoint(user_id: str, meal_id: str, req: LogMealFromPlanRequest = None):
    """Log a planned meal into the meal log."""
    if not user_id:
        raise HTTPException(status_code=400, detail="user_id is required")
    r = req or LogMealFromPlanRequest()
    return await asyncio.to_thread(log_meal_from_plan, user_id, meal_id, r.date)


@app.get("/morning-nudge/{user_id}")
async def morning_nudge_endpoint(user_id: str):
    """Return today's motivational nudge derived from the user's plan_tomorrow session notes."""
    if not user_id or user_id.strip() == "":
        raise HTTPException(status_code=400, detail="user_id is required")
    return await asyncio.to_thread(get_morning_nudge, user_id)


@app.get("/tomorrow-plan/{user_id}")
async def get_tomorrow_plan_endpoint(user_id: str, date: str = None):
    """Get the saved tomorrow-plan note for a user (defaults to tomorrow)."""
    if not user_id or user_id.strip() == "":
        raise HTTPException(status_code=400, detail="user_id is required")
    plan = await asyncio.to_thread(get_tomorrow_plan, user_id, date)
    if plan is None:
        return {}
    return plan


class UpdateTomorrowPlanRequest(BaseModel):
    summary: str
    date: str = None


@app.post("/tomorrow-plan/{user_id}")
async def upsert_tomorrow_plan_endpoint(user_id: str, req: UpdateTomorrowPlanRequest):
    """Create or update the tomorrow-plan note for a user."""
    if not user_id or user_id.strip() == "":
        raise HTTPException(status_code=400, detail="user_id is required")
    return await asyncio.to_thread(
        save_tomorrow_plan_note,
        user_id, req.summary, req.date,
    )


@app.delete("/tomorrow-plan/{user_id}")
async def delete_tomorrow_plan_endpoint(user_id: str, date: str = None):
    """Delete the tomorrow-plan note for a given date."""
    if not user_id or user_id.strip() == "":
        raise HTTPException(status_code=400, detail="user_id is required")
    return await asyncio.to_thread(delete_tomorrow_plan_note, user_id, date)


@app.websocket("/ws/{user_id}")
async def voice_endpoint(websocket: WebSocket, user_id: str,
                         context: str | None = None, name: str | None = None):
    """Real-time voice conversation with Rena via Gemini Live API."""
    await handle_voice(websocket, user_id, context=context, name=name)

import asyncio
import base64
import os
import uuid
from datetime import date, datetime, timezone

from google import genai
from google.cloud import firestore, storage

db = firestore.Client(project=os.getenv("GOOGLE_CLOUD_PROJECT"))


def _emit_tool_status(user_id: str, message: str) -> None:
    """Fire a tool-status banner to the user's active WebSocket session (thread-safe)."""
    try:
        from rena import voice as _voice
        entry = _voice._status_queues.get(user_id)
        if entry:
            q, loop = entry
            loop.call_soon_threadsafe(q.put_nowait, message)
    except Exception:
        pass


# Vertex AI client — used ONLY for Veo 2 video generation (requires Vertex AI)
_genai_client = None

def _get_genai_client():
    """Vertex AI client — Veo 2 only."""
    global _genai_client
    if _genai_client is None:
        _genai_client = genai.Client(
            vertexai=True,
            project=os.getenv("GOOGLE_CLOUD_PROJECT"),
            location=os.getenv("GOOGLE_CLOUD_LOCATION", "us-central1"),
        )
    return _genai_client


# Gemini API client — uses GEMINI_API_KEY for all text/vision generation
_gemini_api_client = None
_gemini_imagen_client = None

def _get_text_client():
    """Gemini API client using API key — cheaper for all text/vision calls."""
    global _gemini_api_client
    if _gemini_api_client is None:
        api_key = os.getenv("GEMINI_API_KEY") or os.getenv("GOOGLE_API_KEY")
        if api_key:
            _gemini_api_client = genai.Client(api_key=api_key)
        else:
            _gemini_api_client = _get_genai_client()
    return _gemini_api_client

def _get_imagen_client():
    """Gemini API client using v1alpha — required for image generation preview models."""
    global _gemini_imagen_client
    if _gemini_imagen_client is None:
        api_key = os.getenv("GEMINI_API_KEY") or os.getenv("GOOGLE_API_KEY")
        if api_key:
            from google.genai import types as _t
            _gemini_imagen_client = genai.Client(
                api_key=api_key,
                http_options=_t.HttpOptions(api_version="v1alpha"),
            )
        else:
            _gemini_imagen_client = _get_genai_client()
    return _gemini_imagen_client


def _user_ref(user_id: str):
    return db.collection("users").document(user_id)


def _goal_ref(user_id: str):
    return db.collection("goals").document(user_id)


def _today_log_ref(user_id: str):
    today = datetime.now(timezone.utc).date().isoformat()
    return _user_ref(user_id).collection("logs").document(today)


_ACTIVITY_MULTIPLIERS = {
    "sedentary": 1.2,
    "lightly_active": 1.375,
    "moderately_active": 1.55,
    "very_active": 1.725,
}


def create_profile(
    user_id: str,
    name: str,
    sex: str,
    age: int,
    height_cm: float,
    weight_kg: float,
    activity_level: str,
) -> dict:
    """
    Create or update a user profile and calculate their daily calorie target.

    Uses Mifflin-St Jeor BMR formula + activity multiplier, then applies a
    300 kcal deficit as a sensible default (refined later when goal is set).

    Args:
        user_id: Google user ID.
        name: First name the user wants to be called.
        sex: "male" or "female".
        age: Age in years.
        height_cm: Height in centimetres.
        weight_kg: Current weight in kilograms.
        activity_level: One of sedentary | lightly_active | moderately_active | very_active.

    Returns:
        Saved profile including calculated daily_calorie_target.
    """
    # Mifflin-St Jeor BMR
    bmr = 10 * weight_kg + 6.25 * height_cm - 5 * age
    bmr += 5 if sex.lower() == "male" else -161

    multiplier = _ACTIVITY_MULTIPLIERS.get(activity_level, 1.375)
    tdee = int(bmr * multiplier)
    daily_calorie_target = max(1200, tdee - 300)  # 300 kcal deficit, floor at 1200

    profile = {
        "name": name,
        "sex": sex.lower(),
        "age": age,
        "height_cm": height_cm,
        "weight_kg": weight_kg,
        "activity_level": activity_level,
        "tdee": tdee,
        "created_at": firestore.SERVER_TIMESTAMP,
    }
    _user_ref(user_id).set(profile, merge=True)

    return {
        "status": "created",
        "name": name,
        "tdee": tdee,
        "daily_calorie_target": daily_calorie_target,
    }


def set_goal(
    user_id: str,
    goal: str,
    deadline: str,
    goal_type: str = "event",
    start_value: float = 0,
    target_value: float = 0,
    unit: str = "",
    direction: str = "",
) -> dict:
    """
    Save the user's health goal. Call once goal and deadline are confirmed.

    goal_type options:
      - "weight_loss"  : losing body weight (direction="decrease", unit="kg")
      - "weight_gain"  : gaining muscle/weight (direction="increase", unit="kg")
      - "fitness"      : performance target like running distance or lifting weight
      - "habit"        : consistency goal like workouts per week or daily protein
      - "event"        : feel-based or date-based goal with no numeric metric

    For weight_loss / weight_gain: start_value = current weight (from profile),
    target_value = goal weight in kg.
    For fitness: start_value = current ability, target_value = goal (e.g. 5 for 5km).
    For habit / event: leave start_value and target_value as 0.

    Calorie deficit is auto-scaled by timeline:
    - >16 weeks: -400 kcal  |  8–16 weeks: -500 kcal  |  <8 weeks: -600 kcal

    Args:
        user_id: The user's unique ID.
        goal: Natural language goal description.
        deadline: Target date YYYY-MM-DD.
        goal_type: One of weight_loss | weight_gain | fitness | habit | event.
        start_value: Starting numeric value (e.g. current weight 83.5).
        target_value: Target numeric value (e.g. goal weight 78.5).
        unit: Unit string (e.g. "kg", "km", "reps").
        direction: "decrease" | "increase" | "" for event/habit.

    Returns:
        Confirmation with goal details and adjusted daily calorie target.
    """
    _emit_tool_status(user_id, "Setting your goal…")
    profile = _user_ref(user_id).get().to_dict() or {}
    tdee = profile.get("tdee", 2000)

    try:
        days_left = (date.fromisoformat(deadline) - datetime.now(timezone.utc).date()).days
    except ValueError:
        days_left = 90

    if days_left > 112:
        deficit = 400
    elif days_left > 56:
        deficit = 500
    else:
        deficit = 600

    daily_calorie_target = max(1200, tdee - deficit)

    # For weight goals, seed start_value from profile if not provided
    if goal_type in ("weight_loss", "weight_gain") and start_value == 0:
        start_value = profile.get("weight_kg", 0)

    _goal_ref(user_id).set({
        "goal": goal,
        "deadline": deadline,
        "goal_type": goal_type,
        "start_value": start_value,
        "target_value": target_value,
        "unit": unit,
        "direction": direction,
        "daily_calorie_target": daily_calorie_target,
        "days_until_goal": days_left,
        "created_at": firestore.SERVER_TIMESTAMP,
    }, merge=True)

    _user_ref(user_id).update({
        "goal": firestore.DELETE_FIELD,
        "deadline": firestore.DELETE_FIELD,
        "daily_calorie_target": firestore.DELETE_FIELD,
    })

    return {
        "status": "saved",
        "goal": goal,
        "goal_type": goal_type,
        "start_value": start_value,
        "target_value": target_value,
        "unit": unit,
        "deadline": deadline,
        "daily_calorie_target": daily_calorie_target,
        "days_until_goal": days_left,
    }


def _get_latest_weight(user_id: str) -> float | None:
    """Return the most recently logged weight for a user (scans last 30 days)."""
    from datetime import timedelta
    for i in range(30):
        d = (datetime.now(timezone.utc).date() - timedelta(days=i)).isoformat()
        log = _user_ref(user_id).collection("logs").document(d).get().to_dict() or {}
        if log.get("weight_kg"):
            return float(log["weight_kg"])
    return None


def _compute_goal_progress(goal_doc: dict, user_id: str) -> dict:
    """Compute current_value, progress_percent, and progress_label for any goal type."""
    goal_type   = goal_doc.get("goal_type", "event")
    start_value = goal_doc.get("start_value", 0) or 0
    target_value = goal_doc.get("target_value", 0) or 0
    unit        = goal_doc.get("unit", "")
    direction   = goal_doc.get("direction", "")

    current_value   = 0.0
    progress_pct    = 0
    progress_label  = ""

    if goal_type in ("weight_loss", "weight_gain"):
        current_weight = _get_latest_weight(user_id) or start_value
        current_value  = current_weight

        if start_value and target_value and start_value != target_value:
            total_change = abs(target_value - start_value)
            change_so_far = abs(current_weight - start_value)
            # Cap at 100% if they've overshot
            progress_pct = int(min(100, (change_so_far / total_change) * 100))

        if goal_type == "weight_loss":
            remaining = round(current_weight - target_value, 1)
            lost      = round(start_value - current_weight, 1)
            if remaining <= 0:
                progress_label = f"Goal reached! Lost {lost}{unit}"
            elif lost > 0:
                progress_label = f"{lost}{unit} lost · {remaining}{unit} to go"
            else:
                progress_label = f"{remaining}{unit} to lose"
        else:
            remaining = round(target_value - current_weight, 1)
            gained    = round(current_weight - start_value, 1)
            if remaining <= 0:
                progress_label = f"Goal reached! Gained {gained}{unit}"
            elif gained > 0:
                progress_label = f"{gained}{unit} gained · {remaining}{unit} to go"
            else:
                progress_label = f"{remaining}{unit} to gain"

    elif goal_type == "fitness":
        # current_value updated by Rena when user reports a milestone
        current_value = goal_doc.get("current_value", 0) or 0
        if target_value and target_value > 0:
            progress_pct = int(min(100, (current_value / target_value) * 100))
        if current_value > 0:
            progress_label = f"{current_value} / {target_value} {unit}"
        else:
            progress_label = f"Target: {target_value} {unit}"

    elif goal_type == "habit":
        current_value = goal_doc.get("current_value", 0) or 0
        if target_value and target_value > 0:
            progress_pct = int(min(100, (current_value / target_value) * 100))
        progress_label = f"{int(current_value)} / {int(target_value)} {unit}" if target_value else ""

    else:  # event
        try:
            total_days = (date.fromisoformat(goal_doc.get("deadline", datetime.now(timezone.utc).date().isoformat())) -
                          date.fromisoformat(goal_doc.get("created_at_date", datetime.now(timezone.utc).date().isoformat()))).days
            days_elapsed = total_days - goal_doc.get("days_until_goal", total_days)
            progress_pct = int(min(100, (days_elapsed / max(total_days, 1)) * 100))
        except Exception:
            progress_pct = 0
        progress_label = f"{goal_doc.get('days_until_goal', 0)} days to go"

    return {
        "current_value": current_value,
        "progress_percent": progress_pct,
        "progress_label": progress_label,
    }


def get_goal(user_id: str) -> dict:
    """
    Get the user's current goal, generating a goal image if not yet created.

    Args:
        user_id: The user's unique ID.

    Returns:
        Dict with goal, deadline, image_url, daily_calorie_target, days_until_goal.
    """
    goal_doc = _goal_ref(user_id).get().to_dict()

    if not goal_doc:
        return {
            "goal": "Not set",
            "deadline": "",
            "daily_calorie_target": 1800,
            "days_until_goal": 0,
        }

    # Recompute days_until_goal live
    try:
        days_left = (date.fromisoformat(goal_doc["deadline"]) - datetime.now(timezone.utc).date()).days
    except Exception:
        days_left = goal_doc.get("days_until_goal", 0)

    # Save created_at_date once (needed for event progress calculation)
    if not goal_doc.get("created_at_date"):
        _goal_ref(user_id).set({"created_at_date": datetime.now(timezone.utc).date().isoformat()}, merge=True)
        goal_doc["created_at_date"] = datetime.now(timezone.utc).date().isoformat()

    goal_doc["days_until_goal"] = days_left
    progress = _compute_goal_progress(goal_doc, user_id)

    return {
        "goal": goal_doc.get("goal", "Not set"),
        "goal_type": goal_doc.get("goal_type", "event"),
        "start_value": goal_doc.get("start_value", 0),
        "target_value": goal_doc.get("target_value", 0),
        "current_value": progress["current_value"],
        "unit": goal_doc.get("unit", ""),
        "direction": goal_doc.get("direction", ""),
        "progress_percent": progress["progress_percent"],
        "progress_label": progress["progress_label"],
        "deadline": goal_doc.get("deadline", ""),
        "daily_calorie_target": goal_doc.get("daily_calorie_target", 1800),
        "days_until_goal": days_left,
    }


def get_progress(user_id: str, for_date: str = None) -> dict:
    """
    Get the user's goal and today's progress (calories, water, workouts).

    Args:
        user_id: The user's unique ID.

    Returns:
        Dict with goal info and today's logged activity.
    """
    _emit_tool_status(user_id, "Checking your progress…")
    profile = _user_ref(user_id).get().to_dict() or {}
    log_date = for_date or datetime.now(timezone.utc).date().isoformat()
    log_ref = _user_ref(user_id).collection("logs").document(log_date)
    today_log = log_ref.get().to_dict() or {}
    goal_doc = _goal_ref(user_id).get().to_dict() or {}

    meals = today_log.get("meals", [])
    workouts = today_log.get("workouts", [])

    calories_consumed = sum(m.get("calories", 0) for m in meals)
    calories_burned   = sum(w.get("calories_burned", 0) for w in workouts)
    protein_consumed  = sum(m.get("protein_g", 0) for m in meals)

    calorie_target = goal_doc.get("daily_calorie_target", profile.get("daily_calorie_target", 1800))
    net_calories   = calories_consumed - calories_burned
    burn_required  = max(0, net_calories - calorie_target)

    # Protein target: 1.6 g per kg of body weight (preserves muscle during deficit)
    weight_kg      = profile.get("weight_kg", 70)
    protein_target = int(weight_kg * 1.6)

    return {
        "goal": goal_doc.get("goal", "Not set"),
        "deadline": goal_doc.get("deadline", "Not set"),
        "calories_consumed": calories_consumed,
        "calories_burned": calories_burned,
        "calories_target": calorie_target,
        "calories_remaining": max(0, calorie_target - net_calories),
        "burn_required": burn_required,
        "protein_consumed_g": protein_consumed,
        "protein_target_g": protein_target,
        "water_glasses": today_log.get("water_glasses", 0),
        "weight_kg": today_log.get("weight_kg"),
        "meals_logged": meals,
        "workouts_logged": workouts,
    }


def seed_test_data(user_id: str) -> dict:
    """Seed 7 days of realistic test data tailored to the user's actual profile."""
    import json, re
    from datetime import timedelta

    # ── Read the user's actual profile ──────────────────────────────────────
    profile = _user_ref(user_id).get().to_dict() or {}
    goal_doc = _goal_ref(user_id).get().to_dict() or {}

    calorie_target = int(profile.get("daily_calorie_target", 2000))
    weight_kg      = float(profile.get("weight_kg", 75.0))
    goal_type      = goal_doc.get("goal_type", "fitness")
    direction      = goal_doc.get("direction", "decrease")  # "decrease" | "increase"
    protein_target = int(weight_kg * 1.6)

    # ── Ask Gemini to generate 7 realistic days of data ─────────────────────
    prompt = f"""Generate 7 days of realistic health tracking data for someone with:
- Daily calorie target: {calorie_target} kcal
- Current weight: {weight_kg} kg
- Goal: {goal_type} (weight {direction})
- Protein target: {protein_target}g/day

Rules:
- Each day has 2-4 meals. Total daily calories should vary realistically: some days 100-200 under target, some days on target, 1-2 days slightly over.
- Meals should be varied and realistic (mix of home cooking and common takeout/cafe items).
- Workouts on 4-5 of the 7 days. Types should match the goal: weight loss = cardio + some strength, fitness/habit = mixed, weight gain = strength focus.
- Water glasses between 5-8 per day.
- Weight should show a realistic {direction} trend over the 7 days (small daily changes, not linear).

Return ONLY a JSON array of 7 objects (day 0 = 6 days ago, day 6 = yesterday). No markdown.
Each object:
{{
  "meals": [{{"name": str, "calories": int, "protein_g": int, "carbs_g": int, "fat_g": int}}],
  "workouts": [{{"type": str, "duration_min": int, "calories_burned": int}}],
  "water_glasses": int,
  "weight_kg": float
}}"""

    client = _get_text_client()
    response = client.models.generate_content(model="gemini-2.5-flash", contents=prompt)
    raw = response.text.strip()
    raw = re.sub(r"^```(?:json)?\n?", "", raw)
    raw = re.sub(r"\n?```$", "", raw)
    days_data = json.loads(raw)

    # ── Write to Firestore ───────────────────────────────────────────────────
    today = datetime.now(timezone.utc).date()
    written = []
    for i, day_obj in enumerate(days_data[:7]):
        day = today - timedelta(days=6 - i)
        day_str = day.isoformat()
        meals = [
            {**m, "logged_at": f"{day_str}T08:00:00Z"}
            for m in day_obj.get("meals", [])
        ]
        workouts = [
            {**w, "logged_at": f"{day_str}T17:00:00Z"}
            for w in day_obj.get("workouts", [])
        ]
        _user_ref(user_id).collection("logs").document(day_str).set({
            "meals":         meals,
            "workouts":      workouts,
            "water_glasses": day_obj.get("water_glasses", 6),
            "weight_kg":     day_obj.get("weight_kg", weight_kg),
        })
        written.append(day_str)

    return {"status": "seeded", "days": written}


def _estimate_macros(meal_name: str, calories: int) -> dict:
    """Use Gemini to estimate protein/carbs/fat for a food when not provided."""
    import json, re
    try:
        client = _get_text_client()
        prompt = (
            f'Estimate macronutrients for: "{meal_name}" (~{calories} kcal).\n'
            'Return JSON only, no explanation: {"protein_g": 0, "carbs_g": 0, "fat_g": 0}\n'
            "Use whole numbers. Reflect typical macros for this food."
        )
        response = client.models.generate_content(
            model="gemini-2.5-flash",
            contents=prompt,
        )
        raw = response.text.strip()
        raw = re.sub(r"^```(?:json)?\n?", "", raw)
        raw = re.sub(r"\n?```$", "", raw)
        data = json.loads(raw)
        return {
            "protein_g": int(data.get("protein_g", 0)),
            "carbs_g":   int(data.get("carbs_g", 0)),
            "fat_g":     int(data.get("fat_g", 0)),
        }
    except Exception as e:
        return {"protein_g": 0, "carbs_g": 0, "fat_g": 0}


def log_meal(user_id: str, meal_name: str, calories: int, protein_g: int = 0, carbs_g: int = 0, fat_g: int = 0) -> dict:
    """
    Log a meal for the user. Macros (protein, carbs, fat) are auto-estimated using
    Gemini if not provided, so you don't need to calculate them yourself.

    Args:
        user_id: The user's unique ID.
        meal_name: Name or description of the meal.
        calories: Estimated calories.
        protein_g: Protein in grams (auto-estimated if 0).
        carbs_g: Carbohydrates in grams (auto-estimated if 0).
        fat_g: Fat in grams (auto-estimated if 0).

    Returns:
        Confirmation with updated daily calorie total.
    """
    _emit_tool_status(user_id, "Logging your meal…")
    # Auto-estimate macros when not provided
    if protein_g == 0 and carbs_g == 0 and fat_g == 0:
        macros = _estimate_macros(meal_name, calories)
        protein_g = macros["protein_g"]
        carbs_g   = macros["carbs_g"]
        fat_g     = macros["fat_g"]

    meal = {
        "name": meal_name,
        "calories": calories,
        "protein_g": protein_g,
        "carbs_g": carbs_g,
        "fat_g": fat_g,
        "logged_at": datetime.now(timezone.utc).isoformat(),
    }
    _today_log_ref(user_id).set(
        {"meals": firestore.ArrayUnion([meal])},
        merge=True
    )
    progress = get_progress(user_id)
    return {
        "status": "logged",
        "meal": meal_name,
        "calories": calories,
        "protein_g": protein_g,
        "carbs_g": carbs_g,
        "fat_g": fat_g,
        "total_today": progress["calories_consumed"],
        "remaining": progress["calories_remaining"],
    }


def log_water(user_id: str, glasses: int) -> dict:
    """
    Log glasses of water consumed.

    Args:
        user_id: The user's unique ID.
        glasses: Number of glasses to add.

    Returns:
        Updated total glasses for today.
    """
    _emit_tool_status(user_id, "Logging water…")
    log_ref = _today_log_ref(user_id)
    today = log_ref.get().to_dict() or {}
    new_total = today.get("water_glasses", 0) + glasses
    log_ref.set({"water_glasses": new_total}, merge=True)
    return {"status": "logged", "water_glasses_today": new_total}


_MET = {
    "walking": 3.5, "walk": 3.5,
    "running": 8.0, "run": 8.0, "jogging": 7.0, "jog": 7.0,
    "cycling": 7.5, "biking": 7.5, "bike": 7.5, "cycle": 7.5,
    "swimming": 6.0, "swim": 6.0,
    "yoga": 2.5,
    "hiit": 8.5, "circuit": 8.0,
    "gym": 5.0, "weightlifting": 5.0, "weights": 5.0, "lifting": 5.0,
    "pilates": 3.0,
    "dancing": 5.0, "dance": 5.0,
    "football": 8.0, "soccer": 8.0, "basketball": 8.0, "tennis": 7.0,
    "cricket": 5.0, "badminton": 5.5,
    "hiking": 6.0, "hike": 6.0,
    "rowing": 7.0, "elliptical": 5.0, "stairclimber": 9.0,
    "stretching": 2.3,
}


def log_workout(user_id: str, workout_type: str, duration_min: int, calories_burned: int = 0) -> dict:
    """
    Log a workout session. Calories burned are auto-calculated from duration and workout type
    if not provided, using MET values and the user's body weight.

    Args:
        user_id: The user's unique ID.
        workout_type: Type of workout (e.g. 'running', 'yoga', 'gym').
        duration_min: Duration in minutes.
        calories_burned: Estimated calories burned. If 0 or omitted, calculated automatically.

    Returns:
        Confirmation of logged workout with calories burned.
    """
    _emit_tool_status(user_id, "Logging your workout…")
    if calories_burned <= 0:
        profile = _user_ref(user_id).get().to_dict() or {}
        weight_kg = profile.get("weight_kg", 70)
        key = workout_type.lower().strip()
        met = _MET.get(key)
        if met is None:
            # Try partial match
            for k, v in _MET.items():
                if k in key or key in k:
                    met = v
                    break
        met = met or 4.0  # sensible default for unknown activities
        calories_burned = int(met * weight_kg * (duration_min / 60))

    workout = {
        "type": workout_type,
        "duration_min": duration_min,
        "calories_burned": calories_burned,
        "logged_at": datetime.now(timezone.utc).isoformat(),
    }
    _today_log_ref(user_id).set(
        {"workouts": firestore.ArrayUnion([workout])},
        merge=True
    )
    return {
        "status": "logged",
        "workout": workout_type,
        "duration_min": duration_min,
        "calories_burned": calories_burned,
    }


def get_recent_workouts(user_id: str, days: int = 7) -> dict:
    """
    Return the user's logged workouts from the past N days, mapped by date.
    Use this before generating a workout plan to understand the user's recent activity patterns.

    Args:
        user_id: The user's unique ID.
        days: Number of past days to look back (default 14).

    Returns:
        Dict with workouts_by_date (date → list of workouts) and a plain-English summary.
    """
    _emit_tool_status(user_id, "Checking your workout history…")
    from datetime import timedelta

    today = datetime.now(timezone.utc).date()
    workouts_by_date = {}
    for i in range(days):
        d = (today - timedelta(days=i)).isoformat()
        doc = _user_ref(user_id).collection("logs").document(d).get()
        if doc.exists:
            data = doc.to_dict() or {}
            entries = data.get("workouts", [])
            if entries:
                workouts_by_date[d] = [
                    {"type": w.get("type", "workout"), "duration_min": w.get("duration_min", 0),
                     "calories_burned": w.get("calories_burned", 0)}
                    for w in entries
                ]

    if not workouts_by_date:
        return {
            "workouts_by_date": {},
            "total_workout_days": 0,
            "summary": f"No workouts logged in the past {days} days. Ask the user what kind of workout they'd like.",
        }

    total_days = len(workouts_by_date)
    all_types = [w["type"] for entries in workouts_by_date.values() for w in entries]
    type_counts = {}
    for t in all_types:
        type_counts[t] = type_counts.get(t, 0) + 1
    top_types = sorted(type_counts, key=lambda x: -type_counts[x])[:3]
    summary = (
        f"User has worked out on {total_days} of the past {days} days. "
        f"Most frequent activities: {', '.join(top_types)}. "
        f"Use this to build a plan that complements their recent activity."
    )
    return {"workouts_by_date": workouts_by_date, "total_workout_days": total_days, "summary": summary}


def scan_image(user_id: str, image_base64: str, mime_type: str = "image/jpeg") -> dict:
    """
    Identify food in a photo and estimate nutritional content using Gemini Vision.
    Use this when the user shares a photo of food from their camera or gallery.

    Args:
        user_id: The user's unique ID.
        image_base64: Base64-encoded image data.
        mime_type: Image MIME type (default image/jpeg).

    Returns:
        Identified food items with calorie and macro estimates.
    """
    _emit_tool_status(user_id, "Analysing your photo…")
    client = _get_text_client()
    image_bytes = base64.b64decode(image_base64)

    from google.genai import types as genai_types
    response = client.models.generate_content(
        model="gemini-2.5-flash",
        contents=[
            genai_types.Part.from_bytes(data=image_bytes, mime_type=mime_type),
            """You are a nutrition expert. Analyze this food image and respond in JSON only.
Identify EVERY distinct food item visible separately and estimate nutritional content for each.
Return exactly this structure:
{
  "identified": true,
  "description": "brief overall description",
  "items": [{"name": "item name", "weight_g": 0, "calories": 0, "protein_g": 0, "carbs_g": 0, "fat_g": 0}],
  "total_calories": 0,
  "total_protein_g": 0,
  "total_carbs_g": 0,
  "total_fat_g": 0,
  "confidence": "high|medium|low"
}
weight_g is the estimated weight in grams of that item as visible in the photo.
If a dish has components (e.g. rice + curry + salad), list each as a separate item.
If no food is visible return {"identified": false}."""
        ],
    )

    import json, re
    raw = response.text.strip()
    # Strip markdown code fences if present
    raw = re.sub(r"^```(?:json)?\n?", "", raw)
    raw = re.sub(r"\n?```$", "", raw)
    raw = raw.strip()

    try:
        result = json.loads(raw)
    except json.JSONDecodeError:
        # Gemini sometimes includes extra text — extract the first JSON object
        match = re.search(r"\{[\s\S]*\}", raw)
        if match:
            try:
                result = json.loads(match.group())
            except json.JSONDecodeError:
                pass
                return {"identified": False}
        else:
            return {"identified": False}

    result["user_id"] = user_id
    return result




def log_weight(user_id: str, weight_kg: float) -> dict:
    """
    Log the user's weight for today. If called multiple times today, only the latest is kept.

    Args:
        user_id: The user's unique ID.
        weight_kg: Current weight in kilograms.

    Returns:
        Confirmation with the logged weight.
    """
    _emit_tool_status(user_id, "Saving your weight…")
    _today_log_ref(user_id).set({"weight_kg": weight_kg}, merge=True)
    return {"status": "logged", "weight_kg": weight_kg}


def delete_meal(user_id: str, meal_name: str) -> dict:
    """
    Remove a logged meal from today's food log.
    Matches by name (case-insensitive, partial match on the first hit found).

    Args:
        user_id: The user's unique ID.
        meal_name: Name or partial name of the meal to remove (e.g. "samosa", "chai").

    Returns:
        Confirmation with the removed meal and updated daily calorie total.
    """
    _emit_tool_status(user_id, "Removing meal…")
    log_ref = _today_log_ref(user_id)
    today = log_ref.get().to_dict() or {}
    meals = today.get("meals", [])

    key = meal_name.lower().strip()
    removed = None
    kept = []
    for m in meals:
        if removed is None and key in m.get("name", "").lower():
            removed = m
        else:
            kept.append(m)

    if removed is None:
        return {"status": "not_found", "message": f"No meal matching '{meal_name}' found in today's log."}

    log_ref.set({"meals": kept}, merge=True)
    calories_now = sum(m.get("calories", 0) for m in kept)
    return {
        "status": "deleted",
        "removed_meal": removed["name"],
        "calories_removed": removed.get("calories", 0),
        "total_calories_today": calories_now,
    }


def update_meal(
    user_id: str,
    meal_name: str,
    new_name: str = None,
    calories: int = None,
    protein_g: int = None,
    carbs_g: int = None,
    fat_g: int = None,
) -> dict:
    """
    Update fields of an already-logged meal. Only pass the fields you want to change.
    Matches the meal by name (case-insensitive, partial match on the first hit).

    Args:
        user_id: The user's unique ID.
        meal_name: Name of the meal to update.
        new_name: Rename the meal (optional).
        calories: New calorie value (optional).
        protein_g: New protein in grams (optional).
        carbs_g: New carbs in grams (optional).
        fat_g: New fat in grams (optional).

    Returns:
        Confirmation with the updated meal details.
    """
    _emit_tool_status(user_id, "Updating meal…")
    log_ref = _today_log_ref(user_id)
    today = log_ref.get().to_dict() or {}
    meals = today.get("meals", [])

    key = meal_name.lower().strip()
    updated = None
    for m in meals:
        if updated is None and key in m.get("name", "").lower():
            if new_name is not None:
                m["name"] = new_name
            if calories is not None:
                m["calories"] = calories
            if protein_g is not None:
                m["protein_g"] = protein_g
            if carbs_g is not None:
                m["carbs_g"] = carbs_g
            if fat_g is not None:
                m["fat_g"] = fat_g
            updated = m
            break

    if updated is None:
        return {"status": "not_found", "message": f"No meal matching '{meal_name}' found in today's log."}

    log_ref.set({"meals": meals}, merge=True)
    calories_now = sum(m.get("calories", 0) for m in meals)
    return {
        "status": "updated",
        "meal": updated,
        "total_calories_today": calories_now,
    }


def remove_water(user_id: str, glasses: int) -> dict:
    """
    Remove glasses of water from today's count. Floors at zero.

    Args:
        user_id: The user's unique ID.
        glasses: Number of glasses to remove.

    Returns:
        Updated total glasses for today.
    """
    _emit_tool_status(user_id, "Removing water…")
    log_ref = _today_log_ref(user_id)
    today = log_ref.get().to_dict() or {}
    current = today.get("water_glasses", 0)
    new_total = max(0, current - glasses)
    log_ref.set({"water_glasses": new_total}, merge=True)
    return {"status": "updated", "water_glasses_today": new_total}


def delete_workout(user_id: str, workout_type: str) -> dict:
    """
    Remove a logged workout from today's workout log.
    Matches by type (case-insensitive, partial match on the first hit found).

    Args:
        user_id: The user's unique ID.
        workout_type: Type or partial name of the workout to remove (e.g. "run", "yoga").

    Returns:
        Confirmation with the removed workout.
    """
    _emit_tool_status(user_id, "Removing workout…")
    log_ref = _today_log_ref(user_id)
    today = log_ref.get().to_dict() or {}
    workouts = today.get("workouts", [])

    key = workout_type.lower().strip()
    removed = None
    kept = []
    for w in workouts:
        if removed is None and key in w.get("type", "").lower():
            removed = w
        else:
            kept.append(w)

    if removed is None:
        return {"status": "not_found", "message": f"No workout matching '{workout_type}' found in today's log."}

    log_ref.set({"workouts": kept}, merge=True)
    return {
        "status": "deleted",
        "removed_workout": removed["type"],
        "calories_removed": removed.get("calories_burned", 0),
    }


# ──────────────────────────────────────────────────────────────────────────────
# WORKOUT PLAN
# ──────────────────────────────────────────────────────────────────────────────

def _workout_plan_ref(user_id: str, date_str: str):
    return _user_ref(user_id).collection("workout_plans").document(date_str)


def _meal_plan_ref(user_id: str, date_str: str):
    return _user_ref(user_id).collection("meal_plans").document(date_str)


def _tomorrow_plan_ref(user_id: str, date_str: str):
    return _user_ref(user_id).collection("tomorrow_plans").document(date_str)


def get_workout_plan(user_id: str, for_date: str = None) -> dict | None:
    """Return the saved workout plan for a given date, or None if not set."""
    date_str = for_date or datetime.now(timezone.utc).date().isoformat()
    doc = _workout_plan_ref(user_id, date_str).get()
    return doc.to_dict() if doc.exists else None


def save_workout_plan(user_id: str, plan: dict) -> dict:
    """Persist a workout plan dict to Firestore, keyed by date."""
    date_str = plan.get("date") or datetime.now(timezone.utc).date().isoformat()
    plan["date"] = date_str
    if not plan.get("id"):
        plan["id"] = str(uuid.uuid4())
    _workout_plan_ref(user_id, date_str).set(plan)
    return plan


def delete_workout_plan(user_id: str, for_date: str = None) -> dict:
    """Delete the saved workout plan for a given date (defaults to today)."""
    date_str = for_date or datetime.now(timezone.utc).date().isoformat()
    _workout_plan_ref(user_id, date_str).delete()
    return {"status": "deleted", "date": date_str}


def get_meal_plan(user_id: str, for_date: str = None) -> dict | None:
    """Return the saved meal plan for a given date, or None if not set."""
    _emit_tool_status(user_id, "Loading your meal plan…")
    date_str = for_date or datetime.now(timezone.utc).date().isoformat()
    doc = _meal_plan_ref(user_id, date_str).get()
    return doc.to_dict() if doc.exists else None


def delete_meal_plan(user_id: str, for_date: str = None) -> dict:
    """Delete the saved meal plan for a given date (defaults to today)."""
    date_str = for_date or datetime.now(timezone.utc).date().isoformat()
    _meal_plan_ref(user_id, date_str).delete()
    return {"status": "deleted", "date": date_str}


def generate_meal_plan(user_id: str, notes: str = "", for_date: str = None) -> dict:
    """
    Generate and save a personalised meal plan for a given date using Gemini.

    Args:
        user_id: The user's unique ID.
        notes: Free-text user preferences (e.g. "have eggs, chicken, oats at home").
        for_date: ISO date string (YYYY-MM-DD). Defaults to today.

    Returns:
        The generated meal plan with 4 meals (breakfast, lunch, dinner, snack),
        cook times, macros, calories, and a YouTube search query for each meal.
    """
    import json, re

    _emit_tool_status(user_id, "Building your meal plan…")

    profile        = _user_ref(user_id).get().to_dict() or {}
    goal_doc       = _goal_ref(user_id).get().to_dict() or {}
    date_str       = for_date or datetime.now(timezone.utc).date().isoformat()
    calorie_target = goal_doc.get("daily_calorie_target", profile.get("daily_calorie_target", 2000))
    protein_target = profile.get("protein_target_g", 120)
    goal_type      = goal_doc.get("goal_type", "fitness")
    goal_text      = goal_doc.get("goal", "general fitness")

    notes_block = f"\nUser preferences / available ingredients: {notes}" if notes and notes.strip() else ""

    prompt = f"""Generate a meal plan for {date_str} for someone with:
- Goal: {goal_text} ({goal_type})
- Daily calorie target: {calorie_target} kcal
- Protein target: {protein_target}g{notes_block}

Create exactly 4 meals: breakfast, lunch, dinner, snack.
Each meal must be practical and easy to cook at home.
For youtube_query: write a short specific search query (e.g. "chicken stir fry quick recipe") that would find a good cooking video on YouTube.
Total calories across all meals should be close to {calorie_target} kcal.

Return ONLY valid JSON, no markdown, no explanation:
{{
  "total_calories": {calorie_target},
  "notes": "Brief note about the plan",
  "meals": [
    {{
      "id": "UUID_PLACEHOLDER",
      "meal_type": "breakfast",
      "name": "Scrambled Eggs on Toast",
      "description": "2 scrambled eggs with 2 slices of wholegrain toast and half an avocado",
      "cook_time_min": 10,
      "calories": 420,
      "protein_g": 18,
      "carbs_g": 35,
      "fat_g": 14,
      "youtube_query": "scrambled eggs avocado toast healthy breakfast recipe",
      "logged": false
    }}
  ]
}}"""

    client    = _get_text_client()
    response  = client.models.generate_content(model="gemini-2.5-flash", contents=prompt)
    raw       = response.text.strip()
    raw       = re.sub(r"^```(?:json)?\n?", "", raw)
    raw       = re.sub(r"\n?```$", "", raw)
    plan_data = json.loads(raw)

    for meal in plan_data.get("meals", []):
        if not meal.get("id") or "PLACEHOLDER" in meal.get("id", ""):
            meal["id"] = str(uuid.uuid4())
        meal["logged"] = False

    plan_data["date"] = date_str
    plan_data["id"]   = str(uuid.uuid4())

    _meal_plan_ref(user_id, date_str).set(plan_data)
    return plan_data


def log_meal_from_plan(user_id: str, meal_id: str, for_date: str = None) -> dict:
    """
    Log a meal from the meal plan into the meal log. Marks the meal as logged so it cannot be logged again.

    Args:
        user_id: The user's unique ID.
        meal_id: The ID of the meal to log.
        for_date: ISO date string (YYYY-MM-DD). Defaults to today.
    """
    _emit_tool_status(user_id, "Logging meal…")
    date_str = for_date or datetime.now(timezone.utc).date().isoformat()
    ref      = _meal_plan_ref(user_id, date_str)
    plan     = ref.get().to_dict()
    if not plan:
        return {"status": "error", "message": "Meal plan not found"}

    meals = plan.get("meals", [])
    meal  = next((m for m in meals if m.get("id") == meal_id), None)
    if not meal:
        return {"status": "error", "message": "Meal not found"}
    if meal.get("logged"):
        return {"status": "already_logged", "message": "Meal already logged"}

    result = log_meal(
        user_id, meal["name"], meal.get("calories", 0),
        meal.get("protein_g", 0), meal.get("carbs_g", 0), meal.get("fat_g", 0)
    )

    for m in meals:
        if m.get("id") == meal_id:
            m["logged"] = True
            break
    ref.update({"meals": meals})

    return {**result, "meal_name": meal["name"]}


def generate_workout_plan(user_id: str, notes: str = "", for_date: str = None) -> dict:
    """
    Generate and save a personalised workout plan for a given date using Gemini.
    Reads the user's goal, body weight, and remaining calories from Firestore.
    Returns the saved plan dict.

    Args:
        user_id: The user's unique ID.
        notes: Optional free-text preferences from the user (e.g. "home workout, focus on legs").
        for_date: ISO date string (YYYY-MM-DD). Defaults to today.

    Returns:
        The generated workout plan with exercises, sets/reps or duration, and calories per exercise.
    """
    import json, re

    _emit_tool_status(user_id, "Building your workout plan…")

    profile  = _user_ref(user_id).get().to_dict() or {}
    goal_doc = _goal_ref(user_id).get().to_dict() or {}
    date_str = for_date or datetime.now(timezone.utc).date().isoformat()
    log      = _user_ref(user_id).collection("logs").document(date_str).get().to_dict() or {}

    calorie_target     = goal_doc.get("daily_calorie_target", profile.get("daily_calorie_target", 2000))
    weight_kg          = float(profile.get("weight_kg", 75.0))
    goal_type          = goal_doc.get("goal_type", "fitness")
    direction          = goal_doc.get("direction", "")
    goal_text          = goal_doc.get("goal", "general fitness")
    calories_consumed  = sum(m.get("calories", 0) for m in log.get("meals", []))
    calories_remaining = max(0, calorie_target - calories_consumed)

    notes_block = f"\n- User preferences / recent history: {notes}" if notes and notes.strip() else ""

    prompt = f"""Generate a workout plan for today for someone with:
- Goal: {goal_text} ({goal_type}, direction: {direction})
- Body weight: {weight_kg} kg
- Calories remaining today: {calories_remaining} kcal{notes_block}

Rules:
- 3-6 exercises total.
- Strength exercises: include sets, reps. Set duration_min to null.
- Cardio exercises: include duration_min. Set sets, reps, weight_kg to null.
- calories_burned: estimate per exercise using MET * {weight_kg}kg * (duration/60). For strength use time under tension estimate.
- target_muscles: comma-separated primary muscles (e.g. "chest, triceps, anterior deltoid").
- Total workout 30-60 minutes.
- Match goal: weight_loss = cardio + light strength; weight_gain = strength focus; fitness = mixed.

Return ONLY valid JSON, no markdown, no explanation:
{{
  "name": "Upper Body Strength",
  "total_duration_min": 45,
  "exercises": [
    {{
      "id": "UUID_PLACEHOLDER",
      "name": "Bench Press",
      "type": "strength",
      "sets": 3,
      "reps": 10,
      "weight_kg": 0,
      "duration_min": null,
      "calories_burned": 45,
      "target_muscles": "chest, triceps, anterior deltoid"
    }},
    {{
      "id": "UUID_PLACEHOLDER",
      "name": "Cycling",
      "type": "cardio",
      "sets": null,
      "reps": null,
      "weight_kg": null,
      "duration_min": 20,
      "calories_burned": 150,
      "target_muscles": "quadriceps, glutes, cardiovascular"
    }}
  ]
}}"""

    client   = _get_text_client()
    response = client.models.generate_content(model="gemini-2.5-flash", contents=prompt)
    raw      = response.text.strip()
    raw      = re.sub(r"^```(?:json)?\n?", "", raw)
    raw      = re.sub(r"\n?```$", "", raw)
    plan_data = json.loads(raw)

    for ex in plan_data.get("exercises", []):
        if not ex.get("id") or "PLACEHOLDER" in ex.get("id", ""):
            ex["id"] = str(uuid.uuid4())
        ex.setdefault("logged", False)

    plan_data["date"] = date_str
    plan_data["id"]   = str(uuid.uuid4())

    return save_workout_plan(user_id, plan_data)


def toggle_exercise_complete(user_id: str, exercise_id: str, for_date: str = None) -> dict:
    """Toggle the completed flag on a planned exercise (does not log the workout)."""
    _emit_tool_status(user_id, "Updating exercise…")
    date_str = for_date or datetime.now(timezone.utc).date().isoformat()
    ref      = _workout_plan_ref(user_id, date_str)
    plan     = ref.get().to_dict()
    if not plan:
        return {"status": "error", "message": "Plan not found"}
    exercises = plan.get("exercises", [])
    for ex in exercises:
        if ex.get("id") == exercise_id:
            ex["completed"] = not ex.get("completed", False)
            break
    ref.update({"exercises": exercises})
    return {"status": "ok", "exercises": exercises}


def log_exercise_from_plan(user_id: str, exercise_id: str, for_date: str = None, calories_override: int = None) -> dict:
    """Log a completed exercise from the workout plan into the workout log."""
    _emit_tool_status(user_id, "Logging exercise…")
    date_str = for_date or datetime.now(timezone.utc).date().isoformat()
    ref      = _workout_plan_ref(user_id, date_str)
    plan     = get_workout_plan(user_id, date_str)
    if not plan:
        return {"status": "error", "message": "Plan not found"}
    exercise = next((e for e in plan.get("exercises", []) if e.get("id") == exercise_id), None)
    if not exercise:
        return {"status": "error", "message": "Exercise not found"}
    if exercise.get("logged"):
        return {"status": "already_logged", "message": "Exercise already logged"}

    calories = calories_override if calories_override is not None else exercise.get("calories_burned", 0)
    duration = exercise.get("duration_min") or 0
    if not duration and exercise.get("sets"):
        duration = max(10, exercise.get("sets", 3) * 3)

    result = log_workout(user_id, exercise["name"], duration or 30, calories)

    # Mark as logged in the plan
    exercises = plan.get("exercises", [])
    for ex in exercises:
        if ex.get("id") == exercise_id:
            ex["logged"] = True
            break
    ref.update({"exercises": exercises})

    return result


# ──────────────────────────────────────────────────────────────────────────────
# EXERCISE VIDEO (Veo 2)
# ──────────────────────────────────────────────────────────────────────────────

def _generate_coaching_script(exercise_name: str, target_muscles: str = "") -> str:
    """Generate a real-life personal trainer coaching script for an exercise."""
    muscles_line = f"Primary muscles: {target_muscles}. " if target_muscles else ""
    prompt = (
        f"You are an experienced personal trainer recording a short coaching voiceover for a {exercise_name} demonstration video. "
        f"{muscles_line}"
        f"Write exactly what you would say out loud while the athlete performs the movement — "
        f"real coaching cues a trainer uses in a gym, not textbook descriptions. "
        f"Include: body position setup, the key movement feel (e.g. 'drive through your heels', 'chest to bar', 'brace your core'), "
        f"and one breath cue naturally woven in. "
        f"Sound like a real coach — direct, confident, encouraging. 28-35 words. "
        f"No intro phrases like 'Alright' or 'Let's go'. Start straight with the cue."
    )
    from google.genai import types as genai_types

    # Disable safety filters — fitness coaching uses legitimate anatomical terms
    # (glutes, chest, groin stretch, etc.) that can trip content filters.
    safety_off = [
        genai_types.SafetySetting(category=c, threshold="OFF")
        for c in [
            "HARM_CATEGORY_HARASSMENT",
            "HARM_CATEGORY_HATE_SPEECH",
            "HARM_CATEGORY_SEXUALLY_EXPLICIT",
            "HARM_CATEGORY_DANGEROUS_CONTENT",
        ]
    ]

    client = _get_text_client()
    response = client.models.generate_content(
        model="gemini-2.5-flash",
        contents=prompt,
        config=genai_types.GenerateContentConfig(safety_settings=safety_off),
    )
    return response.text.strip()


def _add_coaching_audio(video_bytes: bytes, script: str) -> bytes:
    """
    Mux a pre-generated coaching script into the video using Rena's fixed voice.
    Always uses en-US-Neural2-F (Rena's voice) regardless of trainer gender in the video.
    """
    import subprocess, tempfile, os as _os
    from google.cloud import texttospeech

    # Rena always speaks — fixed voice, not tied to video trainer gender
    tts_client      = texttospeech.TextToSpeechClient()
    synthesis_input = texttospeech.SynthesisInput(text=script)
    voice = texttospeech.VoiceSelectionParams(language_code="en-US", name="en-US-Neural2-F")
    audio_config = texttospeech.AudioConfig(
        audio_encoding=texttospeech.AudioEncoding.MP3,
        speaking_rate=0.95,
    )
    tts_response = tts_client.synthesize_speech(
        input=synthesis_input, voice=voice, audio_config=audio_config
    )
    audio_bytes = tts_response.audio_content

    with tempfile.TemporaryDirectory() as tmpdir:
        video_path  = _os.path.join(tmpdir, "video.mp4")
        audio_path  = _os.path.join(tmpdir, "audio.mp3")
        output_path = _os.path.join(tmpdir, "output.mp4")

        with open(video_path, "wb") as f:
            f.write(video_bytes)
        with open(audio_path, "wb") as f:
            f.write(audio_bytes)

        subprocess.run(
            ["ffmpeg", "-y", "-i", video_path, "-i", audio_path,
             "-c:v", "copy", "-c:a", "aac", "-shortest", output_path],
            check=True, capture_output=True,
        )

        with open(output_path, "rb") as f:
            return f.read()


def _veo_prompt(exercise_name: str, target_muscles: str = "", gender: str = "female", script: str = "") -> str:
    muscles_hint = f", engaging {target_muscles}" if target_muscles else ""
    muscles_visual = (
        f" Clearly show the {target_muscles} being activated — camera angle and lighting should highlight the muscle engagement."
        if target_muscles else ""
    )
    script_direction = (
        f" The trainer's movement sequence: {script}"
        if script else ""
    )
    return (
        f"A {gender} certified personal trainer demonstrating perfect form for {exercise_name}{muscles_hint}. "
        f"Full body visible from a 45-degree angle, clear coaching perspective showing correct technique, "
        f"posture, and muscle engagement.{muscles_visual}{script_direction} "
        f"Clean gym background. Professional fitness coaching video. "
        f"No text, subtitles, captions, or overlays on screen."
    )


def get_exercise_video(exercise_name: str, target_muscles: str = "") -> dict:
    """
    Return a cached video URL for an exercise, or start a Veo 2 generation job.

    Returns:
        {"status": "ready", "video_url": "..."} if cached.
        {"status": "generating", "job_id": "..."} if job started or already running.
    """
    import re

    slug         = re.sub(r"[^a-z0-9]+", "_", exercise_name.lower()).strip("_")
    bucket_name  = os.getenv("GCS_BUCKET", "rena-assets")
    gcs_client   = storage.Client(project=os.getenv("GOOGLE_CLOUD_PROJECT"))
    bucket       = gcs_client.bucket(bucket_name)
    blob_path    = f"exercise_videos/{slug}.mp4"
    blob         = bucket.blob(blob_path)

    if blob.exists():
        blob.make_public()
        return {"status": "ready", "video_url": f"https://storage.googleapis.com/{bucket_name}/{blob_path}"}

    # Return existing pending job for the same exercise (skip if stale > 10 min)
    jobs_ref = db.collection("exercise_video_jobs")
    for job_doc in jobs_ref.where(filter=firestore.FieldFilter("slug", "==", slug)).where(filter=firestore.FieldFilter("status", "==", "generating")).limit(1).stream():
        created = job_doc.to_dict().get("created_at")
        if created and (datetime.now(timezone.utc) - created).total_seconds() > 600:
            job_doc.reference.update({"status": "error", "error": "Timed out"})
            break  # stale — fall through to submit a new job
        return {"status": "generating", "job_id": job_doc.id}

    # Submit new Veo 2 job
    try:
        import random
        client = _get_genai_client()

        # 1. Generate coaching script first — video movements will follow it
        script = _generate_coaching_script(exercise_name, target_muscles)

        # 2. Randomly pick trainer gender for the video
        gender = random.choice(["male", "female"])

        # 3. Build Veo prompt informed by the script
        prompt = _veo_prompt(exercise_name, target_muscles, gender=gender, script=script)

        operation = client.models.generate_videos(
            model="veo-2.0-generate-001",
            prompt=prompt,
            config={"aspect_ratio": "9:16", "duration_seconds": 8},
        )

        # generate_videos may return an operation object or the name string directly
        op_name = operation if isinstance(operation, str) else operation.name

        job_id = str(uuid.uuid4())
        jobs_ref.document(job_id).set({
            "slug":           slug,
            "exercise_name":  exercise_name,
            "target_muscles": target_muscles,
            "script":         script,
            "trainer_gender": gender,
            "operation_name": op_name,
            "status":         "generating",
            "attempt":        0,
            "created_at":     firestore.SERVER_TIMESTAMP,
        })

        return {"status": "generating", "job_id": job_id}

    except Exception as e:
        return {"status": "error", "message": str(e)}


def get_exercise_video_status(job_id: str) -> dict:
    """
    Poll the status of a Veo 2 video generation job.

    Returns:
        {"status": "generating"} | {"status": "done", "video_url": "..."} | {"status": "error", ...}
    """
    job_doc = db.collection("exercise_video_jobs").document(job_id).get()
    if not job_doc.exists:
        return {"status": "error", "message": "Job not found"}

    job         = job_doc.to_dict()
    slug        = job["slug"]
    bucket_name = os.getenv("GCS_BUCKET", "rena-assets")

    # Expire jobs stuck in "generating" for more than 10 minutes
    if job["status"] == "generating":
        created = job.get("created_at")
        if created and (datetime.now(timezone.utc) - created).total_seconds() > 600:
            db.collection("exercise_video_jobs").document(job_id).update({"status": "error", "error": "Timed out"})
            return {"status": "error", "message": "Video generation timed out. Please try again."}

    if job["status"] == "done":
        return {"status": "done", "video_url": f"https://storage.googleapis.com/{bucket_name}/exercise_videos/{slug}.mp4"}
    if job["status"] == "error":
        return {"status": "error", "message": job.get("error", "Generation failed")}

    try:
        from google.genai import types as genai_types
        client    = _get_genai_client()
        # Reconstruct GenerateVideosOperation from stored name string
        operation = client.operations.get(
            genai_types.GenerateVideosOperation(name=job["operation_name"])
        )

        if not operation.done:
            return {"status": "generating"}

        # Veo returns inline video_bytes (not a GCS URI)
        video_bytes = operation.response.generated_videos[0].video.video_bytes

        # Mux Rena's coaching voiceover using the pre-generated script
        try:
            script = job.get("script") or _generate_coaching_script(
                job["exercise_name"], job.get("target_muscles", "")
            )
            video_bytes = _add_coaching_audio(video_bytes, script)
        except Exception:
            pass  # upload silent video if audio mux fails

        gcs_client  = storage.Client(project=os.getenv("GOOGLE_CLOUD_PROJECT"))
        dest_bucket = gcs_client.bucket(bucket_name)
        dest_blob   = dest_bucket.blob(f"exercise_videos/{slug}.mp4")
        dest_blob.upload_from_string(video_bytes, content_type="video/mp4")
        dest_blob.make_public()

        video_url = f"https://storage.googleapis.com/{bucket_name}/exercise_videos/{slug}.mp4"
        db.collection("exercise_video_jobs").document(job_id).update({"status": "done", "video_url": video_url})

        return {"status": "done", "video_url": video_url}

    except Exception as e:
        db.collection("exercise_video_jobs").document(job_id).update({"status": "error", "error": str(e)})
        return {"status": "error", "message": str(e)}


# ── Session memory ────────────────────────────────────────────────────────────

def save_session_note(user_id: str, context: str, note: str) -> dict:
    """Save a brief summary of what happened in a voice session."""
    _user_ref(user_id).collection("session_notes").add({
        "context": context,
        "note": note,
        "created_at": firestore.SERVER_TIMESTAMP,
    })
    return {"status": "saved"}


def get_session_notes(user_id: str, limit: int = 4) -> list:
    """Return the most recent session notes, newest first."""
    docs = (
        _user_ref(user_id).collection("session_notes")
        .order_by("created_at", direction=firestore.Query.DESCENDING)
        .limit(limit)
        .stream()
    )
    return [
        {"note": d.to_dict().get("note", ""), "context": d.to_dict().get("context", "")}
        for d in docs
    ]


def get_rich_context(user_id: str) -> dict:
    """
    Assemble a snapshot of the user's current state for context injection.
    Returns today's progress, recent workout summary, goal, and session notes.
    """
    from datetime import timedelta
    today = datetime.now(timezone.utc).date()

    # Today's progress
    progress = get_progress(user_id)

    # Weight trend: last 7 days
    weight_entries = []
    for i in range(7):
        d = (today - timedelta(days=i)).isoformat()
        doc = _user_ref(user_id).collection("logs").document(d).get()
        if doc.exists:
            w = (doc.to_dict() or {}).get("weight_kg")
            if w:
                weight_entries.append({"date": d, "weight_kg": w})

    # Recent workouts summary
    recent = get_recent_workouts(user_id, days=7)

    # Session notes
    notes = get_session_notes(user_id, limit=4)

    return {
        "progress": progress,
        "weight_trend": weight_entries,
        "workout_summary": recent.get("summary", ""),
        "session_notes": notes,
    }


def get_tomorrow_plan(user_id: str, for_date: str = None) -> dict | None:
    """Return the saved tomorrow-plan note for a given date, or None if not set."""
    from datetime import timedelta
    date_str = for_date or (datetime.now(timezone.utc).date() + timedelta(days=1)).isoformat()
    doc = _tomorrow_plan_ref(user_id, date_str).get()
    return doc.to_dict() if doc.exists else None


def save_tomorrow_plan_note(
    user_id: str,
    summary: str,
    for_date: str = None,
) -> dict:
    """
    Save (or update) a summary of the plan_tomorrow session so it can be used
    as a morning nudge. Call this at the END of every plan_tomorrow conversation
    regardless of whether any plans were generated.

    Args:
        user_id: The user's unique ID.
        summary: 1–2 sentence description of what was discussed and planned.
        for_date: The date the plan is for (ISO string). Defaults to tomorrow.
    """
    _emit_tool_status(user_id, "Saving your plan…")
    from datetime import timedelta
    date_str = for_date or (datetime.now(timezone.utc).date() + timedelta(days=1)).isoformat()
    ref = _tomorrow_plan_ref(user_id, date_str)
    existing = (ref.get().to_dict() or {})
    now = datetime.now(timezone.utc)
    data = {
        **existing,
        "summary": summary,
        "date": date_str,
        "updated_at": now,
    }
    if "created_at" not in existing:
        data["created_at"] = now
    ref.set(data)
    # Invalidate today's morning-nudge cache so it reflects the new plan
    today = datetime.now(timezone.utc).date().isoformat()
    _user_ref(user_id).collection("morning_nudges").document(today).delete()
    return {"saved": True, "date": date_str}


def delete_tomorrow_plan_note(user_id: str, for_date: str = None) -> dict:
    """Delete the tomorrow-plan note for a given date."""
    from datetime import timedelta
    date_str = for_date or (datetime.now(timezone.utc).date() + timedelta(days=1)).isoformat()
    _tomorrow_plan_ref(user_id, date_str).delete()
    return {"deleted": True, "date": date_str}


def get_morning_nudge(user_id: str) -> dict:
    """
    Look for a recent plan_tomorrow session note (within ~18 hours) and generate
    a short motivational focus message for the day. Cached once per day in Firestore.
    Returns {"has_nudge": bool, "nudge": str}.
    """
    from datetime import timedelta

    today = datetime.now(timezone.utc).date().isoformat()

    # Return cached nudge if already generated today
    cache_ref = _user_ref(user_id).collection("morning_nudges").document(today)
    cached = cache_ref.get().to_dict()
    if cached:
        return {"has_nudge": True, "nudge": cached["nudge"]}

    # Prefer the dedicated tomorrow_plan summary for today
    tp = _tomorrow_plan_ref(user_id, today).get().to_dict()
    note_text = (tp or {}).get("summary", "")

    if not note_text:
        # Fall back: look for a recent plan_tomorrow session note (within 18 hours)
        cutoff = datetime.now(timezone.utc) - timedelta(hours=18)
        docs = (
            _user_ref(user_id).collection("session_notes")
            .order_by("created_at", direction=firestore.Query.DESCENDING)
            .limit(10)
            .stream()
        )
        for doc in docs:
            d = doc.to_dict()
            if d.get("context") != "plan_tomorrow":
                continue
            created_at = d.get("created_at")
            if created_at and created_at > cutoff:
                note_text = d.get("note", "")
                break

    if not note_text:
        return {"has_nudge": False, "nudge": ""}

    prompt = (
        "You are Rena, a warm health companion. Based on what the user planned yesterday: "
        f"'{note_text}' — write ONE short, warm, motivational sentence (max 20 words) "
        "as a focus message for today. Start with 'Today,' or 'Remember,'. No markdown, no quotes."
    )
    client = _get_text_client()
    resp = client.models.generate_content(model="gemini-2.0-flash", contents=prompt)
    nudge = resp.text.strip()

    cache_ref.set({"nudge": nudge, "generated_at": firestore.SERVER_TIMESTAMP})
    return {"has_nudge": True, "nudge": nudge}


def reset_user(user_id: str) -> dict:
    """
    DEV ONLY — delete all Firestore data for a user so onboarding can be re-tested.
    Deletes the user profile document and all subcollections (logs, progress, visual_journey).
    """
    def delete_collection(col_ref, batch_size=50):
        docs = col_ref.limit(batch_size).stream()
        deleted = 0
        for doc in docs:
            doc.reference.delete()
            deleted += 1
        if deleted >= batch_size:
            delete_collection(col_ref, batch_size)

    user_ref = _user_ref(user_id)
    for sub in ["logs", "progress", "visual_journey", "workout_plans", "session_notes"]:
        delete_collection(user_ref.collection(sub))
    user_ref.delete()

    # Also delete goals doc
    _goal_ref(user_id).delete()

    return {"status": "reset", "user_id": user_id}

import base64
import os
import uuid
from datetime import date, datetime, timezone

from google import genai
from google.cloud import firestore, storage

db = firestore.Client(project=os.getenv("GOOGLE_CLOUD_PROJECT"))

_genai_client = None

def _get_genai_client():
    global _genai_client
    if _genai_client is None:
        _genai_client = genai.Client(
            vertexai=True,
            project=os.getenv("GOOGLE_CLOUD_PROJECT"),
            location=os.getenv("GOOGLE_CLOUD_LOCATION", "us-central1"),
        )
    return _genai_client


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
            "image_url": None,
            "daily_calorie_target": 1800,
            "days_until_goal": 0,
        }

    # Lazily generate image if missing
    if not goal_doc.get("image_url"):
        goal_text = goal_doc.get("goal", "")
        try:
            client = _get_genai_client()
            from google.genai import types as genai_types

            prompt = (
                f'Create a fun, vibrant, bold sticker-style illustration for this health goal: "{goal_text}"\n'
                "Style: colorful, playful, exciting, motivational. Like a phone wallpaper or app icon.\n"
                "Square composition. No text or words. High energy colors."
            )

            response = client.models.generate_content(
                model="gemini-2.5-flash-image",
                contents=prompt,
                config=genai_types.GenerateContentConfig(
                    response_modalities=["IMAGE", "TEXT"]
                ),
            )

            image_data = None
            for part in response.candidates[0].content.parts:
                if part.inline_data:
                    image_data = part.inline_data.data
                    break

            if image_data:
                bucket_name = os.getenv("GCS_BUCKET", "rena-assets")
                storage_client = storage.Client(project=os.getenv("GOOGLE_CLOUD_PROJECT"))
                bucket = storage_client.bucket(bucket_name)

                blob = bucket.blob(f"goals/{user_id}/goal_icon.jpg")
                blob.upload_from_string(image_data, content_type="image/jpeg")
                image_url = f"https://storage.googleapis.com/{bucket_name}/goals/{user_id}/goal_icon.jpg"

                _goal_ref(user_id).set({"image_url": image_url}, merge=True)
                goal_doc["image_url"] = image_url
        except Exception:
            pass  # image generation is best-effort

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
        "image_url": goal_doc.get("image_url"),
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

    client = _get_genai_client()
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
        client = _get_genai_client()
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
        print(f"[_estimate_macros] failed for '{meal_name}': {e}")
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
    client = _get_genai_client()
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
        print(f"[scan_image] JSON parse failed, raw response:\n{raw}")
        match = re.search(r"\{[\s\S]*\}", raw)
        if match:
            try:
                result = json.loads(match.group())
            except json.JSONDecodeError:
                print("[scan_image] Fallback JSON parse also failed")
                return {"identified": False}
        else:
            return {"identified": False}

    result["user_id"] = user_id
    print(f"[scan_image] identified={result.get('identified')} items={len(result.get('items') or [])} total_cal={result.get('total_calories')}")
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
    _today_log_ref(user_id).set({"weight_kg": weight_kg}, merge=True)
    return {"status": "logged", "weight_kg": weight_kg}


# ──────────────────────────────────────────────────────────────────────────────
# WORKOUT PLAN
# ──────────────────────────────────────────────────────────────────────────────

def _workout_plan_ref(user_id: str, date_str: str):
    return _user_ref(user_id).collection("workout_plans").document(date_str)


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


def generate_workout_plan(user_id: str) -> dict:
    """
    Generate and save a personalised workout plan for today using Gemini.
    Reads the user's goal, body weight, and remaining calories from Firestore.
    Returns the saved plan dict.

    Args:
        user_id: The user's unique ID.

    Returns:
        The generated workout plan with exercises, sets/reps or duration, and calories per exercise.
    """
    import json, re

    profile  = _user_ref(user_id).get().to_dict() or {}
    goal_doc = _goal_ref(user_id).get().to_dict() or {}
    today    = datetime.now(timezone.utc).date().isoformat()
    log      = _user_ref(user_id).collection("logs").document(today).get().to_dict() or {}

    calorie_target     = goal_doc.get("daily_calorie_target", profile.get("daily_calorie_target", 2000))
    weight_kg          = float(profile.get("weight_kg", 75.0))
    goal_type          = goal_doc.get("goal_type", "fitness")
    direction          = goal_doc.get("direction", "")
    goal_text          = goal_doc.get("goal", "general fitness")
    calories_consumed  = sum(m.get("calories", 0) for m in log.get("meals", []))
    calories_remaining = max(0, calorie_target - calories_consumed)

    prompt = f"""Generate a workout plan for today for someone with:
- Goal: {goal_text} ({goal_type}, direction: {direction})
- Body weight: {weight_kg} kg
- Calories remaining today: {calories_remaining} kcal

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

    client   = _get_genai_client()
    response = client.models.generate_content(model="gemini-2.5-flash", contents=prompt)
    raw      = response.text.strip()
    raw      = re.sub(r"^```(?:json)?\n?", "", raw)
    raw      = re.sub(r"\n?```$", "", raw)
    plan_data = json.loads(raw)

    for ex in plan_data.get("exercises", []):
        if not ex.get("id") or "PLACEHOLDER" in ex.get("id", ""):
            ex["id"] = str(uuid.uuid4())

    plan_data["date"] = today
    plan_data["id"]   = str(uuid.uuid4())

    return save_workout_plan(user_id, plan_data)


def toggle_exercise_complete(user_id: str, exercise_id: str, for_date: str = None) -> dict:
    """Toggle the completed flag on a planned exercise (does not log the workout)."""
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
    date_str = for_date or datetime.now(timezone.utc).date().isoformat()
    plan     = get_workout_plan(user_id, date_str)
    if not plan:
        return {"status": "error", "message": "Plan not found"}
    exercise = next((e for e in plan.get("exercises", []) if e.get("id") == exercise_id), None)
    if not exercise:
        return {"status": "error", "message": "Exercise not found"}

    calories = calories_override if calories_override is not None else exercise.get("calories_burned", 0)
    duration = exercise.get("duration_min") or 0
    if not duration and exercise.get("sets"):
        # Rough estimate: 3 min per set for strength
        duration = max(10, exercise.get("sets", 3) * 3)

    return log_workout(user_id, exercise["name"], duration or 30, calories)


# ──────────────────────────────────────────────────────────────────────────────
# EXERCISE VIDEO (Veo 2)
# ──────────────────────────────────────────────────────────────────────────────

def _detect_trainer_gender(video_bytes: bytes) -> str:
    """Extract a frame from the video and use Gemini Vision to detect trainer gender."""
    import subprocess, tempfile, os as _os, base64
    from google.genai import types as genai_types

    try:
        with tempfile.TemporaryDirectory() as tmpdir:
            video_path = _os.path.join(tmpdir, "video.mp4")
            frame_path = _os.path.join(tmpdir, "frame.jpg")
            with open(video_path, "wb") as f:
                f.write(video_bytes)
            # Extract frame at 1 second
            subprocess.run(
                ["ffmpeg", "-y", "-ss", "1", "-i", video_path, "-frames:v", "1", frame_path],
                check=True, capture_output=True,
            )
            with open(frame_path, "rb") as f:
                frame_bytes = f.read()

        client = _get_genai_client()
        response = client.models.generate_content(
            model="gemini-2.5-flash",
            contents=[
                genai_types.Part.from_bytes(data=frame_bytes, mime_type="image/jpeg"),
                "Is the fitness trainer in this image male or female? Reply with only one word: male or female.",
            ],
        )
        gender = response.text.strip().lower()
        print(f"[tts] detected trainer gender: {gender}")
        return gender if gender in ("male", "female") else "male"
    except Exception as e:
        print(f"[tts] gender detection failed: {e}")
        return "male"


def _add_coaching_audio(video_bytes: bytes, exercise_name: str, target_muscles: str = "") -> bytes:
    """
    Generate a short coaching voiceover for an exercise and mux it into the video.
    Detects trainer gender from the video and matches the TTS voice accordingly.
    Falls back to returning the original silent video if anything fails.
    """
    import subprocess, tempfile, os as _os
    from google.cloud import texttospeech

    # 1. Detect trainer gender to match voice
    gender = _detect_trainer_gender(video_bytes)
    # Neural2 voices: D/J = male, F/H = female
    tts_voice_name = "en-US-Neural2-D" if gender == "male" else "en-US-Neural2-F"

    # 2. Generate coaching script (~8s spoken = ~30 words)
    muscles_focus = (
        f"You are working your {target_muscles}. Mention them by name in the cues so the athlete knows what to feel. "
        if target_muscles else ""
    )
    prompt = (
        f"Write an 8-second coaching voiceover script for a fitness video demonstrating {exercise_name}. "
        f"{muscles_focus}"
        f"Cover: starting position, 1-2 key movement cues, one breathing tip. "
        f"Natural, encouraging tone. Exactly 28-35 words. No intro like 'Here we go'. Just the cues."
    )
    client   = _get_genai_client()
    response = client.models.generate_content(model="gemini-2.5-flash", contents=prompt)
    script   = response.text.strip()
    print(f"[tts] voice={tts_voice_name} script for '{exercise_name}': {script}")

    # 3. TTS → MP3
    tts_client      = texttospeech.TextToSpeechClient()
    synthesis_input = texttospeech.SynthesisInput(text=script)
    voice = texttospeech.VoiceSelectionParams(
        language_code="en-US",
        name=tts_voice_name,
    )
    audio_config = texttospeech.AudioConfig(
        audio_encoding=texttospeech.AudioEncoding.MP3,
        speaking_rate=0.95,
    )
    tts_response = tts_client.synthesize_speech(
        input=synthesis_input, voice=voice, audio_config=audio_config
    )
    audio_bytes = tts_response.audio_content

    # 3. Mux video + audio with ffmpeg
    with tempfile.TemporaryDirectory() as tmpdir:
        video_path  = _os.path.join(tmpdir, "video.mp4")
        audio_path  = _os.path.join(tmpdir, "audio.mp3")
        output_path = _os.path.join(tmpdir, "output.mp4")

        with open(video_path, "wb") as f:
            f.write(video_bytes)
        with open(audio_path, "wb") as f:
            f.write(audio_bytes)

        subprocess.run(
            [
                "ffmpeg", "-y",
                "-i", video_path,
                "-i", audio_path,
                "-c:v", "copy",
                "-c:a", "aac",
                "-shortest",
                output_path,
            ],
            check=True,
            capture_output=True,
        )

        with open(output_path, "rb") as f:
            return f.read()


def _critique_exercise_video(video_bytes: bytes, exercise_name: str, target_muscles: str = "") -> tuple:
    """
    Use Gemini Vision to check if a generated exercise video matches the intended exercise
    and visually works the expected target muscles.
    Returns (is_acceptable: bool, reason: str).
    """
    import subprocess, tempfile, os as _os
    from google.genai import types as genai_types

    try:
        with tempfile.TemporaryDirectory() as tmpdir:
            video_path = _os.path.join(tmpdir, "video.mp4")
            with open(video_path, "wb") as f:
                f.write(video_bytes)

            frame_bytes_list = []
            for t in [1, 3, 5]:
                frame_path = _os.path.join(tmpdir, f"frame_{t}.jpg")
                result = subprocess.run(
                    ["ffmpeg", "-y", "-ss", str(t), "-i", video_path, "-frames:v", "1", frame_path],
                    capture_output=True,
                )
                if result.returncode == 0 and _os.path.exists(frame_path):
                    with open(frame_path, "rb") as fp:
                        frame_bytes_list.append(fp.read())

        if not frame_bytes_list:
            print("[critic] could not extract frames, accepting video")
            return True, ""

        muscles_clause = (
            f"(2) the movement clearly engages the {target_muscles} — if the body position makes it "
            f"impossible to work those muscles, fail it, "
            if target_muscles else ""
        )

        client = _get_genai_client()
        parts = [genai_types.Part.from_bytes(data=fb, mime_type="image/jpeg") for fb in frame_bytes_list]
        parts.append(
            f"These frames are from a fitness coaching video intended to show '{exercise_name}'"
            + (f" targeting {target_muscles}" if target_muscles else "") + ". "
            "Evaluate whether this video is acceptable. Fail it if: "
            "(1) the person is clearly performing a completely different exercise or the movement is wrong, "
            + muscles_clause +
            "(3) there are severe AI glitches like fully distorted limbs or an impossible body shape. "
            "Minor imperfections are fine — only fail on clear, obvious problems. "
            "Reply with exactly PASS if acceptable, or FAIL: <brief one-line reason> if not."
        )

        response = client.models.generate_content(model="gemini-2.5-flash", contents=parts)
        result_text = response.text.strip()
        print(f"[critic] '{exercise_name}': {result_text}")

        if result_text.upper().startswith("PASS"):
            return True, ""
        reason = result_text[5:].strip() if result_text.upper().startswith("FAIL") else result_text
        return False, reason

    except Exception as e:
        print(f"[critic] critique failed (accepting): {e}")
        return True, ""


def _veo_prompt(exercise_name: str, target_muscles: str = "") -> str:
    muscles_hint = f", engaging {target_muscles}" if target_muscles else ""
    muscles_visual = (
        f" Clearly show the {target_muscles} being activated — camera angle and lighting should make "
        f"the muscle engagement visible."
        if target_muscles else ""
    )
    return (
        f"A certified personal trainer demonstrating perfect form for {exercise_name}{muscles_hint}. "
        f"Full body visible from a 45-degree angle, clear coaching perspective showing correct technique, "
        f"posture, and muscle engagement.{muscles_visual} "
        f"Clean gym background. Professional fitness coaching video."
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

    # Return existing pending job for the same exercise
    jobs_ref = db.collection("exercise_video_jobs")
    for job_doc in jobs_ref.where(filter=firestore.FieldFilter("slug", "==", slug)).where(filter=firestore.FieldFilter("status", "==", "generating")).limit(1).stream():
        return {"status": "generating", "job_id": job_doc.id}

    # Submit new Veo 2 job
    try:
        client = _get_genai_client()
        prompt = _veo_prompt(exercise_name, target_muscles)

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
            "operation_name": op_name,
            "status":         "generating",
            "attempt":        0,
            "created_at":     firestore.SERVER_TIMESTAMP,
        })

        print(f"[veo] started job {job_id} for '{exercise_name}' op={op_name}")
        return {"status": "generating", "job_id": job_id}

    except Exception as e:
        print(f"[veo] failed to start job for '{exercise_name}': {e}")
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

        # Critic layer — reject videos that show wrong exercise or fail to work target muscles
        attempt = job.get("attempt", 0)
        is_ok, reason = _critique_exercise_video(video_bytes, job["exercise_name"], job.get("target_muscles", ""))
        if not is_ok and attempt < 3:
            print(f"[critic] rejected (attempt {attempt}): {reason} — submitting new Veo job")
            new_prompt = _veo_prompt(job["exercise_name"], job.get("target_muscles", ""))
            new_op = client.models.generate_videos(
                model="veo-2.0-generate-001",
                prompt=new_prompt,
                config={"aspect_ratio": "9:16", "duration_seconds": 8},
            )
            new_op_name = new_op if isinstance(new_op, str) else new_op.name
            db.collection("exercise_video_jobs").document(job_id).update({
                "operation_name": new_op_name,
                "attempt":        attempt + 1,
                "status":         "generating",
                "last_rejection": reason,
            })
            return {"status": "generating"}

        if not is_ok:
            print(f"[critic] max attempts reached for '{job['exercise_name']}', using last video")

        # Generate coaching voiceover and mux into video
        try:
            video_bytes = _add_coaching_audio(
                video_bytes, job["exercise_name"], job.get("target_muscles", "")
            )
        except Exception as e:
            print(f"[veo] audio mux failed (uploading silent video): {e}")

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
    for sub in ["logs", "progress", "visual_journey", "workout_plans"]:
        delete_collection(user_ref.collection(sub))
    user_ref.delete()

    # Also delete goals doc
    _goal_ref(user_id).delete()

    return {"status": "reset", "user_id": user_id}

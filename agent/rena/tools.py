import base64
import os
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
                bucket_name = os.getenv("GCS_BUCKET", "rena-visual-journey")
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
    """Seed 7 days of realistic test data for UI testing."""
    from datetime import timedelta
    import random

    meals_by_day = [
        [("Oatmeal with berries", 320, 12, 54, 6), ("Grilled chicken salad", 480, 42, 20, 14), ("Dal and rice", 620, 22, 98, 8)],
        [("Avocado toast", 390, 10, 42, 20), ("Samosa x2", 440, 8, 52, 22), ("Paneer curry with naan", 720, 28, 80, 28)],
        [("Greek yogurt parfait", 280, 18, 36, 6), ("Tuna wrap", 520, 38, 48, 12), ("Pasta bolognese", 680, 32, 88, 16)],
        [("Banana smoothie", 310, 8, 62, 4), ("Caesar salad with chicken", 540, 44, 18, 28), ("Butter chicken with rice", 780, 36, 92, 24)],
        [("Scrambled eggs on toast", 420, 22, 38, 18), ("Lentil soup", 380, 20, 54, 6), ("Grilled salmon with veggies", 560, 48, 24, 22)],
        [("Chia pudding", 290, 10, 40, 10), ("Chicken wrap", 580, 40, 52, 16), ("Vegetable stir fry with tofu", 490, 24, 60, 14)],
        [("Masala chai + poha", 350, 8, 58, 10), ("Rajma rice", 640, 24, 104, 10), ("Mixed vegetable soup", 260, 10, 38, 6)],
    ]
    workouts_by_day = [
        [{"type": "Running", "duration_min": 30, "calories_burned": 280}],
        [],
        [{"type": "Yoga", "duration_min": 45, "calories_burned": 140}],
        [{"type": "Gym — weight training", "duration_min": 50, "calories_burned": 320}],
        [],
        [{"type": "Cycling", "duration_min": 40, "calories_burned": 300}],
        [],
    ]
    water_by_day = [6, 8, 5, 7, 8, 4, 6]
    weight_by_day = [83.5, 83.3, 83.4, 83.1, 83.2, 82.9, 83.0]

    today = datetime.now(timezone.utc).date()
    written = []
    for i in range(7):
        day = today - timedelta(days=6 - i)
        day_str = day.isoformat()
        meals = [
            {
                "name": m[0], "calories": m[1],
                "protein_g": m[2], "carbs_g": m[3], "fat_g": m[4],
                "logged_at": f"{day_str}T08:00:00Z",
            }
            for m in meals_by_day[i]
        ]
        workouts = [
            {**w, "logged_at": f"{day_str}T17:00:00Z"}
            for w in workouts_by_day[i]
        ]
        _user_ref(user_id).collection("logs").document(day_str).set({
            "meals": meals,
            "workouts": workouts,
            "water_glasses": water_by_day[i],
            "weight_kg": weight_by_day[i],
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
    for sub in ["logs", "progress", "visual_journey"]:
        delete_collection(user_ref.collection(sub))
    user_ref.delete()

    # Also delete goals doc
    _goal_ref(user_id).delete()

    return {"status": "reset", "user_id": user_id}

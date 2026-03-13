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


def _today_log_ref(user_id: str):
    today = date.today().isoformat()
    return _user_ref(user_id).collection("logs").document(today)


def set_goal(user_id: str, goal: str, deadline: str, daily_calorie_target: int = 1800) -> dict:
    """
    Save the user's health goal and deadline. Call this during onboarding.

    Args:
        user_id: The user's unique ID.
        goal: A natural language description of the user's goal (e.g. 'Feel confident at Sarah's wedding').
        deadline: Target date in YYYY-MM-DD format.
        daily_calorie_target: Daily calorie target (default 1800).

    Returns:
        Confirmation that the goal was saved.
    """
    _user_ref(user_id).set({
        "goal": goal,
        "deadline": deadline,
        "daily_calorie_target": daily_calorie_target,
        "created_at": firestore.SERVER_TIMESTAMP,
    }, merge=True)
    return {"status": "saved", "goal": goal, "deadline": deadline}


def get_progress(user_id: str) -> dict:
    """
    Get the user's goal and today's progress (calories, water, workouts).

    Args:
        user_id: The user's unique ID.

    Returns:
        Dict with goal info and today's logged activity.
    """
    profile = _user_ref(user_id).get().to_dict() or {}
    today_log = _today_log_ref(user_id).get().to_dict() or {}

    calories_consumed = sum(
        m.get("calories", 0) for m in today_log.get("meals", [])
    )
    calorie_target = profile.get("daily_calorie_target", 1800)

    return {
        "goal": profile.get("goal", "Not set"),
        "deadline": profile.get("deadline", "Not set"),
        "calories_consumed": calories_consumed,
        "calories_target": calorie_target,
        "calories_remaining": calorie_target - calories_consumed,
        "water_glasses": today_log.get("water_glasses", 0),
        "meals_logged": today_log.get("meals", []),
        "workouts_logged": today_log.get("workouts", []),
    }


def log_meal(user_id: str, meal_name: str, calories: int, protein_g: int = 0, carbs_g: int = 0, fat_g: int = 0) -> dict:
    """
    Log a meal for the user.

    Args:
        user_id: The user's unique ID.
        meal_name: Name or description of the meal.
        calories: Estimated calories.
        protein_g: Protein in grams.
        carbs_g: Carbohydrates in grams.
        fat_g: Fat in grams.

    Returns:
        Confirmation with updated daily calorie total.
    """
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


def log_workout(user_id: str, workout_type: str, duration_min: int, calories_burned: int = 0) -> dict:
    """
    Log a workout session.

    Args:
        user_id: The user's unique ID.
        workout_type: Type of workout (e.g. 'running', 'yoga', 'gym').
        duration_min: Duration in minutes.
        calories_burned: Estimated calories burned.

    Returns:
        Confirmation of logged workout.
    """
    workout = {
        "type": workout_type,
        "duration_min": duration_min,
        "calories_burned": calories_burned,
    }
    _today_log_ref(user_id).set(
        {"workouts": firestore.ArrayUnion([workout])},
        merge=True
    )
    return {"status": "logged", "workout": workout_type, "duration_min": duration_min}


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
Identify every food item visible and estimate nutritional content.
Return exactly this structure:
{
  "identified": true,
  "description": "brief description of what you see",
  "items": [{"name": "...", "estimated_calories": 0, "protein_g": 0, "carbs_g": 0, "fat_g": 0}],
  "total_calories": 0,
  "total_protein_g": 0,
  "total_carbs_g": 0,
  "total_fat_g": 0,
  "confidence": "high|medium|low"
}
If no food is visible return {"identified": false}."""
        ],
    )

    import json, re
    raw = response.text.strip()
    # Strip markdown code fences if present
    raw = re.sub(r"^```(?:json)?\n?", "", raw)
    raw = re.sub(r"\n?```$", "", raw)

    result = json.loads(raw)
    result["user_id"] = user_id
    return result


def update_visual_journey(user_id: str) -> dict:
    """
    Generate or update the user's visual journey image based on their current progress.
    Call this when the user hits a milestone (every 10% progress) or asks to see their progress.

    Args:
        user_id: The user's unique ID.

    Returns:
        Public URL of the generated image and the current progress percentage.
    """
    client = _get_genai_client()
    from google.genai import types as genai_types

    # Get current progress and goal
    progress = get_progress(user_id)
    goal = progress["goal"]
    deadline = progress["deadline"]
    calories_target = progress["calories_target"]
    calories_consumed = progress["calories_consumed"]

    # Calculate overall completion (simple daily % for now)
    pct = min(100, int((calories_consumed / max(calories_target, 1)) * 100)) if calories_consumed > 0 else 0

    # Craft a prompt that evolves with progress
    if pct < 25:
        mood = "early morning light, soft and hopeful, just beginning the journey, muted warm tones"
    elif pct < 50:
        mood = "mid-morning golden light, energy building, colors becoming more vivid and saturated"
    elif pct < 75:
        mood = "bright afternoon sunlight, strong vibrant colors, confident and glowing atmosphere"
    else:
        mood = "radiant golden hour, fully vibrant and luminous, triumphant and joyful atmosphere"

    prompt = f"""Create a beautiful, motivational illustration representing this personal health journey:
Goal: "{goal}"
Progress: {pct}% of today's targets achieved
Visual mood: {mood}

Style: Warm, uplifting digital art. No text or words in the image.
Show a symbolic scene that represents progress toward this specific goal.
The image should feel {('like the very start of something exciting' if pct < 25 else 'like real momentum is building' if pct < 50 else 'like the goal is within reach' if pct < 75 else 'like the goal has been achieved — pure celebration')}."""

    response = client.models.generate_content(
        model="gemini-2.5-flash-image",
        contents=prompt,
        config=genai_types.GenerateContentConfig(
            response_modalities=["IMAGE", "TEXT"]
        ),
    )

    # Extract image bytes
    image_data = None
    for part in response.candidates[0].content.parts:
        if part.inline_data:
            image_data = part.inline_data.data
            break

    if not image_data:
        return {"status": "error", "message": "Image generation returned no image"}

    # Upload to Cloud Storage
    bucket_name = os.getenv("GCS_BUCKET", "rena-visual-journey")
    storage_client = storage.Client(project=os.getenv("GOOGLE_CLOUD_PROJECT"))
    bucket = storage_client.bucket(bucket_name)

    filename = f"{user_id}/{date.today().isoformat()}_{pct}pct_{uuid.uuid4().hex[:8]}.jpg"
    blob = bucket.blob(filename)
    blob.upload_from_string(image_data, content_type="image/jpeg")
    public_url = f"https://storage.googleapis.com/{bucket_name}/{filename}"

    # Save to Firestore
    version = datetime.now(timezone.utc).isoformat()
    _user_ref(user_id).collection("visual_journey").document(version).set({
        "image_url": public_url,
        "progress_percent": pct,
        "goal": goal,
        "generated_at": version,
    })

    return {
        "status": "generated",
        "image_url": public_url,
        "progress_percent": pct,
        "goal": goal,
    }


def find_restaurants(user_id: str, location: str, cuisine_preference: str = "") -> dict:
    """
    Find goal-aware restaurant recommendations near the user.

    Args:
        user_id: The user's unique ID.
        location: User's current location or neighborhood.
        cuisine_preference: Optional cuisine type preference.

    Returns:
        Restaurant suggestions filtered by remaining calories and goal timeline.
    """
    progress = get_progress(user_id)
    calories_remaining = progress["calories_remaining"]
    goal = progress["goal"]
    deadline = progress["deadline"]

    # TODO: integrate Google Maps Places API
    # For now return a structured prompt for Rena to reason about
    return {
        "location": location,
        "calories_remaining": calories_remaining,
        "goal": goal,
        "deadline": deadline,
        "cuisine_preference": cuisine_preference,
        "note": "Use this context to suggest appropriate restaurants and dishes that fit the user's remaining calories and goal timeline.",
    }

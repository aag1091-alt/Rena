// REST API wrapper — mirrors RenaAPI.swift

const API = {
  async _fetch(path, options = {}) {
    const res = await fetch(CONFIG.API_BASE + path, {
      headers: { "Content-Type": "application/json", ...options.headers },
      ...options,
    });
    if (!res.ok) throw new Error(`API ${path} → ${res.status}`);
    return res.json();
  },

  onboard(data)           { return this._fetch("/onboard", { method: "POST", body: JSON.stringify(data) }); },
  progress(userId, date)  { return this._fetch(`/progress/${userId}${date ? `?date=${date}` : ""}`); },
  goal(userId)            { return this._fetch(`/goal/${userId}`); },
  insight(userId, date)   { return this._fetch(`/workbook/insight/${userId}${date ? `?date=${date}` : ""}`); },
  morningNudge(userId)    { return this._fetch(`/morning-nudge/${userId}`); },

  workoutPlan(userId, date)        { return this._fetch(`/workout-plan/${userId}${date ? `?date=${date}` : ""}`); },
  mealPlan(userId, date)           { return this._fetch(`/meal-plan/${userId}${date ? `?date=${date}` : ""}`); },
  tomorrowPlan(userId, date)       { return this._fetch(`/tomorrow-plan/${userId}${date ? `?date=${date}` : ""}`); },

  logMealFromPlan(userId, mealId)  { return this._fetch(`/meal-plan/${userId}/meal/${mealId}/log`, { method: "POST" }); },
  logExercise(userId, exId)        { return this._fetch(`/workout-plan/${userId}/exercise/${exId}/log`, { method: "POST" }); },
  toggleExercise(userId, exId)     { return this._fetch(`/workout-plan/${userId}/exercise/${exId}/complete`, { method: "PATCH" }); },

  scanImage(userId, base64, mime)  {
    return this._fetch("/scan", { method: "POST", body: JSON.stringify({ user_id: userId, image_base64: base64, mime_type: mime }) });
  },
  logMeal(userId, name, calories)  {
    return this._fetch("/log/meal", { method: "POST", body: JSON.stringify({ user_id: userId, name, calories }) });
  },

  seed(userId)   { return this._fetch(`/dev/seed/${userId}`, { method: "POST" }); },
  reset(userId)  { return this._fetch(`/dev/reset/${userId}`, { method: "DELETE" }); },
};

// ── State ─────────────────────────────────────────────────────────────────

const app = {
  user:    JSON.parse(localStorage.getItem("rena_user") || "null"),
  profile: JSON.parse(localStorage.getItem("rena_profile") || "null"),
  tab:     "home",
};

const voice = new VoiceManager();

// ── Boot ──────────────────────────────────────────────────────────────────

window.addEventListener("DOMContentLoaded", () => {
  if (app.user && app.profile) {
    showApp();
  } else if (app.user) {
    showScreen("onboarding");
  } else {
    showScreen("login");
    initGoogleSignIn();
  }

  bindVoiceEvents();
  bindTabNav();
  bindScan();
});

// ── Google Sign-In ────────────────────────────────────────────────────────

function initGoogleSignIn() {
  if (!window.google) {
    setTimeout(initGoogleSignIn, 200);
    return;
  }
  google.accounts.id.initialize({
    client_id: CONFIG.GOOGLE_CLIENT_ID,
    callback:  handleCredential,
  });
  google.accounts.id.renderButton(
    document.getElementById("google-btn"),
    { theme: "outline", size: "large", shape: "pill", text: "signin_with" }
  );
  google.accounts.id.prompt();
}

function handleCredential(response) {
  const payload = JSON.parse(atob(response.credential.split(".")[1].replace(/-/g,"+").replace(/_/g,"/")));
  app.user = { id: payload.sub, email: payload.email, name: payload.given_name || payload.name };
  localStorage.setItem("rena_user", JSON.stringify(app.user));

  // Check if already onboarded
  API.progress(app.user.id).then(() => {
    app.profile = { onboarded: true };
    localStorage.setItem("rena_profile", JSON.stringify(app.profile));
    showApp();
  }).catch(() => {
    showScreen("onboarding");
  });
}

// ── Onboarding ────────────────────────────────────────────────────────────

document.addEventListener("submit", async (e) => {
  if (e.target.id !== "onboard-form") return;
  e.preventDefault();
  const fd  = new FormData(e.target);
  const btn = e.target.querySelector("button[type=submit]");
  btn.disabled = true;
  btn.textContent = "Setting up…";
  try {
    await API.onboard({
      user_id:        app.user.id,
      name:           app.user.name,
      sex:            fd.get("sex"),
      age:            parseInt(fd.get("age")),
      height_cm:      parseFloat(fd.get("height_cm")),
      weight_kg:      parseFloat(fd.get("weight_kg")),
      activity_level: fd.get("activity_level"),
      timezone:       Intl.DateTimeFormat().resolvedOptions().timeZone,
    });
    app.profile = { onboarded: true };
    localStorage.setItem("rena_profile", JSON.stringify(app.profile));
    showApp();
    // Open goal-setting voice session
    setTimeout(() => openVoice("goal"), 400);
  } catch (err) {
    btn.disabled = false;
    btn.textContent = "Get started";
    alert("Something went wrong. Please try again.");
  }
});

// ── App shell ─────────────────────────────────────────────────────────────

function showScreen(id) {
  document.querySelectorAll(".screen").forEach(s => s.classList.remove("active"));
  document.getElementById(`screen-${id}`)?.classList.add("active");
}

function showApp() {
  showScreen("app");
  switchTab("home");
  loadHome();
}

// ── Tab navigation ────────────────────────────────────────────────────────

function bindTabNav() {
  document.querySelectorAll(".tab-btn").forEach(btn => {
    btn.addEventListener("click", () => {
      const tab = btn.dataset.tab;
      if (tab === "rena") { openVoice(); return; }
      switchTab(tab);
    });
  });
}

function switchTab(tab) {
  app.tab = tab;
  document.querySelectorAll(".view").forEach(v => v.classList.remove("active"));
  document.getElementById(`view-${tab}`)?.classList.add("active");
  document.querySelectorAll(".tab-btn").forEach(b => {
    b.classList.toggle("active", b.dataset.tab === tab);
  });
  if (tab === "home")    loadHome();
  if (tab === "plan")    loadPlan();
  if (tab === "history") loadHistory();
}

// ── Home ──────────────────────────────────────────────────────────────────

async function loadHome() {
  if (!app.user) return;
  try {
    const [progress, nudge] = await Promise.all([
      API.progress(app.user.id),
      API.morningNudge(app.user.id).catch(() => null),
    ]);
    renderHome(progress, nudge);
  } catch (e) { console.error(e); }
}

function renderHome(p, nudge) {
  const consumed = p.calories_consumed  || 0;
  const target   = p.calories_target    || 2000;
  const burned   = p.calories_burned    || 0;
  const water    = p.water_glasses      || 0;
  const protein  = p.protein_consumed_g || 0;
  const proteinT = p.protein_target_g   || 120;
  const pct      = Math.min(100, Math.round((consumed / target) * 100));
  const circ     = 2 * Math.PI * 54;
  const dash     = circ - (circ * pct / 100);

  document.getElementById("home-content").innerHTML = `
    ${nudge?.has_nudge ? `<div class="nudge-card">${nudge.nudge}</div>` : ""}

    <div class="progress-ring-wrap">
      <svg viewBox="0 0 120 120" class="ring-svg">
        <circle cx="60" cy="60" r="54" class="ring-bg"/>
        <circle cx="60" cy="60" r="54" class="ring-fill"
          stroke-dasharray="${circ}"
          stroke-dashoffset="${dash}"
          transform="rotate(-90 60 60)"/>
      </svg>
      <div class="ring-label">
        <div class="ring-num">${consumed}</div>
        <div class="ring-sub">of ${target} kcal</div>
      </div>
    </div>

    <div class="stat-row">
      <div class="stat-card">
        <div class="stat-icon" style="color:var(--green)">🔥</div>
        <div class="stat-val">${burned}</div>
        <div class="stat-lbl">burned</div>
      </div>
      <div class="stat-card">
        <div class="stat-icon" style="color:var(--blue)">💧</div>
        <div class="stat-val">${water}/8</div>
        <div class="stat-lbl">glasses</div>
      </div>
      <div class="stat-card">
        <div class="stat-icon" style="color:var(--purple)">💪</div>
        <div class="stat-val">${protein}g</div>
        <div class="stat-lbl">of ${proteinT}g protein</div>
      </div>
    </div>

    ${p.meals_logged?.length ? `
      <div class="section-title">Today's meals</div>
      <div class="item-list">
        ${p.meals_logged.map(m => `
          <div class="item-row">
            <span>${m.name}</span>
            <span class="item-cal">${m.calories} kcal</span>
          </div>`).join("")}
      </div>` : ""}

    ${p.workouts_logged?.length ? `
      <div class="section-title">Workouts</div>
      <div class="item-list">
        ${p.workouts_logged.map(w => `
          <div class="item-row">
            <span>${w.type} · ${w.duration_min} min</span>
            <span class="item-cal">${w.calories_burned} kcal</span>
          </div>`).join("")}
      </div>` : ""}
  `;
}

// ── Plan ──────────────────────────────────────────────────────────────────

async function loadPlan() {
  if (!app.user) return;
  const [workout, meal] = await Promise.all([
    API.workoutPlan(app.user.id).catch(() => null),
    API.mealPlan(app.user.id).catch(() => null),
  ]);
  renderPlan(workout, meal);
}

function renderPlan(workout, meal) {
  const el = document.getElementById("plan-content");
  el.innerHTML = `
    <div class="section-title">Workout plan
      <button class="plan-voice-btn" onclick="openVoice('workout_plan')">
        ${workout ? "Update" : "Plan"} with Rena
      </button>
    </div>
    ${workout ? renderWorkoutPlan(workout) : `<div class="empty-state">No workout plan yet — tap "Plan with Rena"</div>`}

    <div class="section-title" style="margin-top:24px">Meal plan
      <button class="plan-voice-btn" onclick="openVoice('meal_plan')">
        ${meal ? "Update" : "Plan"} with Rena
      </button>
    </div>
    ${meal ? renderMealPlan(meal) : `<div class="empty-state">No meal plan yet — tap "Plan with Rena"</div>`}
  `;
}

function renderWorkoutPlan(plan) {
  return `
    <div class="plan-card">
      <div class="plan-name">${plan.name} · ${plan.total_duration_min} min</div>
      ${plan.exercises.map(ex => `
        <div class="exercise-row ${ex.logged ? "done" : ""}">
          <div>
            <div class="ex-name">${ex.name}</div>
            <div class="ex-meta">${ex.type === "cardio"
              ? `${ex.duration_min} min`
              : `${ex.sets}×${ex.reps}${ex.weight_kg ? ` @ ${ex.weight_kg}kg` : ""}`}
              · ${ex.calories_burned} kcal · ${ex.target_muscles}</div>
          </div>
          ${!ex.logged ? `<button class="log-btn" onclick="logExercise('${ex.id}')">Log</button>` : `<span class="done-badge">✓</span>`}
        </div>`).join("")}
    </div>`;
}

function renderMealPlan(plan) {
  return `
    <div class="plan-card">
      <div class="plan-name">${plan.notes} · ${plan.total_calories} kcal</div>
      ${plan.meals.map(m => `
        <div class="exercise-row ${m.logged ? "done" : ""}">
          <div>
            <div class="ex-name">${m.name} <span class="meal-type-badge">${m.meal_type}</span></div>
            <div class="ex-meta">${m.calories} kcal · ${m.cook_time_min} min</div>
          </div>
          ${!m.logged ? `<button class="log-btn" onclick="logMealFromPlan('${m.id}')">Log</button>` : `<span class="done-badge">✓</span>`}
        </div>`).join("")}
    </div>`;
}

async function logExercise(exId) {
  try { await API.logExercise(app.user.id, exId); loadPlan(); } catch (e) { alert("Couldn't log exercise"); }
}
async function logMealFromPlan(mealId) {
  try { await API.logMealFromPlan(app.user.id, mealId); loadPlan(); loadHome(); } catch (e) { alert("Couldn't log meal"); }
}

// ── History ───────────────────────────────────────────────────────────────

async function loadHistory() {
  if (!app.user) return;
  const days = [];
  const today = new Date();
  for (let i = 1; i <= 7; i++) {
    const d = new Date(today); d.setDate(d.getDate() - i);
    days.push(d.toISOString().split("T")[0]);
  }
  const results = await Promise.all(days.map(d =>
    Promise.all([
      API.progress(app.user.id, d).catch(() => null),
      API.insight(app.user.id, d).catch(() => null),
    ]).then(([p, ins]) => ({ date: d, progress: p, insight: ins }))
  ));
  renderHistory(results);
}

function renderHistory(days) {
  document.getElementById("history-content").innerHTML = days.map(({ date, progress: p, insight: ins }) => {
    if (!p) return "";
    const label = new Date(date + "T12:00:00").toLocaleDateString("en-US", { weekday: "short", month: "short", day: "numeric" });
    return `
      <div class="history-card">
        <div class="history-date">${label}</div>
        <div class="history-stats">
          <span>${p.calories_consumed || 0} kcal</span>
          <span>💧 ${p.water_glasses || 0}</span>
          <span>🔥 ${p.calories_burned || 0}</span>
        </div>
        ${ins?.insight ? `<div class="history-insight">${ins.insight}</div>` : ""}
      </div>`;
  }).join("");
}

// ── Scan ──────────────────────────────────────────────────────────────────

function bindScan() {
  const fileInput = document.getElementById("scan-file");
  const cameraInput = document.getElementById("scan-camera");

  [fileInput, cameraInput].forEach(input => {
    input?.addEventListener("change", async (e) => {
      const file = e.target.files[0];
      if (!file) return;
      const reader = new FileReader();
      reader.onload = async (ev) => {
        const b64 = ev.target.result.split(",")[1];
        const mime = file.type || "image/jpeg";
        document.getElementById("scan-result").innerHTML = `<div class="scanning-msg">Scanning…</div>`;
        try {
          const result = await API.scanImage(app.user.id, b64, mime);
          renderScanResult(result);
        } catch (err) {
          document.getElementById("scan-result").innerHTML = `<div class="error-msg">Scan failed. Try again.</div>`;
        }
      };
      reader.readAsDataURL(file);
    });
  });
}

function renderScanResult(result) {
  if (!result.identified) {
    document.getElementById("scan-result").innerHTML = `<div class="empty-state">Couldn't identify food in this photo.</div>`;
    return;
  }
  document.getElementById("scan-result").innerHTML = `
    <div class="scan-card">
      <div class="scan-total">${result.total_calories} kcal total</div>
      ${(result.items || []).map(item => `
        <div class="scan-item">
          <span>${item.name}</span>
          <span>${item.calories} kcal</span>
          <button class="log-btn" onclick="logScanItem('${encodeURIComponent(item.name)}', ${item.calories})">Log</button>
        </div>`).join("")}
    </div>`;
}

async function logScanItem(name, calories) {
  try {
    await API.logMeal(app.user.id, decodeURIComponent(name), calories);
    loadHome();
    alert(`Logged ${decodeURIComponent(name)}!`);
  } catch (e) { alert("Couldn't log item"); }
}

// ── Voice overlay ─────────────────────────────────────────────────────────

function openVoice(context) {
  const ctx  = context || (app.tab === "history" ? "history" : app.tab === "plan" ? "update_workout_plan" : "home");
  const name = app.user?.name || "";
  document.getElementById("voice-overlay").classList.add("active");
  document.getElementById("voice-transcript").textContent = "";
  updateVoiceUI("connecting");
  voice.connect(app.user.id, ctx, name);
}

function closeVoice() {
  voice.disconnect();
  document.getElementById("voice-overlay").classList.remove("active");
  loadHome();
  if (app.tab === "plan") loadPlan();
}

function bindVoiceEvents() {
  document.getElementById("voice-close-btn").addEventListener("click", closeVoice);
  document.getElementById("voice-overlay").addEventListener("click", (e) => {
    if (e.target === e.currentTarget) closeVoice();
  });

  voice.addEventListener("statechange", (e) => updateVoiceUI(e.detail));
  voice.addEventListener("transcriptchange", (e) => {
    document.getElementById("voice-transcript").textContent = e.detail;
  });
  voice.addEventListener("turncomplete", () => {
    if (app.tab === "home")    loadHome();
    if (app.tab === "plan")    loadPlan();
    if (app.tab === "history") loadHistory();
  });
}

function updateVoiceUI(state) {
  const btn   = document.getElementById("voice-action-btn");
  const label = document.getElementById("voice-state-label");
  const wave  = document.getElementById("voice-wave");
  const tstat = voice.toolStatus;

  const labels = {
    idle:       "Tap to speak",
    connecting: "Connecting…",
    listening:  "Listening…",
    thinking:   tstat || "Thinking…",
    speaking:   "Rena is speaking…",
    error:      "Connection error",
  };
  label.textContent = labels[state] || state;
  wave.classList.toggle("active", state === "listening" || state === "speaking");
  btn.classList.toggle("btn-active", state !== "idle");
}

// ── Sign out ──────────────────────────────────────────────────────────────

function signOut() {
  localStorage.removeItem("rena_user");
  localStorage.removeItem("rena_profile");
  app.user    = null;
  app.profile = null;
  showScreen("login");
  initGoogleSignIn();
}

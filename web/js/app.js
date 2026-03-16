// ── State ─────────────────────────────────────────────────────────────────

const app = {
  user:     JSON.parse(localStorage.getItem("rena_user")    || "null"),
  profile:  JSON.parse(localStorage.getItem("rena_profile") || "null"),
  hasGoal:  localStorage.getItem("rena_has_goal") === "true",
  tab:      "home",
  histDate: new Date(),
  planDate: new Date(),
  // onboarding state
  obStep: 1,
  obSex: "male",
  obAge: 28,
  obHeightIn: 70,
  obWeightKg: 70.0,
  // scan state
  scanItems: [],
  scanAdjusted: {},
  scanLogged: false,
};

const voice = new VoiceManager();

// ── Helpers ────────────────────────────────────────────────────────────────

// Known pre-generated exercise videos in GCS (gs://rena-assets/exercise_videos/)
const EXERCISE_VIDEOS = {
  "bodyweight_squats":              "https://storage.googleapis.com/rena-assets/exercise_videos/bodyweight_squats.mp4",
  "plank":                          "https://storage.googleapis.com/rena-assets/exercise_videos/plank.mp4",
  "walking_lunges":                 "https://storage.googleapis.com/rena-assets/exercise_videos/walking_lunges.mp4",
  "elliptical_trainer_moderate_pace": "https://storage.googleapis.com/rena-assets/exercise_videos/elliptical_trainer_moderate_pace.mp4",
};
function exerciseVideoUrl(name) {
  const key = name.toLowerCase().replace(/[^a-z0-9]+/g, "_").replace(/_+$/, "");
  return EXERCISE_VIDEOS[key]
    || `https://m.youtube.com/results?search_query=${encodeURIComponent(name + " exercise tutorial")}`;
}

function fmtDate(d) {
  return d.toLocaleDateString("en-US", { weekday: "short", month: "short", day: "numeric" });
}
function fmtDateISO(d) {
  const y = d.getFullYear();
  const m = String(d.getMonth() + 1).padStart(2, "0");
  const dd = String(d.getDate()).padStart(2, "0");
  return `${y}-${m}-${dd}`;
}
function isToday(d) {
  const t = new Date();
  return d.getFullYear() === t.getFullYear() && d.getMonth() === t.getMonth() && d.getDate() === t.getDate();
}
function isTomorrow(d) {
  const t = new Date(); t.setDate(t.getDate() + 1);
  return d.getFullYear() === t.getFullYear() && d.getMonth() === t.getMonth() && d.getDate() === t.getDate();
}
function isYesterday(d) {
  const t = new Date(); t.setDate(t.getDate() - 1);
  return d.getFullYear() === t.getFullYear() && d.getMonth() === t.getMonth() && d.getDate() === t.getDate();
}
function dateDayLabel(d) {
  if (isToday(d)) return "Today";
  if (isYesterday(d)) return "Yesterday";
  if (isTomorrow(d)) return "Tomorrow";
  return fmtDate(d);
}
function greeting() {
  const h = new Date().getHours();
  if (h < 12) return "Good morning";
  if (h < 17) return "Good afternoon";
  return "Good evening";
}
function todayStr() {
  return new Date().toLocaleDateString("en-US", { weekday: "short", month: "short", day: "numeric" });
}
function heightDisplay(inches) {
  const ft = Math.floor(inches / 12);
  const ins = Math.round(inches % 12);
  return `${ft}'${ins}"`;
}
function pct(val, max) { return Math.min(100, Math.round((val / Math.max(max, 1)) * 100)); }

function updateHeaders(name) {
  const g = greeting(), d = todayStr();
  const first = (name || "").split(" ")[0] || "–";
  ["home","history","plan","scan"].forEach(tab => {
    const ge = document.getElementById(`${tab}-greeting`);
    const ne = document.getElementById(`${tab}-name`);
    const de = document.getElementById(`${tab}-date`);
    if (ge) ge.textContent = g;
    if (ne) ne.textContent = first;
    if (de) de.textContent = d;
  });
}

// ── Boot ──────────────────────────────────────────────────────────────────

window.addEventListener("DOMContentLoaded", () => {
  if (!app.user) {
    showScreen("login");
    initGoogleSignIn();
  } else if (!app.profile) {
    showScreen("onboarding");
    document.getElementById("onboard-welcome").textContent =
      `Welcome, ${app.user.name.split(" ")[0]} 👋`;
  } else {
    showApp();
  }
  bindTabNav();
  bindScan();
  bindVoiceEvents();
  bindDevSheet();
  bindOnboarding();
});

// ── Google Sign-In ────────────────────────────────────────────────────────

function initGoogleSignIn() {
  if (!window.google) { setTimeout(initGoogleSignIn, 200); return; }
  google.accounts.id.initialize({
    client_id: CONFIG.GOOGLE_CLIENT_ID,
    callback: handleCredential,
  });
  google.accounts.id.renderButton(
    document.getElementById("google-btn"),
    { theme: "outline", size: "large", shape: "pill", text: "signin_with" }
  );
  // Custom button triggers One Tap or GIS flow
  document.getElementById("google-btn-custom").addEventListener("click", () => {
    google.accounts.id.prompt();
  });
}

async function handleCredential(response) {
  const raw = response.credential.split(".")[1].replace(/-/g, "+").replace(/_/g, "/");
  const payload = JSON.parse(atob(raw + "=".repeat((4 - raw.length % 4) % 4)));
  app.user = { id: payload.sub, email: payload.email, name: payload.given_name || payload.name, picture: payload.picture || "" };
  localStorage.setItem("rena_user", JSON.stringify(app.user));
  const btn = document.getElementById("google-btn-custom");
  btn.disabled = true; btn.textContent = "Signing in…";
  try {
    const progress = await API.progress(app.user.id);
    app.profile = { onboarded: true };
    localStorage.setItem("rena_profile", JSON.stringify(app.profile));
    showApp();
  } catch {
    // Not yet onboarded
    btn.disabled = false;
    btn.innerHTML = `<svg width="20" height="20" viewBox="0 0 24 24" fill="none">
      <path d="M22.56 12.25c0-.78-.07-1.53-.2-2.25H12v4.26h5.92c-.26 1.37-1.04 2.53-2.21 3.31v2.77h3.57c2.08-1.92 3.28-4.74 3.28-8.09z" fill="white"/>
      <path d="M12 23c2.97 0 5.46-.98 7.28-2.66l-3.57-2.77c-.98.66-2.23 1.06-3.71 1.06-2.86 0-5.29-1.93-6.16-4.53H2.18v2.84C3.99 20.53 7.7 23 12 23z" fill="white"/>
      <path d="M5.84 14.09c-.22-.66-.35-1.36-.35-2.09s.13-1.43.35-2.09V7.07H2.18C1.43 8.55 1 10.22 1 12s.43 3.45 1.18 4.93l3.66-2.84z" fill="white"/>
      <path d="M12 5.38c1.62 0 3.06.56 4.21 1.64l3.15-3.15C17.45 2.09 14.97 1 12 1 7.7 1 3.99 3.47 2.18 7.07l3.66 2.84c.87-2.6 3.3-4.53 6.16-4.53z" fill="white"/>
    </svg> Continue with Google`;
    showScreen("onboarding");
    document.getElementById("onboard-welcome").textContent =
      `Welcome, ${app.user.name.split(" ")[0]} 👋`;
  }
}

// ── Onboarding ────────────────────────────────────────────────────────────

function bindOnboarding() {
  // Step 1 – Sex cards
  document.querySelectorAll(".sex-card").forEach(btn => {
    btn.addEventListener("click", () => {
      app.obSex = btn.dataset.sex;
      document.querySelectorAll(".sex-card").forEach(b => b.classList.remove("selected"));
      btn.classList.add("selected");
      setTimeout(() => goToStep(2), 180);
    });
  });

  // Step 2 – Age slider
  const ageSlider = document.getElementById("age-slider");
  const ageDisplay = document.getElementById("age-display");
  ageSlider.addEventListener("input", () => {
    app.obAge = parseInt(ageSlider.value);
    ageDisplay.textContent = ageSlider.value;
  });
  document.getElementById("age-next").addEventListener("click", () => goToStep(3));

  // Step 3 – Body sliders
  const hSlider = document.getElementById("height-slider");
  const wSlider = document.getElementById("weight-slider");
  hSlider.addEventListener("input", () => {
    app.obHeightIn = parseInt(hSlider.value);
    document.getElementById("height-display").textContent = heightDisplay(app.obHeightIn);
  });
  wSlider.addEventListener("input", () => {
    app.obWeightKg = parseFloat(wSlider.value);
    document.getElementById("weight-display").innerHTML =
      `${parseFloat(wSlider.value).toFixed(1)}<span class="unit">kg</span>`;
  });
  document.getElementById("body-next").addEventListener("click", () => goToStep(4));

  // Step 4 – Activity
  document.querySelectorAll(".activity-item").forEach(btn => {
    btn.addEventListener("click", () => {
      document.querySelectorAll(".activity-item").forEach(b => b.classList.remove("selected"));
      btn.classList.add("selected");
      app.obActivity = btn.dataset.level;
      setTimeout(() => submitOnboarding(), 180);
    });
  });
}

function goToStep(n) {
  const steps = ["sex", "age", "body", "activity"];
  document.querySelectorAll(".onboard-step").forEach((el, i) => {
    el.classList.toggle("active", i + 1 === n);
  });
  document.querySelectorAll(".dot").forEach((d, i) => {
    d.classList.toggle("active", i + 1 === n);
  });
  app.obStep = n;
}

async function submitOnboarding() {
  const btn = document.querySelector(".activity-item.selected");
  if (btn) { btn.style.pointerEvents = "none"; }
  document.getElementById("activity-error").classList.add("hidden");
  try {
    await API.onboard({
      user_id:        app.user.id,
      name:           app.user.name,
      sex:            app.obSex,
      age:            app.obAge,
      height_cm:      app.obHeightIn * 2.54,
      weight_kg:      app.obWeightKg,
      activity_level: app.obActivity,
      timezone:       Intl.DateTimeFormat().resolvedOptions().timeZone,
    });
    app.profile = { onboarded: true };
    localStorage.setItem("rena_profile", JSON.stringify(app.profile));
    showApp();
  } catch {
    document.getElementById("activity-error").textContent = "Something went wrong. Please try again.";
    document.getElementById("activity-error").classList.remove("hidden");
    if (btn) { btn.style.pointerEvents = ""; btn.classList.remove("selected"); }
  }
}



// ── App Shell ─────────────────────────────────────────────────────────────

function showScreen(id) {
  document.querySelectorAll(".screen").forEach(s => s.classList.remove("active"));
  document.getElementById(`screen-${id}`)?.classList.add("active");
}

function showApp() {
  showScreen("app");
  updateHeaders(app.user?.name || "");
  const tabs = ["home", "history", "plan", "scan"];
  const hash = location.hash.replace("#", "");
  switchTab(tabs.includes(hash) ? hash : "home");
}

// ── Tab Navigation ────────────────────────────────────────────────────────

function bindTabNav() {
  document.querySelectorAll(".tab-btn").forEach(btn => {
    btn.addEventListener("click", () => {
      const tab = btn.dataset.tab;
      if (tab === "rena") { openVoiceOverlay(); return; }
      switchTab(tab);
    });
  });
  const tabs = ["home", "history", "plan", "scan"];
  window.addEventListener("hashchange", () => {
    if (document.getElementById("screen-app")?.classList.contains("active")) {
      const hash = location.hash.replace("#", "");
      if (tabs.includes(hash)) switchTab(hash);
    }
  });
}

function switchTab(tab) {
  // Always reset voice overlay when switching pages
  voice.disconnect();
  setVoiceActive(false);
  document.getElementById("voice-overlay")?.classList.add("hidden");
  document.getElementById("voice-transcript").textContent = "";
  document.getElementById("voice-transcript-wrap").style.display = "none";
  app.tab = tab;
  history.replaceState(null, "", `#${tab}`);
  document.querySelectorAll(".view").forEach(v => v.classList.remove("active"));
  document.getElementById(`view-${tab}`)?.classList.add("active");
  document.querySelectorAll(".tab-btn").forEach(b => {
    b.classList.toggle("active", b.dataset.tab === tab);
  });
  if (tab === "home")    loadHome();
  if (tab === "history") loadHistory();
  if (tab === "plan")    loadPlan();
  if (tab === "scan")    { /* scan is ready on demand */ }
}

// ── Home ──────────────────────────────────────────────────────────────────

async function loadHome() {
  if (!app.user) return;
  document.getElementById("home-content").innerHTML =
    `<div class="loading-row"><div class="spinner"></div></div>`;
  try {
    const [progress, goalData, insight, nudge] = await Promise.all([
      API.progress(app.user.id),
      API.goal(app.user.id).catch(() => null),
      API.insight(app.user.id).catch(() => null),
      API.morningNudge(app.user.id).catch(() => null),
    ]);
    renderHome(progress, goalData, insight, nudge);
  } catch (e) {
    document.getElementById("home-content").innerHTML =
      `<div class="loading-row" style="color:#e05252">Failed to load. Tap Rena to reconnect.</div>`;
  }
}

function renderHome(p, goal, insight, nudge) {
  const consumed = p.calories_consumed  || 0;
  const target   = p.calories_target    || 1800;
  const burned   = p.calories_burned    || 0;
  const burnReq  = p.burn_required      || 0;
  const water    = p.water_glasses      || 0;
  const protein  = p.protein_consumed_g || 0;
  const proteinT = p.protein_target_g   || 112;
  const netCal   = consumed - burned;
  const progress = Math.min(100, Math.round((Math.max(0, netCal) / Math.max(target, 1)) * 100));

  let html = "";

  // Nudge card
  if (nudge?.has_nudge && nudge.nudge) {
    html += `<div class="nudge-card">
      <div class="nudge-icon">✦</div>
      <div class="nudge-content">
        <div class="nudge-label">TODAY'S FOCUS</div>
        <div class="nudge-text">${nudge.nudge}</div>
      </div>
    </div>`;
  }

  // Goal card
  html += renderGoalCard(goal);

  // Calorie breakdown
  html += `<div class="cal-breakdown">
    <div class="cal-header-row">
      <div>
        <div class="card-label">CALORIES</div>
        <div class="card-title">Daily breakdown</div>
      </div>
      ${burnReq > 0
        ? `<div class="cal-badge" style="color:#E76F51;background:rgba(231,111,81,0.10)">🔥 Burn ${burnReq} kcal</div>`
        : consumed > 0
        ? `<div class="cal-badge" style="color:#2A9D8F;background:rgba(42,157,143,0.10)">✓ On track</div>`
        : ""}
    </div>
    <div class="cal-bar-wrap">
      <div class="cal-bar-track">
        <div class="cal-bar-fill" style="width:${progress}%"></div>
      </div>
      <div class="cal-bar-labels"><span>0</span><span>${target} kcal target</span></div>
    </div>
    <div class="cal-stats-row">
      <div class="cal-stat">
        <div class="cal-stat-icon" style="background:rgba(231,111,81,0.12);color:#E76F51">🍴</div>
        <div class="cal-stat-val">${consumed}</div>
        <div class="cal-stat-label">Eaten</div>
      </div>
      <div class="cal-divider"></div>
      <div class="cal-stat">
        <div class="cal-stat-icon" style="background:rgba(42,157,143,0.12);color:#2A9D8F">🏃</div>
        <div class="cal-stat-val">${burned}</div>
        <div class="cal-stat-label">Burned</div>
      </div>
      <div class="cal-divider"></div>
      <div class="cal-stat">
        <div class="cal-stat-icon" style="background:rgba(69,123,157,0.12);color:#457B9D">🎯</div>
        <div class="cal-stat-val">${Math.max(0, target - netCal)}</div>
        <div class="cal-stat-label">Remaining</div>
      </div>
    </div>
  </div>`;

  // Stats bar (protein + water)
  const protPct = pct(protein, proteinT);
  const waterPct = pct(water, 8);
  html += `<div class="stats-bar">
    <div class="stat-tile">
      <div class="stat-tile-header">
        <span class="stat-tile-icon" style="color:#2A9D8F">Ⓟ</span>
        <span class="stat-tile-key">PROTEIN</span>
        <span class="stat-tile-val" style="color:#2A9D8F">${protein}/${proteinT}g</span>
      </div>
      <div class="stat-tile-bar-track" style="background:rgba(42,157,143,0.12)">
        <div class="stat-tile-bar-fill" style="width:${protPct}%;background:#2A9D8F"></div>
      </div>
    </div>
    <div class="stat-tile">
      <div class="stat-tile-header">
        <span class="stat-tile-icon" style="color:#457B9D">💧</span>
        <span class="stat-tile-key">WATER</span>
        <span class="stat-tile-val" style="color:#457B9D">${water}/8 glasses</span>
      </div>
      <div class="stat-tile-bar-track" style="background:rgba(69,123,157,0.12)">
        <div class="stat-tile-bar-fill" style="width:${waterPct}%;background:#457B9D"></div>
      </div>
    </div>
  </div>`;

  // Day So Far
  html += `<div class="day-so-far">
    <div class="day-so-far-header">
      <div class="day-so-far-icon">✦</div>
      <div class="card-label">DAY SO FAR</div>
    </div>
    ${insight?.insight
      ? `<div class="day-so-far-text">${insight.insight}</div>`
      : `<div class="day-so-far-empty">Start logging meals and workouts — Rena will give you a read on your day.</div>`
    }
  </div>`;

  document.getElementById("home-content").innerHTML = html;
}

function renderGoalCard(goal) {
  if (!goal || !goal.goal) {
    return `<div class="goal-card-home" style="background:linear-gradient(135deg,#E76F5111,white)">
      <div class="goal-header-row">
        <div class="goal-icon-box" style="background:#E76F5122;color:#E76F51">◎</div>
        <div class="card-label" style="flex:1">YOUR GOAL</div>
      </div>
      <div class="goal-text" style="color:#888;font-style:italic">No goal set yet</div>
      <button onclick="openVoiceOverlay('goal')" style="margin-top:14px;width:100%;padding:12px;border:none;border-radius:14px;background:linear-gradient(90deg,#E76F51,#F4A261);color:white;font-size:14px;font-weight:600;cursor:pointer;display:flex;align-items:center;justify-content:center;gap:8px">
        <span>✦</span> Add goal with Rena
      </button>
    </div>`;
  }

  const gt    = goal.goal_type || "event";
  const text  = goal.goal || "Set your goal";
  const days  = goal.days_until_goal || 0;
  const p     = goal.progress_percent || 0;
  const label = goal.progress_label || "";
  const sv    = goal.start_value || 0;
  const cv    = goal.current_value || 0;
  const tv    = goal.target_value || 0;
  const unit  = goal.unit || "";

  const colors = {
    weight_loss: "#9B7EC8", weight_gain: "#2A9D8F",
    fitness: "#457B9D", habit: "#E9C46A"
  };
  const color = colors[gt] || "#C47A5A";
  const bgPct = Math.min(100, p);
  const showProgress = gt !== "event" && tv > 0;

  return `<div class="goal-card-home" style="background:linear-gradient(135deg,${color}11,white)">
    <div class="goal-header-row">
      <div class="goal-icon-box" style="background:${color}22;color:${color}">◎</div>
      <div class="card-label" style="flex:1">YOUR GOAL</div>
      ${days > 0 ? `<div class="goal-days-badge" style="color:${color};background:${color}22">${days}d to go</div>` : ""}
    </div>
    <div class="goal-text">${text}</div>
    ${showProgress ? `
      <div class="goal-progress-bar-track" style="background:${color}20">
        <div class="goal-progress-bar-fill" style="width:${bgPct}%;background:${color}"></div>
      </div>
      <div class="goal-progress-labels">
        <div class="goal-progress-pct" style="color:${color}">${p}%</div>
      </div>
      <div class="goal-stats-row">
        <div class="goal-stat">
          <div class="goal-stat-label">Started</div>
          <div class="goal-stat-val">${fmtVal(sv)} <span class="goal-stat-unit">${unit}</span></div>
        </div>
        <div class="goal-divider"></div>
        <div class="goal-stat">
          <div class="goal-stat-label">Now</div>
          <div class="goal-stat-val" style="color:${color}">${fmtVal(cv)} <span class="goal-stat-unit">${unit}</span></div>
        </div>
        <div class="goal-divider"></div>
        <div class="goal-stat">
          <div class="goal-stat-label">Target</div>
          <div class="goal-stat-val">${fmtVal(tv)} <span class="goal-stat-unit">${unit}</span></div>
        </div>
      </div>
      ${label ? `<div style="font-size:12px;font-weight:500;color:${color};margin-top:8px">${label}</div>` : ""}
    ` : ""}
    <div style="display:flex;justify-content:flex-end;margin-top:12px">
      <button onclick="openVoiceOverlay('goal')" style="display:inline-flex;align-items:center;gap:5px;padding:7px 14px;border-radius:20px;border:1.5px solid ${color}44;background:${color}11;color:${color};font-size:12px;font-weight:600;cursor:pointer;letter-spacing:0.2px">
        <span style="font-size:11px">✦</span> Change goal
      </button>
    </div>
  </div>`;
}

function fmtVal(v) {
  return v === Math.round(v) ? String(Math.round(v)) : v.toFixed(1);
}

// ── History ───────────────────────────────────────────────────────────────

async function loadHistory() {
  if (!app.user) return;
  renderHistoryShell();
  await loadHistoryDay();
}

function renderHistoryShell() {
  const d = app.histDate;
  const isOldest = daysDiff(d, new Date()) >= 90;
  const isLatest = isToday(d);
  document.getElementById("history-content").innerHTML = `
    <div class="date-nav">
      <button class="date-nav-btn" id="hist-prev" ${isOldest ? "disabled" : ""}>‹</button>
      <div class="date-nav-center">
        <div class="date-nav-label">
          ${isLatest ? '<div class="date-nav-dot"></div>' : ""}
          <span id="hist-date-label">${dateDayLabel(d)}</span>
        </div>
        ${!isLatest ? `<div class="date-nav-sub">${fmtDateISO(d)}</div>` : ""}
      </div>
      <button class="date-nav-btn" id="hist-next" ${isLatest ? "disabled" : ""}>›</button>
    </div>
    <div id="hist-day-content" class="cards-stack"><div class="loading-row"><div class="spinner"></div></div></div>
  `;
  document.getElementById("hist-prev").addEventListener("click", () => {
    app.histDate.setDate(app.histDate.getDate() - 1);
    renderHistoryShell();
    loadHistoryDay();
  });
  document.getElementById("hist-next").addEventListener("click", () => {
    if (!isToday(app.histDate)) {
      app.histDate.setDate(app.histDate.getDate() + 1);
      renderHistoryShell();
      loadHistoryDay();
    }
  });
}

function daysDiff(a, b) {
  return Math.round((b - a) / (1000 * 60 * 60 * 24));
}

async function loadHistoryDay() {
  try {
    const resp = await API.progress(app.user.id, fmtDateISO(app.histDate));
    renderHistoryDay(resp);
  } catch {
    document.getElementById("hist-day-content").innerHTML =
      `<div class="loading-row" style="color:var(--muted)">No data for this day.</div>`;
  }
}

function renderHistoryDay(p) {
  const consumed = p.calories_consumed  || 0;
  const burned   = p.calories_burned    || 0;
  const water    = p.water_glasses      || 0;
  const netCal   = consumed - burned;
  const target   = p.calories_target    || 1800;
  const remaining = Math.max(0, target - netCal);
  const weight   = p.weight_kg;
  const meals    = p.meals_logged       || [];
  const workouts = p.workouts_logged    || [];

  const wPct = Math.min(100, Math.round((water / 8) * 100));

  let html = `
    <div class="day-summary">
      ${summaryTile("🔥", "#E76F51", netCal, "kcal", "Net calories", `${remaining} remaining`)}
      ${summaryTile("💧", "#457B9D", water, "/ 8", "Water",
          water >= 8 ? "Goal reached!" : `${8 - water} more`, wPct, "#457B9D")}
      ${summaryTile("🍴", "#E9C46A", consumed, "kcal", "Eaten", `${burned} burned`)}
    </div>
  `;

  // Weight
  html += `<div class="weight-card">
    <div class="weight-icon">⚖</div>
    <div>
      <div class="weight-label">${isToday(app.histDate) ? "TODAY'S WEIGHT" : "WEIGHT"}</div>
      ${weight != null
        ? `<div><span class="weight-val">${weight.toFixed(1)}</span><span class="weight-unit">kg</span></div>`
        : `<div class="weight-none">Not logged</div>
           <div class="weight-hint">${isToday(app.histDate) ? "Tell Rena your weight to log it" : "No weight recorded this day"}</div>`
      }
    </div>
  </div>`;

  // Food log
  html += renderLogCard("food", "🍴", "#E76F51", "FOOD LOG",
    meals.length ? `${meals.length} meal${meals.length !== 1 ? "s" : ""}` : "Nothing logged",
    meals.length ? `${meals.reduce((s, m) => s + (m.calories || 0), 0)} kcal` : "",
    renderMeals(meals));

  // Workout log
  html += renderLogCard("workout", "🏃", "#2A9D8F", "WORKOUTS",
    workouts.length ? `${workouts.length} workout${workouts.length !== 1 ? "s" : ""}` : "No workouts",
    workouts.length ? `${workouts.reduce((s, w) => s + (w.calories_burned || 0), 0)} kcal` : "",
    renderWorkouts(workouts));

  document.getElementById("hist-day-content").innerHTML = html;

  // Bind expand/collapse
  document.querySelectorAll("[data-expand]").forEach(btn => {
    btn.addEventListener("click", () => {
      const id = btn.dataset.expand;
      const body = document.getElementById(`${id}-body`);
      const ch = btn.querySelector(".log-card-chevron");
      const open = body.style.display !== "none";
      body.style.display = open ? "none" : "block";
      if (ch) ch.classList.toggle("open", !open);
    });
  });
}

function summaryTile(icon, color, val, unit, label, sub, barPct, barColor) {
  return `<div class="summary-tile">
    <div class="summary-tile-icon" style="background:${color}22;color:${color}">${icon}</div>
    <div class="summary-tile-val">${val}<span class="summary-tile-unit">${unit}</span></div>
    <div class="summary-tile-label">${label}</div>
    <div class="summary-tile-sub">${sub}</div>
    ${barPct != null ? `<div class="summary-tile-bar" style="background:${barColor}22">
      <div style="width:${barPct}%;height:100%;background:${barColor};border-radius:2px;transition:width 0.5s"></div>
    </div>` : ""}
  </div>`;
}

function renderLogCard(id, icon, color, key, title, kcal, bodyHtml) {
  return `<div class="log-card">
    <div class="log-card-header" data-expand="${id}" style="cursor:pointer">
      <div class="log-card-icon" style="background:${color}20;color:${color}">${icon}</div>
      <div class="log-card-meta">
        <div class="log-card-key">${key}</div>
        <div class="log-card-title">${title}</div>
      </div>
      ${kcal ? `<span class="log-card-kcal" style="color:${color}">${kcal}</span>` : ""}
      <span class="log-card-chevron open">⌄</span>
    </div>
    <div id="${id}-body" class="log-card-body">
      <div class="log-card-divider"></div>
      ${bodyHtml}
    </div>
  </div>`;
}

function renderMeals(meals) {
  if (!meals.length) return `<div class="log-card-empty"><div class="log-card-empty-icon">🍴</div>Nothing logged</div>`;
  return meals.map(m => `<div class="meal-row">
    <div class="meal-info">
      <div class="meal-name">${m.name}</div>
      <div class="meal-macros">
        ${macroPill("P", m.protein_g, "#2A9D8F")}
        ${macroPill("C", m.carbs_g, "#457B9D")}
        ${macroPill("F", m.fat_g, "#E9C46A")}
      </div>
    </div>
    <div>
      <div class="meal-kcal">${m.calories}</div>
      <div class="meal-kcal-unit">kcal</div>
    </div>
  </div>`).join("");
}

function macroPill(label, val, color) {
  if (val == null) return "";
  return `<div class="macro-pill" style="background:${color}18">
    <span class="macro-pill-key" style="color:${color}">${label}</span>
    <span class="macro-pill-val">${val}g</span>
  </div>`;
}

function renderWorkouts(workouts) {
  if (!workouts.length) return `<div class="log-card-empty"><div class="log-card-empty-icon">🏃</div>No workouts logged</div>`;
  return workouts.map(w => `<div class="workout-row">
    <div class="workout-icon-box">${workoutIcon(w.type)}</div>
    <div class="workout-info">
      <div class="workout-name">${cap(w.type)}</div>
      <div class="workout-dur">${w.duration_min} min</div>
    </div>
    ${w.calories_burned > 0 ? `<div>
      <div class="workout-kcal">−${w.calories_burned}</div>
      <div class="workout-kcal-unit">kcal</div>
    </div>` : ""}
  </div>`).join("");
}

function workoutIcon(type = "") {
  const t = type.toLowerCase();
  if (t.includes("run") || t.includes("jog")) return "🏃";
  if (t.includes("walk")) return "🚶";
  if (t.includes("swim")) return "🏊";
  if (t.includes("bike") || t.includes("cycl")) return "🚴";
  if (t.includes("yoga") || t.includes("stretch")) return "🧘";
  if (t.includes("gym") || t.includes("lift") || t.includes("weight")) return "🏋";
  if (t.includes("hiit") || t.includes("circuit")) return "⚡";
  return "💪";
}

function cap(s = "") { return s.charAt(0).toUpperCase() + s.slice(1); }

// ── Plan ──────────────────────────────────────────────────────────────────

async function loadPlan() {
  if (!app.user) return;
  renderPlanShell();
  await loadPlanDay();
}

function renderPlanShell() {
  const d = app.planDate;
  const tmr = isTomorrow(d);
  document.getElementById("plan-content").innerHTML = `
    <div class="date-nav">
      <button class="date-nav-btn" id="plan-prev">‹</button>
      <div class="date-nav-center">
        <div class="date-nav-label">
          ${isToday(d) ? '<div class="date-nav-dot"></div>' : ""}
          <span>${dateDayLabel(d)}</span>
        </div>
      </div>
      <button class="date-nav-btn" id="plan-next" ${tmr ? "disabled" : ""}>›</button>
    </div>
    <div id="plan-day-content" class="cards-stack"><div class="loading-row"><div class="spinner"></div></div></div>
  `;
  document.getElementById("plan-prev").addEventListener("click", () => {
    app.planDate.setDate(app.planDate.getDate() - 1);
    renderPlanShell();
    loadPlanDay();
  });
  document.getElementById("plan-next").addEventListener("click", () => {
    if (!isTomorrow(app.planDate)) {
      app.planDate.setDate(app.planDate.getDate() + 1);
      renderPlanShell();
      loadPlanDay();
    }
  });
}

async function loadPlanDay() {
  const date = fmtDateISO(app.planDate);
  try {
    const [rawWorkout, rawMeal, rawNote] = await Promise.all([
      API.workoutPlan(app.user.id, date).catch(() => null),
      API.mealPlan(app.user.id, date).catch(() => null),
      API.tomorrowPlan(app.user.id, date).catch(() => null),
    ]);
    const workout = Array.isArray(rawWorkout) ? rawWorkout[0] : rawWorkout;
    const meal    = Array.isArray(rawMeal)    ? rawMeal[0]    : rawMeal;
    const note = rawNote?.summary ?? (typeof rawNote === "string" ? rawNote : null);
    renderPlanDay(workout, meal, note, date);
  } catch {
    document.getElementById("plan-day-content").innerHTML =
      `<div class="loading-row" style="color:var(--muted)">Couldn't load plan.</div>`;
  }
}

function renderPlanDay(workout, meal, note, date) {
  const isPast = !isToday(app.planDate) && !isTomorrow(app.planDate);
  const interactive = !isPast;

  let html = "";

  // Day plan note card (show for today/tomorrow or if there's a note)
  if (!isPast || note) {
    html += renderDayPlanCard(note || "", interactive, date);
  }

  // Workout section
  if (!isPast || workout) {
    html += renderWorkoutSection(workout, interactive, date);
  }

  // Meal section
  if (!isPast || meal) {
    html += renderMealSection(meal, interactive, date);
  }

  document.getElementById("plan-day-content").innerHTML = html;

  // Bind events
  document.querySelectorAll("[data-rena-ctx]").forEach(btn => {
    btn.addEventListener("click", () => openVoiceOverlay(btn.dataset.renaCtx));
  });
  document.querySelectorAll("[data-toggle-ex]").forEach(btn => {
    btn.addEventListener("click", async () => {
      const id = btn.dataset.toggleEx;
      try { await API.toggleExercise(app.user.id, id); loadPlanDay(); } catch {}
    });
  });
  document.querySelectorAll("[data-log-ex]").forEach(btn => {
    btn.addEventListener("click", async () => {
      const id = btn.dataset.logEx;
      btn.textContent = "…"; btn.disabled = true;
      try { await API.logExercise(app.user.id, id); loadPlanDay(); loadHome(); } catch {
        btn.textContent = "Log"; btn.disabled = false;
      }
    });
  });
  document.querySelectorAll("[data-log-meal]").forEach(btn => {
    btn.addEventListener("click", async () => {
      const id = btn.dataset.logMeal;
      btn.textContent = "…"; btn.disabled = true;
      try { await API.logMealFromPlan(app.user.id, id); loadPlanDay(); loadHome(); } catch {
        btn.textContent = "Log"; btn.disabled = false;
      }
    });
  });
  document.querySelectorAll("[data-delete-workout]").forEach(btn => {
    btn.addEventListener("click", async () => {
      const d = btn.dataset.deleteWorkout;
      btn.disabled = true;
      try { await API.deleteWorkoutPlan(app.user.id, d); loadPlanDay(); } catch { btn.disabled = false; }
    });
  });
  document.querySelectorAll("[data-delete-meal]").forEach(btn => {
    btn.addEventListener("click", async () => {
      const d = btn.dataset.deleteMeal;
      btn.disabled = true;
      try { await API.deleteMealPlan(app.user.id, d); loadPlanDay(); } catch { btn.disabled = false; }
    });
  });
  document.querySelectorAll(".ex-play-btn").forEach(btn => {
    btn.addEventListener("click", () => {
      const name = btn.dataset.exName;
      window.open(exerciseVideoUrl(name), "_blank");
    });
  });
}

function renderDayPlanCard(note, interactive, date) {
  const dl = isToday(app.planDate) ? "Today" : isTomorrow(app.planDate) ? "Tomorrow" : dateDayLabel(app.planDate);
  return `<div class="day-plan-card">
    <div class="day-plan-header">
      <div class="day-plan-icon">📝</div>
      <div>
        <div class="day-plan-title">${dl}'s Notes</div>
        <div class="day-plan-sub">${note ? `Your note for ${dl.toLowerCase()}` : "Remind yourself — drink water, eat light, go for a walk…"}</div>
      </div>
    </div>
    ${note ? `<div class="day-plan-note">${note}</div>` : ""}
    ${interactive ? `<button class="rena-action-btn" data-rena-ctx="notes:${date}">
      <div class="rena-action-circle">✦</div>
      <div class="rena-action-text">
        <div class="rena-action-label">${note ? "Update Note" : "Add a Note"}</div>
        <div class="rena-action-sub">${note ? "Tell Rena what to change" : "Tell Rena what to remember for you"}</div>
      </div>
      <span class="rena-action-chevron">›</span>
    </button>` : ""}
  </div>`;
}

function renderWorkoutSection(plan, interactive, date) {
  const suggestions = ["Swap an exercise", "Make it harder", "Add more cardio", "Make it shorter", "Upper body focus", "No equipment"];
  let inner = "";

  if (plan) {
    const totalCalories = (plan.exercises || []).reduce((s, ex) => s + (ex.calories_burned || 0), 0);
    inner += `<div class="plan-meta">
      <div class="plan-meta-name">🏋 ${plan.name || "Workout"}</div>
      <div class="plan-badge">${plan.total_duration_min || 0} min</div>
      <div class="plan-badge">${totalCalories} kcal</div>
    </div>
    <div class="plan-divider"></div>`;
    inner += (plan.exercises || []).map(ex => {
      const vol = ex.type === "cardio" && ex.duration_min
        ? `${ex.duration_min} min`
        : (ex.sets && ex.reps ? `${ex.sets}×${ex.reps}` : "");
      const muscles = (ex.target_muscles || "").split(",").slice(0, 2).join(", ");
      return `<div class="exercise-row">
        <button class="ex-check" data-toggle-ex="${ex.id}" ${!interactive ? "disabled" : ""}>
          ${ex.completed ? "✅" : "⭕"}
        </button>
        <div class="ex-info">
          <div class="ex-name${ex.completed ? " done" : ""}">${ex.name}</div>
          <div class="ex-sub">${[vol, muscles].filter(Boolean).join(" · ")}</div>
        </div>
        <span class="ex-kcal">${ex.calories_burned || 0} kcal</span>
        <button class="ex-play-btn" data-ex-name="${ex.name}" data-ex-muscles="${ex.target_muscles || ""}">▶</button>
        ${interactive ? `<button class="log-btn ${ex.logged ? "logged" : ""}" data-log-ex="${ex.id}" ${ex.logged ? "disabled" : ""}>${ex.logged ? "Logged" : "Log"}</button>` : ""}
      </div>`;
    }).join("");
    inner += `<div class="plan-divider"></div>`;
    if (interactive) {
      inner += `<div class="suggestion-chips">${suggestions.map(s =>
        `<button class="suggestion-chip" data-rena-ctx="update_workout_plan:${date}">${s}</button>`
      ).join("")}</div>`;
      inner += `<button class="rena-action-btn" data-rena-ctx="update_workout_plan:${date}">
        <div class="rena-action-circle">✦</div>
        <div class="rena-action-text">
          <div class="rena-action-label">Update Workout Plan</div>
          <div class="rena-action-sub">Swap exercises, change intensity or focus</div>
        </div>
        <span class="rena-action-chevron">›</span>
      </button>`;
    }
  } else {
    inner += `<div class="plan-empty">No workout plan yet.</div>`;
    if (interactive) {
      inner += `<button class="rena-action-btn" data-rena-ctx="workout_plan:${date}">
        <div class="rena-action-circle">✦</div>
        <div class="rena-action-text">
          <div class="rena-action-label">Add a Workout Plan</div>
          <div class="rena-action-sub">Rena will build ${isToday(app.planDate) ? "today's" : "tomorrow's"} workout for you</div>
        </div>
        <span class="rena-action-chevron">›</span>
      </button>`;
    }
  }

  const deleteBtn = (plan && interactive)
    ? `<button class="plan-delete-btn" data-delete-workout="${date}" title="Delete workout plan">✕</button>`
    : "";

  return `<div class="plan-section">
    <div class="plan-section-header">
      <div class="plan-section-icon" style="background:rgba(42,157,143,0.12);color:#2A9D8F">🏋</div>
      <div class="plan-section-key">WORKOUT</div>
      ${deleteBtn}
    </div>
    ${inner}
  </div>`;
}

function renderMealSection(plan, interactive, date) {
  let inner = "";

  if (plan) {
    const totalCalories = plan.total_calories ?? (plan.meals || []).reduce((s, m) => s + (m.calories || 0), 0);
    inner += `<div class="plan-meta">
      <div class="plan-meta-name">🍽 ${plan.meals?.length || 0} meals</div>
      <div class="plan-badge">${totalCalories} kcal</div>
    </div>`;
    if (plan.notes) inner += `<div class="plan-notes">${plan.notes}</div>`;
    inner += `<div class="plan-divider"></div>`;
    inner += (plan.meals || []).map(m => {
      const typeColors = { breakfast: "#F4A261", lunch: "#2A9D8F", dinner: "#457B9D", snack: "#9B7EC8" };
      const tc = typeColors[m.meal_type] || "#9B7EC8";
      return `<div class="meal-plan-row">
        <div class="meal-plan-top">
          <span class="meal-type-badge" style="color:${tc};background:${tc}20">${cap(m.meal_type || "")}</span>
          <span class="meal-plan-name">${m.name}</span>
          <span class="meal-plan-kcal">${m.calories} kcal</span>
        </div>
        ${m.description ? `<div class="meal-plan-desc">${m.description}</div>` : ""}
        <div class="meal-plan-footer">
          <span class="meal-plan-time">⏱ ${m.cook_time_min} min</span>
          <div class="meal-plan-macros">
            ${macroPill("P", m.protein_g, "#2A9D8F")}
            ${macroPill("C", m.carbs_g, "#E9C46A")}
            ${macroPill("F", m.fat_g, "#E76F51")}
          </div>
        </div>
        <div class="meal-plan-actions">
          <button class="watch-btn" onclick="window.open('https://m.youtube.com/results?search_query=${encodeURIComponent((m.youtube_query || m.name) + " recipe")}','_blank')">▶ Watch</button>
          ${interactive ? `<button class="log-btn ${m.logged ? "logged" : ""}" data-log-meal="${m.id}" ${m.logged ? "disabled" : ""}>${m.logged ? "Logged" : "Log"}</button>` : ""}
        </div>
      </div>`;
    }).join("");
    if (interactive) {
      inner += `<div class="plan-divider"></div>
      <button class="rena-action-btn" data-rena-ctx="update_meal_plan:${date}">
        <div class="rena-action-circle">✦</div>
        <div class="rena-action-text">
          <div class="rena-action-label">Update Meal Plan</div>
          <div class="rena-action-sub">Swap meals, adjust calories or preferences</div>
        </div>
        <span class="rena-action-chevron">›</span>
      </button>`;
    }
  } else {
    inner += `<div class="plan-empty">No meal plan yet.</div>`;
    if (interactive) {
      inner += `<button class="rena-action-btn" data-rena-ctx="meal_plan:${date}">
        <div class="rena-action-circle">✦</div>
        <div class="rena-action-text">
          <div class="rena-action-label">Add a Meal Plan</div>
          <div class="rena-action-sub">Rena will plan ${isToday(app.planDate) ? "today's" : "this day's"} meals</div>
        </div>
        <span class="rena-action-chevron">›</span>
      </button>`;
    }
  }

  const deleteMealBtn = (plan && interactive)
    ? `<button class="plan-delete-btn" data-delete-meal="${date}" title="Delete meal plan">✕</button>`
    : "";

  return `<div class="plan-section">
    <div class="plan-section-header">
      <div class="plan-section-icon" style="background:rgba(244,162,97,0.12);color:#F4A261">🍴</div>
      <div class="plan-section-key">MEALS</div>
      ${deleteMealBtn}
    </div>
    ${inner}
  </div>`;
}

// ── Scan ──────────────────────────────────────────────────────────────────

function bindScan() {
  const showEmpty = () => {
    if (!document.getElementById("scan-preview").classList.contains("hidden")) return;
    document.getElementById("scan-result").innerHTML = `
      <div class="empty-scan">
        <div class="empty-scan-icon">📷</div>
        <div class="empty-scan-text">Take a photo or pick from gallery<br/>Rena will identify the food and estimate calories</div>
      </div>`;
  };
  showEmpty();

  [document.getElementById("scan-file"), document.getElementById("scan-camera")].forEach(input => {
    input?.addEventListener("change", async (e) => {
      const file = e.target.files[0];
      if (!file) return;
      e.target.value = "";

      // Show preview
      const url = URL.createObjectURL(file);
      const prevWrap = document.getElementById("scan-preview");
      prevWrap.classList.remove("hidden");
      prevWrap.innerHTML = `<div class="scan-preview-wrap">
        <img class="scan-preview-img" src="${url}" alt="Food photo"/>
        <div class="scan-overlay" id="scan-overlay">
          <div class="spinner" style="border-color:rgba(255,255,255,0.3);border-top-color:white;width:32px;height:32px"></div>
          <div class="scan-overlay-text">Analyzing your food…</div>
        </div>
      </div>`;
      document.getElementById("scan-result").innerHTML = "";

      app.scanItems = [];
      app.scanAdjusted = {};
      app.scanLogged = false;

      const reader = new FileReader();
      reader.onload = async (ev) => {
        const b64 = ev.target.result.split(",")[1];
        const mime = file.type || "image/jpeg";
        try {
          const result = await API.scanImage(app.user.id, b64, mime);
          document.getElementById("scan-overlay")?.remove();
          prevWrap.querySelector(".scan-preview-wrap").innerHTML +=
            `<button class="scan-preview-close" onclick="resetScan()">✕</button>`;
          renderScanResult(result);
        } catch {
          document.getElementById("scan-overlay")?.remove();
          prevWrap.querySelector(".scan-preview-wrap").innerHTML +=
            `<button class="scan-preview-close" onclick="resetScan()">✕</button>`;
          document.getElementById("scan-result").innerHTML =
            `<div class="loading-row" style="color:#e05252">Scan failed. Try again.</div>`;
        }
      };
      reader.readAsDataURL(file);
    });
  });
}

function resetScan() {
  document.getElementById("scan-preview").classList.add("hidden");
  document.getElementById("scan-preview").innerHTML = "";
  document.getElementById("scan-result").innerHTML = `
    <div class="empty-scan">
      <div class="empty-scan-icon">📷</div>
      <div class="empty-scan-text">Take a photo or pick from gallery<br/>Rena will identify the food and estimate calories</div>
    </div>`;
  app.scanItems = [];
  app.scanAdjusted = {};
  app.scanLogged = false;
}

function renderScanResult(result) {
  let items = result.items || [];
  if (!items.length && result.identified && result.total_calories) {
    items = [{ name: result.description || "Food", calories: result.total_calories,
      protein_g: result.total_protein_g || 0, carbs_g: result.total_carbs_g || 0,
      fat_g: result.total_fat_g || 0 }];
  }
  if (!items.length) {
    document.getElementById("scan-result").innerHTML =
      `<div class="loading-row" style="color:var(--muted)">Couldn't identify any food in this photo.</div>`;
    return;
  }

  app.scanItems = items;
  items.forEach(item => { app.scanAdjusted[item.name] = item.calories; });

  let html = items.map((item, i) => renderScanItemCard(item, i)).join("");
  html += `<div class="scan-footer" id="scan-footer">
    <div class="scan-footer-total">
      <span class="scan-footer-total-label">Total</span>
      <span class="scan-footer-total-kcal" id="scan-total-kcal">${totalAdjusted()} kcal</span>
    </div>
    <button class="btn-log-all" id="btn-log-all" onclick="logAllItems()">Log ${items.length} item${items.length !== 1 ? "s" : ""}</button>
  </div>`;

  document.getElementById("scan-result").innerHTML = html;

  // Bind sliders
  items.forEach((item, i) => {
    const slider = document.getElementById(`scan-slider-${i}`);
    const kcalEl = document.getElementById(`scan-kcal-${i}`);
    if (slider) {
      slider.addEventListener("input", () => {
        const val = Math.round(parseInt(slider.value) / 10) * 10;
        app.scanAdjusted[item.name] = val;
        if (kcalEl) kcalEl.textContent = `${val} kcal`;
        const totalEl = document.getElementById("scan-total-kcal");
        if (totalEl) totalEl.textContent = `${totalAdjusted()} kcal`;
      });
    }
  });
}

function renderScanItemCard(item, i) {
  const min = 50;
  const max = Math.max(500, item.calories * 3);
  return `<div class="scan-item-card" id="scan-item-card-${i}">
    <div class="scan-item-header">
      <div class="scan-item-name">${item.name}</div>
      <button class="scan-item-remove" onclick="removeScanItem(${i})" title="Remove">✕</button>
    </div>
    <div class="scan-item-kcal-row">
      <span class="scan-item-kcal" id="scan-kcal-${i}">${item.calories} kcal</span>
      ${item.weight_g ? `<span class="scan-item-grams">· ~${item.weight_g}g</span>` : ""}
    </div>
    <input type="range" class="rena-slider" id="scan-slider-${i}"
      min="${min}" max="${max}" value="${item.calories}" step="10"/>
    <div class="slider-labels">
      <span>${min} kcal</span>
      <span style="color:var(--muted2)">Adjust portion</span>
      <span>${max} kcal</span>
    </div>
    <div class="scan-item-macro-row">
      ${macroTag(item.protein_g, "Protein", "#2A9D8F")}
      ${macroTag(item.carbs_g,   "Carbs",   "#E9C46A")}
      ${macroTag(item.fat_g,     "Fat",     "#F4A261")}
    </div>
  </div>`;
}

function removeScanItem(i) {
  const item = app.scanItems[i];
  if (!item) return;
  delete app.scanAdjusted[item.name];
  app.scanItems.splice(i, 1);
  // Re-render result area preserving the preview/close button
  const resultEl = document.getElementById("scan-result");
  if (!resultEl) return;
  if (!app.scanItems.length) {
    resultEl.innerHTML = `<div class="scan-empty-removed">All items removed. Take another photo to scan again.</div>`;
    return;
  }
  let html = app.scanItems.map((it, idx) => renderScanItemCard(it, idx)).join("");
  html += `<div class="scan-footer" id="scan-footer">
    <div class="scan-footer-total">
      <span class="scan-footer-total-label">Total</span>
      <span class="scan-footer-total-kcal" id="scan-total-kcal">${totalAdjusted()} kcal</span>
    </div>
    <button class="btn-log-all" id="btn-log-all" onclick="logAllItems()">Log ${app.scanItems.length} item${app.scanItems.length !== 1 ? "s" : ""}</button>
  </div>`;
  resultEl.innerHTML = html;
  // Re-attach slider listeners
  app.scanItems.forEach((item, idx) => {
    const slider = document.getElementById(`scan-slider-${idx}`);
    const kcalEl = document.getElementById(`scan-kcal-${idx}`);
    if (slider) {
      slider.addEventListener("input", () => {
        const val = Math.round(parseInt(slider.value) / 10) * 10;
        app.scanAdjusted[item.name] = val;
        if (kcalEl) kcalEl.textContent = `${val} kcal`;
        const totalEl = document.getElementById("scan-total-kcal");
        if (totalEl) totalEl.textContent = `${totalAdjusted()} kcal`;
      });
    }
  });
}

function macroTag(val, label, color) {
  return `<div class="macro-tag" style="background:${color}18">
    <div class="macro-tag-val" style="color:${color}">${val || 0}g</div>
    <div class="macro-tag-label">${label}</div>
  </div>`;
}

function totalAdjusted() {
  return Object.values(app.scanAdjusted).reduce((s, v) => s + v, 0);
}

async function logAllItems() {
  if (app.scanLogged) return;
  const btn = document.getElementById("btn-log-all");
  if (btn) { btn.disabled = true; btn.innerHTML = `<span class="spinner-sm"></span> Logging…`; }

  for (const item of app.scanItems) {
    const cal = app.scanAdjusted[item.name] ?? item.calories;
    try {
      await API.logMeal(app.user.id, item.name, cal, item.protein_g, item.carbs_g, item.fat_g);
    } catch {}
  }

  app.scanLogged = true;
  const footer = document.getElementById("scan-footer");
  if (footer) {
    const total = totalAdjusted();
    footer.innerHTML = `
      <div class="scan-footer-total">
        <span class="scan-footer-total-label">Total</span>
        <span class="scan-footer-total-kcal">${total} kcal</span>
      </div>
      <div class="scan-success">✓ All items logged!</div>
      <button class="btn-scan-another" onclick="resetScan()">Scan another</button>
    `;
  }
  loadHome();
}

// Update logMeal to include macros
const _origLogMeal = API.logMeal.bind(API);
API.logMeal = function(userId, name, calories, proteinG, carbsG, fatG) {
  return this._fetch("/log/meal", {
    method: "POST",
    body: JSON.stringify({ user_id: userId, name, calories,
      protein_g: proteinG || 0, carbs_g: carbsG || 0, fat_g: fatG || 0 }),
  });
};

// ── Voice Overlay ─────────────────────────────────────────────────────────

const HINTS = {
  home: [
    { icon: "🍴", label: "Log food",     color: "#E76F51", ctx: "log_food" },
    { icon: "💧", label: "Log water",    color: "#457B9D", ctx: "log_water" },
    { icon: "🏃", label: "Log exercise", color: "#2A9D8F", ctx: "log_workout" },
    { icon: "⚖",  label: "Log weight",  color: "#9B7EC8", ctx: "log_weight" },
  ],
  history: [
    { icon: "🍴", label: "Remove food log",    color: "#E76F51", ctx: "history" },
    { icon: "🏃", label: "Remove exercise",    color: "#2A9D8F", ctx: "history" },
    { icon: "💧", label: "Remove water entry", color: "#457B9D", ctx: "history" },
    { icon: "⚖",  label: "Log weight",        color: "#9B7EC8", ctx: "log_weight" },
  ],
  // plan tab hints are generated dynamically in openVoiceOverlay with the current planDate
  scan: [
    { icon: "🍴", label: "Log food",     color: "#E76F51", ctx: "log_food" },
    { icon: "💧", label: "Log water",    color: "#457B9D", ctx: "log_water" },
    { icon: "🏃", label: "Log exercise", color: "#2A9D8F", ctx: "log_workout" },
    { icon: "⚖",  label: "Log weight",  color: "#9B7EC8", ctx: "log_weight" },
  ],
};

function openVoiceOverlay(pendingCtx) {
  // Plan tab hints and default context must include the current plan date so the backend
  // knows which date to generate/update plans for — prompts reference [workout_date] etc.
  const planDate = fmtDateISO(app.planDate);
  const hints = app.tab === "plan" ? [
    { icon: "🏋", label: "Plan my workout", color: "#2A9D8F", ctx: `workout_plan:${planDate}` },
    { icon: "🍴", label: "Plan my meals",   color: "#F4A261", ctx: `meal_plan:${planDate}` },
    { icon: "📝", label: "Add a note",      color: "#9B7EC8", ctx: `notes:${planDate}` },
    { icon: "🍴", label: "Log food",        color: "#E76F51", ctx: "log_food" },
  ] : (HINTS[app.tab] || HINTS.home);
  const defCtx = {
    home:    "home",
    history: "history",
    plan:    `notes:${planDate}`,
    scan:    "scan",
  }[app.tab] || "home";
  const ctx = pendingCtx || defCtx;

  // Render hints
  document.getElementById("voice-hints").innerHTML = hints.map(h =>
    `<button class="voice-hint-chip" style="background:${h.color}12" onclick="switchVoiceCtx('${h.ctx}')">
      <span class="voice-hint-icon" style="color:${h.color}">${h.icon}</span>
      <span class="voice-hint-label">${h.label}</span>
    </button>`
  ).join("");

  document.getElementById("voice-overlay").classList.remove("hidden");
  document.getElementById("voice-transcript").textContent = "";
  document.getElementById("voice-transcript-wrap").style.display = "none";

  // Auto-start voice
  setTimeout(() => {
    const first = (app.user?.name || "").split(" ")[0];
    voice.connect(app.user.id, ctx, first);
    setVoiceActive(true);
  }, 200);
}

function closeVoiceOverlay() {
  voice.disconnect();
  setVoiceActive(false);
  document.getElementById("voice-overlay").classList.add("hidden");
  // Refresh current tab
  if (app.tab === "home")    loadHome();
  if (app.tab === "history") loadHistory();
  if (app.tab === "plan")    loadPlan();
}

function switchVoiceCtx(ctx) {
  voice.disconnect();
  setTimeout(() => {
    const first = (app.user?.name || "").split(" ")[0];
    voice.connect(app.user.id, ctx, first);
    setVoiceActive(true);
  }, 100);
}

function setVoiceActive(active) {
  const btn = document.getElementById("voice-talk-btn");
  const icon = document.getElementById("voice-btn-icon");
  const label = document.getElementById("voice-btn-label");
  const sub = document.getElementById("voice-btn-sub");
  const end = document.getElementById("voice-btn-end");
  if (!btn) return;
  btn.classList.toggle("active", active);
  if (active) {
    icon.innerHTML = `<div class="thinking-dots"><div class="thinking-dot"></div><div class="thinking-dot"></div><div class="thinking-dot"></div></div>`;
    label.textContent = "Connecting…";
    sub.style.display = "none";
    end.style.display = "inline";
  } else {
    icon.innerHTML = `<span class="voice-wave-icon">≋</span>`;
    label.textContent = "Talk to Rena";
    sub.style.display = "";
    end.style.display = "none";
  }
}

function bindVoiceEvents() {
  document.getElementById("voice-backdrop").addEventListener("click", closeVoiceOverlay);
  document.getElementById("voice-talk-btn").addEventListener("click", () => {
    if (voice.state !== "idle") {
      closeVoiceOverlay();
    } else {
      const first = (app.user?.name || "").split(" ")[0];
      const ctx = { home: "home", history: "history", plan: "update_workout_plan", scan: "scan" }[app.tab] || "home";
      voice.connect(app.user.id, ctx, first);
      setVoiceActive(true);
    }
  });

  voice.addEventListener("statechange", (e) => {
    const state = e.detail;
    if (document.getElementById("voice-overlay").classList.contains("hidden")) return;

    const label = document.getElementById("voice-btn-label");
    const icon  = document.getElementById("voice-btn-icon");
    const tw    = document.getElementById("voice-transcript-wrap");
    const te    = document.getElementById("voice-transcript");
    const ts    = voice.toolStatus;

    // Button label stays simple — tool status goes in the transcript area
    const labels = {
      idle:       "Talk to Rena",
      connecting: "Connecting…",
      listening:  "Listening…",
      thinking:   "Thinking…",
      speaking:   "Rena is speaking…",
      error:      "Connection error",
    };
    if (label) label.textContent = labels[state] || state;

    if (state === "listening" || state === "speaking") {
      if (icon) icon.innerHTML = `<span class="voice-wave-icon">≋</span>`;
    } else if (state === "thinking") {
      if (icon) icon.innerHTML = `<div class="thinking-dots"><div class="thinking-dot"></div><div class="thinking-dot"></div><div class="thinking-dot"></div></div>`;
    }

    // Transcript area: show tool status when thinking, clear on listening/speaking/connecting
    if (state === "thinking" && ts) {
      if (te) { te.textContent = ts; te.className = "voice-transcript voice-tool-status"; }
      if (tw) tw.style.display = "block";
    } else if (state === "listening" || state === "connecting" || state === "speaking") {
      if (te) { te.textContent = ""; te.className = "voice-transcript"; }
      if (tw) tw.style.display = "none";
    }
    // "speaking" state: transcript area repopulated by transcriptchange events
  });

  voice.addEventListener("transcriptchange", (e) => {
    const tw = document.getElementById("voice-transcript-wrap");
    const te = document.getElementById("voice-transcript");
    if (!te) return;
    if (e.detail) {
      te.textContent = e.detail;
      te.className = "voice-transcript"; // speech transcript — normal style
      if (tw) tw.style.display = "block";
    } else {
      te.className = "voice-transcript";
      if (tw) tw.style.display = "none";
    }
  });

  voice.addEventListener("turncomplete", () => {
    setTimeout(() => {
      if (app.tab === "home")    loadHome();
      if (app.tab === "history") loadHistory();
      if (app.tab === "plan")    loadPlan();
    }, 500);
  });

  // Close overlay automatically if the WS drops unexpectedly while it's open
  voice.addEventListener("sessionended", () => {
    const overlay = document.getElementById("voice-overlay");
    if (overlay && !overlay.classList.contains("hidden")) {
      setVoiceActive(false);
      overlay.classList.add("hidden");
      document.getElementById("voice-transcript").textContent = "";
      document.getElementById("voice-transcript-wrap").style.display = "none";
      // Refresh data for the current tab
      if (app.tab === "home")    loadHome();
      if (app.tab === "history") loadHistory();
      if (app.tab === "plan")    loadPlan();
    }
  });
}

// ── Dev Sheet ─────────────────────────────────────────────────────────────

function bindDevSheet() {
  document.querySelectorAll(".settings-gear-btn").forEach(btn => btn.addEventListener("click", () => {
    // Populate profile
    const u = app.user || {};
    const avatarEl = document.getElementById("settings-avatar");
    if (u.picture) {
      avatarEl.innerHTML = `<img src="${u.picture}" alt="${u.name}" style="width:100%;height:100%;border-radius:50%;object-fit:cover">`;
    } else {
      avatarEl.textContent = (u.name || "?")[0].toUpperCase();
    }
    document.getElementById("settings-name").textContent  = u.name  || "";
    document.getElementById("settings-email").textContent = u.email || "";
    const first = (u.name || "User").split(" ")[0];
    document.getElementById("dev-seed").textContent  = `🧪 Seed 7 Days Data for ${first}`;
    document.getElementById("dev-reset").textContent = `↩ Reset ${first}'s Onboarding`;
    document.getElementById("dev-sheet").classList.remove("hidden");
  }));
  document.getElementById("dev-close").addEventListener("click", () => {
    document.getElementById("dev-sheet").classList.add("hidden");
  });
  document.getElementById("dev-sheet").addEventListener("click", (e) => {
    if (e.target === e.currentTarget) document.getElementById("dev-sheet").classList.add("hidden");
  });
  document.getElementById("dev-reset").addEventListener("click", async () => {
    if (!confirm("Reset all onboarding data?")) return;
    try {
      await API.reset(app.user.id);
    } catch {}
    signOut();
  });
  document.getElementById("dev-seed").addEventListener("click", async () => {
    const el = document.getElementById("dev-seed");
    const first = (app.user?.name || "User").split(" ")[0];
    const label = `🧪 Seed 7 Days Data for ${first}`;
    el.textContent = "⏳ Seeding…"; el.disabled = true;
    try {
      await API.seed(app.user.id);
      el.textContent = "✓ Seeded!";
      setTimeout(() => { el.textContent = label; el.disabled = false; }, 2000);
    } catch {
      el.textContent = label; el.disabled = false;
    }
  });
  document.getElementById("dev-signout").addEventListener("click", signOut);
}

// ── Sign Out ──────────────────────────────────────────────────────────────

function signOut() {
  localStorage.removeItem("rena_user");
  localStorage.removeItem("rena_profile");
  localStorage.removeItem("rena_has_goal");
  app.user    = null;
  app.profile = null;
  app.hasGoal = false;
  document.getElementById("dev-sheet").classList.add("hidden");
  showScreen("login");
  initGoogleSignIn();
}

// expose for inline handlers
window.resetScan = resetScan;
window.logAllItems = logAllItems;
window.removeScanItem = removeScanItem;
window.switchVoiceCtx = switchVoiceCtx;

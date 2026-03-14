#   

**Name meaning:** "Joyous melody" (Hebrew) / "Peaceful" (Greek) / "Queen" (Latin)
**Tagline:** Your goal. Your timeline. Your Rena.
**Challenge category:** Live Agents (Gemini Live Agent Challenge 2026)

---

## Core Concept: Your Goal, Your Timeline

When you first open Rena, she asks one question — *"What are you working toward?"*

You tell her in your own words:
- *"I want to feel confident at my friend's wedding in July"*
- *"Beach trip in 10 weeks"*
- *"I want to run a half marathon in October"*
- *"I just want to feel better by the holidays"*

Rena sets a countdown, understands your timeline urgency, and becomes a daily companion
working toward that one goal. Everything she does — food suggestions, check-ins, nudges —
is filtered through what you're actually working toward, not a generic calorie target.

Optionally, you can share a photo — an outfit you want to wear, a destination, an inspiration
image. Rena generates a **personal vision board** that evolves as you make progress.
It gets more vivid, more defined, more radiant over time. Tied to real metrics, not just vibes.

---

## Design Principle: Rena Does the Work

Most health apps fail because logging is a chore. Rena flips this:
- Scans your **photo gallery** for food photos you already took
- Listens to you talk naturally and extracts the data
- Learns your patterns and fills in gaps with smart guesses
- Asks for confirmation, not manual input
- You should rarely feel like you're "logging" anything

---

## Core Features (v1 — build these first)

### 1. Goal & Visual Journey
- Set your goal + deadline via voice on first launch
- Optionally upload a photo (outfit, destination, inspiration)
- Rena generates a personal visual that evolves with your progress
- Gets more vivid/radiant as you hit milestones, dims if you fall off track
- Weekly milestone moments — Rena narrates your progress story
- Goal countdown always visible — urgency without anxiety

### 2. Effortless Food Intelligence
- **Gallery scan** — Rena quietly checks your recent photos for food pics and asks
  *"Was this today's lunch?"* — you already took the photo, she does the rest
- **Voice log** — just talk: *"I had salmon, salad, and sparkling water"* — she logs it
- **Camera snap** — point at your plate for instant calorie + macro estimate
- **Barcode scan** — packaged food, instant nutrition breakdown
- **Pattern filling** — if nothing is logged by 2pm, Rena asks *"Did you have your usual
  oatmeal this morning?"* based on your history
- **Restaurant menu camera** — point at a menu, she highlights what fits your goal in green

### 3. Daily Rena Conversations (Live Agent showcase)
The core Gemini Live API feature. Voice-first, feels like talking to a friend.

- **Morning brief** (60 seconds)
  — Goal countdown update
  — Today's focus and calorie target
  — What to eat, energy check-in
  — *"You're 5 weeks out — this week is important"*

- **Evening debrief**
  — What went well, what to adjust
  — Tomorrow's plan
  — Progress update on visual journey

- **Proactive nudges throughout the day**
  — Water reminders with context
  — *"You haven't eaten in 5 hours — quick snack before your energy dips"*
  — Workout reminder tied to your goal timeline

- **Emotional check-ins**
  — Bad day detected (missed meals, stress patterns)
  — Rena adjusts tone: supportive not pushy
  — *"One off day doesn't change where you're going"*

### 4. Goal-Aware Recommendations
- **Pre/post workout nutrition** — based on today's logged activity
- **Weekly adaptation** — as goal date gets closer, Rena tightens or relaxes targets
  based on your actual progress
- **Smart grocery list** — based on the week's meal plan Rena suggests

---

## Progressive Features (add after v1 is stable)

- Intermittent fasting mode
- Sleep-aware daily targets
- Friends/accountability partner (share goal progress)
- Family mode (multiple profiles)
- Travel mode (adjusted goals, local restaurant finder)
- Allergy and dietary restriction memory
- Supplement and medication reminders
- Achievement milestones and streaks
- Stress eating pattern detection
- Workout planner + logging

---

## Tech Stack (planned)

- **AI core:** Gemini Live API + Gemini ADK
- **Multimodal:** Vision (camera/gallery), Audio (voice), Image generation (visual journey)
- **iOS app:** SwiftUI
- **Backend/Agent:** Google Agent Development Kit (ADK)
- **Database:** Firestore (goals, food history, progress, visual states)
- **Hosting:** Cloud Run
- **Credits:** $100 Google Cloud credits (apply by Mar 13, 2026)

---

## Submission Checklist (due March 16, 2026)

- [ ] Public code repository with setup instructions
- [ ] Demo video (≤ 4 minutes showing actual software)
- [ ] Architecture diagram
- [ ] Text description of features and technologies
- [ ] Proof of Google Cloud deployment

---

## Judging Criteria

- **40%** Innovation & Multimodal UX
- **30%** Technical Implementation (Google Cloud)
- **30%** Demo & Presentation

# Cover Day-Night: brightness-method directionality

_Design — 2026-07-22_

## Problem

In `automation/coversDayNight.yaml` the **brightness** day-night method is
stateless and non-directional. It derives two independent booleans from the
current lux reading ([lines 740-741](../../../automation/coversDayNight.yaml)):

- `bright_enough_to_open` → `lux >= open_lux_level`
- `dark_enough_to_close` → `lux <= close_lux_level`

and resolves `desired_position` with "closed wins" in the overlap. Because a lux
threshold carries no notion of time-of-day direction, **any** sustained darkness
re-arms the close — a passing thunderstorm at noon, a solar eclipse, an
over-tight threshold gap — not just the evening. The covers then close in the
middle of the day and re-open when it brightens again.

The intended behaviour is a **directional day-night cycle**: open once in the
morning, close once in the evening, and ignore darkness in between.

A pure lux threshold fundamentally cannot distinguish "dark because it is
evening" from "dark because a storm rolled in at midday" — the two produce an
identical sensor reading. Some anchor for _direction_ is required.

## Goal

Make the brightness method directional by fencing each transition to a window
anchored on the sun, while brightness remains the actual trigger inside that
window. The sun anchor is a **coarse directional fence, not the trigger**: it
answers "which half of the day are we in, and don't let brightness act absurdly
early", nothing more.

Scope is the **brightness method only**. The `sun` and `time` methods are
already directional (real sunset, real clock time) and do not have this bug;
they are untouched.

## Approach — sunrise/sunset arming gates

Anchor on **today's sunrise and sunset**, already computed as `todays_sunrise` /
`todays_sunset` ([lines 681-698](../../../automation/coversDayNight.yaml)). A
single offset constant defines how far _before_ each event brightness may act.

### The rule

Brightness may **lead** the sun event by at most `offset`, and may **lag** it
freely until the opposite phase begins. The two derived boundaries —
`sunrise − offset` (morning) and `sunset − offset` (evening) — split the day
into an **open half** and a **close half**:

- **Open armed:** `sunrise − offset ≤ now < sunset − offset` (the day half).
- **Close armed:** `now ≥ sunset − offset` (the night half). One-sided: after
  midnight `todays_sunset` points at the new day's (future) sunset, so this
  falls false again in the small hours — no re-close overnight.

This kills both failure modes at once: a midday storm is hours before
`sunset − offset` so it cannot arm the close; a 3 a.m. light spike is hours
before `sunrise − offset` so it cannot arm the open.

### Changes to `automation/coversDayNight.yaml`

New constant, near the brightness variables:

```yaml
# How far before today's sunrise/sunset the brightness method may act. Brightness
# may LEAD the sun event by at most this much (bright mornings / overcast dusks)
# and LAG freely until the opposite phase. This is what makes the brightness
# thresholds directional — without it a midday storm arms the close and a 3am
# light arms the open. Constant (not an input) to keep the UI simple; tune here.
brightness_offset_sunrise_sunset: 3600 # 60 min
```

Two arming windows:

```yaml
# Open armed from the morning boundary until the evening boundary (the day half).
brightness_open_armed: >
  {{ todays_sunrise | float(0) > 0 and todays_sunset | float(0) > 0
     and now_ts >= todays_sunrise | float(0) - brightness_offset_sunrise_sunset
     and now_ts <  todays_sunset  | float(0) - brightness_offset_sunrise_sunset }}
# Close armed from the evening boundary onward (the night half). One-sided: after
# midnight todays_sunset points to the new day's (future) sunset, so this falls
# false again in the small hours — no re-close overnight.
brightness_close_armed: >
  {{ todays_sunset | float(0) > 0
     and now_ts >= todays_sunset | float(0) - brightness_offset_sunrise_sunset }}
```

AND the gates into the existing brightness branches of `schedule_wants_open`
([line 845-846](../../../automation/coversDayNight.yaml)) and
`schedule_wants_closed` ([line 856-857](../../../automation/coversDayNight.yaml)):

```yaml
# schedule_wants_open, brightness branch:
{% set due = brightness_open_armed and bright_since is not none
             and (now_ts - bright_since | float(0)) >= stabilizer_seconds | float(0) %}

# schedule_wants_closed, brightness branch:
{% set due = brightness_close_armed and dark_since is not none
             and (now_ts - dark_since | float(0)) >= stabilizer_seconds | float(0) %}
```

Nothing downstream changes. The stabilizer `_bright_since` / `_dark_since`
clocks keep running on raw lux regardless of the gate — the gate only decides
_when acting is allowed_ — so "closed wins", `_commanded`, `transition_needed`,
and the earliest/latest window logic all compose unchanged.

## What this removes

The `config_valid` guard (requiring `close_lux_level < open_lux_level`),
discussed earlier as the fix, is **no longer needed and will not be added.**
With the gates, the open and close thresholds are evaluated in **disjoint time
windows** and can never compete, so the hysteresis dead band that `close < open`
existed to create is replaced by the temporal separation:

- Day half: only the open threshold acts → "open when bright, else hold".
- Night half: only the close threshold acts → "close when dark, else hold".

Both halves are monotonic (open-or-hold / close-or-hold), so there is no
flapping even with equal or inverted thresholds:

- **Equal (open=close=100):** opens at 100 in the morning, closes at 100 in the
  evening.
- **Inverted (open=30, close=500):** opens at 30 lux in the morning, closes
  below 500 lux in the evening (an early-ish, quirky close point, but not
  broken).

`close < open` remains **advisory** in the field description (darker to close
than to open is what users expect) but is not enforced.

## Behaviour traces

Summer, sunrise 05:30, sunset 21:00, offset 60 min → boundaries 04:30 / 20:00.

**Normal day**

- 02:00 — before both boundaries → neither armed → hold (closed).
- 05:45 — lux past open, open armed → **opens.**
- 13:00 — thunderstorm, lux crashes; close not armed (< 20:00) → **stays open.**
- 20:15 — clear bright dusk gives way, lux drops below close, close armed →
  **closes.**
- 22:30 — floodlight spikes sensor; open disarmed for the night → **stays
  closed.**

**Persistently dark evening (storm from 17:00 that never clears)**

- 17:00 — lux crashes → `dark_since` set; close not armed → stays open.
- 17:00–20:00 — still dark → still open; `dark_since` keeps its 17:00 value.
- 20:00 — boundary reached → close armed; `dark_since` is 3 h old so the
  stabilizer is already satisfied → **closes immediately at the boundary.**

The offset only bounds how _early_ a close may fire; persistent darkness always
closes at `sunset − offset` at the latest. Covers are never stuck open.

## Edge cases

- **`sun.sun` unavailable** (`todays_sunrise`/`todays_sunset` resolve to 0): both
  windows are false → brightness holds → covers do not move. Safe fail.
- **Both `_bright_since` and `_dark_since` set at once** (possible with equal or
  inverted thresholds): harmless — each window reads only its own timestamp.
- **Never gets dark in the evening** (bright all night, e.g. strong artificial
  light): brightness never closes — a pre-existing property of the method,
  handled by the optional `latest_close` backstop. Not introduced here.

## Deliberate tradeoff

During a _daytime_ storm the room is dark but the covers stay up until the
evening window — this is exactly the "don't slam shut at midday" behaviour
requested. "Close whenever it is dark" and "ignore midday darkness" are the same
signal; you cannot have both.

## Testing

No automated test harness exists yet (see memory: Dockerized HA test environment
is a future task). Validation is manual on a managed instance:

1. Brightness method, drop lux below close threshold at midday → covers stay
   open.
2. Drop lux below close threshold after `sunset − offset` → covers close.
3. Spike lux above open threshold at night → covers stay closed.
4. Persistent darkness from mid-afternoon → covers close at `sunset − offset`.
5. Equal and inverted thresholds → no flapping; sane open/close points.

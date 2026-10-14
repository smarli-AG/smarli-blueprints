# smarli. Blueprints — Runtime testing plan

**Status:** plan only, nothing built yet. Written 2026-10-14.
**Tracking issue:** [#9](https://github.com/smarli-AG/smarli-blueprints/issues/9).

This document records how runtime tests in a Docker Home Assistant instance should become part of
the blueprint development process. It also records why a `check_config` job in CI was **not**
built. Read [test-environment.md](test-environment.md) first: it describes the existing test
environment and its hard-won gotchas. This plan builds on it.

## Contents

- [Starting point](#starting-point)
- [Decision: no `check_config` job per pull request](#decision-no-check_config-job-per-pull-request)
- [Plan](#plan)
  - [Step 1 — Move the environment into this repo](#step-1--move-the-environment-into-this-repo)
  - [Step 2 — One test per blueprint behaviour](#step-2--one-test-per-blueprint-behaviour)
  - [Step 3 — Fake MQTT devices for device-selector blueprints](#step-3--fake-mqtt-devices-for-device-selector-blueprints)
  - [Step 4 — The development loop](#step-4--the-development-loop)
  - [Step 5 — CI, after the suite is stable](#step-5--ci-after-the-suite-is-stable)
- [Open questions](#open-questions)
- [Resume this work](#resume-this-work)

## Starting point

- **The static checks work.** `ci/checks.sh` checks every blueprint against `Readme.md` in seconds,
  in the pre-commit hook and in CI. It catches structure and annotation errors, and broken
  `display_if` expressions.
- **The real bugs are runtime bugs.** The fix history of this repo and `ha-packages` shows Jinja
  errors (`zip` filter, `bitwise_and` as a function), non-boolean template conditions, and race
  conditions in the cover arbitration. No static check catches these. Only a running Home
  Assistant instance does.
- **A runtime test environment exists, but outside any repo.** `test-environment.md` describes it
  at `C:\Users\Pascal\smarli-ha-test\`. On 2026-10-14 that folder did **not** exist on Pascal's
  current machine, and Docker Desktop was not running. The environment and its test scripts
  (`test-*.ps1`) are either on another machine or lost. Clarify this first — see
  [Open questions](#open-questions).
- **The existing suite covers only `cover_DayNight`** and the `ha-packages` cover logic.

## Decision: no `check_config` job per pull request

A CI job was considered that runs Home Assistant's `check_config` against every blueprint with the
HA Docker image. It was **rejected for now**. The facts below come from reading the Home Assistant
source at tag `2026.10.1`. They were not confirmed by a test run.

**1. Input values are not validated against their selector.**
`BlueprintInputs.validate()` only checks that no input is missing
([`blueprint/models.py`](https://github.com/home-assistant/core/blob/2026.10.1/homeassistant/components/blueprint/models.py)).
The code comment says: "In future we can see if entities are correct domain, areas exist etc using
the new selector helper." What *is* validated:

- the selector definitions in the blueprint (`selector.validate_selector` in `blueprint/schemas.py`);
- the automation after the input values are substituted, with the normal automation schema.

**2. A broken blueprint automation does not fail `check_config`.**
The automation validator catches every error per automation, logs it, and drops the automation
(`_try_async_validate_config_item` in
[`automation/config.py`](https://github.com/home-assistant/core/blob/2026.10.1/homeassistant/components/automation/config.py)).
`check_config` exits with code 1 only for errors in its own `except` list, or for warnings with
`--fail-on-warnings`. A broken blueprint automation is in neither list. The exit code stays 0. The
error appears only as a log line on stderr, such as
`Blueprint '…' generated invalid automation with inputs …`. A CI job would have to search stderr
for these lines.

**3. Device triggers need a real device.**
A device trigger is valid only if its device exists in the device registry
([`device_automation/helpers.py`](https://github.com/home-assistant/core/blob/2026.10.1/homeassistant/components/device_automation/helpers.py)).
With a placeholder device ID, `scene_activateAqaraWirelessMiniSwitch`, `scene_activateHueSmartButton`
and `scene_activateHueTapDial` would always fail with `Unknown device '…'`.

**Why this was rejected.** The job would catch schema errors only, and the repo history shows no
schema errors that reached a technician. The cost is about a day of work, a few minutes of extra
wait on every pull request, and a check that depends on the wording of HA's log messages.

**When to reconsider.** Schema errors mostly arrive with a Home Assistant upgrade, when a syntax is
deprecated or removed. A **manually triggered** workflow (`workflow_dispatch`), pinned to the
fleet's HA version and run before a fleet upgrade, would catch these. It would need a script that
generates one test automation per blueprint, with a placeholder value per selector type for every
input without a default. It would need the stderr search from finding 2 and an exception for
finding 3. Build this only if a blueprint breaks on an HA upgrade.

## Plan

### Step 1 — Move the environment into this repo

Put the environment under `test/runtime/` in this repo, so it is versioned and can be rebuilt on
any machine.

- `docker-compose.yml` with a pinned HA image version.
- The config skeleton: `configuration.yaml`, `virtual.yaml`, the test automations.
- The vendored custom components `virtual` (with the `verify_domain_control(hass, …)` patch) and
  `swissweather`. **Check their licences first.** If vendoring is not allowed, the bootstrap
  script downloads a pinned release instead.
- One bootstrap script for onboarding, the long-lived token, and the `swissweather` config flow.
  This replaces the six manual steps in `test-environment.md` → "Rebuilding from scratch".
- The token stays out of git (`.gitignore`). The bootstrap script creates it.

**Mount, do not copy.** Mount `automation/` and the local `ha-packages` checkout into the
container. The instance can then never run a stale copy. Each test run must print the
`ha-packages` branch and commit that is mounted, and warn when that checkout has uncommitted
changes. This closes the open point in `test-environment.md` → "Known gaps".

**Done when:** a fresh clone plus one bootstrap command gives a working instance, and the existing
cover tests pass against it.

### Step 2 — One test per blueprint behaviour

Each test has two parts:

- **A test automation** that uses the blueprint with real test entities.
- **A test script** that drives the entities and checks the outcome.

Example for `weather_Warning`: set a forecast with `pouring`, trigger the notification time, and
check that a notification with the Pouring title reached a test notify service.

Write new tests in **Python with `pytest`**, with plain HTTP and WebSocket calls. The same tests
then run on a laptop and on a Linux CI runner. The existing scripts are PowerShell 5.1, which does
not run on Linux. Keep the old `.ps1` files as a reference until each one has a Python replacement.

**Done when:** the cover tests from `test-environment.md` → "Test suite" exist in Python, and
`weather_Warning` has its first test.

### Step 3 — Fake MQTT devices for device-selector blueprints

Five blueprints select a **device** of one specific product. A virtual entity has no such device,
so these blueprints cannot be tested today:

| Blueprint | Device filter | What the blueprint listens to |
| --- | --- | --- |
| `allOff_smarliRelay`, `scene_activateSmarliRelay` | manufacturer `smarli.`, model `relay`, `model_id` `S-ZB-1RE1-R251` | the device's `switch` entity toggling |
| `scene_activateHueSmartButton` | integration `mqtt`, Philips, `Hue smart button` | MQTT device triggers (`trigger: device`, `domain: mqtt`) |
| `scene_activateHueTapDial` | integration `mqtt`, Philips, `Hue Tap dial switch` | MQTT device triggers |
| `scene_activateAqaraWirelessMiniSwitch` | integration `mqtt`, Aqara, `Wireless mini switch T1` | MQTT device triggers |

(`weather_Warning` also has a device selector, but only for `mobile_app` notification recipients,
with `default: []`. Its tests can notify all devices instead.)

**Create the fake devices through MQTT discovery.** In production these devices come from
Zigbee2MQTT over MQTT, and every managed instance has Mosquitto. So the test environment does the
same:

- Add a Mosquitto container to the compose stack, and the MQTT integration to the HA instance.
- A test helper publishes retained discovery messages. Each one creates a device with the exact
  `manufacturer`, `model` and `model_id`:
  - a `switch` entity for the smarli. relay;
  - `device_automation` trigger configs for the Hue and Aqara buttons.
- A test presses a button by publishing the trigger payload, or toggles the relay through its
  state topic.

This needs no custom integration. It uses the same path as production. Before relying on it,
confirm that the discovered device carries `model_id` in the device registry, because the relay
filter depends on it. MQTT discovery supports a `model_id` device field in recent HA versions;
check this on the pinned version.

This is the largest single piece of work. It unlocks runtime tests for the `scene_*` family and
`allOff_smarliRelay`.

**Done when:** one `scene_*` blueprint and `allOff_smarliRelay` each have a passing test against a
fake device.

### Step 4 — The development loop

1. Edit the blueprint.
2. `./ci/checks.sh` runs in the pre-commit hook, in seconds, as today.
3. `./test/runtime/run.sh <blueprint>` reloads automations and runs that blueprint's tests against
   the running container.

**The developer starts and stops the container.** The run script only checks that the container
is up. If it is not, the script stops with a clear message. It never starts the container itself.
This also keeps agents from starting a dev server on their own.

**Add to `Readme.md`:** a change to a blueprint's triggers, conditions, actions or templates needs a
runtime test run. A text-only change does not, for example a translation or a release note.

**Add a pull request template** with these fields:

- which runtime tests ran;
- on which HA version;
- with which `ha-packages` commit.

### Step 5 — CI, after the suite is stable

The same compose stack can run in GitHub Actions. That is free, because this repository is public.
Do not make it a required check at first:

- The tests depend on real timing, such as 6–16 s cover travel and stabilizer delays. Shared CI
  runners make that unreliable.
- `swissweather` calls MeteoSwiss over the internet. CI needs a controllable fake weather entity
  instead.
- A gate that fails at random gets ignored. First the suite must pass locally many times in a row.

When the suite is stable, start with a manually or label-triggered workflow. Run it against two HA
versions: the declared floor (`2024.10`) and the fleet's current version. This also covers the
HA-upgrade case from the `check_config` decision above. Make it a required check only after it has
been reliable for a while.

## Open questions

1. **Where is the existing environment?** Is it on another machine, or is it lost? If it exists,
   Step 1 moves it into the repo. If not, Step 1 rebuilds it from `test-environment.md`, which is
   detailed enough.
2. **Who writes blueprints?** If only Pascal, a solid local loop (Steps 1–4) is enough for now. If
   technicians or colleagues contribute, Step 5 becomes important sooner.
3. **Which blueprint matters most after covers?** This decides the order: fake MQTT devices
   (Step 3) first for the `scene_*` family and `allOff`, or `weather_Warning` (Step 2) first.
4. **Which HA version does the fleet run today?** Steps 1 and 5 pin to it.
5. **Do the licences of `virtual` and `swissweather` allow vendoring them into this public repo?**

## Resume this work

GitHub issue [#9](https://github.com/smarli-AG/smarli-blueprints/issues/9) tracks this plan. To pick
it up with Claude Code, answer the open questions in the issue, then start a session in this repo
with:

> Read `docs/runtime-testing-plan.md`, `docs/test-environment.md` and issue #9. Here are my answers to the
> open questions: … Then start with Step 1. Before you build anything, check the current state:
> does `test/runtime/` exist yet, and which steps are already done? Ask me before you start or stop
> any container.

Update the **Status** line at the top of this document when a step is done.

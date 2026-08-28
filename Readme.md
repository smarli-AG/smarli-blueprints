# smarli. Blueprints — Readme

This Readme documents how to write a blueprint file in this repository. Follow it for every new blueprint and every edit to an existing one.

Two conventions run through every blueprint:

- **Home Assistant fields** — native HA blueprint syntax. HA itself reads these.
- **Partner Engine fields** — smarli.'s own metadata and display logic. These live in YAML comments, because HA ignores comments. Only the Partner Engine reads them.

Keep the two separate. A field can be optional on one side and required on the other. See [Optional vs. display_if](#optional-vs-display_if) for a concrete example.

## Contents

- [smarli. Blueprints — Readme](#smarli-blueprints--readme)
  - [Contents](#contents)
  - [Architecture overview](#architecture-overview)
  - [File structure overview](#file-structure-overview)
  - [Top-of-file dev notes](#top-of-file-dev-notes)
  - [Release notes](#release-notes)
  - [Partner Engine metadata block](#partner-engine-metadata-block)
    - [`long_description` markup](#long_description-markup)
  - [Blueprint metadata](#blueprint-metadata)
  - [Input sections](#input-sections)
  - [Per-input frontend annotations](#per-input-frontend-annotations)
    - [Optional vs. `display_if`](#optional-vs-display_if)
  - [Select option translations](#select-option-translations)
  - [`display_if` expression reference](#display_if-expression-reference)
    - [Comparison operators](#comparison-operators)
    - [Logical operators](#logical-operators)
    - [Arithmetic operators](#arithmetic-operators)
    - [Existence / empty checks](#existence--empty-checks)
    - [Array operations](#array-operations)
    - [String operations](#string-operations)
  - [Danger Zone: custom inputs](#danger-zone-custom-inputs)
  - [Variables translation](#variables-translation)
  - [Automation body](#automation-body)
  - [Home Assistant reference links](#home-assistant-reference-links)

## Architecture overview

Shared logic lives in Home Assistant **packages**, not in blueprints. A blueprint is a single YAML file and cannot ship its own entities — supporting entities and shared scripts ship as package files (`smarli_<family>.yaml`, layered over a common `smarli_core.yaml`), included by the Grundinstanz.

These packages act as **coordinators**, not configuration holders:

- `smarli_core.yaml` provides `sensor.smarli_automation_tracker`, a generic key-value store for state that must survive restarts or be shared across blueprints.
- Family packages (e.g. `smarli_cover.yaml`) provide the shared mechanism for their family: detecting manual operation, resolving conflicts between several automations that control the same device, and actually commanding the device.

For covers specifically: several cover blueprints can target the same cover. None of them command the cover directly. Each one publishes what it wants — a target position, or a standing bound — and a single shared resolver script (`script.smarli_cover_resolve`) combines every contributor's intent into the one position it actually commands.

**Rule: a user-configurable value always lives in the blueprint's own inputs, never in the shared package.** A package coordinates and arbitrates; it does not decide policy. For example, `suspension_duration` — how long a cover stays suspended after a manual override — is a per-instance blueprint input. The shared `script.smarli_cover_suspend` does not own or default that value; it only resolves what happens when several instances, each configured with a different duration, apply to the same cover (it takes the maximum across all of them). Follow the same split for any future shared package: define the tunable in the blueprint, pass it into the package script as a parameter, and let the package only resolve conflicts between the values it is handed.

For the full mechanism — tracker key grammar and atomicity, the manual-detection layers, the exact resolver algorithm — see `CLAUDE.md`.

## File structure overview

Every blueprint file follows this order, top to bottom:

```yaml
# TODO: ...                      # optional — internal dev notes, not read by anything

# ! RELEASE NOTES
## X.Y.Z | YYYY-MM-DD
## - change description

# ================
# Partner Engine
# ================
# icon: "..."
# name_en / name_de: "..."
# ... (see Partner Engine metadata block)

blueprint:
  name: ...
  description: ...
  domain: automation
  author: ...
  source_url: ...
  homeassistant:
    min_version: ...
  input:
    trigger_inputs: ...
    condition_inputs: ...
    action_inputs: ...
    custom_inputs: ... # Danger Zone — fixed boilerplate, see below

trigger_variables: ... # only if triggers need computed values
variables: ... # always present, even if empty

mode: single
max_exceeded: silent
triggers: ...
conditions: ...
actions: ...
```

## Top-of-file dev notes

A blueprint file can start with plain `#` comments before the `RELEASE NOTES` header. Use this space for open questions or ideas for later, for example:

```yaml
# TODO: potential improvements:
# - Ability to track multiple weather entities
```

This section is optional. Nothing reads it — not Home Assistant, not the Partner Engine. Remove a note once it is resolved or no longer relevant.

## Release notes

Every blueprint has a release notes header, right after the dev notes:

```yaml
# ! RELEASE NOTES
## 1.5.0 | 2025-09-24
## - Add Partner Engine data
## 1.4.0 | 2025-06-30
## - fix interruption level for iOS notifications interruption-level
## 1.2.0 | 2025-02-27
## - Initial live release
```

Rules:

- List the newest version first.
- Use semantic versioning (`X.Y.Z`).
- Use an ISO date (`YYYY-MM-DD`).
- List every change as its own `##` bullet, prefixed with a dash (`-`).

**Version consistency rule.** The version and date of the newest entry must match, exactly, in three places:

1. This release notes header.
2. The version line inside `blueprint.description` (see [Blueprint metadata](#blueprint-metadata)).
3. The version line inside `long_description_en` and `long_description_de` (see [Partner Engine metadata block](#partner-engine-metadata-block)).

Bump all three together. A blueprint with a stale version number in one of these places is not fully specced.

## Partner Engine metadata block

This block sits between the release notes and the `blueprint:` key. It is entirely made of comments — Home Assistant never sees it. The Partner Engine parses it to build the blueprint's listing.

```yaml
# ================
# Partner Engine
# ================
# is_smart_button: true
# icon: "power"
#
# name_en: "All Off"
# name_de: "Alles Aus"
# subtitle_en: "smarli. smart button"
# subtitle_de: "smarli. Smart Button"
#
# short_description_en: "Turn off all lights and media players in your home with a single button press."
# short_description_de: "Schalte alle Lichter und Medienplayer in deinem Zuhause mit nur einem Knopfdruck aus."
# long_description_en: |
#   __Turn off all lights and media players in your home with a single button press.__
#   [br]
#   The All Off automation let's you turn off all your lights and media players in your home with a single button press.
#   [br]
#   [br]
#   __How to set it up:__
#   1. Select the button that should trigger the automation
#   2. Select if you want to turn off lights, media players or both
#   [br]
#   ---
#   [br]
#   _Version 1.0.0 | 2026-05-21_
#
# long_description_de: "..."
#
# purpose_en: "Comfort"
# purpose_de: "Komfort"
#
# keywords_en: [all off, off]
# keywords_de: [alles aus, ausschalten]
# events_en: [leaving home, going to bed]
# events_de: [Zuhause verlassen, ins Bett gehen]
#
# highlight: true
# deploy: true
```

Field reference:

| Field                                           | Type                      | Notes                                                                                                                                                                                                                                                                                                               |
| ----------------------------------------------- | ------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `is_smart_button`                               | boolean                   | Optional. Only set this on a blueprint whose entire job is activating a scene from a button press (the `activateSceneSmartButton_*` family). Do not set it just because a blueprint happens to be triggered by a smarli. smart button or relay — the flag is about what the blueprint _does_, not what triggers it. |
| `icon`                                          | string                    | An MDI icon name, **without** the `mdi:` prefix (`"power"`, not `"mdi:power"`). This is different from the `mdi:` icons used inside `blueprint.input` sections — see [Input sections](#input-sections).                                                                                                             |
| `name_en` / `name_de`                           | string                    | The blueprint's display name, as shown by the Partner Engine.                                                                                                                                                                                                                                                      |
| `subtitle_en` / `subtitle_de`                   | string                    | A short subtitle under the name for further specification, e.g. the hardware it targets (`"smarli. smart button"`) or its function (`"Phone Notification"`).                                                                                                                                                        |
| `short_description_en` / `short_description_de` | string                    | One sentence, shown on the blueprint card.                                                                                                                                                                                                                                                                          |
| `long_description_en` / `long_description_de`   | string (YAML block, `\|`) | The full blueprint description. Uses the Partner Engine's own lightweight markup, not standard Markdown — see below.                                                                                                                                                                                                |
| `purpose_en` / `purpose_de`                     | string                    | A category tag. Limited to these 3 for now: `"Comfort"` / `"Komfort"`, `"Energy"` / `"Energie"`, `"Security"` / `"Sicherheit"`. Confirm with the Partner Engine team before adding any new ones.                                                                                                                    |
| `keywords_en` / `keywords_de`                   | list of strings           | Keywords that apply to the blueprint. Used for filtering in the Partner Engine.                                                                                                                                                                                                                                     |
| `events_en` / `events_de`                       | list of strings           | Real-world situations the blueprint is useful for, e.g. `[leaving home, going to bed]`. Used for filtering in the Partner Engine.                                                                                                                                                                                   |
| `highlight`                                     | boolean                   | Whether the blueprint is visually highlighted in the list of blueprints.                                                                                                                                                                                                                                            |
| `deploy`                                        | boolean                   | Whether the blueprint is published. Set to `false` while a blueprint is still in progress.                                                                                                                                                                                                                          |

### `long_description` markup

`long_description_en`/`de` is rendered by the Partner Engine's own renderer, not a Markdown engine. Use:

- `__text__` for bold.
- `[br]` on its own line for a line break. Two `[br]` lines in a row make a paragraph break.
- Plain numbered lines (`1.`, `2.`, ...) for steps.
- Plain `-` lines for an unordered list.
- `---` for a horizontal rule, conventionally placed right before the version footer.
- `_Version X.Y.Z | YYYY-MM-DD_` as the last line — italicized with underscores, and matching the release notes exactly (see the [version consistency rule](#release-notes)).

## Blueprint metadata

Inside `blueprint:`, these fields are standard Home Assistant, with repo-specific conventions layered on:

```yaml
blueprint:
  name: smarli. all off button
  description: >
    # 🚫 smarli. All Off Button

    This automation will turn off all lights and media players in your home when a specified button is pressed.

    *Version 1.0.0 | 2026-05-21*

    <details>
    <summary><b>How to set it up</b></summary>

      1. Select if you want to turn off lights, media players or both.
      2. Select the button(s) that will trigger the automation.
    </details>


    All input fields are required unless they are marked as ` (optional) `.
  domain: automation
  author: loocd [smarli. AG]
  source_url: https://github.com/smarli-AG/smarli-blueprints/blob/main/automation/allOff_smarliRelay.yaml
  homeassistant:
    min_version: 2025.4.0 # support for model_id in device selector
```

Rules:

- `description` starts with a Markdown H1 (`#`) and an emoji, matching the blueprint's `name_en`.
- `description` is always written in English, regardless of `long_description_de`. Home Assistant's own blueprint UI has no language switching, so there is only one version.
- The version line uses standard Markdown italics with asterisks (`*Version X.Y.Z | YYYY-MM-DD*`) — this is HA's own renderer, not the Partner Engine's `[br]` markup. It must match the release notes exactly (see the [version consistency rule](#release-notes)).
- Wrap the setup steps in a `<details><summary><b>How to set it up</b></summary> ... </details>` block, so the technician can collapse it.
- List every numbered step that corresponds to a real input the technician must look at.
- End with this exact line, verbatim: `All input fields are required unless they are marked as \` (optional) \`.`
- `author` is the actual person who wrote the blueprint, always followed by `[smarli. AG]` in brackets. `loocd [smarli. AG]` above is just this blueprint's author, not a placeholder to copy verbatim.
- `source_url` always points at this file, on `main`, at its real path.
- Comment `homeassistant.min_version` with the reason when it is not obviously the blueprint's own floor (e.g. `# support for model_id in device selector`). The nested trigger-list syntax used for custom triggers (see [Automation body](#automation-body)) requires HA ≥ 2024.10 — that is the absolute floor for any blueprint using it.

## Input sections

Inputs are grouped into up to four named sections, always in this order:

```yaml
input:
  trigger_inputs:
    name: Trigger Inputs
    icon: mdi:star-box-multiple
    description: These inputs are used to set the automation triggers
    input: { ... }

  condition_inputs:
    name: Condition Inputs
    icon: mdi:help-box-multiple
    description: These inputs are used to set the automation conditions
    input: { ... } # omit `input:` entirely if there is nothing to expose here

  action_inputs:
    name: Action Inputs
    icon: mdi:play-box-multiple
    description: These inputs are used to set the actions
    input: { ... }

  custom_inputs:
    # fixed boilerplate — see Danger Zone, below
```

Note the section-level `icon:` fields use the standard HA `mdi:` prefix. This is the opposite convention from the Partner Engine header's top-level `icon:`, which has no prefix — see the [field reference](#partner-engine-metadata-block) above.

A section can be declared with no `input:` key at all when the blueprint has nothing to expose there (for example, a button-triggered blueprint usually has an empty `condition_inputs`).

## Per-input frontend annotations

Every real input (not the Danger Zone boilerplate — see below) carries three commented annotations, in this order, plus the real HA fields:

```yaml
input:
  scene_to_activate:
    # translation:
    #   name:
    #     en: Scene to Activate
    #     de: Zu aktivierende Szene
    #   description:
    #     en: Select the scene that should be activated when the button is pressed.
    #     de: Wähle die Szene aus, die aktiviert werden soll, wenn der Button gedrückt wird.
    # optional: true
    # display_if: true
    name: Scene to Activate
    description: Select the scene that should be activated when the button is pressed.
    selector:
      entity:
        filter:
          - domain: script
```

- `translation` gives the `name` and `description` in every supported language. Keep it in sync with the plain `name`/`description` fields HA actually reads.
- `optional` and `display_if` are Partner Engine fields. Both are **required on every real input** — never omit either, even when the value is the unremarkable default (`optional: false`, `display_if: true`). An omitted field still has an implicit default (see below), but leaving it out hides whether that was a deliberate choice.

### Optional vs. `display_if`

These are two different, independent optionality mechanisms. Do not confuse them.

**Standard Home Assistant optionality.** Native HA behavior, shown to the technician inside Home Assistant itself. Mark it by appending `(optional)` to the input's `name:` field. The blueprint's own `description:` states the rule: "All input fields are required unless they are marked as `(optional)`." This is unrelated to the Partner Engine.

**Partner Engine optionality — the `# optional:` comment.** Set it to `true` or `false`. If missing, the Partner Engine treats the input as required. Judge this value only for the moment the input is actually visible (its `display_if` state), not for whether Home Assistant enforces a value. An input can be optional on the Home Assistant side (it has a `default:`, or its `name:` says `(optional)`) but still required on the Partner Engine side once it becomes visible.

> **Example.** `notify_recipients` (in `weatherWarning.yaml`) has `default: []`, so Home Assistant never blocks saving the automation without it — its `name:` correctly says "(optional)". But it is only shown at all when `notification_scope == "specific"`. In that state, leaving it empty defeats the point of choosing "specific" — the automation silently falls back to notifying everyone. So its `# optional:` is `false`, even though the Home Assistant side treats it as optional.

**`display_if` — the `# display_if:` comment.** An expression (see the [reference](#display_if-expression-reference) below) that decides whether the Partner Engine shows this input at all, given the values of previously-answered inputs. Set it to `true` for an input that should always be shown. If missing, the input is treated as always shown.

## Select option translations

`select` selectors need a translation on every option, not just on the input itself:

```yaml
selector:
  select:
    options:
      - label: Rainy
        # translation:
        #   label:
        #     en: Rainy
        #     de: Regen
        value: "rainy"
```

## `display_if` expression reference

Available variables are the ones used in previous inputs of the blueprint.

### Comparison operators

| Expression | Description              | Examples                                                  |
| ---------- | ------------------------ | --------------------------------------------------------- |
| `==`       | Equals                   | `severity == 'high'` `temperature == 0` `enabled == true` |
| `!=`       | Not equals               | `mode != 'off'` `count != 0` `device_id != null`          |
| `<`        | Less than                | `temperature < 0` `battery_level < 20` `hour < 9`         |
| `>`        | Greater than             | `humidity > 80` `count > 5` `brightness > 50`             |
| `<=`       | Less than or equal to    | `temperature <= 10` `priority <= 3` `volume <= 50`        |
| `>=`       | Greater than or equal to | `battery >= 80` `confidence >= 0.95` `age >= 18`          |

### Logical operators

| Expression | Description                                                     | Examples                                                                                                                  |
| ---------- | --------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------- |
| `and`      | Logical AND (both conditions must be true)                      | `temperature > 30 and humidity > 70` `enabled == true and mode != 'off'` `count > 0 and count <= 10`                      |
| `or`       | Logical OR (at least one condition must be true)                | `severity == 'high' or severity == 'critical'` `temperature < 0 or temperature > 35` `mode == 'auto' or mode == 'manual'` |
| `not`      | Logical NOT (negates a boolean expression)                      | `not (temperature > 30)` `not enabled` `not (isEmpty(weather_events))`                                                    |
| `( )`      | Parentheses (groups expressions to control order of operations) | `(temperature < 0 or temperature > 35) and enabled` `not (mode == 'off' or mode == 'standby')`                            |

### Arithmetic operators

| Expression | Description                       | Examples                                          |
| ---------- | --------------------------------- | ------------------------------------------------- |
| `%`        | Modulo (remainder after division) | `hour % 2 == 0` `day % 7 == 0` `counter % 5 == 0` |

### Existence / empty checks

| Expression  | Description                                                                 | Examples                                     |
| ----------- | --------------------------------------------------------------------------- | -------------------------------------------- |
| `isEmpty()` | Returns true if a string is empty (`""`) or an array has no elements (`[]`) | `isEmpty(email)` `isEmpty(selected_devices)` |

### Array operations

| Expression      | Description                                                           | Examples                                                                                                     |
| --------------- | --------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------ |
| `includes()`    | Returns true if an array contains the specified value                 | `includes(weather_events, 'rainy')` `includes(['kitchen', 'bedroom'], selected_room)`                        |
| `includesAny()` | Returns true if an array contains ANY of the specified values         | `includesAny(weather_events, ['rainy', 'snowy'])` `includesAny(severity, ['high', 'critical', 'emergency'])` |
| `includesAll()` | Returns true if an array contains ALL of the specified values         | `includesAll(weather_events, ['rainy', 'windy'])` `includesAll(['heating', 'cooling'], modes)`               |
| `length()`      | Returns the number of elements in an array, or characters in a string | `length(weather_events) > 0` `length(notification_text) < 100`                                               |

### String operations

| Expression     | Description                                               | Examples                                                                       |
| -------------- | --------------------------------------------------------- | ------------------------------------------------------------------------------ |
| `contains()`   | Returns true if a string contains the specified substring | `contains(device_name, 'motion')`                                              |
| `startsWith()` | Returns true if a string starts with the specified prefix | `startsWith(entity_id, 'sensor.')` `startsWith(notification_title, '[Alert]')` |
| `endsWith()`   | Returns true if a string ends with the specified suffix   | `endsWith(entity_id, '_temperature')`                                          |

For completeness, set `display_if` to `true` even on inputs that should always be visible. This is not strictly required, but it makes the blueprint easier to read, and it satisfies the rule in [Per-input frontend annotations](#per-input-frontend-annotations) that every real input sets `display_if` explicitly.

## Danger Zone: custom inputs

Every blueprint ends its `input:` block with this exact `custom_inputs` section. Copy it verbatim into any new blueprint — do not translate it, and do not give it `display_if`/`optional` annotations (none of the fields in this section carry them, in any blueprint in this repo):

```yaml
custom_inputs: # leave these as is - should be present in any blueprint
  name: "DANGER ZONE: Additional Custom Inputs"
  icon: mdi:alert
  description: >-
    **WATCH OUT!**  

    This is advanced functionality and should only be used if you know what you're doing!  


    Use this section to define custom triggers and conditions, as well as actions that will run at the end of the automation.
  collapsed: true
  input:
    custom_triggers:
      name: Custom triggers (optional)
      description: >-
        Use this to define custom triggers in addition to the default triggers.
      selector:
        trigger:
      default: []
    custom_conditions:
      name: Custom conditions (optional)
      description: >-
        Use this to define custom conditions in addition to the default conditions.
      selector:
        condition:
      default: []
    custom_actions:
      name: Custom actions (optional)
      description: >-
        Use this to define custom actions that should be executed at the end of this automation.
      selector:
        action:
      default: []
```

This section exists so an experienced technician can extend a blueprint's behavior without needing a blueprint edit. See [Automation body](#automation-body) for how these three inputs get wired into `triggers`/`conditions`/`actions`.

## Variables translation

```yaml
trigger_variables:            # only needed if a trigger must reference an input
  smart_buttons: !input smart_buttons
  smart_buttons_entities: >
    {{ smart_buttons | map('device_entities') | sum(start=[]) | select('match', '^switch\.') | list }}

# this is required in order to use inputs as variables within templates
variables:
  weather_entity: !input weather_entity
  ...
```

- `trigger_variables` exists because Home Assistant does not make automation `variables:` available inside `triggers:`. Only add it when a trigger's template genuinely needs a computed value from an input (for example, resolving a device selector down to its entities for a button-press trigger).
- `variables:` is always present, even when there is nothing to put in it (`variables: {}`). Every `!input` value used inside a template anywhere in the blueprint must be re-declared here first.

## Automation body

```yaml
mode: single
max_exceeded: silent

triggers:
  - trigger: time
    at: !input trigger_time
  ## Custom triggers
  - triggers: !input custom_triggers

conditions: # by default, conditions follow an AND logic
  ## Custom conditions
  - condition: and
    conditions: !input custom_conditions

actions:
  - ... # the blueprint's own actions
  ## Custom actions
  - if:
      - condition: template
        value_template: "{{ custom_actions is not none }}"
    then: !input custom_actions
```

Rules:

- `mode` and `max_exceeded` are standard Home Assistant automation settings. Choose them based on how the blueprint needs to behave — see the [Home Assistant reference links](#home-assistant-reference-links) below. This repo does not mandate a specific mode.
- Merge custom triggers with `- triggers: !input custom_triggers` (a nested trigger list), **not** `- !input custom_triggers`. The nested form is what allows an empty list of custom triggers to be a no-op instead of a schema error. It requires HA ≥ 2024.10 — see [Blueprint metadata](#blueprint-metadata).
- Wrap custom conditions in `condition: and`, so they combine with the blueprint's own conditions rather than replacing them.
- Run custom actions last, guarded by `{{ custom_actions is not none }}`, so an empty list of custom actions is a no-op.

## Home Assistant reference links

This repo's conventions sit on top of standard Home Assistant blueprint and automation syntax. For anything not specific to smarli., use the official docs:

- [Automation modes](https://www.home-assistant.io/docs/automation/modes/) — `mode` (`single`/`restart`/`queued`/`parallel`) and `max_exceeded`.
- [Blueprint selectors](https://www.home-assistant.io/docs/blueprint/selectors/) — every selector type usable in an input's `selector:` block.
- [Creating blueprints](https://www.home-assistant.io/docs/blueprint/) — the blueprint schema itself (`input`, `!input`, `homeassistant.min_version`, etc.).
- [Using blueprints](https://www.home-assistant.io/docs/automation/using_blueprints/) — how a technician imports and configures a blueprint, for context on what they will see.
- [Automation triggers](https://www.home-assistant.io/docs/automation/trigger/) — trigger types and their options.
- [Automation conditions](https://www.home-assistant.io/docs/automation/condition/) — condition types, including the `template` condition used throughout this repo.
- [Automation actions](https://www.home-assistant.io/docs/automation/action/) — action types, `choose`, `if`/`then`, `repeat`, `parallel`.
- [Templating](https://www.home-assistant.io/docs/configuration/templating/) — the Jinja syntax used in every `value_template` and templated field in this repo.

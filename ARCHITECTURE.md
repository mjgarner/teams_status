# Architecture — Teams/Zoom Presence Light

## Purpose

Provide a visual, ambient indicator (a Philips Hue bulb) that shows nearby
people whether the user is currently on a Microsoft Teams or Zoom call,
without depending on Microsoft Graph API access, corporate IT/Entra ID
app registration, or a cloud service.

## Constraints that shaped the design

- No Entra ID (Azure AD) app registration available — corporate tenant blocks
  user self-service registration, and IT declined to provision one
  (cited cost concerns, confirmed to be a misunderstanding but still a hard no)
- No access to a local Teams API or webhook — the new (2023+) Teams client
  does not expose local presence state
- Previous solution (Microsoft Store app "PresenceLight") broke when
  Microsoft changed Graph API requirements
- Personal laptop (not corporate-managed), so local scripts/scheduled tasks
  are permitted without IT restriction
- Existing Home Assistant instance with a Philips Hue integration already
  in place

---

## Solution Overview

A PowerShell script runs continuously on the user's Windows 11 laptop. It
polls the Windows Core Audio subsystem to detect whether Microsoft Teams or
Zoom currently holds an **active microphone capture session**. On every
detected state change (and once forcibly at script startup), it pushes the
status to Home Assistant via two REST calls:

1. Flips `input_boolean.teams_in_call` (for HA history, dashboards, and any
   other automations that may want to react to it)
2. Directly calls `light.turn_on` on the Hue bulb entity with the correct
   color and brightness (for guaranteed, immediate visual sync — does not
   depend on the `input_boolean`'s state-change event firing)

No cloud API, no Entra ID app registration, and no corporate IT dependency
are involved anywhere in this chain.

---

## Component Diagram

```plantuml
@startuml
skinparam componentStyle rectangle
skinparam defaultTextAlignment center

package "Windows 11 Laptop (personal, unmanaged)" {
  [Microsoft Teams] as Teams
  [Zoom] as Zoom
  [Windows Core Audio\n(WASAPI Session API)] as WASAPI
  [teams-presence.ps1\n(PowerShell script)] as Script
  [Windows Task Scheduler] as Scheduler
  [teams-presence.log] as Log
}

package "Home Assistant (local network)" {
  [REST API] as HAAPI
  [input_boolean.teams_in_call] as Boolean
  [Automation:\nTeams Presence - Hue Light] as Automation
  [Hue Integration] as HueInt
}

package "Philips Hue" {
  [Hue Bridge] as Bridge
  [light.oncall_light] as Bulb
}

Scheduler --> Script : starts at login\n(30s delay)
Teams --> WASAPI : holds active\ncapture session
Zoom --> WASAPI : holds active\ncapture session
Script --> WASAPI : polls every 5s
Script --> Log : writes status/errors
Script --> HAAPI : POST input_boolean\nturn_on / turn_off
Script --> HAAPI : POST light.turn_on\n(color + brightness)
HAAPI --> Boolean : updates state
Boolean --> Automation : triggers on\nstate_changed event
Automation --> HueInt : light.turn_on\n(color + brightness)
HAAPI --> HueInt : light.turn_on\n(direct, bypasses automation)
HueInt --> Bridge : Zigbee command
Bridge --> Bulb : set color/brightness

note right of Script
  Primary detection: WASAPI Core Audio
  Fallback detection: Registry ConsentStore
  (see ARCHITECTURE "Known Limitations")
end note

note right of HAAPI
  Script writes to BOTH the input_boolean
  AND the light directly, because HA does
  not reliably fire state_changed events
  when input_boolean is set to its current
  value (e.g. turn_off when already off).
end note
@enduml
```

---

## Detection Logic Flow

```plantuml
@startuml
start
:Script tick (every 5 seconds);
:Call WASAPI Core Audio API\n(IAudioSessionManager2 -> IAudioSessionEnumerator);
if (WASAPI call succeeded?) then (yes)
  :Enumerate active audio sessions;
  :Resolve each session's PID\nto process name;
  if (Any process name matches\nTeams/Zoom/msedgewebview2?) then (yes)
    :micActive = true;
  else (no)
    :micActive = false;
  endif
else (no - exception thrown)
  :Log "WASAPI detection error";
  :Fall back to registry method\n(ConsentStore\\microphone);
  note right
    Known unreliable as of Oct 2026
    due to Microsoft feature-flag
    rollout - kept only as last resort
  end note
  :micActive = registry result;
endif
if (micActive != lastState OR\nfirst run since script start?) then (yes)
  :Push input_boolean state to HA;
  :Push light.turn_on directly to HA\n(color = red if micActive, green if not);
  if (both pushes succeeded?) then (yes)
    :lastState = micActive;
  else (no)
    :Log error, retry next tick;
  endif
else (no change)
  :No action - sleep until next tick;
endif
stop
@enduml
```

---

## Data Flow / Message Format

The integration is intentionally simple — plain REST/JSON over HTTP on the
local network. No MQTT broker, no message queue, no persistent connection.

**Push input_boolean state:**
```
POST http://192.168.3.131:8123/api/services/input_boolean/turn_on
Authorization: Bearer <long-lived access token>
Content-Type: application/json

{ "entity_id": "input_boolean.teams_in_call" }
```

**Push light state directly:**
```
POST http://192.168.3.131:8123/api/services/light/turn_on
Authorization: Bearer <long-lived access token>
Content-Type: application/json

{
  "entity_id": "light.oncall_light",
  "color_name": "red",
  "brightness": 102
}
```

Because the pattern is plain REST, the script could be re-pointed at a
different target (MQTT broker, Node-RED webhook, Hue Bridge API directly,
etc.) by changing only the `Set-HAState` / `Set-HALight` functions — the
detection logic is completely decoupled from the notification mechanism.

---

## Why Not Microsoft Graph API?

This was the preferred approach (full Available/Busy/Away/DND presence
states, not just in-call detection) but was ruled out:

- Requires an Entra ID (Azure AD) app registration
- User self-service app registration is blocked at the tenant level
  (confirmed via direct test — `401 Insufficient privileges`)
- IT declined to create one on request, citing cost (likely a
  misunderstanding, since delegated `Presence.Read` registrations are free,
  but the answer was still no)

If this restriction is ever lifted, Graph API is the recommended upgrade
path — see BACKLOG.md.

---

## Known Limitations

1. **Binary state only** — "in a call" vs. "not in a call." No distinction
   between Available, Busy, Away, Do Not Disturb, or Presenting.
2. **Muted-but-joined calls** may not register as "in a call" if the mic
   session itself isn't held active by the app while muted (behavior can
   vary by app/version).
3. **Registry fallback is unreliable** as of October 2026 due to a Microsoft
   server-side feature-flag rollout affecting `ConsentStore` registry
   updates. WASAPI is now the primary method; registry is last-resort only.
4. **No distinction between Teams meetings and Teams calls** — any active
   mic session from a Teams/Zoom process triggers "in a call," including
   test calls, voice memos recorded in-app, etc.
5. **Single point of failure**: if the laptop is asleep, shut down, or the
   script/task isn't running, the light freezes at its last pushed state.

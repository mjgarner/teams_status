# Teams Presence → Home Assistant Setup Guide

## Overview

A PowerShell script runs silently on your Windows 11 laptop. Every 5 seconds it
checks whether Teams or Zoom is actively holding the microphone (via the WASAPI
Core Audio session API — see "Known Issue" below for why this changed from the
original registry-based approach). When the state changes it pushes to HA
**two ways**: it flips an `input_boolean` (for HA automations/history/dashboards)
**and** directly commands the Hue light via `light.turn_on` (for guaranteed
sync — see "Known Issue: light not updating on unchanged state" below).

---

## Known Issue: Light not updating on unchanged input_boolean state (Nov 2026)

**Symptom:** The script log showed a successful push (`Initial state push
succeeded`) but the Hue light did not actually change color.

**Root cause:** The script originally only flipped `input_boolean.teams_in_call`
and relied on an HA automation (triggered by the boolean's state change) to set
the light color. Home Assistant's `input_boolean.turn_off` service call does
**not** reliably emit a `state_changed` event when the helper is **already**
in the requested state (e.g. calling `turn_off` when it's already `off`). Since
the automation only runs on that event, the light silently fails to sync in
several real-world scenarios:
- Script restart when the boolean was already correctly off
- HA restart that leaves the helper in a stale/unknown state but the script's
  forced initial push happens to match the old value
- Hue bulb power-cycled externally (e.g. someone flips the wall switch) so the
  physical light no longer matches HA's last known state, but the
  `input_boolean` itself never changes

**Fix applied:** The script now calls `light.turn_on` **directly** on the Hue
light entity every time it pushes a state (both the forced startup push and
on every detected call-status change), in addition to flipping the
`input_boolean`. This guarantees the light is always explicitly commanded to
the correct color/brightness, independent of whether HA's state-change event
fires. The `input_boolean` is still updated too, so the existing automation,
history graphs, and any other automations tied to it keep working — it's just
no longer the *only* path controlling the light.

See `Set-HAEverything` in the script for the combined push logic.

---

## Known Issue: Registry detection broke (October 2026)

**Symptom:** The light stopped changing color entirely, even though the script
was still running without errors and successfully pushing state to HA.

**Root cause:** The original script detected mic usage by reading
`LastUsedTimeStop` under:
```
HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\microphone
```
A value of `0` meant "actively in use right now." Starting in **October 2026**,
Microsoft began rolling out a **feature-flagged change** to recent Windows 11
builds (26300.95xx and later, delivered via cumulative updates) that stops this
registry key from updating in real time. This is a confirmed, widely-reported
regression affecting multiple independent projects (HASS.Agent, LuxaforOnAir,
and others) — not a bug in this script.

The rollout is **server-side and inconsistent**: Microsoft toggles the flag
per-device, so the same Windows build can behave correctly on one machine and
incorrectly on another, and a previously-working machine can break days later
with no local update required. Windows' own Settings UI (Privacy & security →
Microphone → "currently in use") still shows the correct state — only the
registry write path is affected.

**Fix applied:** The script now uses the **WASAPI Core Audio session API**
(`IAudioSessionManager2` / `IAudioSessionControl2`) via an embedded C#
type (`Add-Type`) to query real-time microphone session state directly. There
is no native PowerShell cmdlet or WMI class for this — COM interop is required.
The old registry method is kept as an automatic fallback only, in case the
WASAPI call ever fails (e.g., due to a future Windows change).

**If this breaks again in the future:**
1. Check `teams-presence.log` for `WASAPI detection error` messages — this
   indicates the primary method is failing and it has silently fallen back to
   the registry method (which may itself be unreliable going forward).
2. Confirm manually whether Windows' own Settings → Privacy & security →
   Microphone page correctly shows "currently in use" for Teams/Zoom while the
   registry/WASAPI check disagrees.
3. Search for recent GitHub issues on `hass-agent/HASS.Agent` or similar
   projects — they tend to be the fastest to document new Windows regressions
   in this area.
4. Consider polling interval or caching — Microsoft could again change the
   underlying API surface; the WASAPI method is current best practice as of
   October 2026 but is not guaranteed to be permanent.

---


## Step 1 — Copy the script to your laptop

Copy `teams-presence.ps1` to a permanent location on your laptop, for example:

```
C:\Users\<YourName>\Scripts\teams-presence.ps1
```

---

## Step 2 — Create the HA Helper (input_boolean)

1. In HA go to **Settings → Devices & Services → Helpers**
2. Click **+ Create Helper** → **Toggle**
3. Set:
   - **Name:** `Teams In Call`
   - HA will auto-generate entity ID: `input_boolean.teams_in_call`
4. Save

---

## Step 3 — Create the HA Automation (Hue light control)

Go to **Settings → Automations → + Create Automation → Edit in YAML** and paste:

```yaml
alias: Teams Presence - Hue Light
description: Red when in a call, green when free, 40% brightness
mode: single

trigger:
  - platform: state
    entity_id: input_boolean.teams_in_call

action:
  - choose:
      - conditions:
          - condition: state
            entity_id: input_boolean.teams_in_call
            state: "on"
        sequence:
          - service: light.turn_on
            target:
              entity_id: light.oncall_light
            data:
              color_name: red
              brightness: 102
      - conditions:
          - condition: state
            entity_id: input_boolean.teams_in_call
            state: "off"
        sequence:
          - service: light.turn_on
            target:
              entity_id: light.oncall_light
            data:
              color_name: green
              brightness: 102
```

> Light entity: `light.oncall_light`
> Brightness 102 = 40% of 255.

**Optional:** If you want the light to turn OFF entirely when not in a call (rather
than go green), replace the second sequence with:

```yaml
          - service: light.turn_off
            target:
              entity_id: light.oncall_light
```

---

## Step 4 — Unblock the script and test manually

### 4a — Set execution policy (once per machine)

Open **PowerShell** (not as admin) and run:

```powershell
Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned
```

### 4b — Unblock the file (required after every update)

Windows marks files downloaded from the internet as untrusted. After copying
the script to your laptop (or replacing it with an updated version), run:

```powershell
Unblock-File -Path "C:\Users\Michael\Scripts\teams-presence.ps1"
```

This is equivalent to right-clicking the file → Properties → checking "Unblock"
at the bottom. **You must repeat this step any time you replace the script file.**

If you skip this step you will see:
```
File cannot be loaded. The file is not digitally signed.
```

### 4c — Run the script to verify

```powershell
& "C:\Users\Michael\Scripts\teams-presence.ps1"
```

Join a Teams call and watch the console output. You should see:

```
2026-07-30 10:00:00  teams-presence.ps1 started. Polling every 5 seconds.
2026-07-30 10:00:05  State change -> IN_CALL
```

And your Hue light should change color. Check `teams-presence.log` in the same
folder if you see errors.

---

## Step 5 — Set up Windows Task Scheduler (runs silently at login)

1. Open **Task Scheduler** (search in Start menu)
2. Click **Create Task** (not "Create Basic Task")
3. **General tab:**
   - Name: `Teams Presence Monitor`
   - Select: **Run only when user is logged on**
   - Check: **Run with highest privileges** — OFF (not needed)
4. **Triggers tab → New:**
   - Begin the task: **At log on**
   - Specific user: your account
   - Delay task for: `30 seconds` (gives Teams time to start)
5. **Actions tab → New:**
   - Action: **Start a program**
   - Program: `powershell.exe`
   - Arguments:
     ```
     -WindowStyle Hidden -ExecutionPolicy Bypass -File "C:\Users\<YourName>\Scripts\teams-presence.ps1"
     ```
6. **Conditions tab:**
   - Uncheck "Start the task only if the computer is on AC power"
7. **Settings tab:**
   - Check: **If the task is already running, do not start a new instance**
8. Click **OK**

Log off and back on to test, or right-click the task → **Run** to start it immediately.

---

## Troubleshooting

| Symptom | Check |
|---|---|
| Light never changes | Look at `teams-presence.log`. Verify HA entity ID matches exactly. |
| "IN_CALL" fires for non-Teams apps | The script filters by process name. Check the log for which process triggered it. |
| Script stops after a few hours | Check Task Scheduler history. Add `-NoExit` is not needed for loop scripts. |
| AV flags the script | Add `teams-presence.ps1` to your AV exclusions, or sign the script. |
| Teams uses a headset mic only | Registry tracks all audio devices — headset mic usage is captured too. |

---

## How It Works

**Primary method (current):** The script uses the Windows **WASAPI Core Audio
session API** to ask, in real time, which processes currently hold an *active*
microphone capture session. This is the same low-level API Windows itself uses
to power the mic/camera privacy indicators in the system tray and Settings app.
There's no PowerShell cmdlet for this, so the script embeds a small C# type
(via `Add-Type`) that calls `IAudioSessionManager2` → `IAudioSessionEnumerator`
→ `IAudioSessionControl2.GetState()` for each active capture-capable audio
device, and cross-references the returned process IDs against
`$CALL_PROCESS_NAMES`.

**Fallback method (legacy, unreliable as of Oct 2026):** If the WASAPI call
throws an error, the script falls back to reading the registry at:
```
HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\microphone
```
Each process that requests mic access gets a subkey with a `LastUsedTimeStop`
value that is supposed to be `0` while actively in use. See the "Known Issue"
section above for why this can no longer be trusted as the primary signal.

The script checks both the packaged app store (MSIX/UWP) and the NonPackaged
(Win32) store to cover all variants of the Teams client when using the fallback.

---

## Which applications are monitored?

The script currently detects mic usage by **Microsoft Teams and Zoom**. It
filters active audio sessions by process name, matching entries against the
`$CALL_PROCESS_NAMES` list at the top of the script:

```powershell
$CALL_PROCESS_NAMES = @("ms-teams", "Teams", "Zoom", "msedgewebview2")
```

To add another app (e.g. Google Meet running in a browser, or another
conferencing tool), add its process name to this list — use
`Get-Process | Sort-Object ProcessName` while the app is running to find the
exact `ProcessName` value to match.

Note: if you add other apps the `input_boolean` will turn on whenever **any** of
them is using the mic, not just Teams or Zoom.

---

## Message format and integration dependency

When a state change is detected the script makes a plain HTTP POST to the HA
REST API:

```
POST http://192.168.3.131:8123/api/services/input_boolean/turn_on
Authorization: Bearer <token>
Content-Type: application/json

{ "entity_id": "input_boolean.teams_in_call" }
```

The detection logic (registry polling) is entirely separate from the notification
method. Only the `Set-HAState` function in the script needs to change to target
a different system. Common alternatives:

| Target | What to change |
|---|---|
| **MQTT broker** | Replace `Invoke-RestMethod` with an MQTT publish (e.g. via `mosquitto_pub` or a PowerShell MQTT library). Publish `ON`/`OFF` to a topic. Most home automation platforms support MQTT natively. |
| **Node-RED** | Point the URL at a Node-RED HTTP-in node webhook. No HA dependency at all. |
| **Philips Hue bridge directly** | Call the Hue bridge REST API (`http://<bridge-ip>/api/<username>/lights/<id>/state`) and skip HA entirely. |
| **Any REST endpoint** | Swap the URL, auth header, and JSON body to match the target API. The polling logic is unchanged. |

The solution has no hard dependency on Home Assistant beyond the two REST calls.
HA was chosen here because it was already in place and provides the light
automation layer, but the script itself is platform-agnostic.

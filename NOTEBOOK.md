# Notebook — Teams/Zoom Presence Light

A running journal of decisions, dead ends, and progress. Read this first
when resuming work in a new session — it has the "why" behind the current
state of the code, which ARCHITECTURE.md and ADMINISTRATION.md don't cover.

---

## 2026-07-30 — Project kickoff

**Problem:** Previously used Microsoft Store app "PresenceLight" to show
Teams call status on a Hue light via Home Assistant. It worked by talking
directly to HA. Microsoft changed Graph API requirements, requiring Entra ID
app registration with corporate IT involvement. IT declined (citing a cost
concern, probably a misunderstanding about licensing, but a hard no either
way). Need a replacement that doesn't depend on corporate IT.

**Research done:** Surveyed all plausible options — Graph API, local Teams
log monitoring, HASS.Agent, Power Automate Desktop screen scraping, network
traffic analysis. Findings:
- Local Teams log file monitoring is dead — new Teams client (2023+ PWA)
  doesn't write readable presence state to logs anymore
- Graph API is the gold standard (full presence states) but blocked by
  tenant policy — confirmed via direct test, got `401 Insufficient
  privileges` trying to register an app at entra.microsoft.com
- HASS.Agent could work (mic/camera sensors) but user had tried it before
  and hit AV/stability issues, removed it
- Decided: build a lightweight PowerShell script instead of reinstalling
  HASS.Agent, to avoid its overhead/AV footprint

**Decision:** Build custom PowerShell script, polling Windows for mic usage,
pushing to HA via REST, with an HA automation controlling the Hue light.

**Built:**
- `teams-presence.ps1` v1 — registry-based mic detection
  (`CapabilityAccessManager\ConsentStore\microphone`)
- `setup-guide.md` — full deployment instructions
- HA `input_boolean.teams_in_call` helper
- HA automation to map boolean state → Hue light color

**Issues hit during initial setup:**
- PowerShell execution policy blocked the script — fixed with
  `Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned`
- Script still blocked after that — turned out to be the "downloaded from
  internet" Zone.Identifier flag on the copied file — fixed with
  `Unblock-File`
- First version of `Get-MicInUseByTeams` used `return $true` inside a
  `ForEach-Object` pipeline block, which doesn't actually return from the
  function in PowerShell (it's pipeline output, builds an array instead).
  Caused `Cannot convert value "System.Object[]" to type "System.Boolean"`
  errors. Fixed by switching to plain `foreach` loops with `break`.

**Result:** Working end-to-end. Red when in call, green when free, 40%
brightness (adjusted down from a too-bright initial 100%/50% test values).

---

## 2026-10-30 — Detection stopped working (registry regression)

**Symptom reported:** "Working flawlessly for some time, stopped working in
the last couple of days." Light stuck on green regardless of call status.

**Triage steps:**
1. Checked script log — still running, no errors, successfully pushing
   "FREE" state to HA
2. Had user join a live Zoom call and watch the log in real time — no
   `IN_CALL` ever appeared
3. Had user dump the raw registry contents of the ConsentStore while
   actively on an unmuted Zoom call — **Zoom's entry showed a non-zero
   `LastUsedTimeStop`**, meaning Windows itself wasn't reporting it as
   "currently active" via this registry path, even though the mic was
   definitely live

**Research finding:** This is a confirmed, widely-reported Windows
regression. Microsoft began rolling out a **feature-flagged change**
(server-side, inconsistent per-device) to recent Windows 11 builds
(26300.95xx+, via October 2026 cumulative updates) that stops the
`CapabilityAccessManager\ConsentStore` registry keys from updating in real
time. Confirmed via multiple independent open-source projects (HASS.Agent,
LuxaforOnAir, others) hitting the identical issue in Sept/Oct 2026 GitHub
issues. Not a bug in our script — a genuine Microsoft-side change.

**Fix:** Rewrote mic detection to use the **WASAPI Core Audio session API**
directly (`IAudioSessionManager2` → `IAudioSessionEnumerator` →
`IAudioSessionControl2.GetState()`), via an embedded C# type loaded with
`Add-Type` (no native PowerShell cmdlet exists for this). This is the same
low-level mechanism Windows' own privacy indicators use, so it's not subject
to the registry regression. Kept the old registry method as an automatic
fallback only, in case WASAPI ever throws.

Also added Zoom to the list of monitored processes at the same time (user
requested this independently — Teams + Zoom are the two apps actually used
for calls).

**Verified:** Tested with Zoom (worked immediately), tested with Teams ~30
min later (confirmed working).

---

## 2026-11-06 — Light not syncing after restart

**Symptom reported:** On script startup, log showed "Initial state push
succeeded" but the physical Hue light did not change to match.

**Root cause identified:** HA's `input_boolean.turn_off` (and `turn_on`)
service calls don't reliably emit a `state_changed` event when the helper
is **already** in the requested state. Since the color automation only
triggers on that event, pushing "FREE" when the boolean was already `off`
silently did nothing — no event, no automation run, no light change. This
was a latent bug since the very first version; it only became visible once
we added the "force an initial push on startup" feature (also built this
session, see below) because that's when a same-value push became common
(e.g., restarting the script when nothing has changed since last run).

**Two changes made in this session, in order:**

1. **Added forced initial-state push on script startup**, with retry logic
   (5 attempts, 5 seconds apart) in case HA isn't reachable yet right after
   login. This was to fix: *"if the light's state is unknown (e.g. power
   cycled), it won't correct itself until the next call."* This surfaced the
   bug above once implemented and tested.

2. **Added direct light control.** Script now calls `light.turn_on` on
   `light.oncall_light` directly (color + brightness) on every push, in
   addition to flipping `input_boolean.teams_in_call`. This makes the light
   state authoritative and independent of whether HA's automation event
   fires. The `input_boolean` is still updated too (kept for HA history/
   dashboards/possible future automations), it's just no longer the only
   path controlling the light.

**Verified:** Manually set the Hue light to an unrelated color in HA,
restarted the script, confirmed it snapped back to "FREE" (green)
immediately on startup without needing a call.

---

## Open questions / things to revisit

See `BACKLOG.md` for the structured list. Flagging here for context:
- Never tested what happens if the laptop sleeps mid-call and wakes up
  after the call ends — does the script survive sleep/wake, or does the
  WASAPI session enumeration break across a sleep cycle?
- Never tested behavior when joining a call **muted from the start** —
  unclear if WASAPI reports a session as "active" if the mic is muted
  within the app but the OS-level capture session is still held open
- Have not tested multi-monitor/multi-session Windows scenarios (e.g. RDP)

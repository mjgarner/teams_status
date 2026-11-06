# Backlog — Teams/Zoom Presence Light

Open issues, ideas, and things to revisit. Not urgent — the system is
working as of 2026-11-06 — but worth tracking for future sessions.

---

## Open Questions (untested scenarios)

- [ ] **Sleep/wake behavior** — does the script survive the laptop going to
  sleep mid-call and waking up after the call ends? Does WASAPI session
  enumeration throw or hang across a sleep/resume cycle? Not yet tested.
- [ ] **Muted-at-join calls** — if a user joins a Teams/Zoom call already
  muted, does the OS-level audio capture session still register as
  "active" via WASAPI? Unverified — behavior may vary by app and by
  whether the app uses OS-level mute vs. app-level mute.
- [ ] **RDP / multi-session Windows** — untested whether WASAPI session
  enumeration behaves differently when the user is connected via Remote
  Desktop vs. physically logged in at the console.
- [ ] **Multiple audio devices** — untested with more than one microphone
  connected (e.g., built-in laptop mic + USB headset). Does WASAPI
  correctly enumerate sessions across all active capture devices?

---

## Potential Enhancements

- [ ] **Graph API upgrade path** — if corporate policy ever changes to
  allow user-level Entra ID app registration (or IT reconsiders), revisit
  using Microsoft Graph `/me/presence` for full Available/Busy/Away/DND
  states instead of binary in-call detection. See ARCHITECTURE.md "Why Not
  Microsoft Graph API?" for prior research. Candidate community project:
  `nic2045/PresenceGuard` (HACS-ready, OAuth UI login).
- [ ] **Camera-in-use detection as a secondary signal** — could catch cases
  where video is on but mic is somehow not flagged as active. Would need a
  different API (`IMFSensorActivityMonitor` via Media Foundation, or a
  `DEVPKEY_Device_PowerData` check) — more complex than the mic path, not
  started.
- [ ] **Distinguish meeting type** — currently any Teams/Zoom process
  holding an active mic session triggers "in a call," including test calls
  or voice memos. Low priority since this hasn't caused a real false
  positive yet.
- [ ] **Alert on script failure** — currently if the script crashes or the
  scheduled task stops running, there's no notification; the light just
  freezes at its last state. Could add a dead-man's-switch style HA
  automation (e.g., if `input_boolean` hasn't updated in X hours during
  work hours, send a notification).
- [ ] **Extend to other conferencing apps** — Google Meet (browser-based),
  Slack huddles, Discord, etc. Would just require adding process names to
  `$CALL_PROCESS_NAMES`, but need to identify exact `ProcessName` values
  for each (use `Get-Process | Sort-Object ProcessName` while active).
- [ ] **Config externalization** — HA URL, token, light entity, and
  brightness/colors are currently hardcoded at the top of the script.
  Could move to a separate config file (e.g. JSON) so updates don't require
  re-unblocking the whole script file each time config changes. Minor
  convenience, not urgent.

---

## Risks to Monitor

- [ ] **WASAPI method could also break in the future** — Microsoft has
  already broken the registry-based method once (Oct 2026). No guarantee
  WASAPI is permanently stable. Watch `teams-presence.log` for
  `WASAPI detection error` entries; check `hass-agent/HASS.Agent` GitHub
  issues periodically as an early-warning signal since they track the same
  problem space.
- [ ] **HA long-lived token has no expiry by default but can be manually
  revoked** — if HA is ever reconfigured/reinstalled, the token embedded in
  the script will need regenerating. See ADMINISTRATION.md.
- [ ] **Script is a single point of failure** — no redundancy if the laptop
  is off, asleep, or the task fails silently. Acceptable for current use
  case (home office indicator) but worth remembering if reliability
  requirements increase.

---

## Completed / Resolved (moved out of active backlog)

- [x] Initial PresenceLight replacement — resolved 2026-07-30
- [x] Registry detection broken by Windows update — resolved 2026-10-30
  (switched to WASAPI)
- [x] Light not syncing after restart / stale state — resolved 2026-11-06
  (direct light control added)
- [x] Zoom support added alongside Teams — resolved 2026-10-30

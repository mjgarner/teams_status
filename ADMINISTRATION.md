# Administration — Teams/Zoom Presence Light

## Environment Summary

| Component | Value |
|---|---|
| Laptop OS | Windows 11 |
| Laptop ownership | Personal (not corporate-managed) |
| Script location | `C:\Users\Michael\Scripts\teams-presence.ps1` |
| Log file | `C:\Users\Michael\Scripts\teams-presence.log` |
| Home Assistant URL | `http://192.168.3.131:8123` |
| HA helper entity | `input_boolean.teams_in_call` |
| HA light entity | `light.oncall_light` |
| HA automation | "Teams Presence - Hue Light" |
| Startup mechanism | Windows Task Scheduler, task name `Teams Presence Monitor` |

---

## Deployment Procedure (fresh machine or reinstall)

1. Copy `teams-presence.ps1` to `C:\Users\<User>\Scripts\`
2. Unblock the file (required — Windows marks copied files as
   "downloaded from the internet"):
   ```powershell
   Unblock-File -Path "C:\Users\<User>\Scripts\teams-presence.ps1"
   ```
3. Set execution policy once per machine (if not already set):
   ```powershell
   Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned
   ```
4. Test manually before scheduling:
   ```powershell
   & "C:\Users\<User>\Scripts\teams-presence.ps1"
   ```
   Confirm `teams-presence.log` shows a successful initial push, then join
   a test Teams or Zoom call and confirm `State change -> IN_CALL` appears
   and the Hue light changes color.
5. Register the Windows Task Scheduler task (see below) and confirm it
   survives a reboot/relogin.

In Home Assistant, confirm these objects already exist (see `setup-guide.md`
for full creation steps if starting from scratch):
- `input_boolean.teams_in_call` (Settings → Helpers)
- `light.oncall_light` (Hue integration, already paired)
- Automation "Teams Presence - Hue Light" (Settings → Automations)

---

## Windows Task Scheduler Configuration

| Setting | Value |
|---|---|
| Task name | `Teams Presence Monitor` |
| Trigger | At log on, specific user, delay 30 seconds |
| Action | `powershell.exe` |
| Arguments | `-WindowStyle Hidden -ExecutionPolicy Bypass -File "C:\Users\Michael\Scripts\teams-presence.ps1"` |
| Run only when logged on | Yes |
| Run with highest privileges | No |
| Conditions | AC power requirement unchecked |
| Multiple instances | Do not start a new instance |

### Common task operations

**Restart the task after updating the script:**
1. Task Scheduler → find `Teams Presence Monitor` → right-click → **End**
2. Replace the script file, then `Unblock-File` again
3. Right-click the task → **Run**

**Check if it's currently running:**
Task Scheduler → Status column should show "Running". "Last Run Result"
should be `0x0` or blank.

**View recent activity:**
```powershell
Get-Content "C:\Users\Michael\Scripts\teams-presence.log" -Tail 30
```

**Live-tail the log while testing:**
```powershell
Get-Content "C:\Users\Michael\Scripts\teams-presence.log" -Wait -Tail 10
```

---

## Updating the Script

Every time the script file is replaced (bug fix, enhancement, etc.):

1. Stop the running instance (end the scheduled task, or Ctrl+C if running
   manually in a console)
2. Copy the new version into place
3. **Re-run `Unblock-File`** — this is required every single time the file
   is replaced, not just the first time:
   ```powershell
   Unblock-File -Path "C:\Users\Michael\Scripts\teams-presence.ps1"
   ```
4. Test manually first (see Deployment Procedure step 4)
5. Restart the scheduled task

Skipping the `Unblock-File` step produces this error:
```
File ... cannot be loaded. The file is not digitally signed.
```

---

## Home Assistant Long-Lived Access Token

The script authenticates to HA using a long-lived access token embedded in
`$HA_TOKEN` at the top of the script.

**If the token is ever revoked or expires:**
1. In HA: **Profile (click your username) → Security → Long-Lived Access
   Tokens → Create Token**
2. Copy the new token
3. Update `$HA_TOKEN` in `teams-presence.ps1`
4. Re-unblock, re-test, restart the scheduled task

Tokens do not expire by default in HA but can be manually revoked. If the
script log shows repeated `ERROR pushing to HA` with a `401` response, this
is the most likely cause.

---

## Routine Health Checks

Recommended to check periodically (e.g., monthly, or after any Windows
Update):

| Check | Command / Location |
|---|---|
| Task still registered and running | Task Scheduler → `Teams Presence Monitor` |
| Script actively polling | `Get-Content teams-presence.log -Tail 10` — timestamps should be recent |
| WASAPI method still working | Log should NOT show `WASAPI detection error` or `falling back to registry method` |
| HA helper reachable | HA → Developer Tools → States → `input_boolean.teams_in_call` |
| Light entity reachable | HA → Developer Tools → States → `light.oncall_light` |
| Automation still enabled | HA → Settings → Automations → "Teams Presence - Hue Light" (not disabled) |

---

## Troubleshooting Quick Reference

| Symptom | Likely Cause | Action |
|---|---|---|
| Script won't run - "not digitally signed" | File blocked after copy | Run `Unblock-File` |
| Script runs but light never changes | Automation not firing, or input_boolean stuck | Confirmed fixed Nov 2026 - script now also calls `light.turn_on` directly. If recurring, check `Set-HAEverything` logic in script |
| `IN_CALL` never triggers for a real call | WASAPI silently falling back to broken registry method | Check log for `WASAPI detection error`; see ARCHITECTURE.md "Known Limitations" |
| `ERROR pushing to HA` in log | Token expired/revoked, or HA unreachable (network/IP change) | Verify HA URL still correct; regenerate token if 401 |
| Light wrong color/brightness only | Automation YAML or `$LIGHT_COLOR_*` / `$LIGHT_BRIGHTNESS` mismatch | Compare automation YAML in setup-guide.md against script config block |
| Works for Teams but not Zoom (or vice versa) | Process name changed after an app update | Run `Get-Process \| Sort-Object ProcessName` while in a call, compare to `$CALL_PROCESS_NAMES` in script |
| Task doesn't start after reboot | Scheduled task trigger/condition misconfigured | Re-check Task Scheduler config table above |

---

## Change History

See `NOTEBOOK.md` for the full narrative history of decisions and fixes.
This section tracks only the current live configuration values, which
supersede any values shown in chat history or older notebook entries.

| Date | Change | Reason |
|---|---|---|
| 2026-07-30 | Initial deployment — registry-based mic detection | PresenceLight broke due to Graph API requirement |
| 2026-10-30 | Switched primary detection to WASAPI Core Audio API | Microsoft feature-flag rollout broke registry-based detection |
| 2026-11-06 | Added forced initial state push with retries | Light didn't reflect correct state after HA restart / Hue power cycle |
| 2026-11-06 | Script now calls `light.turn_on` directly in addition to `input_boolean` | HA doesn't reliably fire state_changed events when input_boolean is set to its current value |

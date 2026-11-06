# teams-presence.ps1
# Monitors microphone usage by Microsoft Teams and Zoom and pushes presence
# state to Home Assistant via webhook.
#
# State machine:
#   IN_CALL  -> Teams or Zoom is actively using the microphone
#   FREE     -> Neither app is using the microphone
#
# Runs as a persistent loop. Deploy via Windows Task Scheduler (run at logon,
# run whether user is logged on or not is NOT required - run only when logged on).
#
# Requirements: Windows 11, PowerShell 5.1+, network access to HA.
#
# NOTE (2026-10-30): Primary detection uses the WASAPI Core Audio session API
# (via embedded C# / Add-Type) because Microsoft began rolling out a
# feature-flagged change to recent Windows 11 builds (26300.95xx+) that stops
# the CapabilityAccessManager ConsentStore registry keys from updating in
# real time. This is a confirmed, widely-reported regression (not a bug in
# this script). The registry method is kept as a fallback only, since it may
# still work correctly on machines that haven't received the flag yet.
# See setup-guide.md "Known Issue" section for details.

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
$HA_URL        = "http://192.168.3.131:8123"
$HA_TOKEN      = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiI3YmVjMmY1ZjllMmE0NTMwYjc1MTQ1ZWI4OTE0MTM3YiIsImlhdCI6MTc4NTQxODEzOCwiZXhwIjoyMTAwNzc4MTM4fQ.DLsfr7CeeJcfIZ5oEWp3oibGVvIQSM7pw2VOFSF5CW8"
$HA_ENTITY     = "input_boolean.teams_in_call"   # create this helper in HA
$POLL_SECONDS  = 5                                # how often to check (seconds)

# Process names (as reported by Get-Process -> ProcessName, no .exe) that
# count as an active call when they hold an active microphone session.
$CALL_PROCESS_NAMES = @("ms-teams", "Teams", "Zoom", "msedgewebview2")

# ---------------------------------------------------------------------------
# Logging (optional - writes to same folder as script)
# ---------------------------------------------------------------------------
$LogFile = Join-Path $PSScriptRoot "teams-presence.log"

function Write-Log {
    param([string]$Message)
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "$ts  $Message"
    Write-Host $line
    try { Add-Content -Path $LogFile -Value $line -ErrorAction SilentlyContinue } catch {}
}

# ---------------------------------------------------------------------------
# WASAPI Core Audio session detection (primary method)
# ---------------------------------------------------------------------------
# There is no native PowerShell cmdlet or WMI class that exposes real-time
# audio session state (active/inactive capture). This requires COM interop
# with the Core Audio API (IAudioSessionManager2 / IAudioSessionControl2).
$WasapiTypeDef = @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
namespace MicCheck {
[ComImport, Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IMMDeviceEnumerator { [PreserveSig] int EnumAudioEndpoints(int dataFlow, int stateMask, out IMMDeviceCollection devices); }
[ComImport, Guid("0BD7A1BE-7A1A-44DB-8397-CC5392387B5E"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IMMDeviceCollection { [PreserveSig] int GetCount(out int count); [PreserveSig] int Item(int index, out IMMDevice device); }
[ComImport, Guid("D666063F-1587-4E43-81F1-B948E807363F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IMMDevice { [PreserveSig] int Activate(ref Guid iid, int clsCtx, IntPtr p, [MarshalAs(UnmanagedType.IUnknown)] out object iface); }
[ComImport, Guid("77AA99A0-1BD6-484F-8BC7-2C654C9A9B6F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IAudioSessionManager2 {
 [PreserveSig] int GetAudioSessionControl(IntPtr a, int b, out IntPtr c);
 [PreserveSig] int GetSimpleAudioVolume(IntPtr a, int b, out IntPtr c);
 [PreserveSig] int GetSessionEnumerator(out IAudioSessionEnumerator e); }
[ComImport, Guid("E2F5BB11-0570-40CA-ACDD-3AA01277DEE8"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IAudioSessionEnumerator { [PreserveSig] int GetCount(out int count); [PreserveSig] int GetSession(int index, [MarshalAs(UnmanagedType.IUnknown)] out object session); }
[ComImport, Guid("bfb7ff88-7239-4fc9-8fa2-07c950be9c6d"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IAudioSessionControl2 {
 [PreserveSig] int GetState(out int state);
 [PreserveSig] int GetDisplayName(out IntPtr a);
 [PreserveSig] int SetDisplayName(IntPtr a, IntPtr b);
 [PreserveSig] int GetIconPath(out IntPtr a);
 [PreserveSig] int SetIconPath(IntPtr a, IntPtr b);
 [PreserveSig] int GetGroupingParam(out Guid a);
 [PreserveSig] int SetGroupingParam(IntPtr a, IntPtr b);
 [PreserveSig] int RegisterAudioSessionNotification(IntPtr a);
 [PreserveSig] int UnregisterAudioSessionNotification(IntPtr a);
 [PreserveSig] int GetSessionIdentifier(out IntPtr a);
 [PreserveSig] int GetSessionInstanceIdentifier(out IntPtr a);
 [PreserveSig] int GetProcessId(out uint pid); }
[ComImport, Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")] class MMDeviceEnumerator {}
public static class Mic {
 public static List<uint> ActivePids() {
  var result = new List<uint>();
  var en = (IMMDeviceEnumerator)(new MMDeviceEnumerator());
  IMMDeviceCollection devs; if (en.EnumAudioEndpoints(1, 1, out devs) != 0) return result;
  int n; devs.GetCount(out n);
  Guid iid = typeof(IAudioSessionManager2).GUID;
  for (int i = 0; i < n; i++) {
   IMMDevice d; if (devs.Item(i, out d) != 0) continue;
   object o; if (d.Activate(ref iid, 23, IntPtr.Zero, out o) != 0) continue;
   IAudioSessionEnumerator se; if (((IAudioSessionManager2)o).GetSessionEnumerator(out se) != 0) continue;
   int c; se.GetCount(out c);
   for (int j = 0; j < c; j++) {
    object so; if (se.GetSession(j, out so) != 0) continue;
    var s = (IAudioSessionControl2)so;
    int st; s.GetState(out st);
    if (st == 1) { uint pid; s.GetProcessId(out pid); result.Add(pid); }
   }
  }
  return result;
 }
}
}
'@

if (-not ('MicCheck.Mic' -as [type])) {
    Add-Type -TypeDefinition $WasapiTypeDef -Language CSharp
}

function Get-MicInUseByCallApp-Wasapi {
    <#
    .SYNOPSIS
    Returns $true if any process in $CALL_PROCESS_NAMES currently holds an
    ACTIVE audio capture session (real-time, via WASAPI Core Audio API).
    #>
    try {
        $pids = [MicCheck.Mic]::ActivePids()
        foreach ($p in $pids) {
            if ($p -eq 0) { continue }
            $proc = Get-Process -Id $p -ErrorAction SilentlyContinue
            if ($null -eq $proc) { continue }
            foreach ($name in $CALL_PROCESS_NAMES) {
                if ($proc.ProcessName -match [regex]::Escape($name)) {
                    return $true
                }
            }
        }
    } catch {
        Write-Log "WASAPI detection error: $_"
        return $null   # signal failure so caller can fall back
    }
    return $false
}

# ---------------------------------------------------------------------------
# Registry-based detection (fallback method only - see note at top of file)
# ---------------------------------------------------------------------------
function Get-MicInUseByTeams-Registry {
    <#
    .SYNOPSIS
    Legacy fallback. Returns $true if any Teams/Zoom-related process
    currently holds the microphone according to the ConsentStore registry.
    NOTE: As of Oct 2026 this no longer updates in real time on some
    Windows 11 builds due to a Microsoft feature-flag rollout. Kept only
    as a fallback if the WASAPI method throws an error.
    #>

    $basePath = "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\microphone"
    $found = $false

    try {
        foreach ($key in (Get-ChildItem -Path $basePath -ErrorAction SilentlyContinue)) {
            $keyName = $key.PSChildName
            if ($keyName -match "MSTeams" -or $keyName -match "Teams") {
                $stopTime = (Get-ItemProperty -Path $key.PSPath -Name "LastUsedTimeStop" -ErrorAction SilentlyContinue).LastUsedTimeStop
                if ($null -ne $stopTime -and $stopTime -eq 0) {
                    $found = $true
                    break
                }
            }
        }
    } catch {}

    if (-not $found) {
        $nonPackagedPath = Join-Path $basePath "NonPackaged"
        try {
            foreach ($key in (Get-ChildItem -Path $nonPackagedPath -ErrorAction SilentlyContinue)) {
                $keyName = $key.PSChildName
                $isMatch = $false
                foreach ($proc in $CALL_PROCESS_NAMES) {
                    if ($keyName -match [regex]::Escape($proc)) {
                        $isMatch = $true
                        break
                    }
                }
                if ($isMatch) {
                    $stopTime = (Get-ItemProperty -Path $key.PSPath -Name "LastUsedTimeStop" -ErrorAction SilentlyContinue).LastUsedTimeStop
                    if ($null -ne $stopTime -and $stopTime -eq 0) {
                        $found = $true
                        break
                    }
                }
            }
        } catch {}
    }

    return $found
}

function Get-MicInUseByCallApp {
    $result = Get-MicInUseByCallApp-Wasapi
    if ($null -ne $result) {
        return $result
    }
    Write-Log "WASAPI method failed - falling back to registry method"
    return Get-MicInUseByTeams-Registry
}

# Light entity controlled directly by this script (bypasses the automation
# for the initial/forced push - see "Known Issue: light not updating on
# unchanged state" below).
$HA_LIGHT_ENTITY   = "light.oncall_light"
$LIGHT_BRIGHTNESS  = 102   # 40% of 255
$LIGHT_COLOR_BUSY  = "red"
$LIGHT_COLOR_FREE  = "green"

# ---------------------------------------------------------------------------
# Home Assistant REST helpers
# ---------------------------------------------------------------------------
$Headers = @{
    "Authorization" = "Bearer $HA_TOKEN"
    "Content-Type"  = "application/json"
}

function Set-HAState {
    param([bool]$InCall)

    $service = if ($InCall) { "turn_on" } else { "turn_off" }
    $url     = "$HA_URL/api/services/input_boolean/$service"
    $body    = @{ entity_id = $HA_ENTITY } | ConvertTo-Json

    try {
        $response = Invoke-RestMethod -Uri $url -Method Post -Headers $Headers -Body $body -ErrorAction Stop
        return $true
    } catch {
        Write-Log "ERROR pushing to HA: $_"
        return $false
    }
}

function Set-HALight {
    <#
    .SYNOPSIS
    Directly commands the Hue light to the correct color/brightness.

    This exists because HA's input_boolean turn_on/turn_off service calls do
    not reliably emit a state_changed event when the helper is already in the
    requested state (e.g. already "off"). Since the color-changing automation
    is triggered by that state_changed event, relying on the input_boolean
    alone means the light can silently fail to sync - most noticeably on
    script startup, after an HA restart, or after a Hue power cycle. Calling
    light.turn_on directly here guarantees the light always matches reality,
    independent of whether the input_boolean event fires.
    #>
    param([bool]$InCall)

    $color = if ($InCall) { $LIGHT_COLOR_BUSY } else { $LIGHT_COLOR_FREE }
    $url   = "$HA_URL/api/services/light/turn_on"
    $body  = @{
        entity_id  = $HA_LIGHT_ENTITY
        color_name = $color
        brightness = $LIGHT_BRIGHTNESS
    } | ConvertTo-Json

    try {
        $response = Invoke-RestMethod -Uri $url -Method Post -Headers $Headers -Body $body -ErrorAction Stop
        return $true
    } catch {
        Write-Log "ERROR setting light directly: $_"
        return $false
    }
}

function Set-HAEverything {
    <#
    .SYNOPSIS
    Pushes both the input_boolean (for HA automations/history/dashboards)
    and directly commands the light (for guaranteed sync). Returns $true
    only if both succeed.
    #>
    param([bool]$InCall)

    $boolOk  = Set-HAState -InCall $InCall
    $lightOk = Set-HALight -InCall $InCall

    return ($boolOk -and $lightOk)
}

function Get-HAState {
    $url = "$HA_URL/api/states/$HA_ENTITY"
    try {
        $state = Invoke-RestMethod -Uri $url -Method Get -Headers $Headers -ErrorAction Stop
        return $state.state   # "on" or "off"
    } catch {
        Write-Log "ERROR reading HA state: $_"
        return $null
    }
}

# ---------------------------------------------------------------------------
# Main loop
# ---------------------------------------------------------------------------
Write-Log "teams-presence.ps1 started. Polling every $POLL_SECONDS seconds."
Write-Log "HA entity: $HA_ENTITY  |  HA URL: $HA_URL"

# Explicitly push the current state on startup, regardless of what HA's
# input_boolean currently shows. This protects against cases where HA was
# restarted, the helper's state was reset/unknown, or the Hue light was
# power-cycled and no longer matches the last known call status. Retries a
# few times in case HA isn't reachable yet right after boot/login.
$lastState = $null
$initialMicActive = Get-MicInUseByCallApp
if ($null -eq $initialMicActive) { $initialMicActive = $false }

$initialLabel = if ($initialMicActive) { "IN_CALL" } else { "FREE" }
Write-Log "Initial state -> $initialLabel (forcing push to HA)"

$maxInitialRetries = 5
$retryDelaySeconds = 5
for ($attempt = 1; $attempt -le $maxInitialRetries; $attempt++) {
    $ok = Set-HAEverything -InCall $initialMicActive
    if ($ok) {
        $lastState = $initialMicActive
        Write-Log "Initial state push succeeded (input_boolean + light)."
        break
    } else {
        Write-Log "Initial state push failed (attempt $attempt of $maxInitialRetries). Retrying in $retryDelaySeconds seconds..."
        Start-Sleep -Seconds $retryDelaySeconds
    }
}

if ($null -eq $lastState) {
    Write-Log "WARNING: Could not push initial state to HA after $maxInitialRetries attempts. Will keep trying on next detected change."
}

while ($true) {
    try {
        $micActive = Get-MicInUseByCallApp

        if ($micActive -ne $lastState) {
            $label = if ($micActive) { "IN_CALL" } else { "FREE" }
            Write-Log "State change -> $label"
            $ok = Set-HAEverything -InCall $micActive
            if ($ok) {
                $lastState = $micActive
            }
        }
    } catch {
        Write-Log "Unexpected error in main loop: $_"
    }

    Start-Sleep -Seconds $POLL_SECONDS
}

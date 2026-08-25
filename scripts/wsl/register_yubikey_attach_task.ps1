<#
.SYNOPSIS
    Idempotently registers a Scheduled Task that runs attach_yubikey.ps1
    automatically whenever a USB device is connected, fully hidden/backgrounded.

.DESCRIPTION
    Registers (creating or replacing) a Task Scheduler task named
    'AttachYubiKeyToWSL' with an event trigger on USB device-connect events
    (Microsoft-Windows-DriverFrameworks-UserMode/Operational, Event ID 2003).
    That event fires for any USB device, not just a YubiKey -
    attach_yubikey.ps1 itself no-ops when the connected device isn't a match,
    so the broad trigger is safe.

    The task runs as SYSTEM with the highest privileges (so it always has the
    Administrator rights usbipd needs, and never depends on an interactive
    logon session) via powershell.exe -WindowStyle Hidden, so no console
    window ever appears.

    Re-running this script is safe/idempotent: Register-ScheduledTask -Force
    replaces any existing task of the same name with the current definition,
    and enabling an already-enabled event log is a no-op.

.NOTES
    Requirements: Windows Task Scheduler (ScheduledTasks module, built in),
    run elevated. Expects attach_yubikey.ps1 to already be deployed at
    %USERPROFILE%\Documents\Scripts\attach_yubikey.ps1.
#>

#Requires -RunAsAdministrator

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------

$TaskName = 'AttachYubiKeyToWSL'
$TaskDescription = 'Runs attach_yubikey.ps1 to attach a connected YubiKey to WSL whenever a USB device is connected.'

# Fixed deployment location. Resolved to an absolute path here (this script
# runs interactively, as the real user), so the task action gets a concrete
# path baked in - it doesn't matter that the task itself later runs as
# SYSTEM, whose own %USERPROFILE% would point somewhere else entirely.
$ScriptsDir = Join-Path $env:USERPROFILE 'Documents\Scripts'
$AttachScript = Join-Path $ScriptsDir 'attach_yubikey.ps1'

$PowerShellExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

# USB device-connect event: fires for any USB/PnP device, not just the
# YubiKey - attach_yubikey.ps1 no-ops if the device that appeared isn't one.
$EventLogName = 'Microsoft-Windows-DriverFrameworks-UserMode/Operational'
$EventId = 2003

# ---------------------------------------------------------------------------
# Sanity checks
# ---------------------------------------------------------------------------

if (-not (Test-Path -LiteralPath $AttachScript)) {
    Write-Error "attach_yubikey.ps1 not found at expected deployment path: $AttachScript"
    exit 1
}

if (-not (Get-Module -ListAvailable -Name ScheduledTasks)) {
    Write-Error "Required module 'ScheduledTasks' not available."
    exit 1
}

if (-not (Test-Path -LiteralPath $PowerShellExe)) {
    Write-Error "powershell.exe not found at expected path: $PowerShellExe"
    exit 1
}

# ---------------------------------------------------------------------------
# Ensure the source event log is enabled (it's off by default on some builds)
# ---------------------------------------------------------------------------

$log = Get-WinEvent -ListLog $EventLogName
if (-not $log.IsEnabled) {
    $log.IsEnabled = $true
    $log.SaveChanges()
}

# ---------------------------------------------------------------------------
# Build the task definition
# ---------------------------------------------------------------------------

$action = New-ScheduledTaskAction -Execute $PowerShellExe `
    -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$AttachScript`""

$triggerClass = Get-CimClass -ClassName MSFT_TaskEventTrigger -Namespace 'Root/Microsoft/Windows/TaskScheduler'
$trigger = New-CimInstance -CimClass $triggerClass -ClientOnly
$trigger.Subscription = @"
<QueryList><Query Id="0" Path="$EventLogName"><Select Path="$EventLogName">*[System[(EventID=$EventId)]]</Select></Query></QueryList>
"@
$trigger.Enabled = $true

# SYSTEM + ServiceAccount: no stored password, no interactive session, so the
# task runs fully backgrounded regardless of desktop/lock state.
$principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest

$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -StartWhenAvailable -MultipleInstances IgnoreNew

# ---------------------------------------------------------------------------
# Register (idempotent: -Force replaces any existing task of the same name)
# ---------------------------------------------------------------------------

Register-ScheduledTask -TaskName $TaskName -Description $TaskDescription `
    -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null

Write-Output "Scheduled task '$TaskName' registered: runs $AttachScript (hidden, as SYSTEM) on USB device connect."

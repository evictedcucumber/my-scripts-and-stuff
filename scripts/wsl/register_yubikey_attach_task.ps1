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

    The task runs as the registering user (Interactive logon, not SYSTEM)
    with the highest privileges. It must run as the interactive user rather
    than SYSTEM because `usbipd attach --wsl` shells out to wsl.exe, and
    Microsoft Store WSL cannot be launched from Session 0 - a
    SYSTEM/ServiceAccount task would register and "run" successfully but
    silently fail to attach (see https://github.com/microsoft/WSL/issues/9231).
    Running as the user means the task only fires while that user is logged
    on interactively.

    The task's action launches wscript.exe against a small generated VBScript
    wrapper (run_attach_yubikey_hidden.vbs, written into the same deployment
    directory) instead of powershell.exe directly. powershell.exe's own
    -WindowStyle Hidden isn't enough to keep the console fully invisible - the
    console host still briefly flashes a window before the flag takes effect.
    WScript.Shell.Run with an intWindowStyle of 0 launches the process without
    ever creating a window in the first place.

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

# Fixed deployment location, resolved to an absolute path here. The task
# also runs as this same user (see principal below), so %USERPROFILE% at
# registration time and at run time match.
$ScriptsDir = Join-Path $env:USERPROFILE 'Documents\Scripts'
$AttachScript = Join-Path $ScriptsDir 'attach_yubikey.ps1'

# The task runs as this same user rather than SYSTEM - see .DESCRIPTION.
$TaskUserId = "$env:USERDOMAIN\$env:USERNAME"

$PowerShellExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$WScriptExe = Join-Path $env:SystemRoot 'System32\wscript.exe'
$HiddenWrapperScript = Join-Path $ScriptsDir 'run_attach_yubikey_hidden.vbs'

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

if (-not (Test-Path -LiteralPath $WScriptExe)) {
    Write-Error "wscript.exe not found at expected path: $WScriptExe"
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
# Write the hidden-launch VBScript wrapper (see .DESCRIPTION for why this
# exists instead of invoking powershell.exe directly from the task action)
# ---------------------------------------------------------------------------

# VBScript string literals escape an embedded quote by doubling it.
$innerCommandLine = "`"$PowerShellExe`" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$AttachScript`""
$vbsEscapedCommandLine = $innerCommandLine -replace '"', '""'

$vbsContent = @"
Set objShell = CreateObject("WScript.Shell")
objShell.Run "$vbsEscapedCommandLine", 0, True
"@
Set-Content -LiteralPath $HiddenWrapperScript -Value $vbsContent -Encoding ASCII

# ---------------------------------------------------------------------------
# Build the task definition
# ---------------------------------------------------------------------------

# //B (batch mode) suppresses wscript's own error dialogs/prompts.
$action = New-ScheduledTaskAction -Execute $WScriptExe `
    -Argument "//B `"$HiddenWrapperScript`""

$triggerClass = Get-CimClass -ClassName MSFT_TaskEventTrigger -Namespace 'Root/Microsoft/Windows/TaskScheduler'
$trigger = New-CimInstance -CimClass $triggerClass -ClientOnly
$trigger.Subscription = @"
<QueryList><Query Id="0" Path="$EventLogName"><Select Path="$EventLogName">*[System[(EventID=$EventId)]]</Select></Query></QueryList>
"@
$trigger.Enabled = $true

# Interactive: runs in the user's own logon session (required for usbipd's
# wsl.exe invocation to work - see .DESCRIPTION) with no stored password,
# elevated automatically since the user must be an administrator. Only fires
# while $TaskUserId is logged on interactively.
$principal = New-ScheduledTaskPrincipal -UserId $TaskUserId -LogonType Interactive -RunLevel Highest

$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -StartWhenAvailable -MultipleInstances IgnoreNew

# ---------------------------------------------------------------------------
# Register (idempotent: -Force replaces any existing task of the same name)
# ---------------------------------------------------------------------------

Register-ScheduledTask -TaskName $TaskName -Description $TaskDescription `
    -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null

Write-Output "Scheduled task '$TaskName' registered: runs $AttachScript (hidden, as $TaskUserId) on USB device connect."

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

    attach_yubikey.ps1 must already be deployed at
    %USERPROFILE%\Documents\Scripts\attach_yubikey.ps1 - copy it there before
    running this. That fixed path is resolved once here and baked into the
    task's action.

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
    ever creating a window in the first place. On every run the wrapper is
    validated (present, UTF-16LE, expected content) and rewritten only if it is
    missing, wrongly encoded, or out of date.

    Re-running this script is safe/idempotent: Register-ScheduledTask -Force
    replaces any existing task of the same name with the current definition,
    enabling an already-enabled event log is a no-op, and the VBScript wrapper
    is only rewritten when it has drifted.

    Pass -Remove to unregister the task and delete the generated VBScript
    wrapper. attach_yubikey.ps1 is left in place.

.PARAMETER Remove
    Unregister the scheduled task and delete the generated VBScript wrapper
    instead of registering.

.NOTES
    Requirements: Windows Task Scheduler (ScheduledTasks module, built in),
    run elevated. attach_yubikey.ps1 must already be deployed at
    %USERPROFILE%\Documents\Scripts\attach_yubikey.ps1.
#>

#Requires -RunAsAdministrator

[CmdletBinding()]
param(
    [switch]$Remove
)

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

if (-not (Get-Module -ListAvailable -Name ScheduledTasks)) {
    Write-Error "Required module 'ScheduledTasks' not available."
    exit 1
}

# ---------------------------------------------------------------------------
# Teardown (-Remove)
# ---------------------------------------------------------------------------

if ($Remove) {
    if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
        Write-Output "Unregistered scheduled task '$TaskName'."
    }
    else {
        Write-Output "Scheduled task '$TaskName' not present."
    }

    if (Test-Path -LiteralPath $HiddenWrapperScript) {
        Remove-Item -LiteralPath $HiddenWrapperScript -Force
        Write-Output "Removed $HiddenWrapperScript"
    }

    exit 0
}

# ---------------------------------------------------------------------------
# Sanity checks
# ---------------------------------------------------------------------------

if (-not (Test-Path -LiteralPath $AttachScript)) {
    Write-Error "attach_yubikey.ps1 not found at $AttachScript - copy it into that folder first."
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

$log = Get-WinEvent -ListLog $EventLogName -ErrorAction SilentlyContinue
if ($null -eq $log) {
    Write-Error "Event log channel '$EventLogName' not found on this system."
    exit 1
}

if (-not $log.IsEnabled) {
    try {
        $log.IsEnabled = $true
        $log.SaveChanges()
    }
    catch {
        # Some operational/analytic channels reject the config-object write;
        # wevtutil is the reliable fallback.
        Write-Warning "Enabling '$EventLogName' via API failed ($($_.Exception.Message)); trying wevtutil."
        & wevtutil.exe set-log $EventLogName /enabled:true
        if ($LASTEXITCODE -ne 0) {
            Write-Error "Failed to enable event log channel '$EventLogName' (wevtutil exit $LASTEXITCODE)."
            exit 1
        }
    }
}

# ---------------------------------------------------------------------------
# Write / refresh the hidden-launch VBScript wrapper (see .DESCRIPTION for why
# this exists instead of invoking powershell.exe directly from the task
# action). It is validated on every run and only rewritten when it has drifted.
# ---------------------------------------------------------------------------

# VBScript string literals escape an embedded quote by doubling it.
$innerCommandLine = "`"$PowerShellExe`" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$AttachScript`""
$vbsEscapedCommandLine = $innerCommandLine -replace '"', '""'

$vbsContent = @"
Set objShell = CreateObject("WScript.Shell")
objShell.Run "$vbsEscapedCommandLine", 0, True
"@

function Test-HiddenWrapper {
    # $true only if the wrapper exists, is UTF-16LE (BOM), and matches
    # $ExpectedContent (ignoring line-ending / trailing-whitespace differences).
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [string] $ExpectedContent
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        Write-Verbose "VBScript wrapper missing: $Path"
        return $false
    }

    try {
        $bytes = [System.IO.File]::ReadAllBytes($Path)
    }
    catch {
        Write-Verbose "VBScript wrapper unreadable ($($_.Exception.Message)): $Path"
        return $false
    }

    # Set-Content -Encoding Unicode writes UTF-16LE with a BOM (0xFF 0xFE).
    if ($bytes.Length -lt 2 -or $bytes[0] -ne 0xFF -or $bytes[1] -ne 0xFE) {
        Write-Verbose "VBScript wrapper is not UTF-16LE: $Path"
        return $false
    }

    $actual = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::Unicode)
    $normActual = ($actual -replace "`r`n", "`n").Trim()
    $normExpected = ($ExpectedContent -replace "`r`n", "`n").Trim()
    if ($normActual -ne $normExpected) {
        Write-Verbose "VBScript wrapper content is out of date: $Path"
        return $false
    }

    return $true
}

if (Test-HiddenWrapper -Path $HiddenWrapperScript -ExpectedContent $vbsContent) {
    Write-Output "VBScript wrapper is current: $HiddenWrapperScript"
}
else {
    # UTF-16LE (with BOM) so wscript reads the paths correctly even if the
    # username / deployment path contains non-ASCII characters.
    Set-Content -LiteralPath $HiddenWrapperScript -Value $vbsContent -Encoding Unicode

    if (-not (Test-HiddenWrapper -Path $HiddenWrapperScript -ExpectedContent $vbsContent)) {
        Write-Error "VBScript wrapper failed validation after writing: $HiddenWrapperScript"
        exit 1
    }
    Write-Output "VBScript wrapper (re)generated: $HiddenWrapperScript"
}

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

# ExecutionTimeLimit caps a stuck usbipd/wsl.exe invocation so it can't block
# every later trigger (MultipleInstances IgnoreNew would drop them otherwise).
$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -StartWhenAvailable -MultipleInstances IgnoreNew `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 5)

# ---------------------------------------------------------------------------
# Register (idempotent: -Force replaces any existing task of the same name)
# ---------------------------------------------------------------------------

Register-ScheduledTask -TaskName $TaskName -Description $TaskDescription `
    -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null

Write-Output "Scheduled task '$TaskName' registered: runs $AttachScript (hidden, as $TaskUserId) on USB device connect."

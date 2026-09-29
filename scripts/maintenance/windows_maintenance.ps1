<#
.SYNOPSIS
    Runs a batch of Windows maintenance and health tasks in one pass: Windows
    Update, winget upgrades (user + system passes), DISM/SFC system file repair,
    Disk Cleanup, WSL disk compaction, a disk / event-log health check, per-volume
    optimization (defrag / retrim), a Microsoft Defender update + scan, and - with
    -DriverUpdate - Windows Update driver updates. Asks for confirmation up front,
    because some of it is destructive or disruptive.

.DESCRIPTION
    Runs the steps below in order. Each step is independent - a failure is
    caught, logged, and the run continues - and an OK / WARN / FAIL / SKIP
    summary is printed at the end. WARN means a step finished but found
    something worth a look (a health finding, a guard that held work back); it
    does not fail the run. The script exits non-zero if any step failed. It
    never reboots.

    Each step runs in its own console window: the orchestrator re-invokes this
    script with -RunStep <name> per step, waits for it, and reads a small JSON
    result back from a temp run directory (printed at the start and end of the
    run). That keeps each step's noisy output - winget's table redraws, the
    DISM progress bar, Optimize-Volume -Verbose - in a separate window and a
    per-step output.log, leaving the orchestrator window a clean progress list.
    A step window closes a few seconds after a successful step and stays open
    (waiting for Enter) on failure; -KeepStepWindows keeps every step window
    open.

    Before anything runs the script prints what it is about to do - calling out
    the destructive actions (Disk Cleanup empties the Recycle Bin and deletes
    temp files; component store cleanup drops superseded component versions)
    and the disruptive ones
    (wsl --shutdown ends every running WSL session and anything that depends on
    it; winget may close running apps) - and asks for confirmation. Declining
    exits with code 1 without changing anything. -Yes skips the question
    (needed for unattended runs; the plan is still printed). After confirmation
    it runs preflight checks (warns about an already-pending reboot and
    nearly-full volumes) and creates a System Restore point before making
    changes (-SkipRestorePoint to skip; Windows may decline if System
    Protection is off or a point was already created in the last 24 hours).

    The script does not require elevation to start. If it is launched without
    Administrator and any step that needs it (Windows Update, winget system
    pass, integrity repair, Disk Cleanup, WSL compaction, health check, defrag,
    Defender) is going to run, the script relaunches itself elevated in a new
    console (one UAC prompt, asked after the confirmation above), runs there,
    and exits with that run's exit code;
    the elevated window stays open at the end so its output is readable. Pass
    -NoElevate to suppress the relaunch - the admin-only steps are then marked
    SKIP (not FAIL) and the run exits non-zero. The winget user pass
    never runs elevated.

      1. Windows Update
         Scans, downloads, and installs all applicable software updates via the
         PSWindowsUpdate module, including Office and other Microsoft products
         (the Microsoft Update service is registered on first use - the same
         switch as "Receive updates for other Microsoft products" in Settings;
         if that fails the step carries on with Windows Update only). Drivers
         are excluded (-UpdateType Software) - they only come with -DriverUpdate.
         If the module is not installed it is pulled
         from the PowerShell Gallery on first run (Install-Module, CurrentUser
         scope; the NuGet package provider is bootstrapped first if needed).
         Automatic reboots are suppressed (-IgnoreReboot); a resulting pending
         reboot is reported in the summary but not acted on.

      2. Driver updates  (only with -DriverUpdate)
         Installs driver updates offered through Windows Update
         (Get-WindowsUpdate -UpdateType Driver, same PSWindowsUpdate module as
         step 1). This is the "verified drivers only" path: every driver on
         Windows Update is WHQL-certified and submitted by the hardware vendor
         through Microsoft's Hardware Dev Center - unlike Driver Booster and
         similar tools, which pull from their own unvetted repositories. Off by
         default because driver updates carry more regression risk than
         software updates; reboots are suppressed and reported like step 1.

      3. winget upgrade --all --include-unknown  (two passes)
         A user pass runs first in its own de-elevated window (--scope user);
         if this script is already elevated (e.g. "sudo pwsh -File ...") that
         window is launched with a basic-user token via "runas /trustlevel".
         A system pass then runs elevated with no scope filter, covering
         machine-scope packages and anything the user pass missed. The system
         pass is an admin-only step, so it follows the same self-elevation
         (UAC) / -NoElevate rules as the others. Both use the settings below.
         Run non-interactively with --accept-source-agreements,
         --accept-package-agreements and --disable-interactivity. winget's
         "no applicable upgrades" result (0x8A15002B) is treated as success.
         Any other non-zero exit fails that pass.

         Packages listed in winget_ignore.txt, next to this script (see
         winget_ignore.sample.txt), are passed as --exclude and skipped by
         the upgrade. The file is optional; if it is absent, nothing is
         excluded on its account.

         WSL and winget: upgrading the WSL package (Microsoft.WSL) runs
         "wsl --shutdown". When WSL compaction is enabled (the default) the
         up-front confirmation already covers a WSL shutdown, so the package is
         upgraded normally. With -SkipWslCompact no shutdown is authorised, so
         if a WSL distribution is running Microsoft.WSL is excluded from the
         upgrade (--exclude) instead. If this winget build has no --exclude: a
         configured ignore list is skipped with a warning and the upgrade
         proceeds anyway; a pending WSL upgrade instead marks the whole step
         SKIP, since dropping a live session is worse than an unexcluded
         package.

      4. System file integrity (DISM + SFC)
         "DISM /Online /Cleanup-Image /RestoreHealth" (scans the component
         store and repairs it only if it is damaged), then "sfc /scannow". The
         sfc outcome is read from the [SR] entries in CBS.log rather than its
         localised console text. Unrepairable corruption fails the step; a
         repaired one is reported. Runs before Disk Cleanup because the repair
         needs the component store intact.

      5. Disk Cleanup (all fixed drives) + component store
         Enables every Disk Cleanup handler except a few that are unsafe to
         automate - "Downloads Folder", "Previous Installations" (Windows.old,
         the rollback), "Device Driver Packages" (driver rollback) and "Windows
         ESD installation files" (local Reset this PC) - by writing
         StateFlags<profile> under ...\Explorer\VolumeCaches, runs
         "cleanmgr /sagerun:<profile>" and waits for it to finish, then runs
         "DISM /Online /Cleanup-Image /StartComponentCleanup" to trim the
         WinSxS component store. cleanmgr operates on every fixed drive, not
         just C:, and this empties the Recycle Bin. Reports the free-space
         change per drive.

      6. WSL disk compaction  (Hyper-V Optimize-VHD)
         WSL 2 distro disks (ext4.vhdx) grow but never shrink on their own.
         This step runs "fstrim" inside each distro (so freed blocks are marked
         reclaimable), runs "wsl --shutdown" (approved in the up-front
         confirmation), then compacts each distro's .vhdx with
         "Optimize-VHD -Mode Full" and reports the space reclaimed. WSL is
         left stopped; it restarts on next use. Runs before the volume
         optimization step so the freed space is retrimmed. Guards - a
         distro's disk is skipped (SKIP/WARN, never FAIL) when:
           - Optimize-VHD (Hyper-V PowerShell module) or the Hyper-V Virtual
             Machine Management service is missing/stopped - nothing runs and
             WSL is not shut down;
           - the host volume's disk reports anything but Healthy;
           - the host volume has less than max(1 GB, 10% of the disk image)
             free;
           - the disk image is not on a local drive letter, is attached, or is
             still locked after the shutdown (e.g. Docker Desktop restarted its
             backend);
           - WSL has not fully stopped within 60 seconds.
         Docker Desktop's own distros (docker-desktop*) are compacted but not
         fstrim'ed. A power loss or crash mid-compaction can corrupt a distro
         disk - keep backups ("wsl --export"). Distros are read from the
         current user's registry (HKCU), so this needs the same account
         elevated, not a different admin account. Skipped with
         -SkipWslCompact.

      7. Health check  (report only)
         Physical disk health and SSD wear/temperature/error counters
         (Get-PhysicalDisk, Get-StorageReliabilityCounter), an online
         filesystem scan per volume (Repair-Volume -Scan - report only, never
         repairs), low free space, the last 7 days of disk / NTFS / volume /
         WHEA hardware errors, unexpected shutdowns (Kernel-Power 41) and
         bugchecks from the System event log, recent boot times, and the list
         of startup entries. A disk or volume that is unhealthy fails the step;
         softer findings (nearly full, wear, temperature, recent hardware error
         events, unexpected shutdowns) make it WARN.

      8. Optimize / defrag all volumes
         Runs Optimize-Volume on every fixed NTFS/ReFS volume that has a drive
         letter. No operation switch is passed, so Windows performs the
         media-appropriate optimization per volume - full defragmentation on
         HDDs, retrim on SSDs, slab consolidation on thin-provisioned storage -
         the same as the built-in "Optimize Drives" task and "defrag /O". A
         volume whose disk reports anything but Healthy is skipped (WARN).

      9. Microsoft Defender update + scan
         Update-MpSignature, then a quick scan (a full scan with
         -DefenderFullScan), then reports signature age, real-time protection
         and any threats found (an active threat fails the step; a detection
         Defender already handled is a WARN). Skipped when Defender is not the
         active antivirus (a third-party product has put it in passive mode).

.PARAMETER DriverUpdate
    Also install driver updates offered through Windows Update (WHQL-signed,
    vendor-submitted - see step 2). Off by default.

.PARAMETER DefenderFullScan
    Run a Defender full scan in step 9 instead of a quick scan. Can take hours.

.PARAMETER SkipWindowsUpdate
    Skip step 1 (Windows Update).

.PARAMETER SkipWinget
    Skip step 3 (winget upgrade, both passes).

.PARAMETER SkipIntegrity
    Skip step 4 (DISM RestoreHealth + SFC).

.PARAMETER SkipDiskCleanup
    Skip step 5 (cleanmgr + DISM component cleanup).

.PARAMETER SkipWslCompact
    Skip step 6 (WSL disk compaction). Because that step is what needs the
    "wsl --shutdown" approval, skipping it also means the script does not
    shut WSL down: a running WSL keeps Microsoft.WSL held back in step 3.

.PARAMETER SkipHealthCheck
    Skip step 7 (disk / event-log health check).

.PARAMETER SkipDefrag
    Skip step 8 (Optimize-Volume).

.PARAMETER SkipDefender
    Skip step 9 (Defender update + scan).

.PARAMETER SkipRestorePoint
    Do not create a System Restore point before the run changes anything.

.PARAMETER SagerunProfile
    The Disk Cleanup "sageset/sagerun" profile number used for the StateFlags
    registry values and "cleanmgr /sagerun:N". Default 100. Change it only if
    that profile number is already configured for something else on this box.

.PARAMETER Yes
    Skip the up-front confirmation question (the plan is still printed).
    Required for unattended runs; without it a non-interactive session
    declines and exits.

.PARAMETER KeepStepWindows
    Keep every per-step console window open until dismissed (press Enter),
    instead of auto-closing a few seconds after a successful step.

.PARAMETER NoElevate
    Do not relaunch elevated when an admin-only step is due to run. Those steps
    are skipped instead and the run exits non-zero. Use this for unattended
    runs where a UAC prompt cannot be answered.

.PARAMETER Relaunched
    Internal. Set by the script on its own elevated relaunch (after the
    confirmation was already given); keeps the orchestrator window open at the
    end. Not meant to be passed by hand.

.PARAMETER AllowWslShutdown
    Internal. Set by the orchestrator on each step it launches when the
    confirmation covered "wsl --shutdown". Not meant to be passed by hand.

.PARAMETER RunStep
    Internal. Names the single step to run in this process (the orchestrator
    sets this when launching a step's console window). Not meant to be passed
    by hand.

.PARAMETER RunDir
    Internal. The temp run directory a -RunStep child reads/writes (result JSON
    and output.log). Set by the orchestrator.

.EXAMPLE
    .\windows_maintenance.ps1

    Prints the plan, asks to confirm, then runs every step (prompting for UAC
    elevation if not already an administrator).

.EXAMPLE
    .\windows_maintenance.ps1 -Yes -SkipWslCompact -SkipDefrag

    Unattended pass that leaves WSL alone and skips the volume optimization.

.EXAMPLE
    .\windows_maintenance.ps1 -NoElevate -Yes -SkipWindowsUpdate -SkipIntegrity -SkipDiskCleanup -SkipWslCompact -SkipHealthCheck -SkipDefrag -SkipDefender

    No elevation and no question: only the user-scope winget pass runs.

.NOTES
    Requirements: Windows 10 / 11 (or matching Server), PowerShell 5.1+. No
    #Requires -RunAsAdministrator: the script self-elevates when a step needs
    it (see .DESCRIPTION), or with -NoElevate skips those steps. Per step:
      - Windows Update (needs Administrator): internet access; PSWindowsUpdate
        (auto-installed from PSGallery via Install-Module if absent - this also
        registers the NuGet provider and may prompt once to trust PSGallery on
        a locked-down host).
      - Driver updates (-DriverUpdate, needs Administrator): same requirements
        as Windows Update (internet, PSWindowsUpdate).
      - winget: App Installer / winget (in-box on Windows 11 and current
        Windows 10). The system pass needs Administrator; the user pass is
        de-elevated (runas.exe /trustlevel when the script is elevated). The WSL
        hold-back (only with -SkipWslCompact) also calls wsl.exe (with
        WSL_UTF8=1) to see if a distro is running. Optional winget_ignore.txt
        next to the script (see winget_ignore.sample.txt) excludes listed
        package Ids from the upgrade.
      - System file integrity (needs Administrator): DISM and sfc (in-box);
        RestoreHealth may download repair files from Windows Update.
      - Disk Cleanup (needs Administrator): cleanmgr.exe (an optional Feature on
        Server SKUs) and DISM - the step carries on if cleanmgr is missing.
      - WSL compaction (needs Administrator): wsl.exe, and the Hyper-V
        PowerShell module (Optimize-VHD, Get-VHD - the
        Microsoft-Hyper-V-Management-PowerShell feature) with the Hyper-V
        Virtual Machine Management service (vmms) running. Without them the
        step is skipped and WSL is left alone.
      - Health check (needs Administrator): the Storage module (in-box) and the
        System / Diagnostics-Performance event logs.
      - Optimize-Volume (needs Administrator): the Storage module (in-box).
      - Defender (needs Administrator): the Defender module (in-box) with
        Defender as the active antivirus.
      - Restore point: System Protection enabled on the system drive.

    Written for desktops: there are no battery / AC-power checks.

    This script never reboots. After a Windows Update or driver-update run that
    reports a pending reboot, restart the machine yourself to finish it.
#>

#Requires -Version 5.1

[CmdletBinding()]
param(
    [switch]$DriverUpdate,
    [switch]$DefenderFullScan,

    [switch]$SkipWindowsUpdate,
    [switch]$SkipWinget,
    [switch]$SkipIntegrity,
    [switch]$SkipDiskCleanup,
    [switch]$SkipWslCompact,
    [switch]$SkipHealthCheck,
    [switch]$SkipDefrag,
    [switch]$SkipDefender,
    [switch]$SkipRestorePoint,

    [ValidateRange(0, 65535)]
    [int]$SagerunProfile = 100,

    [switch]$Yes,
    [switch]$KeepStepWindows,
    [switch]$NoElevate,

    # Internal - set by the script when it relaunches itself / launches a step.
    [switch]$Relaunched,
    [switch]$AllowWslShutdown,
    [ValidateSet('WindowsUpdate', 'DriverUpdate', 'Winget', 'WingetSystem', 'Integrity', 'DiskCleanup', 'WslCompact', 'HealthCheck', 'Defrag', 'Defender')]
    [string]$RunStep,
    [string]$RunDir
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# How this runs
#
# The orchestrator (a normal invocation) does no maintenance work itself: for
# each step it launches a fresh console window that re-invokes this same script
# with -RunStep <name>, waits for it, and reads back a small JSON result file
# from -RunDir. So each step's noisy output (winget's redraws, DISM's progress
# bar, Optimize-Volume -Verbose) lands in its own window and log, leaving the
# orchestrator window a clean one-line-per-step progress list plus a summary.
#
# A step function streams its own progress with Write-Output and reports its
# one-line result by assigning $script:StepDetail (and, to down-grade itself
# from the default OK, $script:StepStatus = 'WARN' | 'SKIP' | 'FAIL' - throwing
# also means FAIL); $script:RebootRequired flags a pending reboot. In -RunStep
# mode all of them are serialised to the result file.
#
# Outcomes are collected, never aborting the run on one failure (mirrors the
# bash FAILED=() convention), and summarised at the end.
#
# Adding a step: add its name to the -RunStep ValidateSet and to
# $script:StepTitles, add a case to the switch in Invoke-MaintenanceStep, and
# add it to $plannedSteps in the Run section.
# ---------------------------------------------------------------------------

$script:Results = [System.Collections.Generic.List[psobject]]::new()
$script:RebootRequired = $false
$script:SkippedForAdmin = $false
$script:IsAdmin = $false
$script:StepDetail = ''
$script:StepStatus = 'OK'
$script:StepCount = 0
$script:AllowWslShutdown = $false
$script:DefenderFullScan = $false
$script:StepTitles = @{
    WindowsUpdate = 'Windows Update'
    DriverUpdate  = 'Driver updates (Windows Update)'
    Winget        = 'winget upgrade --all (user)'
    WingetSystem  = 'winget upgrade --all (system, elevated)'
    Integrity     = 'System file integrity (DISM + SFC)'
    DiskCleanup   = 'Disk Cleanup + WinSxS'
    WslCompact    = 'WSL disk compaction (Optimize-VHD)'
    HealthCheck   = 'Health check (disks, event log)'
    Defrag        = 'Optimize / defrag volumes'
    Defender      = 'Microsoft Defender update + scan'
}
$script:HostExe = (Get-Process -Id $PID).Path
if ([string]::IsNullOrEmpty($script:HostExe)) {
    $script:HostExe = 'powershell.exe'
}

function Test-Administrator {
    # True when this process is elevated (has a full Administrator token).
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Format-ProcessArgument {
    # Start-Process -ArgumentList joins tokens with spaces without quoting, so
    # wrap anything containing whitespace (e.g. a script path under a profile
    # with a space) ourselves.
    param(
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $Value
    )

    if ($Value -match '\s') {
        return '"' + $Value + '"'
    }
    return $Value
}

function Invoke-UnelevatedStepWindow {
    # Launch a step in a new console with a de-elevated (basic user) token while
    # this process is elevated (e.g. run via sudo). "runas /trustlevel" returns as
    # soon as it has spawned the process, so wait via the step's pid.txt and
    # result.json instead of the process handle.
    param(
        [Parameter(Mandatory)] [string[]] $ChildArgs,
        [Parameter(Mandatory)] [string] $StepDir
    )

    New-Item -ItemType Directory -Path $StepDir -Force | Out-Null
    foreach ($name in 'pid.txt', 'result.json') {
        Remove-Item -LiteralPath (Join-Path $StepDir $name) -Force -ErrorAction SilentlyContinue
    }

    $inner = (@((Format-ProcessArgument $script:HostExe)) + $ChildArgs) -join ' '
    $runas = Start-Process -FilePath 'runas.exe' `
        -ArgumentList @('/trustlevel:0x20000', ('"' + $inner.Replace('"', '\"') + '"')) `
        -Wait -PassThru -WindowStyle Hidden -ErrorAction Stop
    if ($runas.ExitCode -ne 0) {
        throw "runas /trustlevel exited $($runas.ExitCode)"
    }

    $pidFile = Join-Path $StepDir 'pid.txt'
    $resultFile = Join-Path $StepDir 'result.json'
    $deadline = (Get-Date).AddSeconds(60)
    while (-not (Test-Path -LiteralPath $pidFile)) {
        if ((Get-Date) -gt $deadline) {
            throw 'unelevated step window did not start within 60s'
        }
        Start-Sleep -Milliseconds 500
    }

    $childPid = [int](Get-Content -LiteralPath $pidFile -Raw)
    while (-not (Test-Path -LiteralPath $resultFile)) {
        if (-not (Get-Process -Id $childPid -ErrorAction SilentlyContinue)) {
            return
        }
        Start-Sleep -Seconds 1
    }
    # result.json is written just before the window pauses/closes; let it exit.
    Get-Process -Id $childPid -ErrorAction SilentlyContinue | Wait-Process -ErrorAction SilentlyContinue
}

function Invoke-Step {
    # Orchestrator side: run one step in its own console window and fold the
    # result it writes to $RunDir\<Step>\result.json into $script:Results.
    param(
        [Parameter(Mandatory)] [string] $Name,
        [Parameter(Mandatory)] [ValidateScript({ $script:StepTitles.ContainsKey($_) })] [string] $Step,
        [switch] $Skip,
        [switch] $RequiresAdmin,
        [switch] $Unelevated
    )

    $ordinal = '[{0}/{1}] {2}' -f ($script:Results.Count + 1), $script:StepCount, $Name

    if ($Skip) {
        Write-Output "$ordinal - skipped (-Skip... switch)"
        $script:Results.Add([pscustomobject]@{ Step = $Name; Status = 'SKIP'; Detail = 'requested' })
        return
    }

    if ($RequiresAdmin -and -not $script:IsAdmin) {
        Write-Warning "$ordinal - skipped: needs Administrator (drop -NoElevate to auto-elevate)"
        $script:SkippedForAdmin = $true
        $script:Results.Add([pscustomobject]@{ Step = $Name; Status = 'SKIP'; Detail = 'needs Administrator (not elevated)' })
        return
    }

    $stepDir = Join-Path $script:RunDir $Step
    $resultFile = Join-Path $stepDir 'result.json'

    $childArgs = @(
        '-NoProfile'
        '-ExecutionPolicy'
        'Bypass'
        '-File'
        (Format-ProcessArgument $script:SelfPath)
        '-RunStep'
        $Step
        '-RunDir'
        (Format-ProcessArgument $script:RunDir)
        '-SagerunProfile'
        ([string]$script:SagerunProfile)
    )
    if ($script:KeepStepWindows) {
        $childArgs += '-KeepStepWindows'
    }
    if ($script:AllowWslShutdown) {
        $childArgs += '-AllowWslShutdown'
    }
    if ($script:DefenderFullScan) {
        $childArgs += '-DefenderFullScan'
    }

    Write-Output "$ordinal - running in a separate window..."
    $start = Get-Date
    $exitText = 'unknown'
    try {
        if ($Unelevated -and $script:IsAdmin) {
            Invoke-UnelevatedStepWindow -ChildArgs $childArgs -StepDir $stepDir
        }
        else {
            $proc = Start-Process -FilePath $script:HostExe -ArgumentList $childArgs -Wait -PassThru -ErrorAction Stop
            $exitText = [string]$proc.ExitCode
        }
    }
    catch {
        $detail = "could not launch step window: $($_.Exception.Message)"
        Write-Warning "$ordinal - FAILED  $detail"
        $script:Results.Add([pscustomobject]@{ Step = $Name; Status = 'FAIL'; Detail = $detail })
        return
    }
    $span = (Get-Date) - $start

    $result = $null
    if (Test-Path -LiteralPath $resultFile) {
        try {
            $result = Get-Content -LiteralPath $resultFile -Raw | ConvertFrom-Json
        }
        catch {
            Write-Verbose "Could not parse ${resultFile}: $($_.Exception.Message)"
        }
    }

    if ($null -eq $result -or -not $result.PSObject.Properties['Status']) {
        $detail = "step window exited without a result (exit code $exitText)"
        Write-Warning ('{0} - FAILED  ({1:hh\:mm\:ss})  {2}' -f $ordinal, $span, $detail)
        $script:Results.Add([pscustomobject]@{ Step = $Name; Status = 'FAIL'; Detail = $detail })
        return
    }

    if ($result.PSObject.Properties['RebootRequired'] -and $result.RebootRequired) {
        $script:RebootRequired = $true
    }
    $status = [string]$result.Status
    $detail = [string]$result.Detail

    $line = '{0} - {1}  ({2:hh\:mm\:ss})  {3}' -f $ordinal, $status, $span, $detail
    if ($status -eq 'OK') {
        Write-Output $line
    }
    else {
        Write-Warning $line
    }
    $script:Results.Add([pscustomobject]@{ Step = $Name; Status = $status; Detail = $detail })
}

function Invoke-MaintenanceStep {
    # Child side: run exactly one step in this process, capture its console to a
    # transcript, write result.json for the orchestrator, and exit.
    param(
        [Parameter(Mandatory)] [ValidateScript({ $script:StepTitles.ContainsKey($_) })] [string] $Step,
        [Parameter(Mandatory)] [string] $RunDir,
        [Parameter(Mandatory)] [int] $SagerunProfile,
        [switch] $KeepOpen
    )

    $title = $script:StepTitles[$Step]

    $stepDir = Join-Path $RunDir $Step
    New-Item -ItemType Directory -Path $stepDir -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $stepDir 'pid.txt') -Value $PID -Encoding ASCII

    try {
        $Host.UI.RawUI.WindowTitle = "maintenance: $title"
    }
    catch {
        Write-Verbose "Could not set window title: $($_.Exception.Message)"
    }

    $transcribing = $false
    try {
        Start-Transcript -LiteralPath (Join-Path $stepDir 'output.log') -Force | Out-Null
        $transcribing = $true
    }
    catch {
        Write-Verbose "Transcript unavailable: $($_.Exception.Message)"
    }

    Write-Output ('=' * 72)
    Write-Output "  $title   -   $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
    Write-Output ('=' * 72)

    $script:StepDetail = ''
    $script:StepStatus = 'OK'
    $script:RebootRequired = $false
    $status = 'OK'
    $detail = ''
    try {
        switch ($Step) {
            'WindowsUpdate' { Invoke-WindowsUpdate }
            'DriverUpdate' { Invoke-DriverUpdate }
            'Winget' { Invoke-WingetUpgrade -Scope User }
            'WingetSystem' { Invoke-WingetUpgrade -Scope System }
            'Integrity' { Invoke-IntegrityRepair }
            'DiskCleanup' { Invoke-DiskCleanup -SagerunProfile $SagerunProfile }
            'WslCompact' { Invoke-WslCompaction }
            'HealthCheck' { Invoke-HealthCheck }
            'Defrag' { Invoke-VolumeOptimization }
            'Defender' { Invoke-DefenderMaintenance }
        }
        # A step may down-grade itself to WARN / SKIP / FAIL (e.g. winget
        # holding back a WSL upgrade while WSL is running, or the health check
        # finding an unhealthy disk).
        $status = $script:StepStatus
        $detail = $script:StepDetail
    }
    catch {
        $status = 'FAIL'
        $detail = $_.Exception.Message
        Write-Warning "FAILED: $detail"
    }

    if ($transcribing) {
        try {
            Stop-Transcript | Out-Null
        }
        catch {
            Write-Verbose "Stop-Transcript: $($_.Exception.Message)"
        }
    }

    $payload = [pscustomobject]@{
        Step           = $Step
        Status         = $status
        Detail         = $detail
        RebootRequired = [bool]$script:RebootRequired
    }
    try {
        $payload | ConvertTo-Json -Compress |
            Set-Content -LiteralPath (Join-Path $stepDir 'result.json') -Encoding UTF8
    }
    catch {
        Write-Warning "Could not write result.json: $($_.Exception.Message)"
    }

    Write-Output ''
    Write-Output ('-' * 72)
    switch ($status) {
        'OK' { Write-Output "Step complete: $detail" }
        'SKIP' { Write-Output "Step skipped: $detail" }
        'WARN' { Write-Warning "Step finished with warnings: $detail" }
        default { Write-Warning "Step failed: $detail" }
    }

    if ($status -eq 'FAIL' -or $KeepOpen) {
        try {
            [void](Read-Host 'Press Enter to close this window')
        }
        catch {
            Write-Verbose "Could not pause for input: $($_.Exception.Message)"
        }
    }
    else {
        Start-Sleep -Seconds 3
    }

    if ($status -eq 'FAIL') {
        exit 1
    }
    exit 0
}

function Test-PendingReboot {
    # True when Windows has a reboot pending. Asks PSWindowsUpdate first, then
    # falls back to the well-known registry markers if it is not loaded.
    try {
        return [bool](Get-WURebootStatus -Silent -ErrorAction Stop)
    }
    catch {
        foreach ($key in @(
                'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'
                'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending'
            )) {
            if (Test-Path -LiteralPath $key) {
                return $true
            }
        }
        return $false
    }
}

# ---------------------------------------------------------------------------
# Shared helpers
# ---------------------------------------------------------------------------

function Get-PropertyValue {
    # StrictMode-safe optional property read: $null when the object lacks the
    # property (Defender / storage counters vary by Windows build and hardware).
    param(
        [Parameter(Mandatory)] [AllowNull()] $InputObject,
        [Parameter(Mandatory)] [string] $Name
    )

    if ($null -eq $InputObject) {
        return $null
    }
    $property = $InputObject.PSObject.Properties[$Name]
    if ($property) {
        return $property.Value
    }
    return $null
}

function Format-ByteSize {
    # Human-readable size ("1.5 GB", "-320 MB"); keeps the sign.
    param(
        [Parameter(Mandatory)] [double] $Bytes
    )

    $magnitude = [math]::Abs($Bytes)
    $sign = if ($Bytes -lt 0) { '-' } else { '' }
    if ($magnitude -ge 1GB) {
        return ('{0}{1:N1} GB' -f $sign, ($magnitude / 1GB))
    }
    if ($magnitude -ge 1MB) {
        return ('{0}{1:N0} MB' -f $sign, ($magnitude / 1MB))
    }
    return ('{0}{1:N0} KB' -f $sign, ($magnitude / 1KB))
}

function Format-WrappedLine {
    # Word-wrap Text to Width columns with a hanging indent, for the plan
    # printed before the confirmation prompt.
    param(
        [Parameter(Mandatory)] [string] $Text,
        [int] $Width = 76,
        [string] $FirstIndent = '  - ',
        [string] $NextIndent = '    '
    )

    $lines = [System.Collections.Generic.List[string]]::new()
    $current = $FirstIndent
    $lineIsEmpty = $true
    foreach ($word in ($Text -split '\s+')) {
        if ($word -eq '') {
            continue
        }
        if ($lineIsEmpty) {
            $current += $word
            $lineIsEmpty = $false
        }
        elseif (($current.Length + 1 + $word.Length) -gt $Width) {
            $lines.Add($current)
            $current = $NextIndent + $word
        }
        else {
            $current += " $word"
        }
    }
    $lines.Add($current)
    return $lines.ToArray()
}

function Get-FixedVolumeSpace {
    # Free / total bytes per fixed volume with a drive letter, keyed by letter.
    $space = @{}
    try {
        $volumes = @(
            Get-Volume -ErrorAction Stop |
                Where-Object { $_.DriveLetter -and $_.DriveType -eq 'Fixed' }
        )
        foreach ($volume in $volumes) {
            $space[[string]$volume.DriveLetter] = [pscustomobject]@{
                Free = [int64]$volume.SizeRemaining
                Size = [int64]$volume.Size
            }
        }
    }
    catch {
        Write-Verbose "Could not read volume free space: $($_.Exception.Message)"
    }
    return $space
}

function Get-VolumeDiskHealth {
    # HealthStatus of the disk behind a drive letter ('Healthy', 'Warning',
    # 'Unhealthy'), or $null when it cannot be determined (Storage Spaces,
    # exotic setups). Callers treat "unknown" as "go ahead" - the health check
    # step reports the disks separately.
    param(
        [Parameter(Mandatory)] [string] $DriveLetter
    )

    try {
        $disk = Get-Partition -DriveLetter $DriveLetter -ErrorAction Stop |
            Get-Disk -ErrorAction Stop |
            Select-Object -First 1
        if ($disk) {
            return [string]$disk.HealthStatus
        }
    }
    catch {
        Write-Verbose "Could not determine disk health for ${DriveLetter}: $($_.Exception.Message)"
    }
    return $null
}

function Get-WslInventory {
    # Registered WSL distributions for the current user, read from
    # HKCU\...\Lxss: name, WSL version, and where its .vhdx lives (WSL 2).
    $root = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss'
    if (-not (Test-Path -LiteralPath $root)) {
        return @()
    }

    $found = [System.Collections.Generic.List[psobject]]::new()
    foreach ($key in @(Get-ChildItem -LiteralPath $root -ErrorAction SilentlyContinue)) {
        $item = Get-ItemProperty -LiteralPath $key.PSPath -ErrorAction SilentlyContinue
        $name = Get-PropertyValue -InputObject $item -Name 'DistributionName'
        $base = Get-PropertyValue -InputObject $item -Name 'BasePath'
        if (-not $name -or -not $base) {
            continue
        }
        $vhdName = Get-PropertyValue -InputObject $item -Name 'VhdFileName'
        if (-not $vhdName) {
            $vhdName = 'ext4.vhdx'
        }
        $version = Get-PropertyValue -InputObject $item -Name 'Version'
        # BasePath is stored with a "\\?\" long-path prefix; drop it.
        $basePath = ([string]$base) -replace '^\\\\\?\\', ''
        $found.Add([pscustomobject]@{
                Name    = [string]$name
                Version = if ($null -eq $version) { 0 } else { [int]$version }
                VhdPath = Join-Path -Path $basePath -ChildPath ([string]$vhdName)
            })
    }
    return $found.ToArray()
}

function Test-FileLocked {
    # True if the file cannot be opened exclusively - something has it open, or
    # we cannot tell; both are treated the same (fail closed).
    param(
        [Parameter(Mandatory)] [string] $Path
    )

    $stream = $null
    try {
        $stream = [System.IO.File]::Open(
            $Path,
            [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::ReadWrite,
            [System.IO.FileShare]::None)
        return $false
    }
    catch {
        Write-Verbose "Could not open exclusively (${Path}): $($_.Exception.Message)"
        return $true
    }
    finally {
        if ($stream) {
            $stream.Dispose()
        }
    }
}

# ---------------------------------------------------------------------------
# Up-front consent + preflight
# ---------------------------------------------------------------------------

function Get-MaintenancePlan {
    # What this run is about to do, grouped by how much it can hurt. Reads the
    # script's own -Skip... / -DriverUpdate switches. $AdminStepsWillRun is
    # false only for -NoElevate without elevation (those steps get skipped).
    param(
        [Parameter(Mandatory)] [bool] $AdminStepsWillRun
    )

    $destructive = [System.Collections.Generic.List[string]]::new()
    $disruptive = [System.Collections.Generic.List[string]]::new()
    $other = [System.Collections.Generic.List[string]]::new()

    if (-not $SkipWinget) {
        $disruptive.Add('winget upgrade --all: upgrades every installed app. An app that is running may be closed or restarted by its installer, and a failed upgrade can leave an app broken until reinstalled.')
    }

    if ($AdminStepsWillRun) {
        # wsl --shutdown comes from two places: the compaction step (needs the
        # Hyper-V module, otherwise it skips itself before shutting anything
        # down) and winget upgrading Microsoft.WSL (no longer held back once a
        # shutdown is approved).
        $wslPresent = [bool](Get-Command -Name wsl.exe -CommandType Application -ErrorAction SilentlyContinue)
        $canCompact = -not $SkipWslCompact -and [bool](Get-Command -Name Optimize-VHD -ErrorAction SilentlyContinue)
        $shutdownSources = [System.Collections.Generic.List[string]]::new()
        if ($canCompact) {
            $shutdownSources.Add('the WSL disk compaction step')
        }
        if ($script:AllowWslShutdown -and -not $SkipWinget) {
            $shutdownSources.Add('winget if it upgrades Microsoft.WSL')
        }
        if ($wslPresent -and $shutdownSources.Count -gt 0) {
            $distros = @(Get-WslInventory)
            $distroText = if ($distros.Count -gt 0) {
                'Registered distros: ' + (($distros | ForEach-Object { $_.Name }) -join ', ') + '.'
            }
            else {
                'No distros are registered for this user.'
            }
            $runningText = if (Test-WslRunning) { 'WSL is running right now.' } else { 'WSL is not running right now.' }
            $dockerText = if (Get-Process -Name 'Docker Desktop' -ErrorAction SilentlyContinue) {
                ' Docker Desktop is running and will lose its WSL backend.'
            }
            else {
                ''
            }
            $disruptive.Add("wsl --shutdown (run by $($shutdownSources -join ' and ')): every running WSL distro is terminated immediately - unsaved work, running processes, containers, and remote sessions (VS Code, SSH) inside WSL are lost, including the terminal this script may have been started from if that is a WSL shell. $distroText $runningText$dockerText")
        }
        if ($canCompact -and $wslPresent) {
            $disruptive.Add('WSL disk compaction: each distro disk (.vhdx) is trimmed and then compacted with Optimize-VHD while WSL is stopped, and WSL is left stopped afterwards. A power loss or crash mid-compaction can corrupt a distro disk - back up anything irreplaceable first (wsl --export).')
        }
        elseif (-not $SkipWslCompact -and $wslPresent) {
            $other.Add('WSL disk compaction will be skipped: the Hyper-V PowerShell module (Optimize-VHD) is not installed.')
        }
        if (-not $SkipDiskCleanup) {
            $destructive.Add('Disk Cleanup on every fixed drive: empties the Recycle Bin and deletes temp files, error reports, thumbnails, Delivery Optimization and Windows Update leftovers. Not touched: the Downloads folder, previous Windows installation(s), device driver packages and Windows ESD files.')
            $destructive.Add('DISM component store cleanup: removes superseded Windows component versions to free WinSxS space; they cannot be restored afterwards.')
        }
        if ($DriverUpdate) {
            $disruptive.Add('Driver updates (-DriverUpdate): may replace graphics / network / storage drivers - the screen or network can drop briefly and a faulty driver can misbehave (a restore point is created first).')
        }
        if (-not $SkipWindowsUpdate) {
            $other.Add('Windows Update: installs OS updates plus Office and other Microsoft product updates (registers the Microsoft Update service if it is not already - the "Receive updates for other Microsoft products" setting). A reboot may be needed afterwards; this script never reboots.')
        }
        if (-not $SkipIntegrity) {
            $other.Add('System file repair: DISM RestoreHealth and sfc /scannow replace damaged Windows files with good copies (RestoreHealth may download them from Windows Update).')
        }
        if (-not $SkipHealthCheck) {
            $other.Add('Health check: read-only disk / filesystem / event-log report (nothing is repaired).')
        }
        if (-not $SkipDefrag) {
            $other.Add('Optimize volumes: defrag on HDDs, retrim on SSDs.')
        }
        if (-not $SkipDefender) {
            $scanKind = if ($DefenderFullScan) { 'full scan (can take hours)' } else { 'quick scan' }
            $other.Add("Microsoft Defender: signature update and a $scanKind.")
        }
        if (-not $SkipRestorePoint -and -not ($SkipWindowsUpdate -and $SkipIntegrity -and $SkipDiskCleanup -and -not $DriverUpdate)) {
            $other.Add('A System Restore point is created first (skipped by Windows if System Protection is off or one was made in the last 24 hours).')
        }
        if ($disruptive.Count -gt 0 -or $destructive.Count -gt 0 -or $other.Count -gt 0) {
            $other.Add('Expect heavy CPU and disk use for a while (DISM, Disk Cleanup, optimize, Defender). Each step runs in its own console window.')
        }
    }
    else {
        $other.Add('Not elevated and -NoElevate given: Windows Update, integrity repair, Disk Cleanup, WSL compaction, health check, optimize and Defender will be skipped; the winget system pass is skipped too.')
    }

    return [pscustomobject]@{
        Destructive = $destructive.ToArray()
        Disruptive  = $disruptive.ToArray()
        Other       = $other.ToArray()
        Count       = $destructive.Count + $disruptive.Count + $other.Count
    }
}

function Show-MaintenancePlan {
    # Prints the plan from Get-MaintenancePlan, grouped by how much each part
    # can hurt, before the confirmation prompt.
    param(
        [Parameter(Mandatory)] $Plan
    )

    Write-Output ('=' * 72)
    Write-Output '  Windows maintenance - what this run will do'
    Write-Output ('=' * 72)

    $sections = @(
        @{ Title = 'DESTRUCTIVE (cannot be undone)'; Items = @($Plan.Destructive) }
        @{ Title = 'DISRUPTIVE (interrupts running work)'; Items = @($Plan.Disruptive) }
        @{ Title = 'ALSO CHANGES / RUNS'; Items = @($Plan.Other) }
    )
    foreach ($section in $sections) {
        if ($section.Items.Count -eq 0) {
            continue
        }
        Write-Output ''
        Write-Output $section.Title
        foreach ($item in $section.Items) {
            Write-Output (Format-WrappedLine -Text $item)
        }
    }
    Write-Output ''
}

function Test-MaintenanceConsent {
    # True only for an explicit y / yes. Anything else - including no answer or
    # a session that cannot prompt - declines.
    if (-not [Environment]::UserInteractive) {
        Write-Warning 'Not an interactive session - re-run with -Yes to confirm this plan.'
        return $false
    }

    $answer = $null
    try {
        $answer = Read-Host 'Proceed with all of the above? [y/N]'
    }
    catch {
        Write-Warning "Could not read an answer ($($_.Exception.Message)) - re-run with -Yes to confirm this plan."
        return $false
    }
    if ([string]::IsNullOrWhiteSpace($answer)) {
        return $false
    }
    return ($answer.Trim() -match '^(y|yes)$')
}

function Invoke-Preflight {
    # Cheap sanity checks before anything changes. Warnings only - nothing
    # here blocks the run.
    param(
        [Parameter(Mandatory)] [hashtable] $Space
    )

    if (Test-PendingReboot) {
        Write-Warning 'A reboot is already pending (from an earlier update). DISM / component cleanup and updates can fail or do nothing until it is done - consider rebooting first and re-running.'
    }

    foreach ($letter in ($Space.Keys | Sort-Object)) {
        $volume = $Space[$letter]
        if ($volume.Size -le 0) {
            continue
        }
        $percentFree = 100 * $volume.Free / $volume.Size
        if ($percentFree -lt 10) {
            Write-Warning ('{0}: has only {1:N0}% free ({2} of {3}) - nearly-full volumes slow down, especially SSDs.' -f
                $letter, $percentFree, (Format-ByteSize $volume.Free), (Format-ByteSize $volume.Size))
        }
    }
}

function Invoke-RestorePoint {
    # Best-effort safety net before updates / repairs / cleanup. Uses the
    # SystemRestore WMI class (works from Windows PowerShell and pwsh alike,
    # unlike Checkpoint-Computer). Windows silently declines when System
    # Protection is off or a point was made in the last 24 hours, so verify by
    # looking for it afterwards instead of trusting the return value.
    $description = 'windows_maintenance {0}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm')
    try {
        Invoke-CimMethod -Namespace 'root/default' -ClassName 'SystemRestore' -MethodName 'CreateRestorePoint' `
            -Arguments @{ Description = $description; RestorePointType = [uint32]12; EventType = [uint32]100 } `
            -ErrorAction Stop | Out-Null
    }
    catch {
        Write-Warning "Restore point not created: $($_.Exception.Message)"
        return
    }

    $latest = Get-CimInstance -Namespace 'root/default' -ClassName 'SystemRestore' -ErrorAction SilentlyContinue |
        Sort-Object -Property SequenceNumber -Descending |
        Select-Object -First 1
    if ($latest -and $latest.Description -eq $description) {
        Write-Output "Restore point created: $description"
    }
    else {
        Write-Warning 'No new restore point was created (System Protection is off for the system drive, or Windows already made one in the last 24 hours). Continuing without a fresh one.'
    }
}

# ---------------------------------------------------------------------------
# Step 1: Windows Update (via PSWindowsUpdate)
# ---------------------------------------------------------------------------

function Initialize-PSWindowsUpdate {
    # Loads the PSWindowsUpdate module, installing it from the PowerShell
    # Gallery (CurrentUser scope) on first use.
    if (Get-Module -ListAvailable -Name PSWindowsUpdate) {
        Import-Module -Name PSWindowsUpdate -Force
        return
    }

    Write-Output 'PSWindowsUpdate module not present; installing from the PowerShell Gallery (CurrentUser scope)...'

    # Older Windows 10 builds still negotiate TLS 1.0/1.1 by default and the
    # Gallery refuses those - force at least TLS 1.2 for this session.
    try {
        [Net.ServicePointManager]::SecurityProtocol =
            [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    }
    catch {
        Write-Verbose "Could not raise SecurityProtocol to TLS 1.2: $($_.Exception.Message)"
    }

    $nuget = Get-PackageProvider -Name NuGet -ErrorAction SilentlyContinue
    if (-not $nuget -or $nuget.Version -lt [version]'2.8.5.201') {
        Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -Scope CurrentUser | Out-Null
    }

    Install-Module -Name PSWindowsUpdate -Scope CurrentUser -Force -AllowClobber -Repository PSGallery
    Import-Module -Name PSWindowsUpdate -Force
}

function Initialize-MicrosoftUpdateService {
    # Makes sure the Microsoft Update service (Office and other Microsoft
    # products; the "Receive updates for other Microsoft products" setting) is
    # registered, so Get-WindowsUpdate -MicrosoftUpdate can search it. Returns
    # $true when it is usable; on failure warns and returns $false so the step
    # carries on with plain Windows Update. Progress goes to the information
    # stream: anything written with Write-Output here would become part of the
    # return value and make the caller's "if" always true.
    $microsoftUpdateId = '7971f918-a847-4430-9279-4a52d1efe18d'
    try {
        $registered = @(
            Get-WUServiceManager -ErrorAction Stop |
                Where-Object { [string]$_.ServiceID -eq $microsoftUpdateId }
        )
        if ($registered.Count -eq 0) {
            Write-Information -InformationAction Continue -MessageData 'Registering the Microsoft Update service (updates for Office and other Microsoft products)...'
            Add-WUServiceManager -ServiceID $microsoftUpdateId -Confirm:$false -ErrorAction Stop | Out-Null
        }
        return $true
    }
    catch {
        Write-Warning "Microsoft Update service unavailable ($($_.Exception.Message)); continuing with Windows Update only."
        return $false
    }
}

function Invoke-WindowsUpdate {
    # Installs software updates, plus Office and other Microsoft products when
    # the Microsoft Update service is usable. Drivers are left to -DriverUpdate.
    Initialize-PSWindowsUpdate

    # -Install runs scan + download + install in one call; -AcceptAll answers
    # the per-update prompt; -IgnoreReboot suppresses the automatic restart.
    # -UpdateType Software keeps drivers out of this pass - they are only
    # installed by the opt-in -DriverUpdate step, so that switch means what it
    # says. -MicrosoftUpdate adds Office and other Microsoft products.
    $updateArgs = @{
        UpdateType   = 'Software'
        AcceptAll    = $true
        Install      = $true
        IgnoreReboot = $true
        Confirm      = $false
        Verbose      = $true
        ErrorAction  = 'Stop'
    }
    if (Initialize-MicrosoftUpdateService) {
        $updateArgs['MicrosoftUpdate'] = $true
    }
    $applied = @(Get-WindowsUpdate @updateArgs)

    if ($applied.Count -gt 0) {
        $applied |
            Select-Object -Property Status, KB, Size, Title |
            Format-Table -AutoSize |
            Out-String |
            Write-Output
    }
    else {
        Write-Output 'No applicable updates.'
    }

    if (Test-PendingReboot) {
        $script:RebootRequired = $true
        $script:StepDetail = "$($applied.Count) update(s) applied; REBOOT REQUIRED"
        return
    }
    $script:StepDetail = "$($applied.Count) update(s) applied"
}

# ---------------------------------------------------------------------------
# Step 2: Driver updates (only with -DriverUpdate)
# ---------------------------------------------------------------------------

function Invoke-DriverUpdate {
    # "Verified drivers only": drivers offered through Windows Update are
    # WHQL-certified and submitted by the hardware vendor via Microsoft's
    # Hardware Dev Center. Nothing here touches a third-party driver repository.
    Initialize-PSWindowsUpdate

    # -UpdateType Driver restricts the WUA search to Type='Driver'.
    $applied = @(
        Get-WindowsUpdate -UpdateType Driver -AcceptAll -Install -IgnoreReboot `
            -Confirm:$false -Verbose -ErrorAction Stop
    )

    if ($applied.Count -gt 0) {
        $applied |
            Select-Object -Property Status, KB, Size, Title |
            Format-Table -AutoSize |
            Out-String |
            Write-Output
    }
    else {
        Write-Output 'No applicable driver updates.'
    }

    if (Test-PendingReboot) {
        $script:RebootRequired = $true
        $script:StepDetail = "$($applied.Count) driver update(s) applied; REBOOT REQUIRED"
        return
    }
    $script:StepDetail = "$($applied.Count) driver update(s) applied"
}

# ---------------------------------------------------------------------------
# Step 3: winget upgrade --all --include-unknown
# ---------------------------------------------------------------------------

function Resolve-Winget {
    # Full path of winget.exe, from PATH or the App Installer package folder;
    # $null when winget is not installed.
    $command = Get-Command -Name winget.exe -CommandType Application -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($command) {
        return $command.Source
    }

    # An elevated session sometimes can't see the WindowsApps execution alias;
    # fall back to the versioned App Installer package folder.
    try {
        $package = Get-ChildItem -LiteralPath (Join-Path $env:ProgramFiles 'WindowsApps') `
            -Filter 'Microsoft.DesktopAppInstaller_*_x64__8wekyb3d8bbwe' -Directory -ErrorAction Stop |
            Sort-Object -Property Name -Descending |
            Select-Object -First 1
        if ($package) {
            $exe = Join-Path $package.FullName 'winget.exe'
            if (Test-Path -LiteralPath $exe) {
                return $exe
            }
        }
    }
    catch {
        Write-Verbose "WindowsApps fallback lookup failed: $($_.Exception.Message)"
    }
    return $null
}

function Test-WslRunning {
    # True if a WSL distribution is currently running. Upgrading the WSL package
    # runs "wsl --shutdown", so a WSL upgrade would kill any live session.
    $wsl = Get-Command -Name wsl.exe -CommandType Application -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if (-not $wsl) {
        return $false
    }

    # The WSL2 utility VM process is present only while a distro is up - a
    # locale-independent signal that does not depend on parsing wsl.exe output.
    if (Get-Process -Name 'vmmemWSL' -ErrorAction SilentlyContinue) {
        return $true
    }

    # wsl.exe defaults to UTF-16LE output; WSL_UTF8=1 makes --list emit UTF-8.
    $previous = [Environment]::GetEnvironmentVariable('WSL_UTF8')
    $env:WSL_UTF8 = '1'
    try {
        $listed = & $wsl.Source --list --running --quiet 2>$null
        if ($LASTEXITCODE -ne 0) {
            return $false
        }
    }
    catch {
        Write-Verbose "Could not list running WSL distributions: $($_.Exception.Message)"
        return $false
    }
    finally {
        if ($null -eq $previous) {
            Remove-Item -LiteralPath Env:WSL_UTF8 -ErrorAction SilentlyContinue
        }
        else {
            $env:WSL_UTF8 = $previous
        }
    }

    $text = (($listed -join "`n") -replace "`0", '').Trim()
    if ([string]::IsNullOrWhiteSpace($text)) {
        return $false
    }
    # Older builds ignore --quiet and print a "no running distributions" notice.
    return ($text -notmatch 'no running|no distributions')
}

function Test-WingetSupportsExclude {
    # True when this winget build understands "upgrade --exclude" (older ones do
    # not).
    param([Parameter(Mandatory)] [string] $Winget)
    try {
        $help = & $Winget upgrade --help 2>$null
        if ($LASTEXITCODE -ne 0) {
            return $false
        }
    }
    catch {
        Write-Verbose "Could not read winget upgrade help: $($_.Exception.Message)"
        return $false
    }
    return (($help -join "`n") -match '--exclude')
}

function Test-WingetUpgradeAvailable {
    # True when winget reports a pending upgrade for exactly this package Id.
    param(
        [Parameter(Mandatory)] [string] $Winget,
        [Parameter(Mandatory)] [string] $Id
    )
    try {
        $out = & $Winget list --id $Id --exact --upgrade-available `
            --disable-interactivity --accept-source-agreements 2>$null
    }
    catch {
        Write-Verbose "Could not query winget for ${Id}: $($_.Exception.Message)"
        return $false
    }
    return ($LASTEXITCODE -eq 0 -and (($out -join "`n") -match [regex]::Escape($Id)))
}

function Get-WingetIgnoreList {
    # Reads winget_ignore.txt next to this script: one winget package Id per
    # line (the "Id" column from `winget list`/`winget upgrade`), "#" comments
    # and blank lines ignored. Optional - see winget_ignore.sample.txt.
    param(
        [Parameter(Mandatory)] [string] $Path
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        return @()
    }

    $ids = [System.Collections.Generic.List[string]]::new()
    foreach ($line in Get-Content -LiteralPath $Path) {
        $trimmed = $line.Trim()
        if ($trimmed -eq '' -or $trimmed.StartsWith('#')) {
            continue
        }
        if ($ids -notcontains $trimmed) {
            $ids.Add($trimmed)
        }
    }
    return $ids.ToArray()
}

function Invoke-WingetUpgrade {
    # User: runs de-elevated, limited to user-scope packages. System: runs
    # elevated, no scope filter, so it also picks up machine-scope packages and
    # anything the user pass could not upgrade.
    param(
        [Parameter(Mandatory)] [ValidateSet('User', 'System')] [string] $Scope
    )

    $winget = Resolve-Winget
    if (-not $winget) {
        throw 'winget (App Installer) not found. Install it from the Microsoft Store or https://aka.ms/getwinget.'
    }

    if ($Scope -eq 'User' -and $script:IsAdmin) {
        Write-Warning 'The user-scope pass is running elevated (could not de-elevate); user-scope packages may be installed as Administrator.'
    }
    if ($Scope -eq 'System' -and -not $script:IsAdmin) {
        throw 'The system pass needs Administrator.'
    }

    $wingetArgs = @(
        'upgrade'
        '--all'
        '--include-unknown'
        '--accept-source-agreements'
        '--accept-package-agreements'
        '--disable-interactivity'
    )
    if ($Scope -eq 'User') {
        $wingetArgs += @('--scope', 'user')
    }

    $ignoreFile = Join-Path $PSScriptRoot 'winget_ignore.txt'
    $configIgnoreList = Get-WingetIgnoreList -Path $ignoreFile

    # Hold the WSL package back while a distro is running - upgrading it runs
    # "wsl --shutdown" and would drop live sessions. Not needed when the
    # up-front confirmation already approved a WSL shutdown (the default; only
    # -SkipWslCompact leaves it unapproved).
    $wslPackageId = 'Microsoft.WSL'
    $wslUpgradePending = $false
    if ($script:AllowWslShutdown) {
        if (Test-WslRunning) {
            Write-Output "WSL is running and a WSL shutdown was approved for this run - $wslPackageId is not held back."
        }
    }
    else {
        $wslUpgradePending = (Test-WslRunning) -and (Test-WingetUpgradeAvailable -Winget $winget -Id $wslPackageId)
    }

    $excludeList = [System.Collections.Generic.List[string]]::new()
    $excludeList.AddRange([string[]]$configIgnoreList)
    if ($wslUpgradePending -and -not $excludeList.Contains($wslPackageId)) {
        $excludeList.Add($wslPackageId)
    }

    $wslHeldBack = $false
    if ($excludeList.Count -gt 0) {
        if (Test-WingetSupportsExclude -Winget $winget) {
            foreach ($id in $excludeList) {
                $wingetArgs += @('--exclude', $id)
            }
            if ($configIgnoreList.Count -gt 0) {
                Write-Output "Excluding configured package(s) ($ignoreFile): $($configIgnoreList -join ', ')"
            }
            if ($wslUpgradePending) {
                $wslHeldBack = $true
                Write-Output "WSL is running - excluding $wslPackageId from this upgrade."
            }
        }
        elseif ($wslUpgradePending) {
            $script:StepStatus = 'SKIP'
            $script:StepDetail = "held back: WSL is running with a pending $wslPackageId upgrade and this winget build has no --exclude; run 'wsl --shutdown' first or upgrade WSL manually"
            Write-Warning $script:StepDetail
            return
        }
        else {
            Write-Warning "This winget build has no --exclude; the configured ignore list ($($configIgnoreList -join ', ')) will not be applied this run."
        }
    }

    Write-Output "$winget $($wingetArgs -join ' ')"
    & $winget @wingetArgs
    $code = $LASTEXITCODE

    $wslNote = if ($wslHeldBack) { "; $wslPackageId held back (WSL running)" } else { '' }

    # 0x8A15002B / -1978335189 = APPINSTALLER_CLI_ERROR_UPDATE_NOT_APPLICABLE:
    # there was nothing to upgrade.
    $noApplicableUpgrades = -1978335189
    if ($code -eq 0) {
        $script:StepDetail = "winget upgrades applied$wslNote"
        return
    }
    if ($code -eq $noApplicableUpgrades) {
        $script:StepDetail = "nothing to upgrade$wslNote"
        return
    }

    $hex = '0x{0:X8}' -f ($code -band 0xFFFFFFFF)
    throw "winget exited $code ($hex)."
}

# ---------------------------------------------------------------------------
# Step 4: System file integrity (DISM RestoreHealth + SFC)
# ---------------------------------------------------------------------------

function Get-SfcOutcome {
    # What "sfc /scannow" concluded, read from the [SR] entries it wrote to
    # CBS.log since $Since - unlike its console text, that does not depend on
    # the Windows display language. Returns Clean, Repaired, Unrepairable or
    # Unknown; "could not tell" is never reported as Clean.
    param(
        [Parameter(Mandatory)] [datetime] $Since
    )

    $cbsLog = Join-Path $env:SystemRoot 'Logs\CBS\CBS.log'
    if (-not (Test-Path -LiteralPath $cbsLog)) {
        return 'Unknown'
    }

    try {
        $entries = @(Select-String -LiteralPath $cbsLog -Pattern '\[SR\]' -ErrorAction Stop)
    }
    catch {
        Write-Verbose "Could not read ${cbsLog}: $($_.Exception.Message)"
        return 'Unknown'
    }

    $verifyComplete = $false
    $repaired = $false
    $unrepairable = $false
    foreach ($entry in $entries) {
        $line = $entry.Line
        # Lines start with an ISO timestamp: "2026-09-29 12:34:56, Info ...".
        if ($line.Length -lt 19) {
            continue
        }
        $stamp = [datetime]::MinValue
        if (-not [datetime]::TryParse($line.Substring(0, 19), [ref]$stamp)) {
            continue
        }
        if ($stamp -lt $Since) {
            continue
        }
        if ($line -match 'Verify complete') {
            $verifyComplete = $true
        }
        if ($line -match 'Cannot repair') {
            $unrepairable = $true
        }
        if ($line -match 'Repairing corrupted file|Repairing [1-9]\d* component') {
            $repaired = $true
        }
    }

    if ($unrepairable) {
        return 'Unrepairable'
    }
    if ($repaired) {
        return 'Repaired'
    }
    if ($verifyComplete) {
        return 'Clean'
    }
    return 'Unknown'
}

function Invoke-IntegrityRepair {
    # DISM RestoreHealth, then sfc /scannow; unrepairable corruption fails it.
    $problems = [System.Collections.Generic.List[string]]::new()
    $warnings = [System.Collections.Generic.List[string]]::new()
    $notes = [System.Collections.Generic.List[string]]::new()

    # RestoreHealth scans the component store and only repairs it when it is
    # damaged, so a separate ScanHealth pass would just double the runtime.
    $dism = Join-Path $env:SystemRoot 'System32\Dism.exe'
    Write-Output 'DISM /Online /Cleanup-Image /RestoreHealth ...'
    & $dism /Online /Cleanup-Image /RestoreHealth /NoRestart
    $dismCode = $LASTEXITCODE
    if ($dismCode -eq 0) {
        $notes.Add('component store OK')
    }
    elseif ($dismCode -eq 3010) {
        # 3010 = ERROR_SUCCESS_REBOOT_REQUIRED.
        $script:RebootRequired = $true
        $notes.Add('component store repaired (reboot required)')
    }
    else {
        $problems.Add("DISM RestoreHealth failed (exit $dismCode)")
    }

    # sfc runs even if DISM failed - it reports on the live system files, which
    # is still worth knowing.
    $sfc = Join-Path $env:SystemRoot 'System32\sfc.exe'
    Write-Output ''
    Write-Output 'sfc /scannow ...'
    $sfcStart = Get-Date
    & $sfc /scannow
    $sfcCode = $LASTEXITCODE
    switch (Get-SfcOutcome -Since $sfcStart) {
        'Clean' { $notes.Add('sfc found no integrity violations') }
        'Repaired' { $notes.Add('sfc repaired corrupt files') }
        'Unrepairable' { $problems.Add('sfc found corrupt files it could not repair (details in CBS.log)') }
        default { $warnings.Add("sfc result not recognised (exit $sfcCode) - check its output above / CBS.log") }
    }

    if ($problems.Count -gt 0) {
        throw ((@($problems) + @($warnings) + @($notes)) -join '; ')
    }
    if ($warnings.Count -gt 0) {
        $script:StepStatus = 'WARN'
        $script:StepDetail = (@($warnings) + @($notes)) -join '; '
        return
    }
    $script:StepDetail = $notes -join '; '
}

# ---------------------------------------------------------------------------
# Step 5: Disk Cleanup (all fixed drives) + WinSxS component store
# ---------------------------------------------------------------------------

function Invoke-DiskCleanup {
    # Runs Disk Cleanup (cleanmgr /sagerun) on every fixed drive with all but
    # the unsafe handlers enabled, then trims the WinSxS store with DISM.
    param(
        [Parameter(Mandatory)] [int] $SagerunProfile
    )

    $ran = [System.Collections.Generic.List[string]]::new()
    $spaceBefore = Get-FixedVolumeSpace

    $cleanmgr = Join-Path $env:SystemRoot 'System32\cleanmgr.exe'
    if (-not (Test-Path -LiteralPath $cleanmgr)) {
        Write-Warning 'cleanmgr.exe not present (optional Feature on Server SKUs); skipping the /sagerun pass.'
    }
    else {
        # Handlers that stay disabled while the rest are enabled - the Disk
        # Cleanup UI leaves all of these unchecked too, and each one removes
        # something you may want to keep. Regexes against the handler's key
        # name (matched loosely on purpose: a slightly different name on some
        # Windows build should still be excluded, not silently enabled). Add
        # other patterns here to keep more handlers disabled.
        $excluded = @(
            '^Downloads'              # DownloadsFolder: empties %USERPROFILE%\Downloads
            'Previous Installation'   # Windows.old - the OS rollback
            'Device Driver Package'   # old driver versions - driver rollback
            'Windows ESD'             # source for a local "Reset this PC"
        )

        $flag = 'StateFlags{0:D4}' -f $SagerunProfile
        $caches = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\VolumeCaches'
        $handlers = @(Get-ChildItem -LiteralPath $caches -ErrorAction Stop)
        $kept = [System.Collections.Generic.List[string]]::new()
        foreach ($handler in $handlers) {
            # 2 = enabled for this profile, 0 = disabled.
            $value = 2
            foreach ($pattern in $excluded) {
                if ($handler.PSChildName -match $pattern) {
                    $value = 0
                    $kept.Add($handler.PSChildName)
                    break
                }
            }
            New-ItemProperty -LiteralPath $handler.PSPath -Name $flag -PropertyType DWord `
                -Value $value -Force | Out-Null
        }
        Write-Output "Configured $($handlers.Count) cleanup handler(s) for /sagerun:$SagerunProfile; left disabled: $($kept -join ', ')."

        # /sagerun can hand work to child processes and return early, so wait for
        # the process we start and then for any lingering cleanmgr / dismhost.
        # standards-exception: PS-21 cleanmgr's exit code says nothing about the
        # result (it hands work to child processes); completion is detected by
        # waiting on those processes instead.
        Start-Process -FilePath $cleanmgr -ArgumentList "/sagerun:$SagerunProfile" -Wait
        Get-Process -Name 'cleanmgr', 'dismhost' -ErrorAction SilentlyContinue |
            Wait-Process -Timeout 1800 -ErrorAction SilentlyContinue
        $ran.Add("cleanmgr /sagerun:$SagerunProfile")
    }

    # WinSxS component-store cleanup - where most of the reclaimable space is.
    $dism = Join-Path $env:SystemRoot 'System32\Dism.exe'
    Write-Output 'DISM /Online /Cleanup-Image /StartComponentCleanup ...'
    & $dism /Online /Cleanup-Image /StartComponentCleanup /NoRestart
    $dismCode = $LASTEXITCODE
    if ($dismCode -eq 3010) {
        # 3010 = ERROR_SUCCESS_REBOOT_REQUIRED: the cleanup worked but wants a
        # reboot to finish. Report it rather than failing the step.
        $script:RebootRequired = $true
        $ran.Add('DISM StartComponentCleanup (reboot required)')
    }
    elseif ($dismCode -ne 0) {
        throw "DISM StartComponentCleanup failed (exit $dismCode)."
    }
    else {
        $ran.Add('DISM StartComponentCleanup')
    }

    # Free-space change per fixed drive (cleanmgr covers every drive, and the
    # Recycle Bin on each). Other activity can move these numbers a little.
    $spaceAfter = Get-FixedVolumeSpace
    $changes = [System.Collections.Generic.List[string]]::new()
    foreach ($letter in ($spaceBefore.Keys | Sort-Object)) {
        if (-not $spaceAfter.ContainsKey($letter)) {
            continue
        }
        $delta = $spaceAfter[$letter].Free - $spaceBefore[$letter].Free
        $sign = if ($delta -ge 0) { '+' } else { '' }
        $changes.Add(('{0}: {1}{2}' -f $letter, $sign, (Format-ByteSize $delta)))
    }
    if ($changes.Count -gt 0) {
        Write-Output "Free space change: $($changes -join ', ')"
        $ran.Add("free space $($changes -join ' ')")
    }

    $script:StepDetail = ($ran -join ', ')
}

# ---------------------------------------------------------------------------
# Step 6: WSL disk compaction (Hyper-V Optimize-VHD)
# ---------------------------------------------------------------------------

function Invoke-WslTrim {
    # Best-effort "fstrim" inside one distro so blocks freed by deleted files
    # are marked reclaimable before its disk is compacted. Starts the distro if
    # it is not running. Bounded, so a wedged distro cannot hang the step.
    param(
        [Parameter(Mandatory)] [string] $Wsl,
        [Parameter(Mandatory)] [string] $Distro
    )

    Write-Output "  fstrim in $Distro ..."
    # standards-exception: PS-21 needs a bounded wait (WaitForExit, then Kill)
    # so a wedged distro cannot hang the step; best effort, so no exit code.
    $process = Start-Process -FilePath $Wsl -NoNewWindow -PassThru `
        -ArgumentList @('-d', (Format-ProcessArgument $Distro), '-u', 'root', '--exec', 'fstrim', '-av')
    if (-not $process.WaitForExit(120000)) {
        Write-Warning "  fstrim in $Distro did not finish within 2 minutes; continuing."
        try {
            $process.Kill()
        }
        catch {
            Write-Verbose "Could not stop fstrim: $($_.Exception.Message)"
        }
    }
}

function Invoke-WslCompaction {
    # Compacts each WSL 2 distro's .vhdx with Hyper-V's Optimize-VHD. Every
    # guard below runs BEFORE "wsl --shutdown", so a machine that cannot
    # compact never has WSL shut down for nothing.
    if (-not $script:AllowWslShutdown) {
        $script:StepStatus = 'SKIP'
        $script:StepDetail = 'WSL shutdown was not approved'
        return
    }

    # Guard: tooling. Optimize-VHD comes from the Hyper-V PowerShell module and
    # talks to the Hyper-V Virtual Machine Management service.
    $wsl = Get-Command -Name wsl.exe -CommandType Application -ErrorAction SilentlyContinue |
        Select-Object -First 1
    $skipReason = $null
    if (-not $wsl) {
        $skipReason = 'WSL is not installed'
    }
    elseif (-not (Get-Command -Name Optimize-VHD -ErrorAction SilentlyContinue) -or
        -not (Get-Command -Name Get-VHD -ErrorAction SilentlyContinue)) {
        $skipReason = 'Optimize-VHD not available - enable the Microsoft-Hyper-V-Management-PowerShell feature; WSL was left running'
    }
    else {
        $vmms = Get-Service -Name 'vmms' -ErrorAction SilentlyContinue
        if (-not $vmms -or $vmms.Status -ne 'Running') {
            $skipReason = 'Hyper-V Virtual Machine Management service (vmms) is not running; WSL was left running'
        }
    }
    if ($skipReason) {
        $script:StepStatus = 'SKIP'
        $script:StepDetail = $skipReason
        Write-Warning $skipReason
        return
    }

    # Guard: which distro disks are safe to compact.
    $targets = [System.Collections.Generic.List[psobject]]::new()
    $skipped = [System.Collections.Generic.List[string]]::new()
    foreach ($distro in @(Get-WslInventory)) {
        if ($distro.Version -eq 1) {
            # WSL 1 keeps its files in the Windows filesystem - no disk image.
            continue
        }

        $reason = $null
        if (-not (Test-Path -LiteralPath $distro.VhdPath)) {
            $reason = 'no disk image found'
        }
        elseif ($distro.VhdPath -notmatch '^[A-Za-z]:\\') {
            $reason = 'disk image is not on a local drive letter'
        }
        else {
            $letter = $distro.VhdPath.Substring(0, 1)
            $health = Get-VolumeDiskHealth -DriveLetter $letter
            $volume = Get-Volume -DriveLetter $letter -ErrorAction SilentlyContinue
            $imageSize = (Get-Item -LiteralPath $distro.VhdPath).Length
            $needed = [math]::Max(1GB, [int64]($imageSize * 0.1))
            if ($health -and $health -ne 'Healthy') {
                $reason = "host disk reports $health"
            }
            elseif ($volume -and $volume.SizeRemaining -lt $needed) {
                $reason = 'only {0} free on {1}: (needs {2})' -f (Format-ByteSize $volume.SizeRemaining), $letter, (Format-ByteSize $needed)
            }
        }

        if ($reason) {
            Write-Warning "  $($distro.Name): skipped - $reason"
            $skipped.Add("$($distro.Name) ($reason)")
            continue
        }
        $targets.Add($distro)
    }

    if ($targets.Count -eq 0) {
        $script:StepStatus = if ($skipped.Count -gt 0) { 'WARN' } else { 'SKIP' }
        $script:StepDetail = if ($skipped.Count -gt 0) { "nothing compacted; skipped: $($skipped -join ', ')" } else { 'no WSL 2 distributions with a disk image' }
        Write-Output "$script:StepDetail (WSL was not shut down)."
        return
    }

    # Mark freed blocks reclaimable. Docker Desktop manages its own distros.
    Write-Output 'Trimming free space inside each distro (fstrim) so the compaction can reclaim it...'
    foreach ($target in $targets) {
        if ($target.Name -match '^docker-desktop') {
            continue
        }
        try {
            Invoke-WslTrim -Wsl $wsl.Source -Distro $target.Name
        }
        catch {
            Write-Warning "  fstrim in $($target.Name) failed: $($_.Exception.Message)"
        }
    }

    # Approved in the up-front confirmation. Wait until WSL is really down -
    # compacting a disk image that is still attached would fail or corrupt.
    Write-Output 'wsl --shutdown ...'
    & $wsl.Source --shutdown
    if ($LASTEXITCODE -ne 0) {
        throw "wsl --shutdown failed (exit $LASTEXITCODE)"
    }
    $deadline = (Get-Date).AddSeconds(60)
    while ((Test-WslRunning) -and (Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 2
    }
    if (Test-WslRunning) {
        $script:StepStatus = 'WARN'
        $script:StepDetail = 'WSL did not stop within 60 seconds - nothing was compacted'
        Write-Warning $script:StepDetail
        return
    }

    $compacted = [System.Collections.Generic.List[string]]::new()
    $failed = [System.Collections.Generic.List[string]]::new()
    $reclaimedTotal = [int64]0
    foreach ($target in $targets) {
        $name = $target.Name
        $path = $target.VhdPath
        try {
            # Guard: something (e.g. Docker Desktop restarting its backend) may
            # have grabbed the disk again since the shutdown.
            if (Test-FileLocked -Path $path) {
                Write-Warning "  ${name}: disk image is in use (did something restart WSL?) - skipped"
                $skipped.Add("$name (in use)")
                continue
            }
            $vhd = Get-VHD -Path $path -ErrorAction Stop
            if ($vhd.Attached) {
                Write-Warning "  ${name}: disk image is attached - skipped"
                $skipped.Add("$name (attached)")
                continue
            }

            $before = [int64]$vhd.FileSize
            Write-Output "Optimize-VHD -Path '$path' -Mode Full  ($name, $(Format-ByteSize $before))"
            Optimize-VHD -Path $path -Mode Full -ErrorAction Stop
            $after = [int64](Get-Item -LiteralPath $path).Length
            $reclaimedTotal += ($before - $after)
            $compacted.Add(('{0} {1}' -f $name, (Format-ByteSize ($before - $after))))
        }
        catch {
            Write-Warning "  ${name}: compaction failed - $($_.Exception.Message)"
            $failed.Add($name)
        }
    }
    Write-Output 'WSL was left stopped; it starts again the next time it is used.'

    $parts = [System.Collections.Generic.List[string]]::new()
    if ($compacted.Count -gt 0) {
        $parts.Add("reclaimed $(Format-ByteSize $reclaimedTotal): $($compacted -join ', ')")
    }
    if ($skipped.Count -gt 0) {
        $parts.Add("skipped: $($skipped -join ', ')")
    }
    if ($failed.Count -gt 0) {
        $parts.Add("failed: $($failed -join ', ')")
        throw ($parts -join '; ')
    }
    if ($skipped.Count -gt 0) {
        $script:StepStatus = 'WARN'
    }
    $script:StepDetail = $parts -join '; '
}

# ---------------------------------------------------------------------------
# Step 7: Health check (report only)
# ---------------------------------------------------------------------------

function Invoke-HealthCheck {
    # Reads, never repairs. A disk / volume that is unhealthy is a FAIL (needs
    # attention now); softer findings are WARNs.
    $critical = [System.Collections.Generic.List[string]]::new()
    $warnings = [System.Collections.Generic.List[string]]::new()

    Write-Output '--- Physical disks ---'
    $disks = @(Get-PhysicalDisk -ErrorAction Stop | Sort-Object -Property DeviceId)
    foreach ($disk in $disks) {
        $counter = $null
        try {
            $counter = $disk | Get-StorageReliabilityCounter -ErrorAction Stop
        }
        catch {
            Write-Verbose "No reliability counters for $($disk.FriendlyName): $($_.Exception.Message)"
        }
        $wear = Get-PropertyValue -InputObject $counter -Name 'Wear'
        $temperature = Get-PropertyValue -InputObject $counter -Name 'Temperature'
        $powerOnHours = Get-PropertyValue -InputObject $counter -Name 'PowerOnHours'
        $uncorrected = [int64](Get-PropertyValue -InputObject $counter -Name 'ReadErrorsUncorrected') +
            [int64](Get-PropertyValue -InputObject $counter -Name 'WriteErrorsUncorrected')

        $line = '{0} ({1}, {2}): health {3}' -f $disk.FriendlyName, $disk.MediaType, (Format-ByteSize $disk.Size), $disk.HealthStatus
        if ($null -ne $wear) {
            $line += ", wear ${wear}%"
        }
        if ($null -ne $temperature) {
            $line += ", ${temperature} C"
        }
        if ($null -ne $powerOnHours) {
            $line += ", ${powerOnHours} power-on hours"
        }
        Write-Output "  $line"

        if ([string]$disk.HealthStatus -ne 'Healthy') {
            $critical.Add("disk $($disk.FriendlyName) is $($disk.HealthStatus)")
        }
        elseif ([string]$disk.OperationalStatus -ne 'OK') {
            $warnings.Add("disk $($disk.FriendlyName) status $($disk.OperationalStatus)")
        }
        if ($null -ne $wear -and [int]$wear -ge 80) {
            $warnings.Add("disk $($disk.FriendlyName) wear at ${wear}%")
        }
        if ($null -ne $temperature -and [int]$temperature -ge 70) {
            $warnings.Add("disk $($disk.FriendlyName) running hot (${temperature} C)")
        }
        if ($uncorrected -gt 0) {
            $warnings.Add("disk $($disk.FriendlyName) reports $uncorrected uncorrected read/write error(s)")
        }
    }

    Write-Output ''
    Write-Output '--- Volumes ---'
    $volumes = @(
        Get-Volume -ErrorAction Stop |
            Where-Object { $_.DriveLetter -and $_.DriveType -eq 'Fixed' } |
            Sort-Object -Property DriveLetter
    )
    foreach ($volume in $volumes) {
        $letter = [string]$volume.DriveLetter
        $percentFree = if ($volume.Size -gt 0) { 100 * $volume.SizeRemaining / $volume.Size } else { 0 }
        Write-Output ('  {0}: {1}  {2} free of {3} ({4:N0}%)  health {5}' -f
            $letter, $volume.FileSystemType, (Format-ByteSize $volume.SizeRemaining), (Format-ByteSize $volume.Size), $percentFree, $volume.HealthStatus)

        if ([string]$volume.HealthStatus -ne 'Healthy') {
            $critical.Add("volume ${letter}: is $($volume.HealthStatus)")
        }
        if ($percentFree -lt 10) {
            $warnings.Add(('{0}: only {1:N0}% free' -f $letter, $percentFree))
        }

        if (@('NTFS', 'ReFS') -notcontains [string]$volume.FileSystemType) {
            continue
        }
        # Online scan: reports corruption, never repairs or schedules anything.
        Write-Output "  Repair-Volume -DriveLetter $letter -Scan ..."
        try {
            $scan = [string](Repair-Volume -DriveLetter $letter -Scan -ErrorAction Stop)
            if ($scan -match 'NoErrors') {
                Write-Output "  ${letter}: no filesystem errors found"
            }
            elseif ($scan -match 'Error|Corrupt|Needed') {
                $critical.Add("${letter}: filesystem scan reported '$scan' (fix with Repair-Volume -DriveLetter $letter -OfflineScanAndFix)")
            }
            else {
                $warnings.Add("${letter}: filesystem scan finished with an unrecognised result '$scan'")
            }
        }
        catch {
            $warnings.Add("${letter}: filesystem scan could not run ($($_.Exception.Message))")
        }
    }

    Write-Output ''
    Write-Output '--- System event log, last 7 days ---'
    $since = (Get-Date).AddDays(-7)

    $storageProviders = @('disk', 'Ntfs', 'Microsoft-Windows-Ntfs', 'volmgr', 'stornvme', 'storahci', 'Microsoft-Windows-WHEA-Logger')
    $storageEvents = @(
        Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = $storageProviders; Level = 1, 2; StartTime = $since } `
            -ErrorAction SilentlyContinue
    )
    if ($storageEvents.Count -gt 0) {
        $groups = @($storageEvents | Group-Object -Property ProviderName, Id | Sort-Object -Property Count -Descending | Select-Object -First 5)
        foreach ($group in $groups) {
            $sample = $group.Group[0]
            $firstLine = if ($sample.Message) { ($sample.Message -split "\r?\n")[0] } else { '(no message text)' }
            Write-Output ('  {0,4} x {1} event {2}: {3}' -f $group.Count, $sample.ProviderName, $sample.Id, $firstLine)
        }
        $topEvent = $groups[0].Group[0]
        $warnings.Add("$($storageEvents.Count) storage/hardware error event(s) (most: $($topEvent.ProviderName) $($topEvent.Id))")
    }
    else {
        Write-Output '  no disk / filesystem / hardware (WHEA) error events'
    }

    $unexpectedShutdowns = @(
        Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-Kernel-Power'; Id = 41; StartTime = $since } `
            -ErrorAction SilentlyContinue
    )
    if ($unexpectedShutdowns.Count -gt 0) {
        Write-Output "  $($unexpectedShutdowns.Count) unexpected shutdown(s) (Kernel-Power 41)"
        $warnings.Add("$($unexpectedShutdowns.Count) unexpected shutdown(s)")
    }
    $bugchecks = @(
        Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-WER-SystemErrorReporting'; Id = 1001; StartTime = $since } `
            -ErrorAction SilentlyContinue
    )
    if ($bugchecks.Count -gt 0) {
        Write-Output "  $($bugchecks.Count) bugcheck / blue screen(s)"
        $warnings.Add("$($bugchecks.Count) bugcheck(s)")
    }

    Write-Output ''
    Write-Output '--- Boot performance ---'
    $bootTimes = [System.Collections.Generic.List[string]]::new()
    try {
        $bootEvents = @(
            Get-WinEvent -FilterHashtable @{ LogName = 'Microsoft-Windows-Diagnostics-Performance/Operational'; Id = 100 } `
                -MaxEvents 5 -ErrorAction SilentlyContinue
        )
        foreach ($bootEvent in $bootEvents) {
            $node = ([xml]$bootEvent.ToXml()).SelectSingleNode("//*[local-name()='Data'][@Name='BootTime']")
            if ($node) {
                $bootTimes.Add(('{0:N0}s' -f ([double]$node.InnerText / 1000)))
            }
        }
    }
    catch {
        Write-Verbose "Could not read boot performance events: $($_.Exception.Message)"
    }
    if ($bootTimes.Count -gt 0) {
        Write-Output "  last boots, newest first: $($bootTimes -join ', ')"
    }
    else {
        Write-Output '  no boot performance data'
    }

    Write-Output ''
    $startup = @(Get-CimInstance -ClassName Win32_StartupCommand -ErrorAction SilentlyContinue | Sort-Object -Property Name)
    Write-Output "--- Startup entries ($($startup.Count)) ---"
    foreach ($entry in $startup) {
        Write-Output ('  {0}  [{1}]  {2}' -f $entry.Name, $entry.Location, $entry.Command)
    }

    if ($critical.Count -gt 0) {
        $script:StepStatus = 'FAIL'
        $script:StepDetail = (@($critical) + @($warnings)) -join '; '
        return
    }
    if ($warnings.Count -gt 0) {
        $script:StepStatus = 'WARN'
        $script:StepDetail = $warnings -join '; '
        return
    }
    $script:StepDetail = "$($disks.Count) disk(s) and $($volumes.Count) volume(s) healthy; no recent hardware errors"
}

# ---------------------------------------------------------------------------
# Step 8: Optimize / defrag all fixed volumes
# ---------------------------------------------------------------------------

function Invoke-VolumeOptimization {
    # Runs Optimize-Volume (defrag or retrim, per media type) on each fixed
    # NTFS/ReFS volume, skipping any whose disk reports it is unhealthy.
    $targets = @(
        Get-Volume |
            Where-Object {
                $_.DriveLetter -and
                $_.DriveType -eq 'Fixed' -and
                @('NTFS', 'ReFS') -contains $_.FileSystemType
            } |
            Sort-Object -Property DriveLetter
    )

    if ($targets.Count -eq 0) {
        $script:StepDetail = 'no eligible fixed volumes'
        return
    }

    $optimized = [System.Collections.Generic.List[string]]::new()
    $failed = [System.Collections.Generic.List[string]]::new()
    $skipped = [System.Collections.Generic.List[string]]::new()
    foreach ($volume in $targets) {
        $letter = [string]$volume.DriveLetter

        # Guard: don't spend hours thrashing a disk that says it is failing -
        # back it up first. (Unknown health, e.g. Storage Spaces, goes ahead.)
        $health = Get-VolumeDiskHealth -DriveLetter $letter
        if ($health -and $health -ne 'Healthy') {
            Write-Warning "  ${letter}: skipped - its disk reports $health; back it up and check it before optimizing"
            $skipped.Add("${letter}: (disk $health)")
            continue
        }

        Write-Output "Optimize-Volume -DriveLetter $letter  ($($volume.FileSystemType))"
        try {
            # No -Defrag / -ReTrim / -Analyze: Windows runs the media-appropriate
            # optimization for each volume (defrag on HDD, retrim on SSD).
            Optimize-Volume -DriveLetter $letter -Verbose -ErrorAction Stop
            $optimized.Add("${letter}:")
        }
        catch {
            Write-Warning "  ${letter}: optimization failed - $($_.Exception.Message)"
            $failed.Add("${letter}:")
        }
    }

    if ($failed.Count -gt 0) {
        throw "failed for $($failed -join ' ') (ok: $($optimized -join ' '))"
    }
    if ($skipped.Count -gt 0) {
        $script:StepStatus = 'WARN'
        $parts = [System.Collections.Generic.List[string]]::new()
        if ($optimized.Count -gt 0) {
            $parts.Add("optimized $($optimized -join ' ')")
        }
        $parts.Add("skipped $($skipped -join ' ')")
        $script:StepDetail = $parts -join '; '
        return
    }
    $script:StepDetail = "optimized $($optimized -join ' ')"
}

# ---------------------------------------------------------------------------
# Step 9: Microsoft Defender signature update + scan
# ---------------------------------------------------------------------------

function Invoke-DefenderMaintenance {
    # Updates Defender signatures and runs a scan. An active threat fails the
    # step; stale signatures or a detection Defender handled only warn.
    if (-not (Get-Command -Name Get-MpComputerStatus -ErrorAction SilentlyContinue)) {
        $script:StepStatus = 'SKIP'
        $script:StepDetail = 'Microsoft Defender cmdlets not available'
        return
    }

    $status = Get-MpComputerStatus -ErrorAction Stop
    $mode = [string](Get-PropertyValue -InputObject $status -Name 'AMRunningMode')
    if (-not $status.AMServiceEnabled -or $mode -match 'Passive|Not running') {
        # A third-party antivirus owns protection; scanning with Defender here
        # would be noise (and is often blocked).
        $script:StepStatus = 'SKIP'
        $script:StepDetail = "Defender is not the active antivirus (mode: $mode)"
        Write-Output $script:StepDetail
        return
    }

    $warnings = [System.Collections.Generic.List[string]]::new()
    $problems = [System.Collections.Generic.List[string]]::new()

    Write-Output 'Update-MpSignature ...'
    try {
        Update-MpSignature -ErrorAction Stop
    }
    catch {
        Write-Warning "Signature update failed: $($_.Exception.Message)"
        $warnings.Add('signature update failed')
    }

    $status = Get-MpComputerStatus -ErrorAction Stop
    $signatureAge = Get-PropertyValue -InputObject $status -Name 'AntivirusSignatureAge'
    $realTime = Get-PropertyValue -InputObject $status -Name 'RealTimeProtectionEnabled'
    $tamper = Get-PropertyValue -InputObject $status -Name 'IsTamperProtected'
    Write-Output ('Signatures: {0} day(s) old (updated {1})   Real-time protection: {2}   Tamper protection: {3}' -f
        $signatureAge, (Get-PropertyValue -InputObject $status -Name 'AntivirusSignatureLastUpdated'), $realTime, $tamper)
    if ($null -ne $signatureAge -and [int]$signatureAge -gt 3) {
        $warnings.Add("signatures are $signatureAge day(s) old")
    }
    if ($realTime -eq $false) {
        $warnings.Add('real-time protection is OFF')
    }

    $scanType = if ($script:DefenderFullScan) { 'FullScan' } else { 'QuickScan' }
    $scanStart = Get-Date
    Write-Output "Start-MpScan -ScanType $scanType (this can take a while) ..."
    Start-MpScan -ScanType $scanType -ErrorAction Stop

    # Threats still active after the scan are a FAIL; ones Defender already
    # quarantined / removed during it are worth a WARN.
    $active = @(
        Get-MpThreat -ErrorAction SilentlyContinue |
            Where-Object { Get-PropertyValue -InputObject $_ -Name 'IsActive' }
    )
    $detected = @(
        Get-MpThreatDetection -ErrorAction SilentlyContinue |
            Where-Object { (Get-PropertyValue -InputObject $_ -Name 'InitialDetectionTime') -ge $scanStart }
    )
    if ($active.Count -gt 0) {
        $names = ($active | ForEach-Object { Get-PropertyValue -InputObject $_ -Name 'ThreatName' }) -join ', '
        Write-Warning "Active threat(s): $names"
        $problems.Add("$($active.Count) active threat(s): $names")
    }
    elseif ($detected.Count -gt 0) {
        $warnings.Add("$($detected.Count) threat detection(s) during the scan, handled by Defender")
    }

    if ($problems.Count -gt 0) {
        throw ((@($problems) + @($warnings)) -join '; ')
    }
    if ($warnings.Count -gt 0) {
        $script:StepStatus = 'WARN'
        $script:StepDetail = $warnings -join '; '
        return
    }
    $script:StepDetail = "$($scanType -replace 'Scan', ' scan') clean; signatures $signatureAge day(s) old"
}

# ---------------------------------------------------------------------------
# Run
# ---------------------------------------------------------------------------

$script:SelfPath = $PSCommandPath
$script:SagerunProfile = $SagerunProfile
$script:KeepStepWindows = [bool]$KeepStepWindows
$script:DefenderFullScan = [bool]$DefenderFullScan

$script:IsAdmin = Test-Administrator

# Has this run's up-front confirmation covered "wsl --shutdown"? Yes unless
# -SkipWslCompact (that step is what shuts WSL down) or the admin-only steps
# will not run at all. A step window is told by the orchestrator.
if ($RunStep) {
    $script:AllowWslShutdown = [bool]$AllowWslShutdown
}
else {
    $script:AllowWslShutdown = (-not $SkipWslCompact) -and ($script:IsAdmin -or -not $NoElevate)
}

# Child mode: this process was launched by the orchestrator to run one step.
if ($RunStep) {
    if ([string]::IsNullOrEmpty($RunDir)) {
        Write-Error '-RunStep requires -RunDir.'
        exit 1
    }
    Invoke-MaintenanceStep -Step $RunStep -RunDir $RunDir -SagerunProfile $SagerunProfile -KeepOpen:$KeepStepWindows
    exit 1  # Invoke-MaintenanceStep always exits; this is just a guard.
}

$adminStepDue = $DriverUpdate -or -not (
    $SkipWindowsUpdate -and $SkipWinget -and $SkipIntegrity -and $SkipDiskCleanup -and
    $SkipWslCompact -and $SkipHealthCheck -and $SkipDefrag -and $SkipDefender)

# Up-front plan + consent, before anything (even the UAC prompt) happens. Not
# repeated on the elevated relaunch - that only happens after this passed.
if (-not $Relaunched) {
    $plan = Get-MaintenancePlan -AdminStepsWillRun ($script:IsAdmin -or -not $NoElevate)
    if ($plan.Count -gt 0) {
        Show-MaintenancePlan -Plan $plan
        if ($Yes) {
            Write-Output 'Proceeding without asking (-Yes).'
        }
        elseif (-not (Test-MaintenanceConsent)) {
            Write-Warning 'Cancelled - nothing was changed. Re-run and answer y to proceed (or pass -Yes).'
            exit 1
        }
    }
}

# Self-elevate: if an admin-only step (everything except the winget user pass)
# is going to run and we are not elevated, relaunch the whole script elevated
# in a new console and mirror its exit code. -NoElevate opts out (the steps are
# then skipped by the -RequiresAdmin gate in Invoke-Step). Step windows spawned
# later inherit this elevation - no further UAC prompts.
if (-not $script:IsAdmin -and $adminStepDue -and -not $NoElevate) {
    Write-Output 'Windows Update, winget (system), integrity repair, Disk Cleanup, WSL compaction, health check, optimize and Defender need Administrator - relaunching elevated (a UAC prompt will appear)...'

    $childArgs = @(
        '-NoProfile'
        '-ExecutionPolicy'
        'Bypass'
        '-File'
        (Format-ProcessArgument $PSCommandPath)
        '-Relaunched'
    )
    foreach ($entry in $PSBoundParameters.GetEnumerator()) {
        if ($entry.Key -in @('Relaunched', 'NoElevate', 'RunStep', 'RunDir')) {
            continue
        }
        if ($entry.Value -is [System.Management.Automation.SwitchParameter]) {
            if ($entry.Value.IsPresent) {
                $childArgs += "-$($entry.Key)"
            }
        }
        else {
            $childArgs += @("-$($entry.Key)", (Format-ProcessArgument ([string]$entry.Value)))
        }
    }

    try {
        $child = Start-Process -FilePath $script:HostExe -ArgumentList $childArgs `
            -Verb RunAs -Wait -PassThru -ErrorAction Stop
    }
    catch {
        Write-Error ("Could not elevate ({0}). Re-run from an elevated prompt, or pass -NoElevate to skip the admin-only steps." -f $_.Exception.Message)
        exit 1
    }
    exit ([int]$child.ExitCode)
}

$overallStart = Get-Date
$script:RunDir = Join-Path ([System.IO.Path]::GetTempPath()) ('windows_maintenance_{0}' -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
New-Item -ItemType Directory -Path $script:RunDir -Force | Out-Null

Write-Output "Windows maintenance run - $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
Write-Output "Host: $env:COMPUTERNAME   User: $env:USERNAME   Elevated: $script:IsAdmin   Disk Cleanup profile: $SagerunProfile"
Write-Output "Per-step windows and logs: $script:RunDir"
if (-not $script:IsAdmin -and $adminStepDue) {
    Write-Warning '-NoElevate and not elevated - Windows Update, winget (system), integrity repair, Disk Cleanup, WSL compaction, health check, optimize and Defender will be skipped.'
}

# Preflight (warnings only) and a restore point before anything changes.
$spaceBefore = Get-FixedVolumeSpace
Invoke-Preflight -Space $spaceBefore
$changesSystemFiles = $DriverUpdate -or -not ($SkipWindowsUpdate -and $SkipIntegrity -and $SkipDiskCleanup)
if ($script:IsAdmin -and $changesSystemFiles -and -not $SkipRestorePoint) {
    Invoke-RestorePoint
}

# Order matters: repair the component store before cleaning it, compact WSL
# disks before the optimize step so the freed space gets retrimmed, and health-
# check the disks before the optimize step so it can skip a failing one.
$plannedSteps = [System.Collections.Generic.List[hashtable]]::new()
$plannedSteps.Add(@{ Name = 'Windows Update'; Step = 'WindowsUpdate'; Skip = [bool]$SkipWindowsUpdate; RequiresAdmin = $true })
if ($DriverUpdate) {
    $plannedSteps.Add(@{ Name = 'Driver updates (Windows Update)'; Step = 'DriverUpdate'; RequiresAdmin = $true })
}
$plannedSteps.Add(@{ Name = 'winget upgrade (user)'; Step = 'Winget'; Skip = [bool]$SkipWinget; Unelevated = $true })
$plannedSteps.Add(@{ Name = 'winget upgrade (system)'; Step = 'WingetSystem'; Skip = [bool]$SkipWinget; RequiresAdmin = $true })
$plannedSteps.Add(@{ Name = 'System file integrity (DISM + SFC)'; Step = 'Integrity'; Skip = [bool]$SkipIntegrity; RequiresAdmin = $true })
$plannedSteps.Add(@{ Name = 'Disk Cleanup + WinSxS'; Step = 'DiskCleanup'; Skip = [bool]$SkipDiskCleanup; RequiresAdmin = $true })
$plannedSteps.Add(@{ Name = 'WSL disk compaction'; Step = 'WslCompact'; Skip = [bool]$SkipWslCompact; RequiresAdmin = $true })
$plannedSteps.Add(@{ Name = 'Health check (disks, event log)'; Step = 'HealthCheck'; Skip = [bool]$SkipHealthCheck; RequiresAdmin = $true })
$plannedSteps.Add(@{ Name = 'Optimize / defrag volumes'; Step = 'Defrag'; Skip = [bool]$SkipDefrag; RequiresAdmin = $true })
$plannedSteps.Add(@{ Name = 'Defender update + scan'; Step = 'Defender'; Skip = [bool]$SkipDefender; RequiresAdmin = $true })

$script:StepCount = $plannedSteps.Count
foreach ($plannedStep in $plannedSteps) {
    Invoke-Step @plannedStep
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

$span = (Get-Date) - $overallStart
Write-Output ''
Write-Output ('=' * 72)
Write-Output ('  SUMMARY   (total {0:hh\:mm\:ss})' -f $span)
Write-Output ('=' * 72)
$script:Results |
    Format-Table -AutoSize -Property Step, Status, Detail |
    Out-String |
    Write-Output

Write-Output "Per-step output logs: $script:RunDir"

# Free space, start vs end of the run (cleanup and WSL compaction are what move it).
$spaceAfter = Get-FixedVolumeSpace
$spaceLines = [System.Collections.Generic.List[string]]::new()
foreach ($letter in ($spaceBefore.Keys | Sort-Object)) {
    if (-not $spaceAfter.ContainsKey($letter)) {
        continue
    }
    $freeBefore = $spaceBefore[$letter].Free
    $freeAfter = $spaceAfter[$letter].Free
    $sign = if ($freeAfter -ge $freeBefore) { '+' } else { '' }
    $spaceLines.Add(('  {0}: {1} free -> {2} free ({3}{4})' -f
            $letter, (Format-ByteSize $freeBefore), (Format-ByteSize $freeAfter), $sign, (Format-ByteSize ($freeAfter - $freeBefore))))
}
if ($spaceLines.Count -gt 0) {
    Write-Output 'Free space, start -> end of run:'
    Write-Output $spaceLines.ToArray()
}

if ($script:RebootRequired) {
    Write-Warning 'A system reboot is required to finish installing updates. This script does not reboot.'
}

$exitCode = 0

$failedSteps = @($script:Results | Where-Object { $_.Status -eq 'FAIL' })
if ($failedSteps.Count -gt 0) {
    Write-Warning "$($failedSteps.Count) of $($script:Results.Count) step(s) failed - see the summary above."
    $exitCode = 1
}

if ($script:SkippedForAdmin) {
    Write-Warning 'Admin-only steps were skipped (-NoElevate, not elevated) - re-run elevated to include them.'
    $exitCode = 1
}

# WARN never fails the run, but do not let a finding scroll past unnoticed.
$warnSteps = @($script:Results | Where-Object { $_.Status -eq 'WARN' })
if ($warnSteps.Count -gt 0) {
    Write-Warning "$($warnSteps.Count) step(s) finished with warnings ($(($warnSteps | ForEach-Object { $_.Step }) -join ', ')) - details in the summary above and the per-step logs."
}

if ($exitCode -eq 0) {
    if ($warnSteps.Count -gt 0) {
        Write-Output 'All requested maintenance steps completed (with warnings).'
    }
    else {
        Write-Output 'All requested maintenance steps completed successfully.'
    }
}

# Elevated relaunch runs in its own console; hold it open so the summary above
# stays readable after the script ends. Best-effort - skip if the host has no
# interactive input.
if ($Relaunched -and [Environment]::UserInteractive) {
    try {
        Write-Output ''
        [void](Read-Host 'Elevated run complete - press Enter to close this window')
    }
    catch {
        Write-Verbose "Could not pause for input: $($_.Exception.Message)"
    }
}

exit $exitCode

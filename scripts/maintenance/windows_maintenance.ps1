<#
.SYNOPSIS
    Runs a batch of Windows maintenance tasks in one pass: Windows Update,
    winget upgrades (user + system passes), Disk Cleanup on C:, per-volume optimization
    (defrag / retrim), and - with -DriverUpdate - Windows Update driver updates.

.DESCRIPTION
    Runs the steps below in order. Each step is independent - a failure is
    caught, logged, and the run continues - and an OK / FAIL / SKIP summary is
    printed at the end. The script exits non-zero if any step failed. It never
    reboots.

    Each step runs in its own console window: the orchestrator re-invokes this
    script with -RunStep <name> per step, waits for it, and reads a small JSON
    result back from a temp run directory (printed at the start and end of the
    run). That keeps each step's noisy output - winget's table redraws, the
    DISM progress bar, Optimize-Volume -Verbose - in a separate window and a
    per-step output.log, leaving the orchestrator window a clean progress list.
    A step window closes a few seconds after a successful step and stays open
    (waiting for Enter) on failure; -KeepStepWindows keeps every step window
    open.

    The script does not require elevation to start. If it is launched without
    Administrator and any step that needs it (Windows Update, winget system
    pass, Disk Cleanup, defrag) is going to run, the script relaunches itself elevated in a new
    console (one UAC prompt), runs there, and exits with that run's exit code;
    the elevated window stays open at the end so its output is readable. Pass
    -NoElevate to suppress the relaunch - the admin-only steps are then marked
    SKIP (not FAIL) and the run exits non-zero. The winget user pass
    never runs elevated.

      1. Windows Update
         Scans, downloads, and installs all applicable updates via the
         PSWindowsUpdate module. If that module is not installed it is pulled
         from the PowerShell Gallery on first run (Install-Module, CurrentUser
         scope; the NuGet package provider is bootstrapped first if needed).
         Automatic reboots are suppressed (-IgnoreReboot); a resulting pending
         reboot is reported in the summary but not acted on.

      2. winget upgrade --all --include-unknown  (two passes)
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

         If a WSL distribution is running, the WSL package (Microsoft.WSL) is
         also excluded from the upgrade (--exclude) - upgrading it runs
         "wsl --shutdown" and would drop live sessions. If this winget build
         has no --exclude: a configured ignore list is skipped with a
         warning and the upgrade proceeds anyway; a pending WSL upgrade
         instead marks the whole step SKIP, since dropping a live session is
         worse than an unexcluded package.

      3. Disk Cleanup (C:) + component store
         Enables every Disk Cleanup handler except "Downloads Folder" by
         writing StateFlags<profile> under ...\Explorer\VolumeCaches, runs
         "cleanmgr /sagerun:<profile>" and waits for it to finish, then runs
         "DISM /Online /Cleanup-Image /StartComponentCleanup" to trim the
         WinSxS component store. cleanmgr operates on every fixed drive, not
         just C:, and this empties the Recycle Bin.

      4. Optimize / defrag all volumes
         Runs Optimize-Volume on every fixed NTFS/ReFS volume that has a drive
         letter. No operation switch is passed, so Windows performs the
         media-appropriate optimization per volume - full defragmentation on
         HDDs, retrim on SSDs, slab consolidation on thin-provisioned storage -
         the same as the built-in "Optimize Drives" task and "defrag /O".

      5. Driver updates  (only with -DriverUpdate)
         Installs driver updates offered through Windows Update
         (Get-WindowsUpdate -UpdateType Driver, same PSWindowsUpdate module as
         step 1). This is the "verified drivers only" path: every driver on
         Windows Update is WHQL-certified and submitted by the hardware vendor
         through Microsoft's Hardware Dev Center - unlike Driver Booster and
         similar tools, which pull from their own unvetted repositories. Off by
         default because driver updates carry more regression risk than
         software updates; reboots are suppressed and reported like step 1.

.PARAMETER DriverUpdate
    Also install driver updates offered through Windows Update (WHQL-signed,
    vendor-submitted - see step 5). Off by default.

.PARAMETER SkipWindowsUpdate
    Skip step 1 (Windows Update).

.PARAMETER SkipWinget
    Skip step 2 (winget upgrade).

.PARAMETER SkipDiskCleanup
    Skip step 3 (cleanmgr + DISM component cleanup).

.PARAMETER SkipDefrag
    Skip step 4 (Optimize-Volume).

.PARAMETER SagerunProfile
    The Disk Cleanup "sageset/sagerun" profile number used for the StateFlags
    registry values and "cleanmgr /sagerun:N". Default 100. Change it only if
    that profile number is already configured for something else on this box.

.PARAMETER KeepStepWindows
    Keep every per-step console window open until dismissed (press Enter),
    instead of auto-closing a few seconds after a successful step.

.PARAMETER NoElevate
    Do not relaunch elevated when an admin-only step is due to run. Those steps
    are skipped instead and the run exits non-zero. Use this for unattended
    runs where a UAC prompt cannot be answered.

.PARAMETER Relaunched
    Internal. Set by the script on its own elevated relaunch; keeps the
    orchestrator window open at the end. Not meant to be passed by hand.

.PARAMETER RunStep
    Internal. Names the single step to run in this process (the orchestrator
    sets this when launching a step's console window). Not meant to be passed
    by hand.

.PARAMETER RunDir
    Internal. The temp run directory a -RunStep child reads/writes (result JSON
    and output.log). Set by the orchestrator.

.NOTES
    Requirements: Windows 10 / 11 (or matching Server), PowerShell 5.1+. No
    #Requires -RunAsAdministrator: the script self-elevates when a step needs
    it (see .DESCRIPTION), or with -NoElevate skips those steps. Per step:
      - Windows Update (needs Administrator): internet access; PSWindowsUpdate
        (auto-installed from PSGallery via Install-Module if absent - this also
        registers the NuGet provider and may prompt once to trust PSGallery on
        a locked-down host).
      - winget: App Installer / winget (in-box on Windows 11 and current
        Windows 10). The system pass needs Administrator; the user pass is
        de-elevated (runas.exe /trustlevel when the script is elevated). The WSL
        hold-back also calls wsl.exe (with WSL_UTF8=1) to see if a distro is
        running. Optional winget_ignore.txt next to the script (see
        winget_ignore.sample.txt) excludes listed package Ids from the
        upgrade.
      - Disk Cleanup (needs Administrator): cleanmgr.exe (an optional Feature on
        Server SKUs) and DISM - the step carries on if cleanmgr is missing.
      - Optimize-Volume (needs Administrator): the Storage module (in-box).
      - Driver updates (-DriverUpdate, needs Administrator): same requirements
        as Windows Update (internet, PSWindowsUpdate).

    This script never reboots. After a Windows Update or driver-update run that
    reports a pending reboot, restart the machine yourself to finish it.
#>

#Requires -Version 5.1

[CmdletBinding()]
param(
    [switch]$DriverUpdate,

    [switch]$SkipWindowsUpdate,
    [switch]$SkipWinget,
    [switch]$SkipDiskCleanup,
    [switch]$SkipDefrag,

    [ValidateRange(0, 65535)]
    [int]$SagerunProfile = 100,

    [switch]$KeepStepWindows,
    [switch]$NoElevate,

    # Internal - set by the script when it relaunches itself.
    [switch]$Relaunched,
    [ValidateSet('WindowsUpdate', 'DriverUpdate', 'Winget', 'WingetSystem', 'DiskCleanup', 'Defrag')]
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
# one-line result by assigning $script:StepDetail; $script:RebootRequired flags
# a pending reboot. In -RunStep mode both are serialised to the result file.
#
# Outcomes are collected, never aborting the run on one failure (mirrors the
# bash FAILED=() convention), and summarised at the end.
# ---------------------------------------------------------------------------

$script:Results = [System.Collections.Generic.List[psobject]]::new()
$script:RebootRequired = $false
$script:SkippedForAdmin = $false
$script:IsAdmin = $false
$script:StepDetail = ''
$script:StepStatus = 'OK'
$script:StepCount = if ($DriverUpdate) { 6 } else { 5 }
$script:HostExe = (Get-Process -Id $PID).Path
if ([string]::IsNullOrEmpty($script:HostExe)) {
    $script:HostExe = 'powershell.exe'
}

function Test-Administrator {
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
        [Parameter(Mandatory)] [ValidateSet('WindowsUpdate', 'DriverUpdate', 'Winget', 'WingetSystem', 'DiskCleanup', 'Defrag')] [string] $Step,
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
        [Parameter(Mandatory)] [ValidateSet('WindowsUpdate', 'DriverUpdate', 'Winget', 'WingetSystem', 'DiskCleanup', 'Defrag')] [string] $Step,
        [Parameter(Mandatory)] [string] $RunDir,
        [Parameter(Mandatory)] [int] $SagerunProfile,
        [switch] $KeepOpen
    )

    $title = @{
        WindowsUpdate = 'Windows Update'
        DriverUpdate  = 'Driver updates (Windows Update)'
        Winget        = 'winget upgrade --all (user)'
        WingetSystem  = 'winget upgrade --all (system, elevated)'
        DiskCleanup   = 'Disk Cleanup (C:) + WinSxS'
        Defrag        = 'Optimize / defrag volumes'
    }[$Step]

    $stepDir = Join-Path $RunDir $Step
    New-Item -ItemType Directory -Path $stepDir -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $stepDir 'pid.txt') -Value $PID

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
            'DiskCleanup' { Invoke-DiskCleanup -SagerunProfile $SagerunProfile }
            'Defrag' { Invoke-VolumeOptimization }
        }
        # A step may down-grade itself to SKIP (e.g. winget holding back a WSL
        # upgrade while WSL is running).
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
# Step 1: Windows Update (via PSWindowsUpdate)
# ---------------------------------------------------------------------------

function Initialize-PSWindowsUpdate {
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

function Invoke-WindowsUpdate {
    Initialize-PSWindowsUpdate

    # -Install runs scan + download + install in one call; -AcceptAll answers
    # the per-update prompt; -IgnoreReboot suppresses the automatic restart.
    $applied = @(
        Get-WindowsUpdate -AcceptAll -Install -IgnoreReboot -Confirm:$false -Verbose -ErrorAction Stop
    )

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
# Step 2: winget upgrade --all --include-unknown
# ---------------------------------------------------------------------------

function Resolve-Winget {
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
    }
    catch {
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
    param([Parameter(Mandatory)] [string] $Winget)
    try {
        $help = & $Winget upgrade --help 2>$null
    }
    catch {
        return $false
    }
    return (($help -join "`n") -match '--exclude')
}

function Test-WingetUpgradeAvailable {
    param(
        [Parameter(Mandatory)] [string] $Winget,
        [Parameter(Mandatory)] [string] $Id
    )
    try {
        $out = & $Winget list --id $Id --exact --upgrade-available `
            --disable-interactivity --accept-source-agreements 2>$null
    }
    catch {
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
    # "wsl --shutdown" and would drop live sessions.
    $wslPackageId = 'Microsoft.WSL'
    $wslUpgradePending = (Test-WslRunning) -and (Test-WingetUpgradeAvailable -Winget $winget -Id $wslPackageId)

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
# Step 3: Disk Cleanup (C:) + WinSxS component store
# ---------------------------------------------------------------------------

function Invoke-DiskCleanup {
    param(
        [Parameter(Mandatory)] [int] $SagerunProfile
    )

    $ran = [System.Collections.Generic.List[string]]::new()

    $cleanmgr = Join-Path $env:SystemRoot 'System32\cleanmgr.exe'
    if (-not (Test-Path -LiteralPath $cleanmgr)) {
        Write-Warning 'cleanmgr.exe not present (optional Feature on Server SKUs); skipping the /sagerun pass.'
    }
    else {
        # The "Downloads Folder" handler empties %USERPROFILE%\Downloads - never
        # enable it from a script (the Disk Cleanup UI leaves it unchecked too).
        # Add other handler key names here to keep them disabled.
        $excluded = @('DownloadsFolder')

        $flag = 'StateFlags{0:D4}' -f $SagerunProfile
        $caches = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\VolumeCaches'
        $handlers = @(Get-ChildItem -LiteralPath $caches -ErrorAction Stop)
        foreach ($handler in $handlers) {
            # 2 = enabled for this profile, 0 = disabled.
            $value = if ($excluded -contains $handler.PSChildName) { 0 } else { 2 }
            New-ItemProperty -LiteralPath $handler.PSPath -Name $flag -PropertyType DWord `
                -Value $value -Force | Out-Null
        }
        Write-Output "Configured $($handlers.Count) cleanup handler(s) for /sagerun:$SagerunProfile (Downloads excluded)."

        # /sagerun can hand work to child processes and return early, so wait for
        # the process we start and then for any lingering cleanmgr / dismhost.
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

    $script:StepDetail = ($ran -join ', ')
}

# ---------------------------------------------------------------------------
# Step 4: Optimize / defrag all fixed volumes
# ---------------------------------------------------------------------------

function Invoke-VolumeOptimization {
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
    foreach ($volume in $targets) {
        $letter = [string]$volume.DriveLetter
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
    $script:StepDetail = "optimized $($optimized -join ' ')"
}

# ---------------------------------------------------------------------------
# Run
# ---------------------------------------------------------------------------

$script:SelfPath = $PSCommandPath
$script:SagerunProfile = $SagerunProfile
$script:KeepStepWindows = [bool]$KeepStepWindows

$script:IsAdmin = Test-Administrator

# Child mode: this process was launched by the orchestrator to run one step.
if ($RunStep) {
    if ([string]::IsNullOrEmpty($RunDir)) {
        Write-Error '-RunStep requires -RunDir.'
        exit 1
    }
    Invoke-MaintenanceStep -Step $RunStep -RunDir $RunDir -SagerunProfile $SagerunProfile -KeepOpen:$KeepStepWindows
    exit 1  # Invoke-MaintenanceStep always exits; this is just a guard.
}

# Self-elevate: if an admin-only step (Windows Update / driver updates / Disk
# Cleanup / defrag) is going to run and we are not elevated, relaunch the whole
# script elevated in a new console and mirror its exit code. -NoElevate opts out
# (the steps are then skipped by the -RequiresAdmin gate in Invoke-Step). Step
# windows spawned later inherit this elevation - no further UAC prompts.
$adminStepDue = $DriverUpdate -or -not ($SkipWindowsUpdate -and $SkipWinget -and $SkipDiskCleanup -and $SkipDefrag)
if (-not $script:IsAdmin -and $adminStepDue -and -not $NoElevate) {
    Write-Output 'Windows Update / winget (system) / driver updates / Disk Cleanup / defrag need Administrator - relaunching elevated (a UAC prompt will appear)...'

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
    Write-Warning '-NoElevate and not elevated - Windows Update, winget (system), driver updates, Disk Cleanup and defrag will be skipped.'
}

Invoke-Step -Name 'Windows Update'             -Step WindowsUpdate -Skip:$SkipWindowsUpdate -RequiresAdmin
Invoke-Step -Name 'winget upgrade (user)'      -Step Winget        -Skip:$SkipWinget        -Unelevated
Invoke-Step -Name 'winget upgrade (system)'    -Step WingetSystem  -Skip:$SkipWinget        -RequiresAdmin
Invoke-Step -Name 'Disk Cleanup (C:) + WinSxS' -Step DiskCleanup   -Skip:$SkipDiskCleanup   -RequiresAdmin
Invoke-Step -Name 'Optimize / defrag volumes'  -Step Defrag        -Skip:$SkipDefrag        -RequiresAdmin
if ($DriverUpdate) {
    Invoke-Step -Name 'Driver updates (Windows Update)' -Step DriverUpdate -RequiresAdmin
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

if ($exitCode -eq 0) {
    Write-Output 'All requested maintenance steps completed successfully.'
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

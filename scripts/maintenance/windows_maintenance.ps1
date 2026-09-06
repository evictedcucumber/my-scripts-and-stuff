<#
.SYNOPSIS
    Runs a batch of Windows maintenance tasks in one pass: Windows Update,
    winget upgrades, Disk Cleanup on C:, and per-volume optimization
    (defrag / retrim).

.DESCRIPTION
    Runs the steps below in order. Each step is independent - a failure is
    caught, logged, and the run continues - and an OK / FAIL / SKIP summary is
    printed at the end. The script exits non-zero if any step failed. It never
    reboots.

    The script does not require elevation to start. If it is launched without
    Administrator and any step that needs it (Windows Update, Disk Cleanup,
    defrag) is going to run, the script relaunches itself elevated in a new
    console (one UAC prompt), runs there, and exits with that run's exit code;
    the elevated window stays open at the end so its output is readable. Pass
    -NoElevate to suppress the relaunch - the admin-only steps are then marked
    SKIP (not FAIL) and the run exits non-zero. The winget step needs no
    elevation of its own (without it, winget upgrades user-scope packages
    only).

      1. Windows Update
         Scans, downloads, and installs all applicable updates via the
         PSWindowsUpdate module. If that module is not installed it is pulled
         from the PowerShell Gallery on first run (Install-Module, CurrentUser
         scope; the NuGet package provider is bootstrapped first if needed).
         Automatic reboots are suppressed (-IgnoreReboot); a resulting pending
         reboot is reported in the summary but not acted on.

      2. winget upgrade --all --include-unknown
         Run non-interactively with --accept-source-agreements,
         --accept-package-agreements and --disable-interactivity. winget's
         "no applicable upgrades" result (0x8A15002B) is treated as success.
         When elevated, any other non-zero exit fails the step; when not
         elevated it is downgraded to a warning, since winget cannot upgrade
         machine-scope packages without Administrator.

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

.PARAMETER NoElevate
    Do not relaunch elevated when an admin-only step is due to run. Those steps
    are skipped instead and the run exits non-zero. Use this for unattended
    runs where a UAC prompt cannot be answered.

.PARAMETER Relaunched
    Internal. Set by the script on its own elevated relaunch; keeps the new
    console window open at the end. Not meant to be passed by hand.

.NOTES
    Requirements: Windows 10 / 11 (or matching Server), PowerShell 5.1+. No
    #Requires -RunAsAdministrator: the script self-elevates when a step needs
    it (see .DESCRIPTION), or with -NoElevate skips those steps. Per step:
      - Windows Update (needs Administrator): internet access; PSWindowsUpdate
        (auto-installed from PSGallery via Install-Module if absent - this also
        registers the NuGet provider and may prompt once to trust PSGallery on
        a locked-down host).
      - winget: App Installer / winget (in-box on Windows 11 and current
        Windows 10). Machine-scope upgrades need Administrator.
      - Disk Cleanup (needs Administrator): cleanmgr.exe (an optional Feature on
        Server SKUs) and DISM - the step carries on if cleanmgr is missing.
      - Optimize-Volume (needs Administrator): the Storage module (in-box).

    This script never reboots. After a Windows Update run that reports a
    pending reboot, restart the machine yourself to finish installation.
#>

#Requires -Version 5.1

[CmdletBinding()]
param(
    [switch]$SkipWindowsUpdate,
    [switch]$SkipWinget,
    [switch]$SkipDiskCleanup,
    [switch]$SkipDefrag,

    [ValidateRange(0, 65535)]
    [int]$SagerunProfile = 100,

    [switch]$NoElevate,
    [switch]$Relaunched
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Step runner - mirrors the bash FAILED=() convention: one step's failure
# never aborts the run, outcomes are collected and summarised at the end.
#
# A step function streams its own progress with Write-Output and reports its
# one-line result by assigning $script:StepDetail (returning it would fold the
# streamed progress lines into the result and stop them printing live).
# ---------------------------------------------------------------------------

$script:Results = [System.Collections.Generic.List[psobject]]::new()
$script:RebootRequired = $false
$script:SkippedForAdmin = $false
$script:IsAdmin = $false
$script:StepDetail = ''

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

function Invoke-Step {
    param(
        [Parameter(Mandatory)] [string] $Name,
        [Parameter(Mandatory)] [scriptblock] $Action,
        [switch] $Skip,
        [switch] $RequiresAdmin
    )

    Write-Output ''
    Write-Output ('=' * 72)
    Write-Output "  $Name"
    Write-Output ('=' * 72)

    if ($Skip) {
        Write-Output 'Skipped (-Skip... switch).'
        $script:Results.Add([pscustomobject]@{ Step = $Name; Status = 'SKIP'; Detail = 'requested' })
        return
    }

    if ($RequiresAdmin -and -not $script:IsAdmin) {
        Write-Warning 'Needs an elevated session; skipping. Re-run from an Administrator prompt to include this step.'
        $script:SkippedForAdmin = $true
        $script:Results.Add([pscustomobject]@{ Step = $Name; Status = 'SKIP'; Detail = 'needs Administrator (not elevated)' })
        return
    }

    $script:StepDetail = ''
    $start = Get-Date
    try {
        & $Action
        $span = (Get-Date) - $start
        Write-Output ('-> OK  ({0:hh\:mm\:ss})  {1}' -f $span, $script:StepDetail)
        $script:Results.Add([pscustomobject]@{ Step = $Name; Status = 'OK'; Detail = $script:StepDetail })
    }
    catch {
        $span = (Get-Date) - $start
        $message = $_.Exception.Message
        Write-Warning ('-> FAILED  ({0:hh\:mm\:ss})  {1}' -f $span, $message)
        $script:Results.Add([pscustomobject]@{ Step = $Name; Status = 'FAIL'; Detail = $message })
    }
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

function Invoke-WingetUpgrade {
    $winget = Resolve-Winget
    if (-not $winget) {
        throw 'winget (App Installer) not found. Install it from the Microsoft Store or https://aka.ms/getwinget.'
    }

    if (-not $script:IsAdmin) {
        Write-Warning 'Not elevated: winget will upgrade user-scope packages only; machine-scope packages need Administrator.'
    }

    $wingetArgs = @(
        'upgrade'
        '--all'
        '--include-unknown'
        '--accept-source-agreements'
        '--accept-package-agreements'
        '--disable-interactivity'
    )

    Write-Output "$winget $($wingetArgs -join ' ')"
    & $winget @wingetArgs
    $code = $LASTEXITCODE

    # 0x8A15002B / -1978335189 = APPINSTALLER_CLI_ERROR_UPDATE_NOT_APPLICABLE:
    # there was nothing to upgrade.
    $noApplicableUpgrades = -1978335189
    if ($code -eq 0) {
        $script:StepDetail = 'winget upgrades applied'
        return
    }
    if ($code -eq $noApplicableUpgrades) {
        $script:StepDetail = 'nothing to upgrade'
        return
    }

    $hex = '0x{0:X8}' -f ($code -band 0xFFFFFFFF)
    if (-not $script:IsAdmin) {
        # Without elevation winget still upgrades user-scope packages but errors
        # on machine-scope ones - and there is no clean way to tell that apart
        # from a genuine failure, so downgrade it to a warning rather than
        # failing the step.
        Write-Warning "winget exited $code ($hex); machine-scope upgrades need an elevated session."
        $script:StepDetail = "user-scope only; winget exit $hex (re-run elevated for machine-scope)"
        return
    }
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

$script:IsAdmin = Test-Administrator

# Self-elevate: if an admin-only step (Windows Update / Disk Cleanup / defrag)
# is going to run and we are not elevated, relaunch the whole script elevated
# in a new console and mirror its exit code. -NoElevate opts out (the steps are
# then skipped by the -RequiresAdmin gate in Invoke-Step).
$adminStepDue = -not ($SkipWindowsUpdate -and $SkipDiskCleanup -and $SkipDefrag)
if (-not $script:IsAdmin -and $adminStepDue -and -not $NoElevate) {
    Write-Output 'Windows Update / Disk Cleanup / defrag need Administrator - relaunching elevated (a UAC prompt will appear)...'

    $hostExe = (Get-Process -Id $PID).Path
    if ([string]::IsNullOrEmpty($hostExe)) {
        $hostExe = 'powershell.exe'
    }

    $childArgs = @(
        '-NoProfile'
        '-ExecutionPolicy'
        'Bypass'
        '-File'
        (Format-ProcessArgument $PSCommandPath)
        '-Relaunched'
    )
    foreach ($entry in $PSBoundParameters.GetEnumerator()) {
        if ($entry.Key -eq 'Relaunched' -or $entry.Key -eq 'NoElevate') {
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
        $child = Start-Process -FilePath $hostExe -ArgumentList $childArgs `
            -Verb RunAs -Wait -PassThru -ErrorAction Stop
    }
    catch {
        Write-Error ("Could not elevate ({0}). Re-run from an elevated prompt, or pass -NoElevate to skip the admin-only steps." -f $_.Exception.Message)
        exit 1
    }
    exit ([int]$child.ExitCode)
}

$overallStart = Get-Date
Write-Output "Windows maintenance run - $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
Write-Output "Host: $env:COMPUTERNAME   User: $env:USERNAME   Elevated: $script:IsAdmin   Disk Cleanup profile: $SagerunProfile"
if (-not $script:IsAdmin -and $adminStepDue) {
    Write-Warning '-NoElevate and not elevated - Windows Update, Disk Cleanup and defrag will be skipped.'
}

Invoke-Step -Name 'Windows Update'               -Skip:$SkipWindowsUpdate -RequiresAdmin -Action { Invoke-WindowsUpdate }
Invoke-Step -Name 'winget upgrade --all'         -Skip:$SkipWinget                       -Action { Invoke-WingetUpgrade }
Invoke-Step -Name 'Disk Cleanup (C:) + WinSxS'   -Skip:$SkipDiskCleanup   -RequiresAdmin -Action { Invoke-DiskCleanup -SagerunProfile $SagerunProfile }
Invoke-Step -Name 'Optimize / defrag volumes'    -Skip:$SkipDefrag        -RequiresAdmin -Action { Invoke-VolumeOptimization }

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

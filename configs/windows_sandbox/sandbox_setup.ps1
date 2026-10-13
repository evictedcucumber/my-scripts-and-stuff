<#
.SYNOPSIS
    Sets up a fresh Windows Sandbox: dark mode, winget, and the Microsoft Store.

.DESCRIPTION
    Run automatically at logon by windows_sandbox.wsb (from the read-only mapped
    folder C:\sandbox_setup). Do not run it on a real machine: it changes the
    current user's theme and region and installs system packages.

    Steps, in order. A failing step is reported and skipped, and the rest still
    run:
      1. Dark mode: sets AppsUseLightTheme / SystemUsesLightTheme to 0 under
         HKCU\...\Themes\Personalize.
      2. winget: installs the Microsoft.WinGet.Client module from PSGallery and
         bootstraps winget with Repair-WinGetPackageManager -AllUsers. This is
         the method Microsoft documents for Windows Sandbox.
      3. Microsoft Store: downloads ThioJoe's Install-Microsoft-Store.ps1 at a
         pinned commit, checks its SHA256, and runs it. That script fetches the
         Store and its dependencies straight from Microsoft's Windows Update
         delivery service and installs them with Add-AppxPackage. It also sets
         the region to US, because the Store won't work with the sandbox's
         default "World" region.
      4. Restarts explorer.exe so the taskbar and Start pick up dark mode.

    The output is also logged to the desktop as sandbox_setup.log.

.NOTES
    Requirements: Windows Sandbox (Windows 11 23H2+, for the environment
    variable in the .wsb HostFolder path), Windows PowerShell 5.1, and network
    access (on by default in the sandbox) to the PowerShell Gallery, GitHub and
    Microsoft's update CDN. Runs as the sandbox's WDAGUtilityAccount, which is
    an administrator.
#>

#Requires -Version 5.1

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'   # Invoke-WebRequest is very slow with the progress bar on

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------

# Pinned so the downloaded script can't change underneath us. When bumping the
# commit, re-check the script and update the hash. Source:
# https://github.com/ThioJoe/Windows-Sandbox-Tools/blob/<commit>/Installer%20Scripts/Install-Microsoft-Store.ps1
$StoreScriptCommit = 'c4b68ac6bfd99fcd109aee9f236e561f868b2f68'
$StoreScriptSha256 = 'EA370118B190AAEF260ECE514722130E8104736A8853866D24B7E3296BA7CFF9'
$StoreScriptUrl = "https://raw.githubusercontent.com/ThioJoe/Windows-Sandbox-Tools/$StoreScriptCommit/Installer%20Scripts/Install-Microsoft-Store.ps1"

$LogPath = Join-Path ([Environment]::GetFolderPath('Desktop')) 'sandbox_setup.log'

# ---------------------------------------------------------------------------
# Steps
# ---------------------------------------------------------------------------

function Enable-DarkMode {
    $key = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize'
    if (-not (Test-Path $key)) {
        New-Item -Path $key -Force | Out-Null
    }
    Set-ItemProperty -Path $key -Name AppsUseLightTheme -Value 0 -Type DWord
    Set-ItemProperty -Path $key -Name SystemUsesLightTheme -Value 0 -Type DWord
}

function Install-Winget {
    Install-PackageProvider -Name NuGet -Force | Out-Null
    Install-Module -Name Microsoft.WinGet.Client -Force -Repository PSGallery | Out-Null
    Repair-WinGetPackageManager -AllUsers

    # The App Installer alias lives here, and this session's PATH may predate it.
    $winget = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\winget.exe'
    $version = & $winget --version
    if ($LASTEXITCODE -ne 0) {
        throw "winget --version exited with $LASTEXITCODE"
    }
    Write-Output "winget $version installed."
}

function Install-MicrosoftStore {
    $scratch = Join-Path $env:TEMP 'msstore_install'
    New-Item -ItemType Directory -Path $scratch -Force | Out-Null
    $installer = Join-Path $scratch 'Install-Microsoft-Store.ps1'

    Invoke-WebRequest -Uri $StoreScriptUrl -OutFile $installer -UseBasicParsing
    $hash = (Get-FileHash -Path $installer -Algorithm SHA256).Hash
    if ($hash -ne $StoreScriptSha256) {
        throw "Install-Microsoft-Store.ps1 hash mismatch: expected $StoreScriptSha256, got $hash"
    }

    # Run it in its own process: it calls `exit` and may Read-Host on errors,
    # and neither should end or stall this script's remaining steps.
    $proc = Start-Process -FilePath powershell.exe -Wait -PassThru -NoNewWindow -WorkingDirectory $scratch `
        -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$installer`"")
    if ($proc.ExitCode -ne 0) {
        throw "Install-Microsoft-Store.ps1 exited with $($proc.ExitCode)"
    }

    # The Store script doesn't always fail with a nonzero exit code, so check the
    # result directly.
    if (-not (Get-AppxPackage -Name Microsoft.WindowsStore)) {
        throw 'Microsoft.WindowsStore is not installed after running the installer'
    }
    Write-Output 'Microsoft Store installed.'
}

function Invoke-ExplorerRestart {
    Stop-Process -Name explorer -Force
    # Explorer usually respawns by itself; start it only if it hasn't.
    Start-Sleep -Seconds 3
    if (-not (Get-Process -Name explorer -ErrorAction SilentlyContinue)) {
        Start-Process explorer.exe
    }
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

Start-Transcript -Path $LogPath -Append | Out-Null

$steps = [ordered]@{
    'Enable dark mode'        = ${function:Enable-DarkMode}
    'Install winget'          = ${function:Install-Winget}
    'Install Microsoft Store' = ${function:Install-MicrosoftStore}
    'Restart Explorer'        = ${function:Invoke-ExplorerRestart}
}

$failed = [System.Collections.Generic.List[string]]::new()
foreach ($name in $steps.Keys) {
    Write-Output "==> $name"
    try {
        & $steps[$name]
    } catch {
        Write-Warning "$name failed: $($_.Exception.Message)"
        $failed.Add($name)
    }
}

Write-Output ''
if ($failed.Count -gt 0) {
    Write-Warning "Setup finished with failures: $($failed -join ', '). Log: $LogPath"
} else {
    Write-Output "Setup complete. Log: $LogPath"
}

Stop-Transcript | Out-Null

if ($failed.Count -gt 0) {
    exit 1
}

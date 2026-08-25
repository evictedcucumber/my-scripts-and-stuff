<#
.SYNOPSIS
    Attaches a connected YubiKey to WSL via usbipd-win.

.DESCRIPTION
    Looks up the USB device matching a YubiKey VID:PID in `usbipd list` output
    and, if found and not already attached, attaches it to WSL with
    `usbipd attach --wsl`. Run from an elevated Windows PowerShell prompt
    whenever the YubiKey needs to become visible inside WSL (usbipd attach
    requires Administrator).

.NOTES
    Requirements: usbipd-win (https://github.com/dorssel/usbipd-win), run elevated.
#>

#Requires -RunAsAdministrator

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------

# Yubico YubiKey 5-series VID:PID
$VidPid = '1050:0407'

# ---------------------------------------------------------------------------
# Sanity checks
# ---------------------------------------------------------------------------

if (-not (Get-Command usbipd -ErrorAction SilentlyContinue)) {
    Write-Error "Required command 'usbipd' not found in PATH. Install usbipd-win: https://github.com/dorssel/usbipd-win"
    exit 1
}

# ---------------------------------------------------------------------------
# Find and attach the device
# ---------------------------------------------------------------------------

$deviceLines = @(usbipd list | Select-String -SimpleMatch $VidPid)

if ($deviceLines.Count -eq 0) {
    Write-Output "YubiKey ($VidPid) not found."
    exit 0
}

if ($deviceLines.Count -gt 1) {
    Write-Warning "Multiple devices matched $VidPid; using the first one."
}

$fields = ($deviceLines[0].Line -split '\s+')
$busId = $fields[0]
$state = $fields[-1]

if ($state -eq 'Attached') {
    Write-Output "YubiKey already attached to WSL (busid $busId)."
    exit 0
}

usbipd attach --wsl --busid $busId
if ($LASTEXITCODE -ne 0) {
    Write-Error "usbipd attach failed for busid $busId (exit code $LASTEXITCODE)."
    exit 1
}

Write-Output "YubiKey attached to WSL with busid $busId."

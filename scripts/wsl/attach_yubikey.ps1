<#
.SYNOPSIS
    Attaches a connected YubiKey to WSL via usbipd-win.

.DESCRIPTION
    Looks up the USB device matching a YubiKey VID:PID in `usbipd list` output
    and, if found and not already attached, attaches it to WSL with
    `usbipd attach --wsl`. If the device has never been shared it is bound
    first (`usbipd bind`, a one-time persistent operation). Run from an
    elevated Windows PowerShell prompt whenever the YubiKey needs to become
    visible inside WSL (usbipd bind/attach require Administrator).

.NOTES
    Requirements: usbipd-win (https://github.com/dorssel/usbipd-win), run elevated.
#>

#Requires -RunAsAdministrator

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------

# Yubico YubiKey 5-series VID:PID (OTP+FIDO+CCID). Adjust for your key's
# enabled interfaces if it differs.
$VidPid = '1050:0407'

# ---------------------------------------------------------------------------
# Sanity checks
# ---------------------------------------------------------------------------

if (-not (Get-Command usbipd -ErrorAction SilentlyContinue)) {
    Write-Error "Required command 'usbipd' not found in PATH. Install usbipd-win: https://github.com/dorssel/usbipd-win"
    exit 1
}

# ---------------------------------------------------------------------------
# Find the device
# ---------------------------------------------------------------------------

$listOutput = usbipd list
if ($LASTEXITCODE -ne 0) {
    Write-Error "'usbipd list' failed (exit code $LASTEXITCODE)."
    exit 1
}

$deviceLines = @($listOutput | Select-String -SimpleMatch $VidPid)

if ($deviceLines.Count -eq 0) {
    Write-Output "YubiKey ($VidPid) not found."
    exit 0
}

if ($deviceLines.Count -gt 1) {
    Write-Warning "Multiple devices matched $VidPid; using the first one."
}

# usbipd list columns: BUSID  VID:PID  DEVICE (may contain spaces)  STATE.
# Trim first so a leading-space format wouldn't shift the bus id, and read
# the state from the whole line rather than the last whitespace token (STATE
# can be multi-word, e.g. "Not shared").
$line = $deviceLines[0].Line.Trim()
$busId = ($line -split '\s+')[0]

if ($busId -notmatch '^[0-9]+-[0-9]+(\.[0-9]+)*$') {
    Write-Error "Could not parse bus id from usbipd list line: $line"
    exit 1
}

if ($line -match '\bAttached\b') {
    Write-Output "YubiKey already attached to WSL (busid $busId)."
    exit 0
}

# ---------------------------------------------------------------------------
# Bind (one-time) then attach
# ---------------------------------------------------------------------------

if ($line -match '\bNot shared\b') {
    Write-Output "YubiKey (busid $busId) is not shared; binding it now (one-time, persistent)..."
    usbipd bind --busid $busId
    if ($LASTEXITCODE -ne 0) {
        Write-Error "usbipd bind failed for busid $busId (exit code $LASTEXITCODE)."
        exit 1
    }
}

usbipd attach --wsl --busid $busId
if ($LASTEXITCODE -ne 0) {
    Write-Error "usbipd attach failed for busid $busId (exit code $LASTEXITCODE)."
    exit 1
}

Write-Output "YubiKey attached to WSL with busid $busId."

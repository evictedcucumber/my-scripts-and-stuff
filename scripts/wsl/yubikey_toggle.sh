#!/usr/bin/env bash
#
# yubikey_toggle.sh
#
# Manually toggle a YubiKey between Windows and WSL using usbipd-win.
#
# With no arguments: if the key is attached to WSL it is detached (handed back
# to Windows), otherwise it is attached to WSL.
#
# Usage:
#   yubikey_toggle.sh [--wsl | attach | --windows | detach | --status | -h]
#
# Options:
#   (none)              Toggle: attached -> detach, otherwise attach.
#   --wsl, attach       Attach the key to WSL (no-op if already attached).
#   --windows, detach   Detach the key back to Windows (no-op if not attached).
#   --status            Print where the key is: WSL, Windows or not connected.
#   -h, --help          Show this help.
#
# Environment:
#   USBIPD           Path to usbipd.exe
#                    (default: /mnt/c/Program Files/usbipd-win/usbipd.exe).
#   YUBIKEY_VIDPID   VID:PID of the key (default: 1050:0407).
#
# Notes:
#   - The key is exclusive: while it is in WSL, Windows cannot use it.
#   - The brief freeze happens at toggle time (the driver swap) rather than on
#     every insert.
#   - The first attach needs `usbipd bind`, which requires Administrator; this
#     script runs it via PowerShell with elevation, triggering one UAC prompt
#     (one-time, the share persists).
#   - The old AttachYubiKeyToWSL scheduled task must be removed (elevated
#     PowerShell: register_yubikey_attach_task.ps1 -Remove) or it will keep
#     auto-attaching the key on insert.
#
# Requirements: WSL2 with Windows interop, usbipd-win 4+ on Windows, jq,
# wslpath. powershell.exe is used only for the elevated bind.

set -euo pipefail

USBIPD="${USBIPD:-/mnt/c/Program Files/usbipd-win/usbipd.exe}"
VIDPID="${YUBIKEY_VIDPID:-1050:0407}"
POWERSHELL="/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe"

usage() {
  sed -n '3,/^# Requirements/{s/^# \{0,1\}//;p}' "${BASH_SOURCE[0]}"
}

die() {
  echo "Error: $*" >&2
  exit 1
}

# Print "<connected> <attached> <shared>" as true/false words.
read_state() {
  local json instance
  instance="VID_${VIDPID%%:*}&PID_${VIDPID##*:}"
  json="$("$USBIPD" state | tr -d '\r')" || die "usbipd state failed"
  jq -r --arg id "$instance" '
    [.Devices[]
      | select(.BusId != null)
      | select(.InstanceId | ascii_upcase | contains($id | ascii_upcase))]
    | if length == 0 then "false false false"
      else "true \(.[0].ClientIPAddress != null) \(.[0].PersistedGuid != null)" end
  ' <<<"$json" || die "could not parse usbipd state"
}

load_state() {
  local out
  out="$(read_state)"
  read -r CONNECTED ATTACHED SHARED <<<"$out"
}

status() {
  load_state
  if [[ "$CONNECTED" != true ]]; then
    echo "YubiKey ($VIDPID) not connected"
  elif [[ "$ATTACHED" == true ]]; then
    echo "YubiKey ($VIDPID) is attached to WSL"
  else
    echo "YubiKey ($VIDPID) is on Windows"
  fi
}

bind_key() {
  local win_path
  win_path="$(wslpath -w "$USBIPD")"
  echo "Sharing the YubiKey with usbipd (one-time; a UAC prompt will appear)..."
  "$POWERSHELL" -NoProfile -Command \
    "Start-Process -FilePath '$win_path' -ArgumentList 'bind','--hardware-id','$VIDPID' -Verb RunAs -Wait -WindowStyle Hidden" \
    || die "elevated usbipd bind failed"
}

do_attach() {
  load_state
  [[ "$CONNECTED" == true ]] || die "YubiKey ($VIDPID) not connected"
  if [[ "$ATTACHED" == true ]]; then
    echo "YubiKey ($VIDPID) is already attached to WSL"
    return 0
  fi
  if [[ "$SHARED" != true ]]; then
    bind_key
    load_state
    [[ "$SHARED" == true ]] || die "YubiKey ($VIDPID) is still not shared after bind"
  fi
  "$USBIPD" attach --wsl --hardware-id "$VIDPID" || die "usbipd attach failed"
  load_state
  [[ "$ATTACHED" == true ]] || die "attach reported success but the key is not attached"
  echo "YubiKey ($VIDPID) attached to WSL"
}

do_detach() {
  load_state
  [[ "$CONNECTED" == true ]] || die "YubiKey ($VIDPID) not connected"
  if [[ "$ATTACHED" != true ]]; then
    echo "YubiKey ($VIDPID) is already on Windows"
    return 0
  fi
  "$USBIPD" detach --hardware-id "$VIDPID" || die "usbipd detach failed"
  load_state
  [[ "$ATTACHED" != true ]] || die "detach reported success but the key is still attached"
  echo "YubiKey ($VIDPID) returned to Windows"
}

do_toggle() {
  load_state
  [[ "$CONNECTED" == true ]] || die "YubiKey ($VIDPID) not connected"
  if [[ "$ATTACHED" == true ]]; then
    do_detach
  else
    do_attach
  fi
}

main() {
  if [[ $# -gt 1 ]]; then
    usage >&2
    exit 1
  fi
  case "${1:-}" in
    -h | --help) usage; return 0 ;;
  esac
  [[ -x "$USBIPD" ]] || die "usbipd.exe not found at '$USBIPD' (set USBIPD)"
  command -v jq >/dev/null || die "jq is required"
  case "${1:-}" in
    "") do_toggle ;;
    --wsl | attach) do_attach ;;
    --windows | detach) do_detach ;;
    --status) status ;;
    *) echo "Error: unknown argument '$1'" >&2; usage >&2; exit 1 ;;
  esac
}

main "$@"

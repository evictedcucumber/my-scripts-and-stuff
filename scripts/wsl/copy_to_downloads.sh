#!/usr/bin/env bash
#
# copy_to_downloads.sh
#
# Copy a WSL file or directory into the Windows user's Downloads folder.
#
# The destination is resolved from the Windows "Shell Folders" registry entry
# (so a redirected Downloads is honoured), falling back to
# %USERPROFILE%\Downloads and finally /mnt/c/Users/$USER/Downloads. The copied
# item keeps its own name; timestamps are preserved, mode/ownership are not
# (they don't translate to the Windows filesystem).
#
# Usage:
#   copy_to_downloads.sh [options] <wsl-path>
#
# Options:
#   -d, --dest DIR   Destination directory (WSL or Windows path); overrides
#                    autodetection. Also settable via WIN_DOWNLOADS_DIR.
#   -f, --force      Replace an existing item of the same name at the
#                    destination (otherwise the copy is refused).
#   -v, --verbose    Pass -v to cp.
#   -h, --help       Show this help.
#
# Requirements: WSL (wslpath), coreutils. powershell.exe / cmd.exe are used for
# Downloads-folder autodetection when present.
#
set -euo pipefail

# ---------------------------------------------------------------------------
# Args
# ---------------------------------------------------------------------------

DEST_OVERRIDE="${WIN_DOWNLOADS_DIR:-}"
FORCE=false
CP_OPTS=(-R --preserve=timestamps)
SRC=""

usage() {
  cat <<'EOF'
Usage: copy_to_downloads.sh [options] <wsl-path>

Copy a WSL file or directory into the Windows user's Downloads folder.

Options:
  -d, --dest DIR   Destination directory (WSL or Windows path); overrides
                   autodetection. Also settable via WIN_DOWNLOADS_DIR.
  -f, --force      Replace an existing item of the same name at the destination.
  -v, --verbose    Pass -v to cp.
  -h, --help       Show this help.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -d | --dest)
      [[ $# -ge 2 ]] || { echo "Error: $1 requires an argument." >&2; exit 1; }
      DEST_OVERRIDE="$2"
      shift 2
      ;;
    -f | --force)
      FORCE=true
      shift
      ;;
    -v | --verbose)
      CP_OPTS+=(-v)
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    --)
      shift
      break
      ;;
    -*)
      echo "Error: unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
    *)
      break
      ;;
  esac
done

if [[ -n "${1:-}" ]]; then
  SRC="$1"
  shift
fi

if [[ $# -gt 0 ]]; then
  echo "Error: too many arguments (expected a single source path)." >&2
  exit 1
fi

if [[ -z "$SRC" ]]; then
  echo "Error: no source path given." >&2
  usage >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Sanity checks
# ---------------------------------------------------------------------------

if ! command -v wslpath >/dev/null 2>&1; then
  echo "Error: 'wslpath' not found - this script must be run inside WSL." >&2
  exit 1
fi

if [[ ! -e "$SRC" ]]; then
  echo "Error: source path does not exist: $SRC" >&2
  exit 1
fi

# Absolute path without resolving a final-component symlink, so the copy keeps
# the name the user pointed at.
SRC_PARENT="$(cd -- "$(dirname -- "$SRC")" && pwd -P)"
SRC_ABS="${SRC_PARENT%/}/$(basename -- "$SRC")"
ITEM_NAME="$(basename -- "$SRC_ABS")"

if [[ "$SRC_ABS" == "/" || -z "$ITEM_NAME" || "$ITEM_NAME" == "/" ]]; then
  echo "Error: refusing to copy '$SRC' (cannot derive a target name)." >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Resolve the destination directory
# ---------------------------------------------------------------------------

to_wsl_path() {
  # A drive-letter path (C:\..., C:/..., C:foo) goes through wslpath; anything
  # else is assumed to already be a WSL path and passes through unchanged.
  local p="$1"
  case "$p" in
    ?:*) wslpath -u -- "$p" ;;
    *) printf '%s\n' "$p" ;;
  esac
}

query_windows_downloads() {
  # Prefer the registry value (honours a redirected Downloads); fall back to
  # %USERPROFILE%\Downloads. Run from /mnt/c so the Windows tools don't warn
  # about a UNC working directory.
  local win_dir=""

  if command -v powershell.exe >/dev/null 2>&1; then
    # shellcheck disable=SC2016  # $k/$g/$p/$env are PowerShell vars, kept literal
    win_dir="$(
      cd /mnt/c && powershell.exe -NoProfile -NonInteractive -Command '
        $k = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Shell Folders"
        $g = "{374DE290-123F-4565-9164-39C4925E467B}"
        try { $p = (Get-ItemProperty -Path $k -Name $g -ErrorAction Stop).$g } catch { $p = $null }
        if (-not $p) { $p = Join-Path $env:USERPROFILE "Downloads" }
        [Environment]::ExpandEnvironmentVariables($p)
      ' 2>/dev/null | tr -d '\r' | head -n1
    )" || win_dir=""
  fi

  if [[ -z "$win_dir" ]] && command -v cmd.exe >/dev/null 2>&1; then
    local profile
    profile="$(cd /mnt/c && cmd.exe /c 'echo %USERPROFILE%' 2>/dev/null | tr -d '\r' | head -n1)" || profile=""
    [[ -n "$profile" && "$profile" != '%USERPROFILE%' ]] && win_dir="${profile}\\Downloads"
  fi

  [[ -n "$win_dir" ]] && wslpath -u -- "$win_dir"
}

if [[ -n "$DEST_OVERRIDE" ]]; then
  DOWNLOADS_DIR="$(to_wsl_path "$DEST_OVERRIDE")"
else
  DOWNLOADS_DIR="$(query_windows_downloads || true)"
  [[ -n "$DOWNLOADS_DIR" ]] || DOWNLOADS_DIR="/mnt/c/Users/${USER:-$(id -un)}/Downloads"
fi

if [[ -z "$DOWNLOADS_DIR" ]]; then
  echo "Error: could not determine the Windows Downloads folder." >&2
  echo "       Pass --dest or set WIN_DOWNLOADS_DIR." >&2
  exit 1
fi

if [[ ! -d "$DOWNLOADS_DIR" ]]; then
  echo "Error: destination is not a directory: $DOWNLOADS_DIR" >&2
  echo "       Pass --dest or set WIN_DOWNLOADS_DIR to override." >&2
  exit 1
fi

DEST_PATH="${DOWNLOADS_DIR%/}/${ITEM_NAME}"

# ---------------------------------------------------------------------------
# Copy
# ---------------------------------------------------------------------------

if [[ "$SRC_ABS" == "$DEST_PATH" ]]; then
  echo "Error: source and destination are the same path: $DEST_PATH" >&2
  exit 1
fi

if [[ -e "$DEST_PATH" ]]; then
  if [[ "$FORCE" != true ]]; then
    echo "Error: destination already exists: $DEST_PATH" >&2
    echo "       Re-run with --force to replace it." >&2
    exit 1
  fi
  echo "Replacing existing: $DEST_PATH"
  rm -rf -- "$DEST_PATH"
fi

echo "Copying: $SRC_ABS"
echo "     ->  $DEST_PATH"

if ! cp "${CP_OPTS[@]}" -- "$SRC_ABS" "$DEST_PATH"; then
  echo "Error: copy failed." >&2
  exit 1
fi

SIZE="$(du -sh -- "$DEST_PATH" 2>/dev/null | cut -f1 || true)"
WIN_DEST="$(wslpath -w -- "$DEST_PATH" 2>/dev/null || true)"

echo "Done.${SIZE:+ ($SIZE)}"
[[ -n "$WIN_DEST" ]] && echo "Windows path: $WIN_DEST"

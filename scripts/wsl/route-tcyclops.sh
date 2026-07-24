#!/usr/bin/env bash
# Adds a route to the tcyclops internal network (192.168.2.0/24) via the
# Windows host, as seen from inside WSL2 (NAT mode).
#
# Why this is needed: WSL2 NAT mode puts WSL on its own subnet (e.g. 172.x).
# The Windows host's default-route gateway, as seen from WSL, is also the
# only path back into other Windows-side interfaces -- including the
# "tcyclops-internal" Hyper-V vSwitch on 192.168.2.0/24. That gateway IP is
# not stable across WSL restarts, so it must be detected at runtime rather
# than hardcoded.

set -euo pipefail

TARGET_NET="10.0.0.0/24"
LOG_TAG="[tcyclops-route]"

# Detect the current default gateway WSL is using to reach the Windows host.
GATEWAY="$(ip route show default | awk '/^default/ {print $3; exit}')"

if [[ -z "${GATEWAY:-}" ]]; then
    echo "${LOG_TAG} ERROR: could not determine default gateway, aborting." >&2
    exit 1
fi

# If a route to the target network already exists, don't add a duplicate.
# This makes the script safe to re-run (idempotent) rather than relying on
# "only runs once at boot" being strictly true.
if ip route show "${TARGET_NET}" | grep -q .; then
    EXISTING_VIA="$(ip route show "${TARGET_NET}" | awk '/via/ {print $3; exit}')"
    if [[ "${EXISTING_VIA}" == "${GATEWAY}" ]]; then
        echo "${LOG_TAG} Route to ${TARGET_NET} via ${GATEWAY} already present. Nothing to do."
        exit 0
    else
        echo "${LOG_TAG} Existing route via ${EXISTING_VIA} is stale (gateway is now ${GATEWAY}). Replacing."
        sudo ip route del "${TARGET_NET}" || true
    fi
fi

echo "${LOG_TAG} Adding route: ${TARGET_NET} via ${GATEWAY}"
sudo ip route add "${TARGET_NET}" via "${GATEWAY}"
echo "${LOG_TAG} Done."

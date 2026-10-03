#!/usr/bin/env bash
# ============================================================================
# hushsend-stun-server — prove a deployed server does the ONE thing it should, and none of
# the things it should not.
#
#   usage: bash verify.sh <host> [port]
#
# Checks:
#   1. STUN answers over UDP and returns a mapped address.
#   2. The TCP port accepts connections (networks that block UDP still need it).
#      Reachability only — turnutils_stunclient has no TCP mode to speak STUN with.
#   3. The server REFUSES to allocate a relay. This is the load-bearing one: a
#      relay would put this operator on the media path, which is the position the
#      separation of STUN from signaling exists to keep everyone out of.
#
# Exit code 0 only if 1 and 3 hold. Run it from a DIFFERENT machine than the
# server — a loopback test proves nothing about NAT or the firewall.
#
# Until 2026-10-03 check 3 could not fail: it read any non-zero exit of
# turnutils_uclient as "refused", and without `-y` the client exits non-zero on
# its own arguments before sending anything. It now sends an anonymous TURN
# Allocate itself and reads the server's answer (lib.sh, stun_relay_probe).
# ============================================================================
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
. "$HERE/lib.sh"

HOST="${1:-}"
PORT="${2:-3478}"

if [[ -z "$HOST" ]]; then
  echo "usage: $0 <host> [port]" >&2
  exit 2
fi
for tool in turnutils_stunclient python3; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "need $tool — coturn's client tools and python3:" >&2
    echo "  sudo apt-get install -y coturn python3   |   brew install coturn" >&2
    exit 2
  fi
done

fail=0
say() { printf '%s\n' "$*"; }

# --- 1. STUN answers over UDP -------------------------------------------------
if addr=$(stun_binding "$HOST" "$PORT"); then
  say "ok    STUN/UDP answered — it sees you as $addr"
else
  say "FAIL  STUN/UDP did not return a mapped address"
  fail=1
fi

# --- 2. TCP port reachable ----------------------------------------------------
if stun_timeout 5 bash -c "exec 3<>/dev/tcp/${HOST}/${PORT}" 2>/dev/null; then
  say "ok    TCP/$PORT accepts connections (clients on UDP-blocking networks can reach it)"
else
  say "warn  TCP/$PORT did not accept a connection — check the firewall allows ${PORT}/tcp"
  say "      Not fatal: UDP is the normal path. It matters on networks that block UDP."
fi

# --- 3. It must NOT relay ------------------------------------------------------
case "$(stun_relay_probe "$HOST" "$PORT")" in
  refused)
    say "ok    an anonymous relay allocation is refused — the operator stays off the media path" ;;
  allocated)
    say "FAIL  the server ALLOCATED A RELAY to an anonymous client — it is acting as TURN, not STUN."
    say "      Is \`stun-only\` in the config? Without it coturn hands relays to anyone."
    fail=1 ;;
  auth-required)
    say "FAIL  the server asks for credentials, i.e. it relays for whoever holds them."
    say "      A STUN-only server holds none: look for lt-cred-mech / use-auth-secret / user= lines."
    fail=1 ;;
  *)
    say "FAIL  no answer to the relay probe — this proves nothing either way"
    fail=1 ;;
esac

say ""
if [[ "$fail" -eq 0 ]]; then
  say "PASS — $HOST:$PORT answers STUN and refuses to relay."
  say ""
  say "Still to confirm ON THE HOST (this script cannot see it): that nothing is logged."
  say "  sudo find /var/log /var/tmp /tmp -maxdepth 4 -name 'turn_*.log' -mmin -10"
  say "  # any output means log-file=/dev/null did not take effect (install.sh checks this too)"
else
  say "FAILED — do not point clients at this host yet."
fi
exit "$fail"

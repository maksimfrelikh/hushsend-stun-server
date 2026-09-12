#!/usr/bin/env bash
# ============================================================================
# hushsend-stun-server — prove a deployed server does the ONE thing it should, and none of
# the things it should not.
#
#   usage: ./verify.sh <host> [port]
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
# ============================================================================
set -uo pipefail

HOST="${1:-}"
PORT="${2:-3478}"

if [[ -z "$HOST" ]]; then
  echo "usage: $0 <host> [port]" >&2
  exit 2
fi

if ! command -v turnutils_stunclient >/dev/null 2>&1; then
  echo "need turnutils_stunclient — install the coturn client tools:" >&2
  echo "  sudo apt-get install -y coturn        # ships the turnutils_* binaries" >&2
  exit 2
fi

fail=0
say() { printf '%s\n' "$*"; }

# --- 1. STUN answers over UDP -------------------------------------------------
out="$(timeout 15 turnutils_stunclient -p "$PORT" "$HOST" 2>&1)"
addr="$(printf '%s' "$out" | grep -oiE '(reflexive|mapped) addr: [0-9a-f.:]+' | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}|([0-9a-f]*:){2,}[0-9a-f]*' | head -1)"
if [[ -n "$addr" ]]; then
  say "ok    STUN/UDP answered — it sees you as $addr"
else
  say "FAIL  STUN/UDP did not return a mapped address"
  printf '%s\n' "$out" | sed 's/^/        /' | head -5
  fail=1
fi

# --- 2. TCP port reachable ----------------------------------------------------
if timeout 5 bash -c "exec 3<>/dev/tcp/${HOST}/${PORT}" 2>/dev/null; then
  say "ok    TCP/$PORT accepts connections (clients on UDP-blocking networks can reach it)"
else
  say "warn  TCP/$PORT did not accept a connection — check the firewall allows ${PORT}/tcp"
  say "      Not fatal: UDP is the normal path. It matters on networks that block UDP."
fi

# --- 3. It must NOT relay ------------------------------------------------------
# turnutils_uclient asks for an ALLOCATION. Against this server that must fail:
# a TURN allocation has to be authenticated and the config deliberately defines
# NO authentication at all, so there are no credentials any client could present.
# Success here means someone added lt-cred-mech / use-auth-secret / a user= line,
# and the operator is now on the media path.
if command -v turnutils_uclient >/dev/null 2>&1; then
  if timeout 20 turnutils_uclient -u any -w any -p "$PORT" -n 1 -c "$HOST" >/dev/null 2>&1; then
    say "FAIL  the server ALLOCATED A RELAY — it is acting as TURN, not STUN."
    say "      Check that no lt-cred-mech / use-auth-secret / static-auth-secret / user= line"
    say "      crept into /etc/turnserver.conf. Their ABSENCE is what refuses the allocation."
    fail=1
  else
    say "ok    relay allocation refused — the operator stays off the media path"
  fi
else
  say "skip  turnutils_uclient not installed — the relay check did NOT run"
fi

say ""
if [[ "$fail" -eq 0 ]]; then
  say "PASS — $HOST:$PORT answers STUN and refuses to relay."
  say ""
  say "Still to confirm ON THE HOST (this script cannot see it): that nothing is logged."
  say "  find /var/tmp /var/log -name 'turn_*' -newermt '-10 minutes' 2>/dev/null"
  say "  # any output means log-file=/dev/null did not take effect — check the config loaded at all"
else
  say "FAILED — do not point clients at this host yet."
fi
exit "$fail"

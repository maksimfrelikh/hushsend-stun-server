#!/usr/bin/env bash
# ============================================================================
# CI check: does turnserver.conf.template render into a config coturn really
# loads — and does that server answer STUN, refuse to relay and log nothing?
#
#   bash check.sh
#
# No root: coturn runs as the current user on a high port. If coturn silently
# discarded the file it would run on its defaults (port 3478, relaying, logging),
# so the port it binds is the first thing checked.
# ============================================================================
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
. "$HERE/lib.sh"

for tool in turnserver turnutils_stunclient python3; do
  command -v "$tool" >/dev/null || { echo "need $tool (package coturn)" >&2; exit 2; }
done

WORK=$(mktemp -d)
TS_PID=
cleanup() {
  [ -n "$TS_PID" ] && kill "$TS_PID" 2>/dev/null || true
  rm -rf "$WORK"
}
trap cleanup EXIT

PORT=34790
cat >"$WORK/stun.env" <<EOF
REALM=stun.ci.test
LISTEN_PORT=$PORT
TLS_LISTEN_PORT=34791
EXTERNAL_IP=
EOF
bash "$HERE/render.sh" "$WORK/stun.env" >"$WORK/turnserver.conf"
touch "$WORK/started"

# `-c` and NOT `-n`: `-n` means "ignore the configuration file".
turnserver -c "$WORK/turnserver.conf" --pidfile= >"$WORK/stdout" 2>&1 &
TS_PID=$!

fail() {
  echo "FAIL  $*" >&2
  echo "----- coturn stdout:" >&2
  cat "$WORK/stdout" >&2 || true
  exit 1
}

for _ in $(seq 1 30); do
  stun_udp_port_bound "$PORT" && break
  sleep 0.5
done
stun_udp_port_bound "$PORT" || fail "coturn is not listening on the rendered port $PORT — the config was not loaded"
echo "ok    coturn loaded the rendered config (listening on $PORT)"

addr=$(stun_binding 127.0.0.1 "$PORT") || fail "STUN did not answer on $PORT"
echo "ok    STUN answers (mapped address $addr)"

verdict=$(stun_relay_probe 127.0.0.1 "$PORT")
[ "$verdict" = refused ] || fail "relay probe: $verdict (expected: refused)"
echo "ok    an anonymous relay allocation is refused"

logs=$(stun_new_log_files "$WORK/started")
[ -z "$logs" ] || fail "coturn wrote a log file despite log-file=/dev/null: $logs"
# An option coturn does not know (or rejects) is reported before log-file is read — and, as
# measured on 4.18, that alone creates /var/tmp/turn_*.log. A startup banner is harmless.
! grep -qiE 'Bad configuration format|CONFIG ERROR|unknown option' "$WORK/stdout" ||
  fail "coturn rejected an option in the rendered config"
echo "ok    no log file, no rejected option"

# NEGATIVE CONTROL. The same config WITHOUT `stun-only` must be caught handing out a relay —
# otherwise the probe above proves nothing, which is exactly how the old verify.sh passed every
# server. coturn with no authentication configured gives relays to anyone (measured 2026-10-03).
kill "$TS_PID" 2>/dev/null || true
wait "$TS_PID" 2>/dev/null || true
CONTROL_PORT=34794
sed -e '/^stun-only$/d' -e "s/^listening-port=$PORT\$/listening-port=$CONTROL_PORT/" \
  -e 's/^tls-listening-port=.*/tls-listening-port=34795/' "$WORK/turnserver.conf" >"$WORK/control.conf"
turnserver -c "$WORK/control.conf" --pidfile= >"$WORK/stdout" 2>&1 &
TS_PID=$!
for _ in $(seq 1 30); do
  stun_udp_port_bound "$CONTROL_PORT" && break
  sleep 0.5
done
verdict=$(stun_relay_probe 127.0.0.1 "$CONTROL_PORT")
[ "$verdict" = allocated ] || fail "negative control: without stun-only the probe said '$verdict', expected 'allocated' — the probe cannot see a relay"
echo "ok    negative control: without stun-only the same config DOES relay, and the probe sees it"

echo "PASS  turnserver.conf.template renders into a STUN-only server that does not relay or log"

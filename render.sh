#!/usr/bin/env bash
# ============================================================================
# Render turnserver.conf.template to stdout:  bash render.sh <stun.env> [template]
#
# Used by install.sh (on the host) and check.sh (in CI). Replacement is literal
# (awk index/substr). The output is refused if it lacks `stun-only` (without it
# coturn hands out anonymous relays), lacks log-file=/dev/null, configures any
# credentials (a STUN-only server holds none), or carries the no-udp-relay +
# no-tcp-relay pair that makes coturn discard the whole file.
# ============================================================================
set -euo pipefail

ENV_FILE="${1:-}"
TEMPLATE="${2:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/turnserver.conf.template}"
fail() { echo "render: $*" >&2; exit 2; }

[ -n "$ENV_FILE" ] || { echo "usage: $0 <stun.env> [template]" >&2; exit 2; }
[ -r "$ENV_FILE" ] || fail "cannot read $ENV_FILE"
[ -r "$TEMPLATE" ] || fail "cannot read $TEMPLATE"

REALM= LISTEN_PORT= TLS_LISTEN_PORT= EXTERNAL_IP=
while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in '' | '#'*) continue ;; esac
  key=${line%%=*}
  val=${line#*=}
  case "$key" in
    REALM | LISTEN_PORT | TLS_LISTEN_PORT | EXTERNAL_IP) printf -v "$key" '%s' "$val" ;;
    *) echo "render: $ENV_FILE: unknown key '$key' (ignored)" >&2 ;;
  esac
done <"$ENV_FILE"

[[ "$REALM" =~ ^[A-Za-z0-9.-]+$ ]] || fail "REALM must be a hostname, got '$REALM'"
for v in LISTEN_PORT TLS_LISTEN_PORT; do
  [[ "${!v}" =~ ^[0-9]+$ ]] || fail "$v must be a number, got '${!v}'"
done
[ "$LISTEN_PORT" != "$TLS_LISTEN_PORT" ] || fail "LISTEN_PORT and TLS_LISTEN_PORT must differ"
if [ -n "$EXTERNAL_IP" ] && ! [[ "$EXTERNAL_IP" =~ ^[0-9a-fA-F.:]+(/[0-9a-fA-F.:]+)?$ ]]; then
  fail "EXTERNAL_IP must be PUBLIC or PUBLIC/PRIVATE, got '$EXTERNAL_IP'"
fi
export REALM LISTEN_PORT TLS_LISTEN_PORT EXTERNAL_IP

out=$(awk '
  function repl(s, key, val,    out, i) {
    out = ""
    while ((i = index(s, key)) > 0) {
      out = out substr(s, 1, i - 1) val
      s = substr(s, i + length(key))
    }
    return out s
  }
  {
    line = $0
    if (line == "external-ip=@EXTERNAL_IP@" && ENVIRON["EXTERNAL_IP"] == "") {
      print "# external-ip is not set: this host has its public address on an interface"
      next
    }
    n = split("REALM LISTEN_PORT TLS_LISTEN_PORT EXTERNAL_IP", keys, " ")
    for (k = 1; k <= n; k++) line = repl(line, "@" keys[k] "@", ENVIRON[keys[k]])
    print line
  }
' "$TEMPLATE")

active=$(printf '%s\n' "$out" | grep -vE '^[[:space:]]*(#|$)' || true)
if printf '%s\n' "$out" | grep -qE '@[A-Z_]+@'; then
  fail "a placeholder survived rendering"
fi
if printf '%s\n' "$active" | grep -qiE '^[[:space:]]*(lt-cred-mech|use-auth-secret|static-auth-secret|user[[:space:]]*=|userdb|a[[:space:]]*$)'; then
  fail "the config would configure credentials — a STUN-only server holds none"
fi
if printf '%s\n' "$active" | grep -q '^no-udp-relay' && printf '%s\n' "$active" | grep -q '^no-tcp-relay'; then
  fail "no-udp-relay together with no-tcp-relay makes coturn discard the whole file"
fi
printf '%s\n' "$active" | grep -qx 'stun-only' || fail "stun-only is missing — without it coturn hands out ANONYMOUS relays (measured 2026-10-03)"
printf '%s\n' "$active" | grep -qx 'log-file=/dev/null' || fail "log-file=/dev/null is missing — this server must not log"
printf '%s\n' "$out"

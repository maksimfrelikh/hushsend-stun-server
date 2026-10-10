#!/usr/bin/env bash
# ============================================================================
# Install or update the hushsend STUN server on THIS host. Run as root.
#
# First install (writes /etc/hushsend-stun/stun.env from the options):
#   sudo bash install.sh --realm stun.example.org [--port 3478] [--tls-port 5349] \
#                        [--external-ip PUBLIC/PRIVATE] [--disable-stock-coturn]
# Later (re-renders from the template and the saved stun.env):
#   sudo bash install.sh [--dry-run]
#
# What it does: installs coturn if missing (Debian/Ubuntu), renders
# turnserver.conf.template into /etc/hushsend-stun/turnserver.conf, installs the
# hushsend-stun.service unit, restarts it and checks against 127.0.0.1 that the
# port is bound, STUN answers, a relay allocation is REFUSED and no log file
# appeared. Any failure puts the previous config back (or stops the service on
# a first install).
#
# --disable-stock-coturn  stop and disable the distro's coturn.service. Use it on
#   a DEDICATED host: installing the package starts a default coturn there (on
#   3478, logging). Never on a host where coturn.service is your TURN relay —
#   laptop-server keeps it; this server takes 3479 there.
# ============================================================================
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
. "$HERE/lib.sh"

ETC=/etc/hushsend-stun
SITE_ENV=$ETC/stun.env
TARGET=$ETC/turnserver.conf
UNIT=hushsend-stun
UNIT_FILE=/etc/systemd/system/$UNIT.service

DRY_RUN=0 DISABLE_STOCK=0
REALM_OPT= PORT_OPT= TLS_OPT= EXT_OPT= EXT_SET=0
while [ $# -gt 0 ]; do
  case "$1" in
    --realm) REALM_OPT=$2; shift ;;
    --port) PORT_OPT=$2; shift ;;
    --tls-port) TLS_OPT=$2; shift ;;
    --external-ip) EXT_OPT=$2; EXT_SET=1; shift ;;
    --dry-run) DRY_RUN=1 ;;
    --disable-stock-coturn) DISABLE_STOCK=1 ;;
    -h | --help) sed -n '2,24p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done

say() { printf '%s\n' "$*"; }
die() { printf 'FAIL  %s\n' "$*" >&2; exit 1; }
[ "$(id -u)" -eq 0 ] || die "run as root: sudo bash $0"

# --- coturn -------------------------------------------------------------------------
if ! command -v turnserver >/dev/null 2>&1; then
  command -v apt-get >/dev/null 2>&1 || die "coturn is not installed and this is not a Debian/Ubuntu host — install it first"
  say "installing coturn…"
  apt-get update -qq && apt-get install -y coturn
fi
for tool in turnutils_stunclient python3; do
  command -v "$tool" >/dev/null 2>&1 || die "missing $tool (packages coturn, python3)"
done
getent passwd turnserver >/dev/null 2>&1 || die "no 'turnserver' user — the coturn package normally creates it"

# --- per-host values -------------------------------------------------------------------
mkdir -p "$ETC"
chmod 0755 "$ETC"
if [ ! -e "$SITE_ENV" ]; then
  [ -n "$REALM_OPT" ] || die "first install: pass --realm <the hostname clients will use> (see stun.env.example)"
  (
    umask 077
    {
      echo "# Written by install.sh on $(date -u +%Y-%m-%dT%H:%MZ). Plain KEY=value, no inline comments."
      echo "REALM=$REALM_OPT"
      echo "LISTEN_PORT=${PORT_OPT:-3478}"
      echo "TLS_LISTEN_PORT=${TLS_OPT:-5349}"
      echo "EXTERNAL_IP=$EXT_OPT"
    } >"$SITE_ENV"
  )
  say "wrote $SITE_ENV"
elif [ -n "$REALM_OPT$PORT_OPT$TLS_OPT" ] || [ "$EXT_SET" -eq 1 ]; then
  # Explicit options update the saved values.
  [ -z "$REALM_OPT" ] || sed -i "s|^REALM=.*|REALM=$REALM_OPT|" "$SITE_ENV"
  [ -z "$PORT_OPT" ] || sed -i "s|^LISTEN_PORT=.*|LISTEN_PORT=$PORT_OPT|" "$SITE_ENV"
  [ -z "$TLS_OPT" ] || sed -i "s|^TLS_LISTEN_PORT=.*|TLS_LISTEN_PORT=$TLS_OPT|" "$SITE_ENV"
  [ "$EXT_SET" -eq 0 ] || sed -i "s|^EXTERNAL_IP=.*|EXTERNAL_IP=$EXT_OPT|" "$SITE_ENV"
  say "updated $SITE_ENV"
fi
sed 's/^/    /' "$SITE_ENV"
PORT=$(sed -n 's/^LISTEN_PORT=//p' "$SITE_ENV" | tail -1)

# --- render ----------------------------------------------------------------------------
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
bash "$HERE/render.sh" "$SITE_ENV" >"$WORK/turnserver.conf"
say "--- changes to $TARGET:"
if [ -r "$TARGET" ]; then diff -u "$TARGET" "$WORK/turnserver.conf" || true; else say "(new file)"; fi
if ! cmp -s "$HERE/$UNIT.service" "$UNIT_FILE" 2>/dev/null; then say "--- $UNIT_FILE will be (re)installed"; fi
if [ "$DRY_RUN" -eq 1 ]; then
  say "--- dry run: nothing changed"
  exit 0
fi

# --- the port must be ours to take ---------------------------------------------------------
if [ "$DISABLE_STOCK" -eq 1 ] && systemctl is-enabled --quiet coturn 2>/dev/null; then
  if grep -qE '^[[:space:]]*(use-auth-secret|lt-cred-mech)' /etc/turnserver.conf 2>/dev/null; then
    die "coturn.service on this host is configured as a TURN relay — not disabling it. Drop --disable-stock-coturn and give this server another --port."
  fi
  systemctl disable --now coturn
  say "disabled the distro's coturn.service"
fi
if ! systemctl is-active --quiet "$UNIT" && stun_udp_port_bound "$PORT"; then
  die "UDP $PORT is already in use by something else (ss -lunp | grep $PORT). Another coturn? Choose --port, or on a dedicated host --disable-stock-coturn."
fi

# --- install, keeping the previous config -----------------------------------------------------
BACKUP=
if [ -e "$TARGET" ]; then
  BACKUP="$TARGET.bak-$(date +%Y%m%d-%H%M%S)"
  cp -p "$TARGET" "$BACKUP"
fi
install -m 0640 -o root -g turnserver "$WORK/turnserver.conf" "$TARGET"
install -m 0644 "$HERE/$UNIT.service" "$UNIT_FILE"
systemctl daemon-reload
systemctl enable "$UNIT" >/dev/null 2>&1
touch "$WORK/started"
systemctl restart "$UNIT"

rollback() {
  printf 'FAIL  %s\n' "$1" >&2
  if [ -n "$BACKUP" ]; then
    cp -p "$BACKUP" "$TARGET"
    systemctl restart "$UNIT" || true
    printf 'ROLLED BACK to %s\n' "$BACKUP" >&2
  else
    systemctl disable --now "$UNIT" >/dev/null 2>&1 || true
    printf 'First install failed: %s is stopped and disabled.\n' "$UNIT" >&2
  fi
  exit 1
}

for _ in $(seq 1 30); do
  stun_udp_port_bound "$PORT" && break
  sleep 0.5
done
systemctl is-active --quiet "$UNIT" || rollback "$UNIT is not running (journalctl -u $UNIT -n 30)"
stun_udp_port_bound "$PORT" || rollback "nothing listens on UDP $PORT — the config was not loaded"
addr=$(stun_binding 127.0.0.1 "$PORT") || rollback "STUN does not answer on 127.0.0.1:$PORT"
say "ok    STUN answers on $PORT (mapped $addr)"
case "$(stun_relay_probe 127.0.0.1 "$PORT")" in
  refused) say "ok    an anonymous relay allocation is refused" ;;
  allocated) rollback "the server ALLOCATED A RELAY to an anonymous client — is stun-only in the config?" ;;
  auth-required) rollback "the server offers relays to whoever holds credentials — a STUN-only server holds none" ;;
  *) rollback "the relay probe got no answer at all from 127.0.0.1:$PORT" ;;
esac
logs=$(stun_new_log_files "$WORK/started")
[ -z "$logs" ] || rollback "coturn wrote log files: $logs"
say "ok    no log file"
say "INSTALLED  $UNIT on UDP+TCP $PORT (config $TARGET, previous: ${BACKUP:-none})"
say "Now check it from ANOTHER machine:  bash verify.sh <realm> $PORT"

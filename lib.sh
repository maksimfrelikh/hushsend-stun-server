# shellcheck shell=bash
# ============================================================================
# Shared checks — sourced by install.sh (on the host), check.sh (CI) and
# verify.sh (from another machine). Need coturn's client tools (turnutils_*).
# ============================================================================

# `timeout` is coreutils; macOS lacks it. The perl fallback is the classic portable one: alarm()
# survives exec, so the command itself is killed by SIGALRM when the time is up.
stun_timeout() { if command -v timeout >/dev/null 2>&1; then timeout "$@"; else perl -e 'alarm shift; exec @ARGV' "$@"; fi; }

# Is something listening on this UDP port? (`ss` on Linux, `lsof` elsewhere.)
stun_udp_port_bound() { # port
  if command -v ss >/dev/null 2>&1; then ss -lun | grep -qE "[:.]$1[[:space:]]"; else lsof -nP -iUDP:"$1" >/dev/null 2>&1; fi
}

# STUN binding over UDP. Prints the mapped address; fails if none came back.
stun_binding() { # host port
  local out addr
  out=$(stun_timeout 15 turnutils_stunclient -p "$2" "$1" 2>&1 || true)
  addr=$(printf '%s' "$out" | grep -oiE '(reflexive|mapped) addr: [0-9a-f.:]+' | head -1 | sed 's/.*: //')
  [ -n "$addr" ] || { printf '%s\n' "$out" | tail -5 >&2; return 1; }
  printf '%s\n' "$addr"
}

# Ask for a RELAY the way any stranger could: an anonymous TURN Allocate over
# UDP, built by hand (RFC 5766) so the answer is read straight off the wire.
# Prints one of:
#   allocated      — a success response: the server hands out relays (FAIL)
#   auth-required  — 401: relays exist for whoever holds credentials (FAIL for
#                    a STUN-only server — it is meant to hold none)
#   refused        — any other error, or no answer at all to three tries while
#                    the same address answers STUN (`stun-only` ignores TURN)
#   unreachable    — the host did not answer anything; proves nothing
# The binding request in stun_binding() is what establishes the path is alive;
# call that first. (turnutils_uclient is no use here: against a server that
# ignores TURN it waits indefinitely, and without -y/-e it exits on its own
# arguments before sending anything — which is how an earlier verify.sh
# "passed" this check against every server.)
stun_relay_probe() { # host port
  python3 - "$1" "$2" <<'PY'
import os, socket, struct, sys

host, port = sys.argv[1], int(sys.argv[2])
COOKIE = 0x2112A442

def request(msg_type, attrs=b""):
    tid = os.urandom(12)
    return tid, struct.pack("!HHI", msg_type, len(attrs), COOKIE) + tid + attrs

def answer(sock, tid):
    for _ in range(3):
        try:
            data = sock.recv(2048)
        except socket.timeout:
            return None
        if len(data) >= 20 and data[8:20] == tid:
            return data
    return None

def ask(sock, addr, msg_type, attrs=b""):
    tid, msg = request(msg_type, attrs)
    for _ in range(3):
        sock.sendto(msg, addr)
        got = answer(sock, tid)
        if got is not None:
            return got
    return None

family, _, _, _, addr = socket.getaddrinfo(host, port, type=socket.SOCK_DGRAM)[0]
sock = socket.socket(family, socket.SOCK_DGRAM)
sock.settimeout(2)

# 1. Is anyone home? A plain Binding request.
if ask(sock, addr, 0x0001) is None:
    print("unreachable"); sys.exit(0)

# 2. Anonymous Allocate, REQUESTED-TRANSPORT = UDP (17).
resp = ask(sock, addr, 0x0003, struct.pack("!HHI", 0x0019, 4, 17 << 24))
if resp is None:
    print("refused"); sys.exit(0)
msg_type = struct.unpack("!H", resp[:2])[0]
if msg_type == 0x0103:
    print("allocated"); sys.exit(0)
code, pos, end = None, 20, 20 + struct.unpack("!H", resp[2:4])[0]
while pos + 4 <= end:
    a_type, a_len = struct.unpack("!HH", resp[pos:pos + 4])
    if a_type == 0x0009 and a_len >= 4:
        code = resp[pos + 6] * 100 + resp[pos + 7]
    pos += 4 + a_len + (-a_len % 4)
print("auth-required" if code == 401 else "refused")
PY
}

# coturn log files newer than the reference file, wherever coturn falls back to —
# including the private /tmp of a systemd unit with PrivateTmp (root only).
stun_new_log_files() { # reference-file
  find /var/log /var/tmp /tmp -maxdepth 4 -name 'turn_*.log' -newer "$1" 2>/dev/null || true
}

# hushsend-stun-server — deployment runbook

## 0. Status (2026-10-10)

**Installed on laptop-server, not reachable from outside yet.** `hushsend-stun.service` runs there
since 2026-10-10 19:47 UTC on 3479 (§ 6 step 4: STUN answers, an anonymous relay is refused, no log
file), and ufw allows 3479/udp. Checked from the host the same day: the LAN address answers on 3479
and the public address answers on the TURN relay's 3478, but not on 3479 — the router forward (§ 6
step 2) is not in place yet. `verify.sh` from another network has not run, and hushsend's clients
still get STUN from the TURN relay's coturn (`stun:turn.hushsend.frelikh.dev:3478`, run by the
signaling operator — the live bundle names it).

**Corrected 2026-10-03.** This file used to say the config "has been loaded by a real coturn 4.6.1
and checked end to end … refuses relay allocations". The refusal was never real: the config relied on
having no authentication, and coturn with no authentication hands out relays to anyone (measured on
4.18; see the template's header). The check that "confirmed" it could not fail. The template now
carries `stun-only`, and `check.sh` proves the refusal in CI — with a negative control that catches
the same config relaying when `stun-only` is removed.

## Two gotchas that cost an afternoon — read these first

**`-n` means "ignore the configuration file".** Not "no daemon". Every `turnserver -c yours.conf -n`
silently discards your config and runs on built-in defaults: port 3478, relaying ON, logging ON. The
symptom is baffling — "Address already in use" on a port your config never mentions, and a log file
appearing at `/var/tmp/turn_*.log` when you set `log-file=/dev/null`. If you see either, drop the `-n`.

**`no-udp-relay` and `no-tcp-relay` cannot be used together.** coturn rejects the pair and then
discards the entire file, falling back to defaults — which relay and log. A config that reads as
stricter and silently does the opposite is the worst failure mode available here.

And three that cost the 2026-10-03 rework:

- **No authentication does not mean no relay** — it means *anonymous* relays. Only `stun-only` stops
  TURN.
- **`user-quota=0` / `total-quota=0` mean unlimited**, not zero.
- **An option coturn does not know is logged as a warning before `log-file` is read**, so it creates
  `/var/tmp/turn_*.log` even with `log-file=/dev/null` (seen with `no-loopback-peers` on 4.18). CI fails
  when coturn writes a log file or prints anything at all.

## 1. Who runs it

The security value is that this is **not the same party** as the hushsend signaling server: an
adversary holding both can inject an ICE candidate *and* tell the peer to attest that same address,
and hushsend's path attestation passes either way. Separate code is not separate control — if one
person runs both hosts, one order reaches both.

Strongest to weakest: a different organisation (ideally another jurisdiction) → **several independent
STUN servers cross-checked by the client** (the target: `VITE_STUN_URLS` is a list, so no single
operator is authoritative) → a second host you control elsewhere.

## 2. Host and DNS

- A small VM is plenty: STUN answers one packet per request and relays nothing.
- A DNS name for the host (`A`, plus `AAAA` if it has IPv6). Clients are given the NAME, so a later
  move is a DNS change. Behind Cloudflare: **DNS only** (grey cloud) — the proxy carries HTTP, not
  UDP.
- Behind NAT set `--external-ip PUBLIC/PRIVATE`.

## 3. Install

```bash
git clone https://github.com/maksimfrelikh/hushsend-stun-server.git && cd hushsend-stun-server
sudo bash install.sh --realm stun.example.org [--port 3478] [--external-ip PUBLIC/PRIVATE] [--disable-stock-coturn]
```

The first run writes `/etc/hushsend-stun/stun.env` from the options; later runs re-render from it
(`sudo bash install.sh`, or `--dry-run` to see the diff). Each run installs coturn if missing,
renders `/etc/hushsend-stun/turnserver.conf`, installs `hushsend-stun.service` (its own unit, not the
distro's `coturn.service`), restarts it and checks against 127.0.0.1: the port is bound, STUN answers,
an anonymous relay allocation is refused, no log file appeared. A failure restores the previous
config, or stops the service on a first install.

- **Dedicated host:** pass `--disable-stock-coturn`. Installing the package starts a default coturn on
  3478 — relaying, logging — which also takes the port this server wants. The installer refuses to
  disable a `coturn.service` that is configured as a TURN relay.
- **Next to a TURN relay** that already owns `coturn.service` and 3478: give this server another port
  (laptop-server: 3479). The installer stops with an explanation if the port is taken.

## 4. Firewall and router

`LISTEN_PORT` over **UDP**:

```bash
sudo ufw allow 3478/udp     # your LISTEN_PORT
```

Behind NAT, forward the same port (UDP) to the host. **No relay range** — there is no relay.

TCP is not needed for hushsend: a browser asks a `stun:` URL over UDP only, and on a network that
blocks UDP the way out is TURN over TCP/TLS — the relay's job, not this server's. coturn listens on
TCP anyway; open the port only for a non-browser client that speaks STUN over TCP. `verify.sh`
reports the TCP port as information, not as a failure.

## 5. Verify — the gate

```bash
bash verify.sh stun.example.org [port]
```

From a **different machine** (a loopback test proves nothing about NAT or the firewall): STUN must
answer, and an anonymous TURN Allocate must be refused. `verify.sh` builds that Allocate itself and
reads the server's answer. On the host, the installer has already checked for log files; to re-check
by hand: `sudo find /var/log /var/tmp /tmp -maxdepth 4 -name 'turn_*.log' -mmin -10`.

Then point hushsend at it — `VITE_STUN_URLS` in hushsend's `deploy/build-env.sh`, rebuild and
redeploy the frontend (the value is compiled into the bundle).

## 6. laptop-server (the first deployment)

The TURN relay's `coturn.service` holds 3478 there, so this server takes **3479** (TLS 5350, which
listens on nothing without a certificate). Manual steps, in order:

1. DNS: nothing to do. The `frelikh.dev` zone (Cloudflare) has a wildcard `*.frelikh.dev` →
   `94.46.199.61`, DNS only, so `stun.hushsend.frelikh.dev` already resolves (checked 2026-10-10). An
   explicit `A stun.hushsend` record is optional — if you add one, **DNS only**: a proxied record
   overrides the wildcard, and the proxy does not carry UDP.
2. Router: forward **3479 UDP** → `192.168.1.19:3479` (TCP is not needed — § 4).
3. ufw: `sudo ufw allow 3479/udp`.
4. Install:
   ```bash
   cd ~/projects/hushsend-stun-server && git pull --ff-only
   sudo bash install.sh --realm stun.hushsend.frelikh.dev --port 3479 --tls-port 5350 --external-ip 94.46.199.61/192.168.1.19
   ```
5. Verify from outside the home network (a phone hotspot will do): `bash verify.sh stun.hushsend.frelikh.dev 3479`.
6. hushsend: `VITE_STUN_URLS=stun:stun.hushsend.frelikh.dev:3479` in `deploy/build-env.sh`, push,
   redeploy the frontend.

From the home LAN a STUN reply names the router (192.168.1.1), not the public address — the router
hairpins and rewrites the source. That is the router, not this server; check from outside.

## 7. Moving to another host

Keep the port the clients were built with, and the move needs no client rebuild:

1. Install on the new host (§ 3) with the same `--port` and `--realm`; verify it there by address
   (`bash verify.sh <new-ip> <port>`).
2. Point the DNS name at the new host. Wait out the record's TTL.
3. On the old host: `sudo systemctl disable --now hushsend-stun`, then close its port in the router
   and ufw.

Changing the port means changing `VITE_STUN_URLS`, a rebuild and a redeploy of the frontend. And a
move only buys separation if the new host is run by someone else (§ 1).

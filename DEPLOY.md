# hushsend-stun-server — deployment runbook

`turnserver.conf` here has been loaded by a real coturn **4.6.1** and checked end to end: the server
starts, answers STUN, refuses relay allocations, and writes no log. Re-check it on your own host with
§ 4 rather than taking that on faith — the point of this file is a server you can verify, not one you
are told about.

## Status: not yet deployed anywhere (checked 2026-09-18)

This repo is ready to deploy but **is not running as a service anywhere**. hushsend's clients still
point at `stun:turn.hushsend.frelikh.dev:3478` — the coturn on the APP host, which also serves TURN.
So the separation this repo exists for does not exist operationally yet; the repo split happened,
the machine did not. Scheduled for after the product launches.

What was verified on 2026-09-18, by starting this exact config on a spare port rather than reading
it: it comes up, answers STUN, and `verify.sh` (which uses coturn's own `turnutils_uclient`, not a
hand-rolled probe) confirms the relay allocation is refused. So "copy the repo to a machine and run
it" works — after the three edits in § 2, which are NOT optional:

  1. `realm=<YOUR.STUN.HOSTNAME>` is a placeholder and must be replaced.
  2. `external-ip=` must be uncommented if the host is behind NAT.
  3. `tls-listening-port` does nothing without a certificate — see the note in the config.

There is no systemd unit in this repo on purpose: the distro's `coturn.service` reads
`/etc/turnserver.conf`, which is what § 2 installs.

## Two gotchas that cost an afternoon — read these first

**`-n` means "ignore the configuration file".** Not "no daemon". Every `turnserver -c yours.conf -n`
silently discards your config and runs on built-in defaults: port 3478, relaying ON, logging ON. The
symptom is baffling — "Address already in use" on a port your config never mentions, and a log file
appearing at `/var/tmp/turn_*.log` when you set `log-file=/dev/null`. If you see either, drop the
`-n`.

**`no-udp-relay` and `no-tcp-relay` cannot be used together.** coturn rejects the pair
(`CONFIG ERROR: --no-udp-relay and --no-tcp-relay options cannot be used together`) and then discards
the entire file, falling back to defaults — which relay and log. A config that reads as stricter and
silently does the opposite is the worst failure mode available here. That is why this repo disables
relaying by **configuring no authentication at all** instead: a TURN allocation must be
authenticated, a STUN binding request must not, so a server with no credentials to offer cannot hand
out a relay. Verified, not assumed.

## 0. Who runs it

The security value is that this is **not the same party** as the hushsend signaling server: an
adversary holding both can inject an ICE candidate *and* tell the peer to attest that same address,
and hushsend's path attestation passes either way. Separate code is not separate control — if one
person runs both hosts, one order reaches both.

Strongest to weakest: a different organisation (ideally another jurisdiction) → **several independent
STUN servers cross-checked by the client** (the target: `VITE_STUN_URLS` is a list, so no single
operator is authoritative) → a second host you control elsewhere.

## 1. Host + DNS

- A small VM is plenty: STUN answers one packet per request and relays nothing.
- `A`/`AAAA` for the name you will put in `VITE_STUN_URLS`, e.g. `stun.example.org`.
- Behind 1:1 NAT you MUST set `external-ip`, or the server reports a private address and every
  reflexive candidate it hands out is useless.

## 2. Install + configure

```bash
sudo apt-get update && sudo apt-get install -y coturn
sudo install -m 0644 turnserver.conf /etc/turnserver.conf
sudo sed -i 's/<YOUR.STUN.HOSTNAME>/stun.example.org/' /etc/turnserver.conf
```

Then set `external-ip` in `/etc/turnserver.conf` if the host is behind NAT.

```bash
echo 'TURNSERVER_ENABLED=1' | sudo tee /etc/default/coturn
sudo systemctl enable --now coturn
sudo systemctl status coturn --no-pager
```

## 3. Firewall

One port, UDP **and** TCP (some networks block UDP; STUN over TCP still gets through):

```bash
sudo ufw allow 3478/udp
sudo ufw allow 3478/tcp
```

**Do not open a relay range.** There is no relay. If you find yourself opening 49152–65535, re-read
`turnserver.conf`.

## 4. Verify — the gate

```bash
./verify.sh stun.example.org
```

Run it from a **different machine**; a loopback test proves nothing about NAT or the firewall. It
must report STUN answering and the relay allocation refused. Then, on the host itself:

```bash
find /var/tmp /var/log -name 'turn_*' -newermt '-10 minutes' 2>/dev/null
# any output means log-file=/dev/null did not take effect — most likely the config was not loaded
```

A STUN log is a record of who used a privacy tool and when. That is the metadata these users are most
exposed by, so treat a log file as a failed deployment, not a cosmetic issue.

## 5. Point hushsend at it

Build-time, **as one of several**:

```
VITE_STUN_URLS=stun:stun.example.org:3478,stun:stun.partner.net:3478
```

Rebuild and redeploy the frontend. Nothing else changes: Max privacy still never requests a relay from
any STUN server it is given.

---

## Development: all three on one machine

Temporarily running the frontend, the signaling server and this STUN server on one box is fine for
development. It buys **no** security separation — one operator, one machine — so do not read a green
`verify.sh` there as the property being achieved. It is a functional test.

The practical obstacle is the port. If the box already runs a coturn for hushsend's Reliable mode, it
holds **3478/tcp+udp**, so this instance needs its own:

```conf
# /etc/turnserver-hushstun.conf — the dev instance, alongside the existing coturn
listening-port=3479
tls-listening-port=5350      # MUST be set: unset, coturn falls back to 3478 and collides
```

Everything else from `turnserver.conf` is unchanged. Run it as a second unit (or by hand while
testing) and point the client at it:

```
VITE_STUN_URLS=stun:<this-host>:3479
```

Check what is actually taken before choosing ports:

```bash
ss -lntu | grep -E ':(3478|3479|3480|5349|5350)\b'
```

When the STUN server moves to its own host under someone else's control, drop the port override and
use the standard 3478 — and only then does the separation start to mean anything.

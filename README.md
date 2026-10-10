# hushsend-stun-server

A **STUN-only** server for [hushsend](https://github.com/maksimfrelikh/hushsend), deliberately
operated **apart from the signaling server**.

There is no server code here, and there should not be: STUN is answered by `coturn`, which is mature
and audited, and a hand-rolled replacement would be a liability rather than a feature. What this repo
holds is everything else a host needs: the config template, an installer with its own systemd unit
(so it runs alone on a small VM or next to a TURN relay that already owns `coturn.service`), a check
that runs in CI against a real coturn, and `verify.sh` for checking a live server from outside.

**Quick start on a new host** (Debian/Ubuntu, as root):

```bash
git clone https://github.com/maksimfrelikh/hushsend-stun-server.git && cd hushsend-stun-server
sudo bash install.sh --realm stun.example.org --disable-stock-coturn   # add --external-ip PUBLIC/PRIVATE behind NAT
bash verify.sh stun.example.org        # from ANOTHER machine
```

Then point a DNS name at the host and the client at the name (§ Wiring it into hushsend).
[DEPLOY.md](DEPLOY.md) has the details, the firewall and the move between hosts.

## Why separate it at all

hushsend's threat model treats the signaling server as **fully malicious**. A 2026-09-12 audit found
that such a server can put itself on the network path in Max-privacy mode: ICE credentials ride the
SDP it relays, so it can answer connectivity checks itself and inject its own `typ host` candidate at
its own address. Confidentiality survives (DTLS is end-to-end; the fingerprint binding defeats any
MITM that terminates it), but the operator then sees **both IPs, the session duration and the byte
volume** — exactly what Max privacy promises to deny.

The defence is path attestation: after authentication the two peers exchange, over the
DTLS-protected channel, the addresses they can be reached at, and each checks the address it actually
selected against the peer's list. An interposer is then named by the very peer it is impersonating.

**That check has one dependency, and it is this server.** A peer behind NAT learns its own public
address from the STUN server's reply. So an adversary who controls *both* signaling *and* STUN can
inject a candidate AND tell the peer to attest that same address — and the check passes. Splitting
the two means defeating the attestation requires compromising **two independent parties**.

## The property this repo cannot give you by itself

Separate code is not separate control. **If the same person or company runs both hosts, a legal order
reaches both**, and the security gain collapses to "survives the compromise of one machine" — real,
but much weaker than it sounds.

Independence has to be real to count. In rough order of strength:

1. **A different organisation entirely**, ideally in a different jurisdiction — an NGO, a partner
   project, a foundation that already runs infrastructure for at-risk users.
2. **Several independent STUN servers, cross-checked by the client.** hushsend accepts a
   comma-separated `VITE_STUN_URLS`, so the browser gathers a reflexive candidate from each. If two
   independent servers report the same public address and a third disagrees, the liar is visible.
   This is the most robust option because it does not require trusting any single operator — and it
   still works when one of them is yours.
3. **A second host you control, in a different jurisdiction.** Helps against machine compromise, not
   against compulsion.

Option 2 is the recommended target. Treat this repo as one of the several, not as the one.

## What the server must and must not do

**STUN only. No relay.** coturn runs with `stun-only`: it answers binding requests and ignores TURN.

- Max privacy is STUN-only by design — it never requests a relay, so this host must not offer one.
- A relay would put this operator on the media path, which is the position the whole exercise exists
  to keep anyone out of.
- No credentials and no shared secret are configured, so there is nothing here to steal and nothing
  to compel beyond the IP addresses it necessarily observes.

> **Corrected 2026-10-03.** Until then this repo relied on configuring *no* authentication, on the
> theory that coturn must then refuse every relay. Measured, it does the opposite: with no auth
> configured coturn switches to anonymous credentials and hands a relay to anyone who asks. The check
> that had "confirmed" the refusal on 2026-09-18 could not fail (it read the test client's own
> argument error as a refusal). The config never ran anywhere, so nothing was exposed. Now `stun-only`
> does the refusing, and CI proves it both ways: the server refuses an anonymous allocation, and the
> same config without `stun-only` is caught relaying.

**What it unavoidably sees:** the IP and port of every client that asks, and when. That is inherent —
answering "what does my address look like from outside?" requires seeing the address. It is why the
hushsend threat model must state that the STUN operator learns the same rendezvous-time metadata the
signaling operator does, and why the two being different parties is the point.

**What it must never do:** log those addresses. `no-stdout-log` plus a `/dev/null` log file is in the
config, and both the installer and CI check that coturn wrote no log file.

## Files

| File | What it is |
|---|---|
| [`turnserver.conf.template`](turnserver.conf.template) | the coturn config: `stun-only`, no credentials, no logs; per-host values as `@…@` |
| [`stun.env.example`](stun.env.example) | the per-host values; on a host they live in `/etc/hushsend-stun/stun.env` |
| [`render.sh`](render.sh) | renders the template — and refuses a result without `stun-only` or `log-file=/dev/null`, or with credentials |
| [`install.sh`](install.sh) | installs coturn if needed, renders `/etc/hushsend-stun/turnserver.conf`, installs and restarts `hushsend-stun.service`, checks it, rolls back on failure |
| [`hushsend-stun.service`](hushsend-stun.service) | the systemd unit — its own, so it can run next to another coturn |
| [`verify.sh`](verify.sh) | from another machine: STUN answers over UDP, an anonymous relay is refused (plus the TCP port's state, as information) |
| [`check.sh`](check.sh) | CI: the template on a real coturn, with a negative control |
| [`lib.sh`](lib.sh) | the shared checks, including the hand-built TURN Allocate probe |
| [`DEPLOY.md`](DEPLOY.md) | the runbook |

## Wiring it into hushsend

Point the client's build-time STUN list (hushsend `deploy/build-env.sh`) at this host — ideally
**in addition to** independent ones:

```
VITE_STUN_URLS=stun:stun1.example.org:3478,stun:stun2.example.net:3478
```

Nothing else in hushsend changes: the client asks whatever servers it is given, and Max privacy still
never requests a relay from any of them. Use a DNS name, not an address: moving this server to
another host is then a DNS change, not a client rebuild.

## License

MIT — see [LICENSE](LICENSE).

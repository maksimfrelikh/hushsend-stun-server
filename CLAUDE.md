# hushsend-stun-server — guide for Claude Code

STUN for hushsend clients, run apart from the signaling operator. No server code: coturn with
`stun-only`, an installer, checks. Read [README.md](README.md) (why it exists) and
[DEPLOY.md](DEPLOY.md) (§ 0 is the deployment status — keep it true).

## The three repositories

| Repo | Owns |
|---|---|
| [hushsend](https://github.com/maksimfrelikh/hushsend) | the client; `VITE_STUN_URLS` in `deploy/build-env.sh` names this server |
| [hush-signaling-server](https://github.com/maksimfrelikh/hush-signaling-server) | signaling + the TURN relay (`deploy/turn/`) — the OTHER coturn, the one with a secret |
| **hushsend-stun-server** (this) | STUN only: no relay, no credentials, no logs |

The TURN relay and this server both run coturn, but they are separate configs, units and
repositories on purpose: this one must be able to move to another operator without taking any
secret with it.

## Invariants — each one is checked, keep it that way

- **`stun-only` is the control against relaying.** Not "no authentication": with none configured,
  coturn hands out anonymous relays (measured 2026-10-03). `render.sh` refuses a config without
  `stun-only`; `check.sh` (CI) proves an anonymous Allocate is refused AND, as a negative control,
  that the same config without `stun-only` relays — so the probe cannot pass vacuously, which is how
  the old `verify.sh` "confirmed" a refusal that never existed.
- **No credentials** of any kind in the config (`render.sh` refuses them).
- **No logs.** `log-file=/dev/null` + `no-stdout-log`; `check.sh` fails if coturn writes a log file
  or prints anything — an option coturn does not know is logged before `log-file` is read.
- **Never `turnserver -n` with a config file** — `-n` discards it.
- The relay probe is the hand-built TURN Allocate in `lib.sh` (`stun_relay_probe`), not
  `turnutils_uclient`: against a server that ignores TURN the client waits forever.

## Testing

`bash check.sh` needs `turnserver`, `turnutils_stunclient` and `python3`; no root. CI runs it on
Ubuntu's coturn 4.6.1 (laptop-server's version). On the Mac (Homebrew coturn 4.18) the Bash sandbox
cannot bind ports — run it in a terminal tab with `PATH=/opt/homebrew/bin:$PATH`; it passed there on
2026-10-03.

## Deploy

The owner runs `install.sh` (root) and does DNS / router / ufw. Give the exact commands
(DEPLOY.md § 6 for laptop-server), then verify from outside the host's network and update
DEPLOY.md § 0 — "running" is written only after `verify.sh` passed from another network.

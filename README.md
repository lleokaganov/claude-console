# claude-console

Run a [Claude Code](https://docs.claude.com/en/docs/claude-code) instance as
an always-on personal assistant, reachable from your phone over an
end-to-end-encrypted bridge.

A *console* = a wschat bridge + a `claude -p` responder loop + a systemd
unit that auto-restarts both. Each console has a fixed cryptographic
identity, so the contact on your phone's chat app stays stable across
restarts.

Originally built for self-use on a Raspberry Pi; designed so the same
pattern works for any trusted peer (your other devices, family members
you've explicitly given the keys to).

## How it works

```
   ┌────────────┐    e2e-encrypted    ┌────────────────────────────┐
   │ chat app   │ ◄─── wschat ─────► │ wschat bridge              │
   │ on phone   │      bridge         │ (this repo)                │
   └────────────┘                     │   ↓ message                │
                                       │ responder → stream-json    │
                                       │   ↓                        │
                                       │ claude -p (long-running,   │
                                       │   stream-json IO, pinned   │
                                       │   session UUID, --resume)  │
                                       │   ↓ JSON events            │
                                       │ jq parser → assistant text │
                                       │   ↓                        │
                                       │ writes to bridge → peer    │
                                       └────────────────────────────┘
                                       systemd Restart=always
                                       (4 supervised children)
```

`claude` is **one persistent process per console** — not a fresh
invocation per message. The conversation stays in memory, context is
not reloaded on every turn, and the pinned session UUID lets the
process resume the same chat across restarts and reboots.

The peer's chat app must speak the wschat protocol — see the [`telefon`
chat app](https://github.com/lleokaganov/tele) and its
[`claude-client`](https://github.com/lleokaganov/tele/tree/master/claude-client)
(the wschat CLI binary).

## Requirements

- Linux with systemd, `sudo` (passwordless for the install user) and
  `openssl`.
- [Claude Code CLI](https://docs.claude.com/en/docs/claude-code/quickstart)
  installed and authenticated. Strongly recommended: a long-lived OAuth
  token via `claude setup-token` written to an env file — see
  `CLAUDE_TOKEN_ENV` below. Plain `claude login` works too but its OAuth
  expires every ~24h and a long-running claude process won't refresh it.
- `jq` for parsing stream-json events (`sudo apt install jq`).
- A wschat binary on disk. Default path: `/home/claude/wschat`. Override
  with `WSCHAT_BIN=/path/to/wschat` when running `install.sh`.
- A peer running a wschat-compatible chat app, who has shared their public
  contact QR with you.

## Quick start

```sh
sudo mkdir -p /home/claude
sudo chown $USER:$USER /home/claude

# 1. Drop the wschat binary at /home/claude/wschat (or set WSCHAT_BIN).

# 2. Make a directory for the new console — the name is whatever you want
#    to call this peer.
mkdir /home/claude/Alice

# 3. Paste the peer's invite URL or raw QR into key.txt.
#    Both forms work:
#      https://example.org/?peer=K0…              (URL with ?peer= query)
#      K0…                                         (raw QR string)
nano /home/claude/Alice/key.txt

# 4. Install + start.
./install.sh Alice
# (or:  cd /home/claude/Alice && /home/claude/install.sh)
```

After a few seconds the peer's app will receive an introduction and a new
contact "Claude · Alice" will appear in their contact list. Any message
they send is fed to a fresh `claude -p --continue` invocation; the reply
is sent back through the bridge.

## Management

```sh
./restart.sh Alice    # kick a wedged bridge / hung responder
./stop.sh    Alice    # disable + stop (won't come back on boot)
./install.sh Alice    # re-install (idempotent — keeps identity / peer_qr / CLAUDE.md)
```

To watch the live log:

```sh
sudo journalctl -u claude-Alice -f
tail -F /home/claude/Alice/.bridge/log
```

## Configuration

Environment overrides (set when running `install.sh`):

| Var                | Default                            | Meaning                                                    |
|--------------------|------------------------------------|------------------------------------------------------------|
| `CONSOLE_HOME`     | `/home/claude`                     | parent dir for consoles                                    |
| `WSCHAT_BIN`       | `$CONSOLE_HOME/wschat`             | wschat binary path                                         |
| `SERVICE_USER`     | current user                       | systemd `User=`                                            |
| `CLAUDE_TOKEN_ENV` | `$CONSOLE_HOME/.claude-token.env`  | file exporting `CLAUDE_CODE_OAUTH_TOKEN` (long-lived auth) |
| `MAILBOX_X_PUB`    | _empty (off)_                      | hex X25519 pub of a `ws_mailbox` sidecar for offline cache |
| `MAILBOX_ED_PUB`   | _empty (off)_                      | hex Ed25519 pub of that mailbox                            |

### Long-lived auth token

The default `claude login` OAuth token expires every ~24h, and a
long-running claude process inside the console won't refresh it on its
own — without an explicit long-lived token your console will silently
start replying `Not logged in · Please run /login` after a day.

To set up:

```sh
claude setup-token
# Copy the printed sk-ant-oat01-… token, then:
echo 'export CLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat01-...' > /home/claude/.claude-token.env
chmod 600 /home/claude/.claude-token.env
```

The token is valid for one year. `run.sh` sources this file before
starting `claude`, so the env var is in scope of the persistent process.

### ws_mailbox offline cache (optional)

If you also run [`ws_mailbox`](https://github.com/lleokaganov/ws_mailbox)
next to your `ws_server` instance, pass its public keys to
`install.sh` via `MAILBOX_X_PUB` and `MAILBOX_ED_PUB`. The console's
wschat will then transparently store outgoing messages in the mailbox
when the peer is offline, and pull pending messages from it on
reconnect — so chat survives both ends going offline at different
times.

## Files in each console directory

```
<CONSOLE_HOME>/<NAME>/
├── CLAUDE.md                          # persona / context (edit to taste)
├── run.sh                             # generated; supervisor for 4 children
└── .bridge/
    ├── seeds.env                      # fixed crypto seeds      (chmod 600)
    ├── peer_qr                        # the peer's invite QR
    ├── peer_qr.source.txt             # the original URL it came from
    ├── session.uuid                   # pinned claude session ID (chmod 600)
    ├── session.bootstrapped           # marker: session created at least once
    ├── log                            # wschat output (truncated on restart)
    ├── say                            # watch-file: append text to send
    ├── claude.in                      # stream-json user messages → claude
    ├── claude.out                     # stream-json events from claude
    └── claude.err                     # claude stderr (errors only)
```

And one shared (across all consoles) file at `$CONSOLE_HOME/.claude-token.env`
holding the long-lived OAuth token export.

## Security notes

- **`--dangerously-skip-permissions`**. Each `claude -p` invocation is
  launched with that flag — full tool access including shell, file edits
  and (whatever the system user can do via) `sudo`. This is meant for
  consoles whose peer you fully trust — yourself, or a close family
  member. **Don't give an untrusted peer a console.**
- **Identity = trust**. The peer authenticates by their public key. If the
  key is compromised, an attacker can impersonate the peer and drive your
  Claude. Protect the peer's app like any other long-term credential.
- **`.bridge/seeds.env`** is `chmod 600` and contains the console's
  private keys. Don't share it. Don't regenerate it after first run.
- **`CLAUDE.md`** is the only persona/permissions surface. Be explicit
  about what the console can and cannot do. The default template defers
  irreversible / system changes to the owner — adjust as appropriate.
- **The bridge is end-to-end encrypted**: the relay only routes opaque
  ciphertext; the chat app and the bridge are the only places plaintext
  exists. Treat both endpoints accordingly.

## Caveats

- The responder reads wschat's log line-by-line. Multi-line messages
  from the peer carry the nick prefix only on the first line (a wschat
  artefact) — continuation lines are picked up by the same case-arm and
  joined into the user message. Edge cases (peer nicknamed `[wschat]`
  or `  ✓…`) would be eaten as status lines.
- `claude` runs as one persistent process; its conversation is
  rebuilt on restart by `--resume <session UUID>`. If the session
  itself becomes corrupted or you want a fresh start, delete
  `.bridge/session.uuid` and `.bridge/session.bootstrapped`, then
  restart the unit — a new session UUID is generated and the
  conversation starts from scratch (memory files survive).
- The context window will eventually fill. `claude` auto-compacts
  long sessions into summaries near the limit — the peer sees no
  break in conversation, but precise wording of very old turns is
  replaced by summaries.
- No rate limiting. A peer who pastes a wall of text immediately fills
  `claude.in` with that many user-turn events.

## License

MIT. See [LICENSE](LICENSE).

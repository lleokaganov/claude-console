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
   ┌────────────┐    e2e-encrypted    ┌──────────────────┐
   │ chat app   │ ◄─── wschat ──── ► │ wschat bridge    │
   │ on phone   │      bridge         │   (this repo)    │
   └────────────┘                     │                  │
                                       │   ↓ message      │
                                       │ claude -p        │
                                       │   --continue     │
                                       │   ↓ reply        │
                                       │ writes to bridge │
                                       └──────────────────┘
                                       systemd Restart=always
```

The peer's chat app must speak the wschat protocol — see the [`telefon`
chat app](https://github.com/lleokaganov/tele) and its
[`claude-client`](https://github.com/lleokaganov/tele/tree/master/claude-client)
(the wschat CLI binary).

## Requirements

- Linux with systemd, `sudo` (passwordless for the install user) and
  `openssl`.
- [Claude Code CLI](https://docs.claude.com/en/docs/claude-code/quickstart)
  installed and logged in (`claude login`) for the user that will run the
  console.
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

| Var            | Default                       | Meaning                  |
|----------------|-------------------------------|--------------------------|
| `CONSOLE_HOME` | `/home/claude`                | parent dir for consoles  |
| `WSCHAT_BIN`   | `$CONSOLE_HOME/wschat`        | wschat binary path       |
| `SERVICE_USER` | current user                  | systemd `User=`          |

## Files in each console directory

```
<CONSOLE_HOME>/<NAME>/
├── CLAUDE.md                          # persona / context (edit to taste)
├── run.sh                             # generated; bridge + responder
└── .bridge/
    ├── seeds.env                      # fixed crypto seeds  (chmod 600)
    ├── peer_qr                        # the peer's invite QR
    ├── peer_qr.source.txt             # the original URL it came from
    ├── log                            # wschat output (truncated on restart)
    └── say                            # watch-file: append text to send
```

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

- v1 responder is line-based. Multi-line messages from the peer carry the
  nick prefix only on the first line (a wschat artefact) — long-form
  prose may be truncated. To be improved.
- Each incoming message spawns a new `claude -p --continue` process,
  which loads context fresh from `CLAUDE.md` every time. Responses are
  noticeably slower than an interactive Claude session.
- No rate limiting. A peer who pastes a wall of text triggers a wall of
  `claude -p` invocations.

## License

MIT. See [LICENSE](LICENSE).

#!/bin/bash
# claude-console installer — set up a Claude Code "console" reachable from a
# phone over an end-to-end encrypted chat bridge.
#
# A console = (wschat bridge) + (claude -p responder loop) + (systemd unit).
# One console per peer (e.g. yourself, or a family member you trust). Each
# has a fixed cryptographic identity so the peer's contact stays stable.
#
# Usage:
#   cd $CONSOLE_HOME/<NAME> && bash /path/to/install.sh
#   bash install.sh <NAME>
#   NAME=<NAME> bash install.sh
#   curl -fsS <url>/install.sh | bash -s <NAME>
#
# Env overrides:
#   CONSOLE_HOME   parent dir for consoles. Default: /home/claude
#   WSCHAT_BIN     wschat binary to use.    Default: $CONSOLE_HOME/wschat
#   SERVICE_USER   systemd User=.           Default: current user
#
# Bootstrap (only the missing pieces are written; existing files untouched):
#   key.txt            → .bridge/peer_qr  (accepts a peer-invite URL with a
#                                          "?peer=K0…" query, or a raw "K0…"
#                                          QR string)
#   .bridge/seeds.env  → fresh random 32-byte X + ED seeds (FIXED forever
#                        after generation — gives the peer a stable contact)
#   CLAUDE.md          → generic English template (edit to personalise)
#
# Then writes $CONSOLE_HOME/<NAME>/run.sh and the systemd unit
# /etc/systemd/system/claude-<NAME>.service, daemon-reloads, enables, and
# restarts. Idempotent: re-runs refresh run.sh + the unit without touching
# the identity / peer_qr / CLAUDE.md.

set -euo pipefail

CONSOLE_HOME="${CONSOLE_HOME:-/home/claude}"
WSCHAT_BIN="${WSCHAT_BIN:-$CONSOLE_HOME/wschat}"
SERVICE_USER="${SERVICE_USER:-$USER}"

# --- NAME resolution: arg → env → basename of cwd ---
NAME="${1:-${NAME:-}}"
if [ -z "${NAME}" ]; then
  NAME="$(basename "$(pwd)")"
  case "$NAME" in "$(basename "$CONSOLE_HOME")"|""|"/") NAME="" ;; esac
fi
[ -n "${NAME}" ] || { echo "usage: $0 <NAME>  (or run from $CONSOLE_HOME/<NAME>)" >&2; exit 1; }
case "$NAME" in
  *[!A-Za-z0-9_-]*|"") echo "[fatal] bad NAME '$NAME' — allowed: letters, digits, _, -" >&2; exit 1 ;;
esac

DIR="$CONSOLE_HOME/$NAME"
UNIT="claude-${NAME}.service"
UNIT_PATH="/etc/systemd/system/${UNIT}"
TAG="[claude-${NAME}]"

[ -d "$DIR" ] || { echo "$TAG missing $DIR — create the dir first" >&2; exit 1; }
mkdir -p "$DIR/.bridge"
chmod 700 "$DIR/.bridge"

# --- .bridge/peer_qr: bootstrap from key.txt if needed ---
if [ ! -s "$DIR/.bridge/peer_qr" ]; then
  KEYSRC=""
  for cand in "$DIR/key.txt" "$DIR/.bridge/key.txt"; do
    [ -f "$cand" ] && { KEYSRC="$cand"; break; }
  done
  [ -n "$KEYSRC" ] || { echo "$TAG no peer_qr, and no key.txt to seed it from (put the peer's invite URL or raw 'K0…' QR into $DIR/key.txt)" >&2; exit 1; }
  echo "$TAG seeding peer_qr from $KEYSRC"
  raw="$(tr -d '\n\r ' < "$KEYSRC")"
  case "$raw" in
    *"peer="*) QR="${raw#*peer=}"; QR="${QR%%&*}";;
    K0*)       QR="$raw";;
    *) echo "$TAG key.txt content not recognised (expected ?peer=K0… URL or raw K0… QR)" >&2; exit 1;;
  esac
  printf '%s\n' "$QR" > "$DIR/.bridge/peer_qr"
  if [ "$KEYSRC" != "$DIR/.bridge/peer_qr.source.txt" ]; then
    mv "$KEYSRC" "$DIR/.bridge/peer_qr.source.txt"
  fi
fi

# --- .bridge/seeds.env: generate once, then FIXED forever ---
if [ ! -s "$DIR/.bridge/seeds.env" ]; then
  echo "$TAG generating fresh wschat seeds (one-shot — DO NOT regenerate later)"
  X_SEED="$(openssl rand -hex 32)"
  ED_SEED="$(openssl rand -hex 32)"
  cat > "$DIR/.bridge/seeds.env" <<EOF
# Fixed wschat identity for "Claude · ${NAME}". Generated $(date '+%Y-%m-%d').
# Regenerating these = NEW contact in the peer's app (loses chat history).
WSCHAT_X_SEED=${X_SEED}
WSCHAT_ED_SEED=${ED_SEED}
EOF
  chmod 600 "$DIR/.bridge/seeds.env"
fi

# --- CLAUDE.md: write a generic template if absent (edit to taste) ---
if [ ! -f "$DIR/CLAUDE.md" ]; then
  echo "$TAG writing generic CLAUDE.md template (edit $DIR/CLAUDE.md to personalise)"
  cat > "$DIR/CLAUDE.md" <<CLAUDEMD_EOF
# Personal Claude for ${NAME}

You are **${NAME}'s** personal Claude. You run on the host owner's machine
under the user account \`${SERVICE_USER}\` and talk to ${NAME} via an
end-to-end-encrypted bridge from their chat app.

## Who is on the other side
The peer is **${NAME}**. Adjust your tone, language, and assumed expertise
to who they are — this template is intentionally generic; edit it.

## Environment
- Working directory: \`${DIR}\`
- You run as \`${SERVICE_USER}\` with full shell access (the wrapper invokes
  you with \`--dangerously-skip-permissions\`).
- This is the host owner's machine. Treat it accordingly.

## Caution by default
Anything **irreversible** or **system-wide** — package install/remove,
edits to \`/etc\`, restarting network or production services, deleting
files outside \`${DIR}\` — confirm with the owner first via the chat
before doing it. Routine work (answering questions, editing files in
your own directory, helping with text or code) needs no ceremony.

## The bridge
A wrapper (\`run.sh\`) manages the wschat bridge and feeds incoming
messages to you as prompts. Reconnects, queueing and per-restart log
rotation are not your concern. Your reply is whatever you print on stdout.

## Privacy
You have your own session and memory. You do not see other Claude
sessions on this machine (the owner's, or other family members'). Do
not repeat anyone else's chats.
CLAUDEMD_EOF
fi

# --- prerequisites ---
[ -x "$WSCHAT_BIN" ] || { echo "$TAG missing wschat binary at $WSCHAT_BIN (override with WSCHAT_BIN=…)" >&2; exit 1; }
command -v claude >/dev/null || { echo "$TAG 'claude' CLI not in PATH" >&2; exit 1; }

# --- launcher: write run.sh in two parts ---
# Part 1 (UNQUOTED): bake NAME and WSCHAT_BIN into run.sh's own scope.
echo "$TAG writing $DIR/run.sh"
cat > "$DIR/run.sh" <<RUN_HEAD_EOF
#!/bin/bash
# Eternal Claude console — wschat bridge + claude -p responder.
# Generated by install.sh — values baked at install-time.
NAME='${NAME}'
WSCHAT_BIN='${WSCHAT_BIN}'
RUN_HEAD_EOF

# Part 2 (QUOTED): body. All \${...} refs are literal, resolved by run.sh
# at runtime where NAME and WSCHAT_BIN are already set above.
cat >> "$DIR/run.sh" <<'RUN_BODY_EOF'
set -u
cd "$(dirname "$(readlink -f "$0")")"

SAY=.bridge/say
LOG=.bridge/log
QR_FILE=.bridge/peer_qr
SEEDS=.bridge/seeds.env

[ -f "$SEEDS" ]   || { echo "missing $SEEDS"   >&2; exit 1; }
[ -f "$QR_FILE" ] || { echo "missing $QR_FILE" >&2; exit 1; }

. "$SEEDS"
PEER_QR=$(cat "$QR_FILE")
# Nick: "Claude · <NAME>␟claude" — U+241F is a type-tag separator the
# peer's app may use to label the contact as 'type=claude' (optional;
# apps that don't parse it just see the full string as the nick).
NICK=$'Claude · '"${NAME}"$'\xe2\x90\x9fclaude'

touch "$SAY"
: > "$LOG"   # fresh log per restart — wschat re-introduces on (re)connect.

WSCHAT_NICK="$NICK" WSCHAT_X_SEED="$WSCHAT_X_SEED" WSCHAT_ED_SEED="$WSCHAT_ED_SEED" \
  WSCHAT_PEER_QR="$PEER_QR" WSCHAT_WATCH="$SAY" \
  "$WSCHAT_BIN" >> "$LOG" 2>&1 &
WSCHAT_PID=$!

# Line-by-line responder. wschat formats incoming as "<peer.nick>: <text>";
# anything else is status / receipts / blank. The peer's nick is what they
# chose in their app, not our local NAME, and may be empty until they
# introduce themselves — so we don't try to match a specific nick.
# A peer named "[wschat]" or "  ✓" would be eaten, which is silly enough
# to be acceptable for v1.
#
# Background subshell (not exec'd into PID 1) so this script can supervise
# BOTH children. See `wait -n` below for why.
(
  tail -n 0 -F "$LOG" 2>/dev/null | while IFS= read -r line; do
    case "$line" in
      '['*)         continue ;;   # "[wschat] ..." status
      '  ✓'*)       continue ;;   # delivery / read receipts of OUR outgoing
      ''|' '*)      continue ;;   # blank / leading-space cruft
      *': '*)
        msg="${line#*: }"
        [ -z "$msg" ] && continue
        reply=$(claude -p --continue --dangerously-skip-permissions "$msg" 2>/dev/null)
        [ -n "$reply" ] && printf '%s\n' "$reply" >> "$SAY"
        ;;
    esac
  done
) &
RESPONDER_PID=$!

trap 'kill "$WSCHAT_PID" "$RESPONDER_PID" 2>/dev/null; wait 2>/dev/null' EXIT TERM INT

sleep 5
echo "[run.sh ${NAME}] bridge pid=$WSCHAT_PID, responder pid=$RESPONDER_PID — supervising" >&2

# Why wait -n: an earlier version exec'd `tail | while` and ran wschat in
# the background. When wschat died silently, the tail-pipe kept running,
# the script stayed alive, and systemd Restart=always never fired — the
# unit looked healthy but the bridge was dead. Now: whichever child exits
# first triggers this script to exit non-zero → systemd restarts the unit
# → wschat is revived. Needs bash 4.3+ (Debian trixie has 5.x).
wait -n "$WSCHAT_PID" "$RESPONDER_PID"
DEAD_CODE=$?
echo "[run.sh ${NAME}] child exited (code=$DEAD_CODE) — exiting so systemd restarts the unit" >&2
exit 1
RUN_BODY_EOF
chmod +x "$DIR/run.sh"

# --- systemd unit ---
echo "$TAG writing $UNIT_PATH (sudo)"
sudo tee "$UNIT_PATH" > /dev/null <<UNIT_EOF
[Unit]
Description=Claude console for ${NAME} (wschat bridge + responder)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${SERVICE_USER}
WorkingDirectory=${DIR}
ExecStart=${DIR}/run.sh
Restart=always
RestartSec=5s

[Install]
WantedBy=multi-user.target
UNIT_EOF

echo "$TAG daemon-reload + enable + (re)start"
sudo systemctl daemon-reload
sudo systemctl enable "$UNIT"
# `enable --now` is a no-op for an already-active unit, so a re-run wouldn't
# pick up the new run.sh. Restart explicitly.
sudo systemctl restart "$UNIT"

sleep 6
echo
echo "$TAG systemd status:"
sudo systemctl --no-pager --lines=5 status "$UNIT" || true
echo
echo "$TAG bridge log (look for 'me=<id>' + 'connected' + 'ready'):"
tail -15 "$DIR/.bridge/log" 2>/dev/null || echo "(no log yet)"
echo
echo "$TAG DONE. Contact 'Claude · ${NAME}' should appear in the peer's app."
echo "$TAG Check:    sudo journalctl -u $UNIT -f"
echo "$TAG Stop:     sudo systemctl stop $UNIT"
echo "$TAG Disable:  sudo systemctl disable --now $UNIT"

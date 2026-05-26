#!/bin/bash
# Stop + disable a claude-console.
#
#   cd $CONSOLE_HOME/<NAME> && bash stop.sh
#   bash stop.sh <NAME>
#   NAME=<NAME> bash stop.sh
#
# `disable --now` stops the unit AND removes the boot-time enable —
# the console will NOT come back on reboot. Identity, peer_qr, CLAUDE.md
# and the unit file are left in place; re-run `install.sh <NAME>` to
# bring the console back.

set -u

CONSOLE_HOME="${CONSOLE_HOME:-/home/claude}"

NAME="${1:-${NAME:-}}"
if [ -z "${NAME}" ]; then
  NAME="$(basename "$(pwd)")"
  case "$NAME" in "$(basename "$CONSOLE_HOME")"|""|"/") NAME="" ;; esac
fi
[ -n "${NAME}" ] || { echo "usage: $0 <NAME>  (or run from $CONSOLE_HOME/<NAME>)" >&2; exit 1; }
case "$NAME" in
  *[!A-Za-z0-9_-]*|"") echo "[fatal] bad NAME '$NAME'" >&2; exit 1 ;;
esac

UNIT="claude-${NAME}.service"
TAG="[stop ${NAME}]"

if ! systemctl list-unit-files "$UNIT" --no-pager 2>/dev/null | grep -q "$UNIT"; then
  echo "$TAG no such unit — nothing to stop"
  exit 0
fi

echo "$TAG disable --now $UNIT"
sudo systemctl disable --now "$UNIT"

echo "$TAG status:"
sudo systemctl --no-pager --lines=2 status "$UNIT" || true
echo "$TAG done. To bring back: install.sh $NAME"

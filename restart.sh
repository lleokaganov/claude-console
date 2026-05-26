#!/bin/bash
# Restart a claude-console (kick a wedged bridge / hung responder /
# accumulated bridge-log noise).
#
#   cd $CONSOLE_HOME/<NAME> && bash restart.sh
#   bash restart.sh <NAME>
#   NAME=<NAME> bash restart.sh
#
# `systemctl restart` SIGTERMs the whole cgroup, waits, and SIGKILLs if
# needed, then starts fresh. run.sh truncates .bridge/log on every start,
# so bridge-log bloat from a long run resets here too. journald logs are
# NOT touched (journald rotates on its own).

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
DIR="$CONSOLE_HOME/$NAME"
TAG="[restart ${NAME}]"

if ! systemctl list-unit-files "$UNIT" --no-pager 2>/dev/null | grep -q "$UNIT"; then
  echo "$TAG no such unit — install first via install.sh $NAME" >&2
  exit 1
fi

echo "$TAG systemctl restart $UNIT"
sudo systemctl restart "$UNIT"

sleep 6
echo "$TAG status:"
sudo systemctl --no-pager --lines=4 status "$UNIT" || true
echo
echo "$TAG bridge log (look for 'connected' + 'ready'):"
tail -10 "$DIR/.bridge/log" 2>/dev/null || echo "(no log yet)"

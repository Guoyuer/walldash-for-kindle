#!/bin/sh
# Push the deskdash KOReader plugin to the Kindle over SSH, restart KOReader, then take a screenshot.
# Usage: sh tools/deploy_dash.sh [--no-restart]
#
# Normally the running plugin gets "restart" (exit code 85: koreader.sh relaunches KOReader in a few seconds).
# If the plugin isn't running (e.g. it failed to load), KOReader is stopped with SIGTERM and relaunched only once
# koreader.sh has finished: a second launch while the first is still exiting fights over the Kindle UI.
cd "$(dirname "$0")/.." || exit 1
H=${KINDLE_SSH:-kindle}
P=/mnt/us/koreader/plugins/deskdash.koplugin
ssh "$H" "mkdir -p $P" && scp -q deskdash.koplugin/*.lua "$H:$P/" || exit 1
ssh "$H" "cd /mnt/us/koreader && for f in $P/*.lua; do ./luajit -b \$f /dev/null || echo \"SYNTAX ERROR in \$f\"; done"
[ "$1" = "--no-restart" ] && exit 0
ssh "$H" '
ko() { pgrep -o -f "[l]uajit ./reader.lua"; }
OLD=$(ko); : > /mnt/us/koreader/crash.log
if [ -n "$OLD" ]; then
  echo restart > /tmp/deskdash_cmd
  i=0; while [ $i -lt 20 ]; do N=$(ko); [ -n "$N" ] && [ "$N" != "$OLD" ] && break; sleep 1; i=$((i+1)); done
  if [ $i -ge 20 ]; then
    echo "no response to restart, sending SIGTERM"; rm -f /tmp/deskdash_cmd; kill -TERM $OLD
    i=0; while pgrep -f "[k]oreader.sh" >/dev/null && [ $i -lt 300 ]; do sleep 1; i=$((i+1)); done
    if pgrep -f "[k]oreader.sh" >/dev/null; then echo "KOReader did not exit - quit it from its menu"; exit 1; fi
    sleep 5; OLD=
  fi
fi
[ -z "$OLD" ] && setsid /var/local/kmc/bin/kpm launch koreader --asap > /tmp/ko_launch.log 2>&1 < /dev/null &
sleep 15; grep -nE "deskdash|ERROR|rror|traceback" /mnt/us/koreader/crash.log | tail -20; echo "koreader pid: $(ko)"' || exit 1
python tools/kctl.py shot "${SHOT:-tools/inbox/dash.png}" | tail -1

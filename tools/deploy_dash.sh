#!/bin/sh
# Push the deskdash KOReader plugin to the Kindle over SSH, restart KOReader, then take a screenshot.
# Usage: sh tools/deploy_dash.sh [--no-restart]
#
# KOReader is stopped with the plugin's "quit" command (a normal exit), never killed:
# killing it lets koreader.sh's restart loop and a second launch fight over the Kindle UI.
cd "$(dirname "$0")/.." || exit 1
H=${KINDLE_SSH:-kindle}
P=/mnt/us/koreader/plugins/deskdash.koplugin
ssh "$H" "mkdir -p $P" && scp -q deskdash.koplugin/*.lua "$H:$P/" || exit 1
ssh "$H" "cd /mnt/us/koreader && for f in $P/*.lua; do ./luajit -b \$f /dev/null || echo \"SYNTAX ERROR in \$f\"; done"
[ "$1" = "--no-restart" ] && exit 0
ssh "$H" '
if pgrep -f "[l]uajit ./reader.lua" >/dev/null; then
  echo quit > /tmp/deskdash_cmd
  i=0; while pgrep -f "[k]oreader.sh" >/dev/null && [ $i -lt 60 ]; do sleep 1; i=$((i+1)); done
  if pgrep -f "[k]oreader.sh" >/dev/null; then echo "KOReader did not exit cleanly (dashboard closed?) - quit it from its menu"; exit 1; fi
  echo "KOReader exited after ${i}s"; sleep 5
fi
rm -f /tmp/deskdash_cmd; : > /mnt/us/koreader/crash.log
setsid /var/local/kmc/bin/kpm launch koreader --asap > /tmp/ko_launch.log 2>&1 < /dev/null &
sleep 30; grep -nE "deskdash|ERROR|rror|traceback" /mnt/us/koreader/crash.log | tail -20; echo "koreader pid: $(pgrep -f "[l]uajit ./reader.lua" | head -1)"' || exit 1
python tools/kctl.py shot "${SHOT:-tools/inbox/dash.png}" | tail -1

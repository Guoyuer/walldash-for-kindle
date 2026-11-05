#!/bin/sh
# Push the deskdash KOReader plugin to the Kindle and restart KOReader, then take a screenshot.
# Usage: sh tools/deploy_dash.sh [--no-restart]
cd "$(dirname "$0")/.." || exit 1
FILES=$(ls deskdash.koplugin/*.lua)
python tools/kctl.py push $FILES || exit 1
python tools/kctl.py run 'P=/mnt/us/koreader/plugins/deskdash.koplugin; mkdir -p $P && cp /mnt/us/deskdash.koplugin/*.lua $P/
cd /mnt/us/koreader && for f in $P/*.lua; do ./luajit -b $f /dev/null || echo "SYNTAX ERROR in $f"; done'
[ "$1" = "--no-restart" ] && exit 0
KCTL_TIMEOUT=90 python tools/kctl.py run '#timeout=80
pkill -TERM -f "luajit ./reader.lua"; i=0; while pgrep -f "koreader.sh" >/dev/null && [ $i -lt 20 ]; do sleep 1; i=$((i+1)); done
# a stale copy of the startup script makes KOReader nag "startup script has been updated" on every launch
rm -f /var/tmp/koreader.sh
: > /mnt/us/koreader/crash.log
setsid /var/local/kmc/bin/kpm launch koreader --asap > /tmp/ko_launch.log 2>&1 < /dev/null &
sleep 30; grep -nE "deskdash|ERROR|rror|traceback" /mnt/us/koreader/crash.log | tail -20; echo "koreader pid: $(pgrep -f "luajit ./reader.lua" | head -1)"'
python tools/kctl.py shot "${SHOT:-tools/inbox/dash.png}" | tail -1

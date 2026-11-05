#!/bin/sh
# Runs ON THE KINDLE (BusyBox sh), started by tools/deploy_dash.sh with the new plugin unpacked in /tmp/dd.
# Installs it, restarts KOReader, waits for the dashboard, and rolls back to the previous version on errors.
V=$1
P=/mnt/us/koreader/plugins/deskdash.koplugin
LOG=/mnt/us/koreader/crash.log
ko() { pgrep -o -f "[l]uajit ./reader.lua"; }

# Fast path: the plugin's "restart" command (exit code 85 -> koreader.sh relaunches only KOReader, a few seconds).
# Slow path (plugin not running): SIGTERM, wait for koreader.sh to finish restoring the Kindle UI, relaunch.
# Never relaunch while the old koreader.sh is still exiting: two instances fight over the Kindle UI.
restart() {
  : > $LOG; OLD=$(ko)
  if [ -n "$OLD" ]; then
    echo restart > /tmp/deskdash_cmd
    i=0; while [ $i -lt 20 ]; do N=$(ko); [ -n "$N" ] && [ "$N" != "$OLD" ] && return 0; sleep 1; i=$((i+1)); done
    rm -f /tmp/deskdash_cmd; echo "plugin not responding: full KOReader restart (slow, up to a few minutes)"
    kill -TERM $OLD 2>/dev/null
    i=0; while pgrep -f "[k]oreader.sh" >/dev/null && [ $i -lt 300 ]; do sleep 1; i=$((i+1)); done
    if pgrep -f "[k]oreader.sh" >/dev/null; then echo "KOReader did not exit - quit it from its menu"; return 1; fi
    sleep 5
  fi
  setsid /var/local/kmc/bin/kpm launch koreader --asap >/tmp/ko_launch.log 2>&1 </dev/null &
}

# Wait (<= 60 s) until version $1's dashboard is on screen; fail on Lua errors in the log.
verify() {
  i=0; while [ $i -lt 60 ]; do
    grep -q "deskdash: loaded version $1" $LOG && grep -q "deskdash: dashboard up" $LOG && break
    sleep 1; i=$((i+1))
  done
  if grep -nE "page build failed|attempt to|traceback|deskdash[a-z_]*\.lua:[0-9]+:" $LOG; then return 1; fi
  if [ $i -ge 60 ]; then echo "dashboard didn't come up within 60 s"; tail -5 $LOG; return 1; fi
  echo "dashboard up after ${i}s"
}

rm -rf $P.new && cp -r /tmp/dd/deskdash.koplugin $P.new || exit 1
echo "return \"$V\"" > $P.new/deskdash_version.lua
rm -rf $P.bak; [ -d $P ] && mv $P $P.bak; mv $P.new $P
restart || exit 1
if verify "$V"; then echo "deployed $V"; exit 0; fi

echo "*** $V failed - rolling back"
PREV=$(sed -n 's/^return "\(.*\)"$/\1/p' $P.bak/deskdash_version.lua 2>/dev/null)
rm -rf $P.failed; mv $P $P.failed; mv $P.bak $P
restart && verify "${PREV:-dev}" && echo "rolled back to ${PREV:-previous version} (failed build kept in $P.failed)"
exit 1

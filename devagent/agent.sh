#!/bin/sh
# Kindle side of the debug relay. Long-polls $SRV for shell commands, runs them, posts output back.
# Lives at /mnt/us/devagent/agent.sh; started by documents/DevAgent_Start.sh.
# A command whose first line is "#timeout=N" gets N seconds (default 30) before it is killed.
DIR=/mnt/us/devagent
. "$DIR/config.sh"            # sets SRV and TOK
export SRV TOK
export PATH="$DIR/bin:$PATH"
LOG=$DIR/agent_log.txt
echo $$ > "$DIR/agent.pid"
: > "$LOG"
log() { echo "$(date -u '+%F %T') $*" >> "$LOG"; }

if command -v curl >/dev/null 2>&1; then HTTP=curl; else HTTP=wget; fi
export HTTP
log "agent up, srv=$SRV http=$HTTP"

# keep the device (and Wi-Fi) awake while debugging
lipc-set-prop com.lab126.powerd preventScreenSaver 1 2>>"$LOG"

fails=0
while :; do
  if [ "$HTTP" = curl ]; then
    curl -s -m 30 -o /tmp/devagent_cmd "$SRV/poll?t=$TOK"
  else
    wget -q -T 30 -O /tmp/devagent_cmd "$SRV/poll?t=$TOK"
  fi
  rc=$?
  if [ $rc -ne 0 ]; then
    fails=$((fails + 1)); [ $fails -le 3 ] && log "poll failed rc=$rc"
    sleep 3; continue
  fi
  [ $fails -gt 0 ] && log "poll ok again"; fails=0
  [ -s /tmp/devagent_cmd ] || continue

  id=$(head -n 1 /tmp/devagent_cmd)
  tail -n +2 /tmp/devagent_cmd > /tmp/devagent_cmd.sh
  T=$(sed -n '1s/^#timeout=\([0-9][0-9]*\).*/\1/p' /tmp/devagent_cmd.sh); T=${T:-30}

  # run in its own process group so a timeout kills everything it started
  ( cd /mnt/us && exec setsid sh /tmp/devagent_cmd.sh ) > /tmp/devagent_out 2>&1 < /dev/null &
  cp=$!
  ( sleep "$T"; kill -9 -"$cp" 2>/dev/null || kill -9 "$cp" 2>/dev/null; echo "[killed after ${T}s]" >> /tmp/devagent_out ) &
  wp=$!
  wait "$cp"; rc=$?
  kill "$wp" 2>/dev/null
  echo "[exit $rc]" >> /tmp/devagent_out
  sh "$DIR/bin/kpost" "result?id=$id" /tmp/devagent_out

  # self-update: a command can touch this file to make the agent re-exec itself
  if [ -f /tmp/devagent_restart ]; then
    rm -f /tmp/devagent_restart; log "re-exec"; exec sh "$DIR/agent.sh"
  fi
done

#!/bin/sh
# Name: Dev Agent - Start
# Author: kindle-mod
# Connects to the debug relay on the PC (see devagent/config.sh). Stop: "Dev Agent - Stop" or restart.
DIR=/mnt/us/devagent
[ -f "$DIR/agent.pid" ] && kill "$(cat "$DIR/agent.pid")" 2>/dev/null
if command -v setsid >/dev/null 2>&1; then
  setsid sh "$DIR/agent.sh" >> "$DIR/agent_log.txt" 2>&1 < /dev/null &
else
  nohup sh "$DIR/agent.sh" >> "$DIR/agent_log.txt" 2>&1 < /dev/null &
fi
sleep 2

#!/bin/sh
# Name: Dev Agent - Stop
# Author: kindle-mod
DIR=/mnt/us/devagent
[ -f "$DIR/agent.pid" ] && kill "$(cat "$DIR/agent.pid")" 2>/dev/null
rm -f "$DIR/agent.pid"
# leave screensaver prevention alone if the desk clock is running
[ -f /mnt/us/deskclock/clock.pid ] && kill -0 "$(cat /mnt/us/deskclock/clock.pid)" 2>/dev/null || \
  lipc-set-prop com.lab126.powerd preventScreenSaver 0

#!/bin/sh
# Name: SSH - Start
# Author: kindle-mod
# Starts the key-only SSH server (also started automatically when the deskdash plugin loads).
sh /mnt/us/kdev/sshd.sh > /tmp/kindle_sshd_start.log 2>&1

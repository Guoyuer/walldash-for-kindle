#!/bin/sh
# Start a key-only SSH server on the Kindle (port 22, LAN only), using Jobman's dropbear.
# Jobman's dropbear build reads authorized_keys and host keys from /mnt/us/jobman/ssh/etc/dropbear.
# Idempotent: does nothing if it's already running.
D=/mnt/us/jobman/bin/dropbearmulti
K=/mnt/us/jobman/ssh/etc/dropbear
[ -x "$D" ] || { echo "dropbear not found ($D)"; exit 1; }
cp /mnt/us/kdev/authorized_keys $K/authorized_keys
iptables -C INPUT -i wlan0 -p tcp --dport 22 -s 192.168.0.0/16 -j ACCEPT 2>/dev/null ||
  iptables -I INPUT -i wlan0 -p tcp --dport 22 -s 192.168.0.0/16 -j ACCEPT
P=/var/run/kindle_sshd.pid
if [ -f $P ] && kill -0 "$(cat $P)" 2>/dev/null; then echo "sshd already running"; exit 0; fi
# -s: no password logins, -R: create host keys once, -K: keepalive
$D dropbear -R -s -p 22 -K 30 -P $P 2>>/tmp/kindle_sshd.log
echo "sshd started"

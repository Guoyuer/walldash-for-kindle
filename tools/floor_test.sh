#!/bin/sh
# Suspend floor A/B on the Kindle: our `rtcwake -m mem` vs the stock powerd suspend, same duration, Wi-Fi off.
# Run detached on the device (Wi-Fi goes off, so SSH drops):  setsid sh /tmp/floor_test.sh >/dev/null 2>&1 &
# It waits for the charger to be unplugged, takes ~2*SECS + 40 s, and writes /mnt/us/floor_test.log.
# 2026-11-09: powerd ignored the rtcWakeup set at readyToSuspend and slept until the power button was pressed,
# so B needs a button press to end (the longer sleep only makes the sample better).
# Each sample logs wall s, monotonic ms (stops while suspended) and the gauge's raw coulomb counter (69800/mAh).
export LD_LIBRARY_PATH=
SECS=${1:-90}
BAT=/sys/class/power_supply/bd71827_bat
AC=/sys/class/power_supply/bd71827_ac/online
OUT=/mnt/us/floor_test.log
EV=goingToScreenSaver,readyToSuspend,suspending,resuming,wakeupFromSuspend,outOfScreenSaver

cc() { echo $((0x$(grep -E '^\[0x7[9ABC]\]' $BAT/registers | sed 's/.*= //' | tr -d '\r\n'))); }
mono() { awk '/now at/ { print int($3 / 1000000); exit }' /proc/timer_list; }
mark() { echo "$1 wall=$(date +%s) mono_ms=$(mono) cc=$(cc)" >>$OUT; }

: >$OUT
touch /tmp/deskdash_awake                 # the dashboard stays awake and leaves suspending to this script
n=0
while [ "$(cat $AC)" != 0 ]; do           # wait for the unplug (at most 30 min)
    n=$((n + 1)); [ $n -gt 900 ] && { echo "gave up waiting for unplug" >>$OUT; exit 1; }
    sleep 2
done
echo "unplugged, secs=$SECS" >>$OUT
lipc-set-prop com.lab126.cmd wirelessEnable 0
sleep 8                                   # Wi-Fi down, charger current settled

# A: ours
cat $BAT/registers >/mnt/us/floor_regs_a.txt
mark A_before
rtcwake -d /dev/rtc1 -m mem -s $SECS >/dev/null 2>&1
mark A_after
dmesg | tail -80 >/mnt/us/floor_dmesg_a.txt
sleep 3

# B: stock powerd. Power button -> screensaver -> readyToSuspend -> we set the RTC alarm -> powerd suspends.
rm -f /tmp/floor_b_done /tmp/floor_b_armed
lipc-set-prop com.lab126.powerd preventScreenSaver 0
lipc-wait-event -m -s $((SECS + 120)) com.lab126.powerd $EV | while read ev rest; do
    case $ev in
    readyToSuspend)
        if [ ! -f /tmp/floor_b_armed ]; then
            touch /tmp/floor_b_armed
            cat $BAT/registers >/mnt/us/floor_regs_b.txt
            mark B_before
            lipc-set-prop -i com.lab126.powerd rtcWakeup $SECS
        fi ;;
    resuming|wakeupFromSuspend)
        [ -f /tmp/floor_b_done ] || { mark B_after; touch /tmp/floor_b_done; } ;;
    esac
    echo "event $ev $rest wall=$(date +%s) mono_ms=$(mono)" >>$OUT
done &
sleep 1
mark B_button
powerd_test -p >/dev/null 2>&1
n=0
while [ ! -f /tmp/floor_b_done ] && [ $n -lt $((SECS + 100)) ]; do n=$((n + 1)); sleep 1; done
[ -f /tmp/floor_b_done ] || echo "B: no resume event (armed: $(ls /tmp/floor_b_armed 2>/dev/null))" >>$OUT
dmesg | tail -120 >/mnt/us/floor_dmesg_b.txt

# Back to the dashboard's normal state.
lipc-set-prop com.lab126.powerd preventScreenSaver 1
sleep 1
state=$(lipc-get-prop com.lab126.powerd state)
echo "state after B: $state" >>$OUT
[ "$state" = active ] || powerd_test -p >/dev/null 2>&1
# Our lipc-wait-event exits by its -s timeout. Never pkill lipc-wait-event: KOReader runs its own, and killing it
# leaves KOReader spinning on "Polling for input events returned an error: 32" (restart KOReader to recover).
lipc-set-prop com.lab126.cmd wirelessEnable 1
echo done >>$OUT

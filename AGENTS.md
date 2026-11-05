# AGENTS.md — handoff notes for coding agents

Goal: a jailbroken Kindle hung on the wall as an always-on clock + weather display, running on battery.
User-facing docs are in `README.md` (Chinese). This file is the setup/context an agent needs to keep working.

## Device

- Kindle Paperwhite 4 (PW4), firmware 5.18.1, hard-float (`kindlehf`), 1072x1448, 300 dpi, 8bpp framebuffer (stride 1088).
- Jailbroken (SpiderCat). Installed via KPM (`/var/local/kmc/bin/kpm`, repo repo.kindlemodding.org): **KOReader 2026.7.2**, **Jobman**.
- Wi-Fi IP `192.168.0.10` (DHCP; update `~/.ssh/config` if it changes). Touch: goodix `/dev/input/event2`; power key `event0`.
- `/mnt/us` is the user storage (vfat). **Plugged into a PC, it's exported as USB mass storage and unmounted on the device**: scripts there stop and SSH fails. Use a wall charger while developing.

## Access: SSH (key only)

- `ssh kindle` — host alias in `~/.ssh/config` (root, `~/.ssh/kindle_ed25519`). Password logins are disabled.
- Server: Jobman's dropbear (`/mnt/us/jobman/bin/dropbearmulti`), started by `kdev/sshd.sh`. That dropbear build reads
  `authorized_keys` and host keys from `/mnt/us/jobman/ssh/etc/dropbear/` (it ignores `~/.ssh`); `sshd.sh` copies
  `kdev/authorized_keys` there and opens port 22 for 192.168.0.0/16 in iptables (default INPUT policy is DROP).
- Started automatically when the deskdash plugin loads (KOReader start), or by the library scriptlet **SSH - Start**.
- **When unplugged in battery mode the Kindle is suspended ~58 s of every minute → SSH is unreachable.** Plug it into a
  charger (it then stays awake), or press the power button for a 60 s window.
- Remote `pgrep -f`/`pkill -f`: the pattern also matches the `sh -c` running your ssh command. Use `"[k]oreader.sh"` style patterns.

## Tools (PC side)

```bash
python tools/kctl.py run "cmd"          # ssh
python tools/kctl.py shot [out.png]     # framebuffer screenshot -> tools/inbox/shot.png (needs Pillow)
python tools/kctl.py dash next|prev|refresh|close|quit|sleep|"page N" [out.png]   # plugin command + screenshot
python tools/kctl.py push file ...      # repo-relative -> same path under /mnt/us
python tools/kctl.py tap X Y / swipe X1 Y1 X2 Y2   # injected touch: stock UI only (KOReader EVIOCGRABs the touchscreen)
sh tools/deploy_dash.sh [--no-restart]  # push plugin, luajit syntax check, restart KOReader, check crash.log, screenshot
```

- Plugin commands go through `/tmp/deskdash_cmd` (polled every second) because injected touches can't reach KOReader.
- `deploy_dash.sh` stops KOReader with `quit` (or SIGTERM if the plugin isn't loaded) and **waits for `koreader.sh` to
  finish before relaunching**. Never kill KOReader and relaunch immediately: two instances fight over the stock UI, and
  you get a "startup script updated" dialog and a stuck Home screen (needed a reboot once).
- Launch KOReader: `setsid /var/local/kmc/bin/kpm launch koreader --asap`. Logs: `/mnt/us/koreader/crash.log`.

## The dashboard: `deskdash.koplugin/`

KOReader plugin (installed to `/mnt/us/koreader/plugins/deskdash.koplugin`). Menu: Tools > Desk dashboard.

- `main.lua`: menu/settings (`deskdash_*` in KOReader settings: autostart, clock_24h, battery_mode, units), opens the
  dashboard at KOReader start, reopens it after 5 idle minutes, starts sshd. Plugin-local modules must be `require`d
  at load time and are prefixed `deskdash_` to avoid name clashes.
- `deskdash_weather.lua`: Open-Meteo forecast + ip-api location/UTC offset, via the system `curl`
  (**must run with `LD_LIBRARY_PATH=`** inside KOReader). Weather glyphs from KOReader's `nerdfonts/symbols.ttf`.
- `deskdash_dashboard.lua`: full-screen InputContainer, 4 pages (Now / Hourly / 7-Day / Details). Swipe = page,
  tap = refresh, long-press = close. Ticks on each minute; weather every 15 min (retried next minute on failure);
  flashing full refresh every 30 min; back to page 1 after 2 min idle.
  - Times: Kindle clock is UTC; `now()` adds the API's `utc_offset_seconds`; always format with `os.date("!...")`.
  - Layout gotcha: `FrameContainer:getSize()` ignores width/height → use the `fixed(w, h)` child helper.
  - Low-contrast e-ink: secondary text is 0x33 gray, not lighter. Fonts: NotoSans Regular/Bold (KOReader can't see Amazon Ember).

### Battery mode (`sleepUntilNextMinute`)

- When unplugged (`/sys/class/power_supply/bd71827_ac/online` = 0), on page 1 and ≥60 s after the last touch: after the
  minute redraw (+2 s for the e-ink refresh) it runs `rtcwake -d /dev/rtc1 -m mem -s <secs to next minute>`.
  `/dev/rtc1` (snvs) is the wake-capable RTC; rtc0 isn't. Measured awake time ≈ 2–3 s per minute.
- KOReader timers use a clock that stops during suspend, so the pending tick is unscheduled and called directly on wake.
- Waking more than 2 s early = power button (or USB plug-in) → stays awake/interactive for 60 s. Touch can't wake it.
- The frontlight comes back on at every resume, so it's turned off before sleeping and restored only on an early
  (power-button) wake or when the dashboard closes.
- Wi-Fi drops during suspend and reassociates ~2 s after resume; `waitForWifi()` polls `lipc-get-prop com.lab126.wifid cmState` (≤20 s) before fetching.
- `/mnt/us/deskdash_battery.log`: battery % at each weather fetch. The `sleep` command forces one cycle even when plugged in.
- Bypasses the stock powerd (it keeps `preventScreenSaver 1`); powerd hasn't objected so far.

## Known quirks / decisions

- The stock status bar (Wi-Fi/battery; five dashes while Wi-Fi reconnects) sometimes shows in the top-right corner
  even though KOReader stops `awesome` and disables pillow. The user said this is fine; don't spend time on it.
- The user prefers simple solutions, no NAS/server dependency, and tapping KOReader by hand after a reboot (no boot autostart).
- `initctl stop lab126_gui` was tried and rejected: the stock UI takes 30–60 s to come back.
- `ref/` (gitignored) has KOReader source for API reference; the device copy is in `/mnt/us/koreader/frontend/`.

## Repo conventions

- LF line endings (`.gitattributes`); shell scripts run on BusyBox `sh` (no bash-isms).
- Don't commit secrets; `tools/inbox/` (screenshots) is ignored.

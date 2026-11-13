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
sh tools/check.sh                       # < 1 s, no Kindle: compile all plugin files, flag unknown globals, tests/run.lua
sh tools/deploy_dash.sh [--shots]       # ~12 s: check -> upload -> restart -> verify -> auto-rollback -> screenshot
python tools/kctl.py run "cmd"          # ssh
python tools/kctl.py shot [out.png]     # screenshot (~2.5 s) -> tools/inbox/shot.png (needs Pillow)
python tools/kctl.py dash next|prev|refresh|close|demo|"page N"|"tap X Y" [out.png]
python tools/kctl.py command quit|restart|sleep|"demo off"
python tools/kctl.py push file ...      # repo-relative -> same path under /mnt/us
```

Dev loop: edit -> `sh tools/deploy_dash.sh` -> look at `tools/inbox/dash.png` (`--shots`: all 4 pages + `demo.png`).

- **Local checks** (`tools/check.sh`) need LuaJIT on the PC (`winget install DEVCOM.LuaJIT`, same 2.1 as the device).
  `luajit -bl` bytecode listings are scanned for GGET/GSET of names outside an allow-list, which catches a
  missing `local` / typo'd upvalue. Pure logic (parseWallTime, precipSummary, activeAlert, moon, levels) lives in
  `deskdash_weather.lua` so `tests/run.lua` can test it without KOReader's UI (it stubs logger/json off-device).
- **Deploy** (`deploy_dash.sh` + device-side `kindle_deploy.sh`): one ssh session (tar of plugin + script over stdin).
  The new build goes to `plugins/deskdash.koplugin`, the old one to `.koplugin.bak`; `deskdash_version.lua`
  (`git describe --dirty`) is written into it and logged as `deskdash: loaded version …`. It waits for
  `deskdash: dashboard up` after the first paint and before the weather request. It fails on Lua errors in
  crash.log (`page build failed`, `attempt to`, `file.lua:N:`),
  then **rolls back** to `.bak` (failed build kept as `.koplugin.failed`; KOReader only loads dirs ending in `.koplugin`).
- Restart: the plugin's `restart` command (exit code 85: `koreader.sh` relaunches only KOReader, a few seconds). If the
  plugin isn't running (main.lua failed to load) it falls back to SIGTERM and **waits for `koreader.sh` to finish**
  (restores the stock UI, can take >3 min) before launching. Never kill KOReader and relaunch immediately: two
  instances fight over the stock UI ("startup script updated" dialog, stuck Home screen; needed a reboot once).
- Plugin commands go through `/tmp/deskdash_cmd` (polled every second) because KOReader EVIOCGRABs the touchscreen.
  `kctl dash` waits for a matching repaint acknowledgment before reading the framebuffer. Deploy screenshots
  also wait for the first weather attempt. Keep commands serial.
- Screenshots: `/dev/fb0` holds several frames (6.8 MB, 23 s over Wi-Fi); `kctl` reads only the visible one, gzipped (~35 KB).
- Remote: private GitHub repo `Guoyuer/kindle-mod` (push after committing). No cloud CI: deploying needs the LAN.
- Launch KOReader: `setsid /var/local/kmc/bin/kpm launch koreader --asap`. Logs: `/mnt/us/koreader/crash.log`.

## The dashboard: `deskdash.koplugin/`

KOReader plugin (installed to `/mnt/us/koreader/plugins/deskdash.koplugin`). Menu: Tools > Desk dashboard.

- `main.lua`: reads saved dashboard options from KOReader settings (`deskdash_*`), opens the
  dashboard at KOReader start, reopens it after 5 idle minutes, starts sshd. Plugin-local modules must be `require`d
  at load time and are prefixed `deskdash_` to avoid name clashes.
- `deskdash_weather.lua`: one Open-Meteo request for `best_match` and NBM. Hourly and daily forecasts use NBM together,
  with a whole-forecast fallback to `best_match`. The homepage precipitation hint uses the same hourly interval
  and probability as the hourly page. Current model estimates and daily UV come from `best_match`.
  CAMS AQI (labelled as an estimate) + NWS alerts (api.weather.gov, US only; fetched even if the forecast fails) + computed moon phase +
  ip-api location/UTC offset, via the system `curl`.
  **Current conditions come from the nearest NWS station's latest observation** (`Weather.observation`, station
  cached after the first lookup; Queens Plaza -> KNYC Central Park), mapped to a WMO code by `Weather.obsCode`;
  Open-Meteo's modelled `current.weather_code` is only the fallback (>2 h old / unknown text / outside the US). The
  model said "Clear" (7 % cloud) while every station reported Cloudy, so don't trust it for the sky.
  Model accuracy study: `docs/weather-accuracy.md` (NBM beats best_match ~2x on temperature here; rerun
  `python tools/verify_forecast.py`)
  (**must run with `LD_LIBRARY_PATH=`** inside KOReader). `deskdash_weather_job.lua` runs Wi-Fi wait and HTTP
  requests in one subprocess. The UI keeps using cached data and collects results asynchronously.
  Weather glyphs from KOReader's `nerdfonts/symbols.ttf`.
- `deskdash_dashboard.lua`: full-screen InputContainer, 4 pages (Now / Hourly / 7-Day / Details). Swipe = page,
  tap = refresh, long-press = close. Ticks on each minute; weather at fixed wall-clock slots a few minutes
  after NWS stations report: :03/:18/:33/:48 plugged in, :03 on battery (`WEATHER_STEP*`, `Weather.secondsToSlot`;
  failed automatic requests back off from 1 min to at most 15 min). The worker sends forecast, alerts, observation
  and AQI as parallel `curl`s (`Weather.curlAll`); AQI only when the cached value is ≥ 55 min old;
  flashing full refresh every 30 min; back to page 1 after 2 min idle. Pages 2–4 have page dots and a settings gear for
  language, clock format and orientation. Closing the dashboard restores KOReader's prior orientation.
  Page 1 has no city name, page dots or gear. It shows
  an alert line and a precipitation line when there is one. On battery at <= 20 % a "Charge me" badge appears bottom-left.
  Details = 8 tiles (feels like, humidity, wind, UV, precipitation, AQI, next sun event, moon).
  - Times: `localNow()` adds the API's UTC offset to the UTC clock to match `parseWallTime`'s offset-free
    forecast timestamps. Before geolocation it uses the Kindle's configured time zone. Format those values
    with `os.date("!...")` and use `os.time()` for elapsed time.
  - Layout gotcha: `FrameContainer:getSize()` ignores width/height → use the `fixed(w, h)` child helper.
  - Low-contrast e-ink: secondary text is 0x33 gray, not lighter. Fonts: NotoSans Regular/Bold (KOReader can't see Amazon Ember).

### Battery mode (`sleepUntilNextMinute`)

- When unplugged (`/sys/class/power_supply/bd71827_ac/online` = 0), on page 1 and ≥60 s after the last touch: after the
  minute redraw it paints, waits for the e-ink refresh to finish (`UIManager:waitForVSync()`), then runs `rtcwake -d /dev/rtc1 -m mem -s <secs to next minute>`.
  `/dev/rtc1` (snvs) is the wake-capable RTC; rtc0 isn't. Measured awake time ≈ 2–3 s per minute.
- KOReader timers use a clock that stops during suspend, so the pending tick is unscheduled and called directly on wake.
- Waking more than 2 s early = power button (or USB plug-in) → stays awake/interactive for 60 s. Touch can't wake it.
- The frontlight comes back on at every resume, so it's turned off before sleeping and restored on an early
  (power-button) wake, on any minute tick that doesn't go back to sleep (e.g. charger plugged in), or when the dashboard closes.
- Wi-Fi is switched off before each sleep (`lipc-set-prop com.lab126.cmd wirelessEnable 0`) and on only to fetch the
  weather (~10 s to connect; the worker polls `com.lab126.wifid cmState` for up to 30 s), then off again at the next sleep.
  The dashboard waits for an in-flight weather job before suspending. The PW4 kernel syncs filesystems on suspend entry.
  `restore()` turns light + Wi-Fi back on when staying awake (power button, charger, dashboard closed). Only Wi-Fi the
  plugin switched off is switched back on.
- Night (`NIGHT`, local 2:00-5:00): wakes only every 10 minutes (`Weather.secondsToNextWake`) and skips weather
  fetches (`Weather.isNight`). Full flashing refresh when the local minute is a multiple of 30.
- The `sleep` command forces one cycle even when plugged in.
- **Power log** `/mnt/us/deskdash_power.csv` (`powerTick`/`logPower`): one row per hour + on plug/unplug/start/close.
  Counters (wakes, power-button wakes, fetches, failures, Wi-Fi wait s) are in memory; awake_s is the delta of
  KOReader's monotonic clock (stops during suspend), so it costs nothing per wake. charge_mAh = fuel-gauge coulomb
  counter (`bd71827_bat/charge_now`, µAh), its drop per hour = average mA. `python tools/power.py` fetches it and
  prints mA per interval, awake %, projected days, and a fit mA = asleep + k·awake. Use it to judge power changes.
- **Metrics** `/mnt/us/deskdash_metrics.csv` (long format: time,event,metric,n,sum,max; flushed with each power row):
  every Bench phase is aggregated in memory (wake.*, weather.*, command.*), plus resume.to_tick, refresh.ui/full,
  suspend.failed and CPU ms (cpu.koreader, cpu.system_busy/total). `python tools/power.py --metrics` ranks them.
  Monotonic awake times include up to ~1 s of RTC-resolution error per suspend (sleep is restored in whole seconds).
  Dev flag `/tmp/deskdash_awake`: the dashboard doesn't sleep while it exists and keeps Wi-Fi on; with it, the
  `sleep` command runs one real cycle that sleeps only 6 s, so `bench on` + 10x `kctl command sleep` + `flush`
  benchmarks wakes in ~1.5 min. `flush` writes the power/metrics rows immediately.
- The `cc` column is the gauge's raw coulomb counter (~69800 counts/mAh); use it over `charge_mAh` (1 mAh steps).
  The touch controller is locked (`/proc/touch`) around each `rtcwake` (~0.5 mA lower). Currents: docs/performance-benchmarks.md.
- Bypasses the stock powerd (it keeps `preventScreenSaver 1`); powerd hasn't objected so far.

## Known quirks / decisions

- Performance baseline, benchmark commands, and battery-test handoff are in
  [docs/performance-benchmarks.md](docs/performance-benchmarks.md).

- The stock status bar (Wi-Fi/battery; five dashes while Wi-Fi reconnects) sometimes shows in the top-right corner
  even though KOReader stops `awesome` and disables pillow. The user said this is fine; don't spend time on it.
- The user prefers simple solutions, no NAS/server dependency, and tapping KOReader by hand after a reboot (no boot autostart).
- The Kindle is only a wall clock, so `main.lua` adds `autosuspend` to KOReader's `plugins_disabled` (effective from
  the next KOReader start). Don't add hand-over code for that plugin or patch it on the device.
  Why: on 2026-11-09 at 07:03 its Kindle t1 task re-queued itself with a past deadline and spun the UI loop: no
  ticks, no suspends, powerd logging `batmon:Charging state` ~185 times/s (`/var/local/log/messages_*.gz`), ~33 mA
  until 11:21 (142 mAh). The tell-tale is hourly rows missing from `deskdash_power.csv` without a `close` row.
  Don't unpack those logs into `/tmp` (64 MB tmpfs shared with `/var`); pipe `zcat` instead.
- `initctl stop lab126_gui` was tried and rejected: the stock UI takes 30–60 s to come back.
- `ref/` (gitignored) has KOReader source for API reference; the device copy is in `/mnt/us/koreader/frontend/`.

## Repo conventions

- LF line endings (`.gitattributes`); shell scripts run on BusyBox `sh` (no bash-isms).
- Don't commit secrets; `tools/inbox/` (screenshots) is ignored.

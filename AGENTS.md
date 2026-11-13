# DeskDash development notes

Use the [README](README.md) for installation and the [contribution guide](CONTRIBUTING.md) for testing and deployment.

## Code and checks

- Keep changes small. Reuse the existing KOReader widgets and test pure logic in `tests/run.lua`.
- Run `sh tools/check.sh` before deployment. Use LF line endings and BusyBox-compatible shell syntax on the Kindle. Use PowerShell-native syntax on Windows.
- Preserve unrelated work. Read-only investigations leave files and devices alone. Verify the result at the feature's normal entry point.
- Keep private keys, device configuration, and raw captures out of Git. `ref/` and `tools/inbox/` are local directories.

## Plugin

- `main.lua` registers the plugin and manages KOReader settings. Require plugin-local modules at load time and prefix them with `deskdash_`.
- `deskdash_dashboard.lua` handles input, layout, refresh scheduling, and device power. `deskdash_curve.lua` handles chart interpolation. Check affected pages in both orientations and languages.
- `deskdash_weather.lua` parses and selects data. `deskdash_weather_job.lua` runs the Wi-Fi wait and requests in a background process. Keep network I/O off the UI thread. Clear `LD_LIBRARY_PATH` when running Kindle system curl.
- Format forecast wall times with `os.date("!...")`. Use `os.time()` for elapsed wall time and KOReader's monotonic clock for awake time.

## PW4 power and deployment

- Keep Kindle-specific hardware operations scoped to the PW4. It uses `/dev/rtc1` for timed wake, `/proc/touch` for touch power, and the BD71827 power supply paths. Use the SDL build to check UI and a PW4 to check suspend, wake, and current draw.
- Wait for e-ink refresh and in-flight weather before suspending. KOReader's monotonic timers pause in suspend. Preserve the minute tick on wake and restore Wi-Fi, touch, and frontlight on interactive wake or close.
- DeskDash disables KOReader's Auto suspend on PW4. Keep one owner for suspend. A past-deadline Auto suspend task has caused the UI loop to spin, with missing hourly power samples while the dashboard was open.
- Use a wall charger during SSH development. USB mass-storage mode unmounts `/mnt/us`, and a suspended device cannot answer SSH. Send dashboard commands serially and wait for repaint acknowledgment before capturing the framebuffer.
- Let `koreader.sh` finish restoring the stock UI before relaunching KOReader. The deploy helper verifies first paint and rolls back on startup errors.

# Contributing to WallDash

Report the Kindle model, firmware and KOReader version, power source, language, orientation, and steps to reproduce. For display bugs, include the affected page and a screenshot. Review logs and screenshots for personal information before attaching them.

## Offline checks

Use LuaJIT 2.1 and a POSIX shell. On Ubuntu, install LuaJIT with `sudo apt-get install luajit`. On Windows, use Git for Windows and `winget install DEVCOM.LuaJIT` or use WSL.

```sh
sh tools/check.sh
```

The script compiles the plugin, checks Lua global names, and runs the weather and chart tests without a Kindle or network connection. GitHub Actions also checks shell and Python syntax.

## UI and hardware testing

Use the [KOReader SDL emulator](https://github.com/koreader/koreader/blob/v2026.07.2/doc/Building.md#building-and-running-the-emulator) on Linux or macOS, or use WSL with graphical support. In a dedicated KOReader source checkout, copy `deskdash.koplugin/` into `plugins/`. After building KOReader, run from its root:

```sh
./kodev run -w=1072 -h=1448 -d=300
```

On Linux, the KOReader AppImage also runs the plugin. Copy the directory into the AppImage's data directory under `plugins/` (typically `~/.config/koreader/plugins/`) and set `EMULATE_READER_W`, `EMULATE_READER_H`, and `EMULATE_READER_DPI` when launching it.

Check all four pages in portrait and landscape, including English and Chinese, 12- and 24-hour clocks, both temperature units, and the behavior when weather is unavailable. For other Kindle models, the [QEMU-based e-ink emulator](https://github.com/katadelos/eink-emulator) can help check firmware startup and installation on the supported guest images. Add hardware support only after verifying touch, suspend-to-RAM, RTC and power-button wake, Wi-Fi and frontlight recovery, and behavior both plugged in and on battery on that model.

## Optional Kindle development tools

For SSH deployment, install [Jobman](https://github.com/KindleTweaks/jobman) via KPM. On the computer, generate an Ed25519 key (or use an existing key pair):

```sh
ssh-keygen -t ed25519 -f ~/.ssh/kindle_ed25519
```

Via USB, copy `kdev/sshd.sh` to `kdev/sshd.sh` on the Kindle drive and your **public** key to `kdev/authorized_keys`. The key stays local to your setup. Copy `documents/SSH_Start.sh` to the Kindle's `documents/` folder, eject the drive, and run **SSH - Start** from the library. The plugin also runs the helper at KOReader startup if it is installed. The helper starts root SSH with public-key authentication and permits port 22 on the Wi-Fi interface from `192.168.0.0/16`. Adjust both subnet rules in your local copy of the helper if your network uses a different range.

In the computer's `~/.ssh/config`, replace `<kindle-wifi-ip>` with the device's Wi-Fi IP:

```sshconfig
Host kindle
    HostName <kindle-wifi-ip>
    User root
    IdentityFile ~/.ssh/kindle_ed25519
    IdentitiesOnly yes
```

Connect the Kindle to a wall charger while developing. Battery mode makes SSH intermittently unavailable, and USB mass storage unmounts the files the server needs. Use Python 3 and install Pillow for screenshots and the deploy helper.

```sh
python -m pip install Pillow
ssh kindle
python tools/kctl.py shot
python tools/kctl.py dash next
sh tools/deploy_dash.sh --shots
```

The deploy helper assumes the KPM KOReader layout. It runs the local checks, uploads the plugin, restarts KOReader, verifies the first paint, and restores the previous plugin if startup fails. Send dashboard commands one at a time.

See [power and latency testing](docs/performance-benchmarks.md) for hardware benchmarks and [weather sources](docs/weather-accuracy.md) for provider selection and fallbacks.

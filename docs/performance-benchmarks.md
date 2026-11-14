# PW4 power and latency testing

Use the [optional SSH setup](../CONTRIBUTING.md#optional-kindle-development-tools) on a Kindle Paperwhite 4. Record the firmware, KOReader and WallDash versions, orientation, power source, frontlight, and Wi-Fi state. Compare runs with the same conditions and keep charger-powered latency tests separate from battery tests.

## Latency

Open WallDash while connected to a wall charger. Run from the repository root:

```sh
python tools/kctl.py command 'bench on'
python tools/kctl.py command refresh
python tools/kctl.py command 'page 2'
python tools/kctl.py command 'page 4'
python tools/kctl.py command 'page 1'
python tools/benchmark.py
python tools/kctl.py command 'bench off'
```

`command` measures UI dispatch, paint submission, and e-ink refresh wait after the dashboard receives the command. `weather` includes Wi-Fi connection and the network requests. To test a forced suspend cycle, use `python tools/kctl.py command sleep` on the home page, then wait for wake and Wi-Fi before reading the results. This command can suspend even on external power.

`tools/benchmark.py` reads `/tmp/deskdash_bench.tsv` over SSH or accepts a saved TSV. It reports p95 when a group has at least 20 samples.

## Battery

Unplug the charger with the home page open. Let WallDash wake naturally for several hours, including a full night window when comparing night behavior. Reconnect power to collect results:

```sh
python tools/power.py
python tools/power.py --metrics
```

The tools read the hourly power and timing logs from `/mnt/us/deskdash_power.csv` and `/mnt/us/deskdash_metrics.csv`. Compare average discharge current, awake fraction, weather retries, and Wi-Fi time. Compare daytime and the 02:00–05:00 night window separately. Missing hourly samples are worth checking against the device log before calculating an average.

The current estimate uses the BD71827 gauge's raw coulomb counter when available. Awake time comes from KOReader's monotonic clock and can include up to about a second of RTC rounding per wake. The runtime estimate uses a 1,503 mAh reference capacity, so measure your device's full discharge for a battery-life figure.

In a November 2026 test on one PW4 with firmware 5.18.1, Wi-Fi off and touch unlocked, bare `rtcwake` suspend drew about 3.1 mA and stock `powerd` suspend about 2.5 mA (±0.3 mA). These estimates cover suspend alone. The running dashboard also wakes to refresh the screen and fetch weather. The test procedure is in `tools/floor_test.sh` and may require a power-button wake from stock suspend.

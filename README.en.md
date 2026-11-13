# DeskDash for Kindle

[简体中文](README.md)

Turn a jailbroken Kindle Paperwhite 4 into a wall-mounted e-ink clock and weather display. Swipe through current conditions, a 24-hour temperature and precipitation chart, a seven-day forecast, and details such as wind, UV, air quality, and moon phase.

<img src="docs/dashboard.png" width="320" alt="DeskDash showing the time, current temperature, and an upcoming rain notice">

## Compatibility

DeskDash supports the **Kindle Paperwhite 4 (10th generation, 2018)**. The tested configuration is firmware **5.18.1** with KOReader **2026.07.2** (`kindlehf`). Use KOReader's SDL build for [desktop UI testing](CONTRIBUTING.md#ui-and-hardware-testing).

## Install

1. Install [KOReader](https://github.com/koreader/koreader/wiki/Installation-on-Kindle-devices) on an already jailbroken PW4 and open it once.
2. Quit KOReader and connect the Kindle via USB. Download or clone this repository and copy the entire `deskdash.koplugin` directory into `koreader/plugins/` on the Kindle drive. The resulting path is `koreader/plugins/deskdash.koplugin/main.lua`.
3. Safely eject the Kindle, connect it to Wi-Fi, and open KOReader from the library. The dashboard opens automatically by default. To open it manually, use **Tools → Desk dashboard → Open dashboard**.

To update or uninstall, quit KOReader, then replace or remove the plugin directory. After uninstalling, re-enable **Auto suspend** in KOReader's plugin management and restart KOReader.

## Use

- Swipe left or right to change pages, tap to refresh the weather, or long-press to return to KOReader. The dashboard reopens after five idle minutes in the file browser.
- The gear on pages 2–4 controls language, clock format, units, and orientation.
- Battery mode is on by default. On battery, the home page updates once a minute, then sleeps. Press the power button for roughly a minute of interaction. From 2 to 5 a.m. local time, the clock updates every 10 minutes and skips weather requests. Weather usually updates hourly on battery and every 15 minutes on external power.
- Use **Tools → Desk dashboard** to turn off automatic opening or battery mode. DeskDash disables KOReader's Auto suspend from the next KOReader start to avoid concurrent sleep timers.

## Weather data and privacy

By default, [ip-api](https://ip-api.com/docs/api:json) infers an approximate location from your public IP over HTTP. DeskDash processes and displays forecast, nowcast, and air-quality data from [Open-Meteo](https://open-meteo.com/). US station observations and alerts come from the [National Weather Service](https://www.weather.gov/documentation/services-web-api). Requests to the weather providers include latitude and longitude.

You can [set a fixed location](docs/weather-accuracy.md#fixed-location) to skip the IP lookup.

Open-Meteo data is licensed under [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/). The plugin uses its free hosted endpoint, which is available for non-commercial use under the [Open-Meteo terms](https://open-meteo.com/en/terms).

See [CONTRIBUTING.md](CONTRIBUTING.md) for offline checks, the KOReader emulator, and optional device tools. The project source is licensed under [GNU AGPL v3](LICENSE).

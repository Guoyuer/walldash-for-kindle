# Weather sources and model selection

## Fixed location

Quit KOReader and open `koreader/settings.reader.lua`. Add these entries inside the settings table, replacing the example coordinates with your own. The city name is optional. When both coordinates are set, DeskDash skips IP geolocation.

```lua
["deskdash_lat"] = 48.8584,
["deskdash_lon"] = 2.2945,
["deskdash_city"] = "Paris",
```

## Data sources

| Display | Source |
| --- | --- |
| Current condition text and icon | Recent US National Weather Service station observation when available. Falls back to the Open-Meteo model if the station report is older than two hours or its condition is unavailable. |
| Current temperature, wind, and humidity | Open-Meteo `best_match` model estimates. |
| Hourly and seven-day forecasts | Open-Meteo's NOAA National Blend of Models (`ncep_nbm_conus`) when the forecast fields are available. Falls back to `best_match` for both pages together. |
| Near-term rain and snow | Open-Meteo `best_match` 15-minute precipitation and snowfall. Falls back to the hourly precipitation summary when there is no near-term notice. |
| UV, sunrise, sunset, and air quality | Open-Meteo forecast and air-quality APIs. AQI is a model estimate. |
| US weather alerts | National Weather Service. |

## Forecast comparison

One seven-day comparison in New York City, ending November 5, 2026, compared day-ahead forecasts from the Open-Meteo Previous Runs API with hourly observations from two NWS stations.

| Station | Matched hours | NBM temperature MAE | `best_match` temperature MAE |
| --- | ---: | ---: | ---: |
| LaGuardia (KLGA) | 95 | 1.10 °C | 2.69 °C |
| Central Park (KNYC) | 142 | 0.92 °C | 2.37 °C |

The temperature results informed the preference for NBM where available. The comparison covers a single city and week, with only one hour of measured precipitation. It does not establish accuracy for other regions, current conditions, or the 15-minute nowcast.

Run `python tools/verify_forecast.py` from the repository root to repeat the comparison for the latest seven days. It uses public weather endpoints and takes a fresh sample each time.

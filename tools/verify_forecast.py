"""Day-ahead forecast skill of Open-Meteo models vs NWS station observations (last 7 days, Queens Plaza).

  python tools/verify_forecast.py

See docs/weather-accuracy.md for the method and results.
"""
import json, urllib.request, datetime as dt, statistics as st

LAT, LON = 40.7507, -73.9393
UA = {"User-Agent": "deskdash-kindle"}
MODELS = ["best_match", "gfs_seamless", "ncep_nbm_conus", "ecmwf_ifs025", "icon_seamless", "gem_seamless"]


def get(url, headers=None):
    return json.load(urllib.request.urlopen(urllib.request.Request(url, headers=headers or {}), timeout=60))


def obs(station):
    end = dt.datetime.now(dt.timezone.utc)
    start = end - dt.timedelta(days=7)
    url = (f"https://api.weather.gov/stations/{station}/observations?start={start:%Y-%m-%dT%H:%M:%SZ}"
           f"&end={end:%Y-%m-%dT%H:%M:%SZ}&limit=500")
    out = {}
    for f in get(url, UA)["features"]:
        p = f["properties"]
        t = dt.datetime.fromisoformat(p["timestamp"]).astimezone(dt.timezone.utc)
        if t.minute < 45:   # keep the routine ~:51 hourly METAR
            continue
        hour = (t + dt.timedelta(minutes=10)).replace(minute=0, second=0, microsecond=0)
        layers = [c.get("amount") for c in p.get("cloudLayers") or []]
        cover = max([{"CLR": 0, "SKC": 0, "FEW": 19, "SCT": 44, "BKN": 75, "OVC": 100, "VV": 100}.get(a, 0) for a in layers] or [0]) if layers else None
        pr = p.get("precipitationLastHour", {}).get("value")
        out[hour] = dict(temp=p["temperature"]["value"], cover=cover, precip=pr, text=p["textDescription"])
    return out


def forecasts():
    v = "temperature_2m_previous_day1,precipitation_previous_day1,cloud_cover_previous_day1"
    url = (f"https://previous-runs-api.open-meteo.com/v1/forecast?latitude={LAT}&longitude={LON}&hourly={v}"
           f"&models={','.join(MODELS)}&past_days=7&forecast_days=1&timezone=GMT")
    d = get(url)["hourly"]
    times = [dt.datetime.fromisoformat(t).replace(tzinfo=dt.timezone.utc) for t in d["time"]]
    res = {}
    for m in MODELS:
        suf = "" if len(MODELS) == 1 else "_" + m
        res[m] = {t: dict(temp=d.get("temperature_2m_previous_day1" + suf, [None] * len(times))[i],
                          precip=d.get("precipitation_previous_day1" + suf, [None] * len(times))[i],
                          cover=d.get("cloud_cover_previous_day1" + suf, [None] * len(times))[i])
                  for i, t in enumerate(times)}
    return res


def score(fc, ob, label):
    print(f"\n== vs {label} ({len(ob)} hourly obs) ==")
    print(f"{'model':16} {'temp MAE':>8} {'bias':>6} {'cloud MAE':>9} {'sky hit':>7} {'rain hit':>8} {'false rain':>10} {'n':>4}")
    for m, f in fc.items():
        te, cl, sky, hits, miss, fa, n = [], [], [], 0, 0, 0, 0
        for h, o in ob.items():
            x = f.get(h)
            if not x or x["temp"] is None:
                continue
            n += 1
            if o["temp"] is not None:
                te.append(x["temp"] - o["temp"])
            if o["cover"] is not None and x["cover"] is not None:
                cl.append(abs(x["cover"] - o["cover"]))
                sky.append((x["cover"] >= 60) == (o["cover"] >= 60))   # "cloudy or not" agreement
            if o["precip"] is not None and x["precip"] is not None:
                wet_o, wet_f = o["precip"] > 0.2, x["precip"] >= 0.2
                hits += wet_o and wet_f; miss += wet_o and not wet_f; fa += wet_f and not wet_o
        mae = st.mean(abs(e) for e in te) if te else float("nan")
        bias = st.mean(te) if te else float("nan")
        print(f"{m:16} {mae:8.2f} {bias:6.2f} {st.mean(cl) if cl else float('nan'):9.1f} "
              f"{100 * sum(sky) / len(sky) if sky else float('nan'):6.0f}% "
              f"{hits:3d}/{hits + miss:<4d} {fa:10d} {n:4d}")


fc = forecasts()
for s in ["KLGA", "KNYC"]:
    score(fc, obs(s), s)

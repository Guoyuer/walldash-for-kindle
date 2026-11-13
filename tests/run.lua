-- Offline tests for the dashboard's weather, chart, and device selection logic.
-- Run from the repo root: luajit tests/run.lua  (PC), or on the Kindle inside /mnt/us/koreader (real logger/rapidjson).
-- tools/check.sh runs this before every deploy.
local plugin_dir = arg and arg[1] or "deskdash.koplugin"
package.path = plugin_dir .. "/?.lua;" .. package.path
if not pcall(require, "logger") then   -- not inside KOReader: stub what the module needs
    package.preload.logger = function() return { info = print, warn = print, err = print, dbg = function() end } end
    package.preload.json = function() return { decode = function() error("no json on this host") end } end
end
local W = require("deskdash_weather")

local failed, passed = 0, 0
local function eq(name, got, want)
    if got == want then passed = passed + 1
    else failed = failed + 1; print(string.format("FAIL %s: got %s, want %s", name, tostring(got), tostring(want))) end
end
local hm = function(t) return os.date("!%H:%M", t) end

-- Unsupported devices must return before loading UI or touching Kindle power settings.
do
    local device = package.loaded.device
    package.loaded.device = { model = "KindlePaperWhite5", isSDL = function() return false end }
    eq("other Kindle models do not load the plugin", dofile(plugin_dir .. "/main.lua").disabled, true)
    package.loaded.device = device
end

-- Exercise station discovery without making network requests.
do
    local json = package.loaded.rapidjson or package.loaded.json
    local decode, popen = json.decode, io.popen
    local station_url = "https://api.weather.gov/gridpoints/OKX/34,45/stations"
    local station_id, calls = "KNYC", 0
    json.decode = function(body)
        if body == "point" then return { properties = { observationStations = station_url } } end
        return { features = { { properties = { stationIdentifier = station_id } } } }
    end
    io.popen = function(cmd)
        calls = calls + 1
        local body = cmd:find("/points/", 1, true) and "point" or "stations"
        return { read = function() return body end, close = function() end }
    end
    eq("station discovery accepts NWS gridpoints URL", W.findStation(40.7829, -73.9654), "KNYC")
    eq("station discovery fetches point and station list", calls, 2)
    station_id = "bad/station"
    eq("station discovery rejects malformed identifier", W.findStation(40.7829, -73.9654), nil)
    station_url, calls = "https://example.org/gridpoints/OKX/34,45/stations", 0
    eq("station discovery rejects other hosts", W.findStation(40.7829, -73.9654), nil)
    eq("station discovery stops after an unexpected URL", calls, 1)
    json.decode, io.popen = decode, popen
end

-- parseWallTime: "local" epochs that format back to the same wall-clock time
eq("parseWallTime time", hm(W.parseWallTime("2026-11-05T13:00")), "13:00")
eq("parseWallTime date-only = noon", hm(W.parseWallTime("2026-11-05")), "12:00")
eq("parseWallTime leap day", os.date("!%Y-%m-%d", W.parseWallTime("2028-02-29T10:00")), "2028-02-29")
eq("parseWallTime epoch", W.parseWallTime("1970-01-01T00:00"), 0)
eq("parseWallTime DST day", os.date("!%Y-%m-%d %H:%M", W.parseWallTime("2026-03-08T03:30")), "2026-03-08 03:30")
eq("parseWallTime alert with offset", hm(W.parseWallTime(("2026-11-05T18:00:00-05:00"):sub(1, 16))), "18:00")
eq("malformed wall time", W.parseWallTime("unknown"), nil)

local hourly = {
    time = { "2026-11-05T15:00", "2026-11-05T16:00", "2026-11-05T17:00", "2026-11-05T18:00" },
    precipitation_probability = { 90, 6, 69, 1 },
}
eq("hourly probability uses interval end", W.hourlyPrecipChance(hourly, 2), 70)
eq("low probability rounds to five", W.hourlyPrecipChance(hourly, 1), 5)
eq("small probability rounds to zero", W.hourlyPrecipChance(hourly, 3), 0)
eq("summary agrees with hourly row", W.precipSummary(hourly, W.parseWallTime("2026-11-05T15:30"), hm), "16:00–17:00 · 70% precip")
local Chinese = require("deskdash_chinese")
eq("Chinese precipitation summary", W.precipSummary(hourly, W.parseWallTime("2026-11-05T15:30"), hm,
    Chinese["%s–%s · %d%% precip"]), "16:00–17:00 · 降水 70%")
eq("current interval remains eligible", W.precipSummary(hourly, W.parseWallTime("2026-11-05T16:15"), hm), "16:00–17:00 · 70% precip")
eq("expired interval ignored", W.precipSummary(hourly, W.parseWallTime("2026-11-05T17:00"), hm), nil)
eq("missing hourly forecast", W.precipSummary(nil, 0, hm), nil)

local function forecastFixture(default_suffix, missing_nbm)
    local h = { time = hourly.time }
    local d = { time = { "2026-11-05" } }
    for _, field in ipairs{ "temperature_2m", "weather_code", "precipitation_probability", "is_day" } do
        h[field .. default_suffix] = { 1, 2, 3, 4 }
        if default_suffix ~= "" then h[field .. "_ncep_nbm_conus"] = { 0, 12, 13, 14 } end
    end
    for _, field in ipairs{ "weather_code", "temperature_2m_max", "temperature_2m_min", "precipitation_sum" } do
        d[field .. default_suffix] = { 2 }
        if default_suffix ~= "" then d[field .. "_ncep_nbm_conus"] = { 20 } end
    end
    if missing_nbm then d.precipitation_sum_ncep_nbm_conus = {} end
    d["uv_index_max" .. default_suffix] = { 4 }
    return { hourly = h, daily = d, daily_units = { ["precipitation_sum" .. default_suffix] = "inch" } }
end
local nbm = W.selectForecast(forecastFixture("_best_match"))
eq("NBM hourly selected including zero", nbm.hourly.temperature_2m[1], 0)
eq("NBM daily selected", nbm.daily.precipitation_sum[1], 20)
eq("UV uses default", nbm.daily.uv_index_max[1], 4)
eq("units are retained", nbm.daily_units.precipitation_sum, "inch")
local fallback = W.selectForecast(forecastFixture("_best_match", true))
eq("missing daily NBM falls back hourly too", fallback.hourly.temperature_2m[1], 1)
eq("missing daily NBM falls back daily", fallback.daily.precipitation_sum[1], 2)
local outside = W.selectForecast(forecastFixture(""))
eq("unsuffixed hourly outside coverage", outside.hourly.temperature_2m[1], 1)
eq("unsuffixed daily outside coverage", outside.daily.temperature_2m_max[1], 2)

local partial = forecastFixture("")
partial.current = { temperature_2m = 0, apparent_temperature = {} }
partial.daily.sunrise = { "2026-11-05T06:30" }
partial.daily.sunset = { {} }
local selected = W.selectForecast(partial)
eq("current zero survives normalization", selected.current.temperature_2m, 0)
eq("invalid feels-like is absent", selected.current.apparent_temperature, nil)
eq("sunrise is parsed", hm(selected.daily.sunrise[1]), "06:30")
eq("invalid sunset is absent", selected.daily.sunset[1], nil)
eq("missing sunrise series is safe", outside.daily.sunrise[1], nil)

local daily = { time = { "2026-11-05", "2026-11-06" } }
local day_index, is_today = W.firstForecastDay(daily, W.parseWallTime("2026-11-06T00:01"))
eq("yesterday is skipped after midnight", day_index, 2)
eq("cached second day becomes today", is_today, true)
day_index, is_today = W.firstForecastDay(daily, W.parseWallTime("2026-11-04T23:59"))
eq("future-only forecast starts at first date", day_index, 1)
eq("a future date is not today", is_today, false)
eq("expired daily forecast", W.firstForecastDay(daily, W.parseWallTime("2026-11-07T00:00")), nil)

-- activeAlert
local now = W.parseWallTime("2026-11-05T15:00")
eq("no alerts", W.activeAlert(nil, now, hm), nil)
eq("active alert", W.activeAlert({ { event = "Wind Advisory", ends = "2026-11-05T18:00:00-05:00" } }, now, hm), "Wind Advisory until 18:00")
eq("Chinese alert preserves provider title", W.activeAlert({ { event = "Wind Advisory", ends = "2026-11-05T18:00:00-05:00" } },
    now, hm, Chinese["%s until %s"]), "Wind Advisory · 至 18:00")
eq("expired alert skipped", W.activeAlert({ { event = "Old", ends = "2026-11-05T14:00:00-05:00" },
    { event = "Flood Watch", ends = "2026-11-06T06:00:00-05:00" } }, now, hm), "Flood Watch until 06:00")
eq("alert without end", W.activeAlert({ { event = "Heat Advisory" } }, now, hm), "Heat Advisory")

-- moon
local name, lit = W.moon(947182440)          -- new moon 2000-01-06 18:14 UTC
eq("new moon name", name, "New Moon"); eq("new moon dark", lit < 0.01, true)
name, lit = W.moon(948429600)                -- full moon 2000-01-21 04:40 UTC
eq("full moon name", name, "Full Moon"); eq("full moon lit", lit > 0.98, true)
eq("moon icon is 3 bytes", #select(3, W.moon(os.time())), 3)

-- night schedule (2:00-5:00, every 10 min)
local N = { from = 2, to = 5, step = 10 }
local at = function(hhmmss) return W.parseWallTime("2026-11-05T" .. hhmmss:sub(1, 5)) + tonumber(hhmmss:sub(7, 8)) end
eq("day: next minute", W.secondsToNextWake(at("13:20:15"), N), 45)
eq("01:59 -> 02:00", W.secondsToNextWake(at("01:59:30"), N), 30)
eq("02:00 -> 02:10", W.secondsToNextWake(at("02:00:01"), N), 599)
eq("02:13 -> 02:20", W.secondsToNextWake(at("02:13:20"), N), 400)
eq("04:50 -> 05:00", W.secondsToNextWake(at("04:50:02"), N), 598)
eq("05:00 -> 05:01", W.secondsToNextWake(at("05:00:02"), N), 58)
eq("night 03:00", W.isNight(at("03:00:00"), N), true)
eq("not night 05:00", W.isNight(at("05:00:00"), N), false)
eq("not night 01:59", W.isNight(at("01:59:59"), N), false)

-- weather slots (step, offset minutes, gap seconds)
eq("battery slot :33", W.secondsToSlot(at("13:20:15"), 30, 3, 300), 12 * 60 + 45)
eq("fetch at :03 -> :33", W.secondsToSlot(at("13:03:15"), 30, 3, 300), 29 * 60 + 45)
eq("manual :31 skips :33", W.secondsToSlot(at("13:31:00"), 30, 3, 300), 32 * 60)
eq("plugged slot :18", W.secondsToSlot(at("13:03:10"), 15, 3, 300), 14 * 60 + 50)
eq("hourly battery slot :03", W.secondsToSlot(at("13:03:15"), 60, 3, 300), 59 * 60 + 45)
eq("slot crosses midnight", os.date("!%H:%M", at("23:50:00") + W.secondsToSlot(at("23:50:00"), 30, 3, 300)), "00:03")
eq("missing forecast body", select(2, W.parseForecast(nil)), "no response")
eq("missing alerts body", W.parseAlerts(nil), nil)
eq("missing AQI body", W.parseAirQuality(nil), nil)

-- NWS observation text -> WMO code
eq("obs cloudy", W.obsCode("Cloudy"), 3); eq("obs mostly cloudy", W.obsCode("Mostly Cloudy"), 3)
eq("obs partly", W.obsCode("Partly Cloudy"), 2); eq("obs clear", W.obsCode("Clear"), 0); eq("obs sunny", W.obsCode("Sunny"), 0)
eq("obs light rain+fog", W.obsCode("Light Rain and Fog/Mist"), 61); eq("obs heavy rain", W.obsCode("Heavy Rain"), 65)
eq("obs showers", W.obsCode("Showers in Vicinity"), 80); eq("obs drizzle", W.obsCode("Light Drizzle"), 53)
eq("obs snow", W.obsCode("Light Snow"), 71); eq("obs freezing", W.obsCode("Freezing Rain"), 66)
eq("obs thunder", W.obsCode("Thunderstorms and Rain"), 95); eq("obs fog", W.obsCode("Fog/Mist"), 45)
-- shortText: real NWS strings (KNYC/KLGA/KJFK, Nov 2026) -> home-page headline
eq("short single", W.shortText("Mostly Cloudy"), "Mostly Cloudy")
eq("short empty", W.shortText(""), "")
eq("short rain+fog", W.shortText("Light Rain and Fog/Mist"), "Light Rain")
eq("short cloudy+windy", W.shortText("Partly Cloudy and Windy"), "Partly Cloudy")
eq("short wind only", W.shortText("Windy"), "Windy")
eq("short thunder+rain", W.shortText("Thunderstorms and Rain and Fog/Mist"), "Thunderstorms")
eq("short worst KJFK", W.shortText("Heavy Thunderstorms and Heavy Rain and Thunderstorms and Hail and Fog/Mist"),
    "Heavy Thunderstorms")
eq("short two precip fit", W.shortText("Rain and Snow"), "Rain and Snow")
eq("short fog+haze", W.shortText("Fog/Mist and Haze"), "Fog/Mist and Haze")
eq("short double space", W.shortText("Light  Snow and Fog and Blowing Snow"), "Light Snow")
eq("short thunder first", W.shortText("Light Rain and Fog/Mist and Thunderstorms"), "Thunderstorms")
eq("short fog then snow", W.shortText("Fog and Blowing Snow"), "Blowing Snow")
eq("short two precip", W.shortText("Light Snow and Sleet and Fog and Blowing Snow"), "Light Snow and Sleet")
local function rest(s) return select(2, W.shortText(s)) end
eq("rest single", rest("Mostly Cloudy"), nil)
eq("rest rain+fog", rest("Light Rain and Fog/Mist"), "Fog/Mist")
eq("rest windy", rest("Partly Cloudy and Windy"), "Windy")
eq("rest worst KJFK", rest("Heavy Thunderstorms and Heavy Rain and Thunderstorms and Hail and Fog/Mist"),
    "Heavy Rain · Hail · Fog/Mist")
eq("rest thunder first", rest("Light Rain and Fog/Mist and Thunderstorms"), "Light Rain · Fog/Mist")
eq("rest wind only", rest("Windy and Breezy"), "Breezy")
eq("rest two in head", rest("Rain and Snow"), nil)
eq("obs unknown precip -> model", W.obsCode("Unknown Precipitation and Fog"), nil)
eq("obs haze", W.obsCode("Haze"), 45); eq("obs unknown", W.obsCode("Funnel Cloud?"), nil); eq("obs empty", W.obsCode(""), nil)

-- nowcast: 15-minute sums ending at each timestamp
local function minutely(values, snow, unit)
    local m = { time = {}, precipitation = values, snowfall = snow or {}, unit = unit or "mm" }
    for i = 1, #values do
        m.time[i] = os.date("!%Y-%m-%dT%H:%M", W.parseWallTime("2026-11-05T15:00") + (i - 1) * 900)
    end
    for i = 1, #values do m.snowfall[i] = m.snowfall[i] or 0 end
    return m
end
local t1505 = W.parseWallTime("2026-11-05T15:05")
local nc = W.nowcast(minutely{ 0, 0, 0, 0.1, 0.4, 0, 0 }, t1505)
eq("nowcast start kind", nc.kind, "start")
eq("nowcast start minutes", nc.minutes, 25)   -- wet from 15:30 (the 15:45 value covers 15:30-15:45)
eq("nowcast rain", nc.snow, false)
eq("nowcast text", W.nowcastText(nc), "Rain in ~25 min")
eq("nowcast Chinese", W.nowcastText(nc, function(s) return Chinese[s] end), "约 25 分钟后有雨")
nc = W.nowcast(minutely{ 0, 0.5, 0.2, 0, 0 }, t1505)
eq("nowcast stop kind", nc.kind, "stop")
eq("nowcast stop minutes", nc.minutes, 25)    -- wet until 15:30
eq("nowcast stop text", W.nowcastText(nc), "Rain stopping in ~25 min")
nc = W.nowcast(minutely({ 0.3, 0.3, 0.3, 0.3, 0.3, 0.3, 0.3, 0.3, 0.3 }, { 0.5, 0.5, 0.5, 0.5, 0.5, 0.5, 0.5, 0.5, 0.5 }), t1505)
eq("nowcast steady kind", nc.kind, "steady")
eq("nowcast steady minutes", nc.minutes, 105)   -- 15:05 -> 17:00, whole quarter hours
eq("nowcast snow", nc.snow, true)
eq("nowcast steady text", W.nowcastText(nc), "Snow for the next 1 h 45 min")
eq("nowcast steady Chinese", W.nowcastText(nc, function(s) return Chinese[s] end), "未来 1 小时 45 分钟持续下雪")
eq("nowcast dry", W.nowcast(minutely{ 0, 0, 0.05, 0 }, t1505), nil)
eq("nowcast past rain ignored", W.nowcast(minutely{ 2, 0, 0, 0 }, W.parseWallTime("2026-11-05T15:01")), nil)
eq("nowcast expired", W.nowcast(minutely{ 1, 1 }, W.parseWallTime("2026-11-05T16:00")), nil)
eq("nowcast missing", W.nowcast(nil, t1505), nil)
eq("nowcast inch threshold", W.nowcast(minutely({ 0, 0, 0.004 }, nil, "inch"), t1505).minutes, 10)
eq("nowcast inch dry", W.nowcast(minutely({ 0, 0, 0.003 }, nil, "inch"), t1505), nil)
eq("nowcast at least 5 min", W.nowcast(minutely{ 0, 0, 0, 1 }, W.parseWallTime("2026-11-05T15:29")).minutes, 5)
eq("duration hours", W.duration(120), "2 h")
local nc_parsed = W.selectForecast((function()
    local f = forecastFixture("_best_match")
    f.minutely_15 = { time = { "2026-11-05T15:00" }, precipitation_best_match = { 0.2 },
        precipitation_ncep_nbm_conus = { 0 }, snowfall_best_match = { 0.1 } }
    f.minutely_15_units = { precipitation_best_match = "inch" }
    return f
end)())
eq("minutely uses best_match", nc_parsed.minutely.precipitation[1], 0.2)
eq("minutely snowfall", nc_parsed.minutely.snowfall[1], 0.1)
eq("minutely unit", nc_parsed.minutely.unit, "inch")
eq("missing minutely is nil", nbm.minutely, nil)

-- monotone curve
local Curve = require("deskdash_curve")
local ys = { 10, 12, 15, 15, 11, 8, 9, 14 }
local f = Curve.monotone(ys)
local through, bounded = true, true
for k = 1, #ys do through = through and math.abs(f(k) - ys[k]) < 1e-9 end
for k = 1, #ys - 1 do
    local lo, hi = math.min(ys[k], ys[k + 1]), math.max(ys[k], ys[k + 1])
    for s = 1, 19 do
        local y = f(k + s / 20)
        bounded = bounded and y >= lo - 1e-9 and y <= hi + 1e-9
    end
end
eq("curve passes through points", through, true)
eq("curve stays between neighbours", bounded, true)
eq("curve flat segment", f(3.5), 15)
eq("curve single point", Curve.monotone({ 7 })(1), 7)
local g = Curve.monotone({ 9, 9, 8, 6 }, { 0, 3, 6, 8 })
eq("uneven x passes through", g(6), 8)
eq("uneven x last point", g(8), 6)
eq("uneven x plateau flat", g(1.5), 9)
local ok_range = true
for s = 0, 20 do local y = g(6 + s / 10); ok_range = ok_range and y <= 8 + 1e-9 and y >= 6 - 1e-9 end
eq("uneven x stays between neighbours", ok_range, true)
local lo, hi = Curve.range({ 10, 11 }, 4)
eq("range widened", lo .. "," .. hi, "8.5,12.5")
lo, hi = Curve.range({ 2, 20 }, 4)
eq("range kept", lo .. "," .. hi, "2,20")

-- small helpers
eq("aqi good", W.aqiLevel(50), "Good"); eq("aqi moderate", W.aqiLevel(51), "Moderate")
eq("aqi hazardous", W.aqiLevel(400), "Hazardous")
eq("compass N", W.compass(359), "N"); eq("compass SW", W.compass(225), "SW"); eq("compass nil", W.compass(nil), "")
eq("uv high", W.uvLevel(7), "High")
eq("unknown weather code", (W.describe(1234, true)), "—")
eq("night icon", select(2, W.describe(0, false)) ~= select(2, W.describe(0, true)), true)

print(string.format("%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)

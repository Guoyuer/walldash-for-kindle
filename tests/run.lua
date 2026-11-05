-- Unit tests for the pure logic in deskdash_weather.lua.
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

-- parseISO: "local" epochs that format back to the same wall-clock time
eq("parseISO time", hm(W.parseISO("2026-11-05T13:00")), "13:00")
eq("parseISO date-only = noon", hm(W.parseISO("2026-11-05")), "12:00")
eq("parseISO leap day", os.date("!%Y-%m-%d", W.parseISO("2028-02-29T10:00")), "2028-02-29")
eq("parseISO epoch", W.parseISO("1970-01-01T00:00"), 0)
eq("parseISO DST day", os.date("!%Y-%m-%d %H:%M", W.parseISO("2026-03-08T03:30")), "2026-03-08 03:30")
eq("parseISO alert with offset", hm(W.parseISO(("2026-11-05T18:00:00-05:00"):sub(1, 16))), "18:00")

local hourly = {
    time = { "2026-11-05T15:00", "2026-11-05T16:00", "2026-11-05T17:00", "2026-11-05T18:00" },
    precipitation_probability = { 90, 10, 70, 0 },
}
eq("hourly probability uses interval end", W.hourlyPrecipChance(hourly, 2), 70)
eq("summary agrees with hourly row", W.precipSummary(hourly, W.parseISO("2026-11-05T15:30"), hm), "16:00–17:00 · 70% precip")
eq("current interval remains eligible", W.precipSummary(hourly, W.parseISO("2026-11-05T16:15"), hm), "16:00–17:00 · 70% precip")
eq("expired interval ignored", W.precipSummary(hourly, W.parseISO("2026-11-05T17:00"), hm), nil)
eq("missing hourly forecast", W.precipSummary(nil, 0, hm), nil)

local function forecastFixture(default_suffix, missing_nbm)
    local h = { time = hourly.time }
    local d = { time = { "2026-11-05" } }
    for _, field in ipairs{ "temperature_2m", "weather_code", "precipitation_probability", "is_day" } do
        h[field .. default_suffix] = { 1, 2, 3, 4 }
        if default_suffix ~= "" then h[field .. "_ncep_nbm_conus"] = { 0, 12, 13, 14 } end
    end
    for _, field in ipairs{ "weather_code", "temperature_2m_max", "temperature_2m_min", "precipitation_probability_max", "precipitation_sum" } do
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

-- activeAlert
local now = W.parseISO("2026-11-05T15:00")
eq("no alerts", W.activeAlert(nil, now, hm), nil)
eq("active alert", W.activeAlert({ { event = "Wind Advisory", ends = "2026-11-05T18:00:00-05:00" } }, now, hm), "Wind Advisory until 18:00")
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
local at = function(hhmmss) return W.parseISO("2026-11-05T" .. hhmmss:sub(1, 5)) + tonumber(hhmmss:sub(7, 8)) end
eq("day: next minute", W.secondsToNextWake(at("13:20:15"), N), 45)
eq("01:59 -> 02:00", W.secondsToNextWake(at("01:59:30"), N), 30)
eq("02:00 -> 02:10", W.secondsToNextWake(at("02:00:01"), N), 599)
eq("02:13 -> 02:20", W.secondsToNextWake(at("02:13:20"), N), 400)
eq("04:50 -> 05:00", W.secondsToNextWake(at("04:50:02"), N), 598)
eq("05:00 -> 05:01", W.secondsToNextWake(at("05:00:02"), N), 58)
eq("night 03:00", W.isNight(at("03:00:00"), N), true)
eq("not night 05:00", W.isNight(at("05:00:00"), N), false)
eq("not night 01:59", W.isNight(at("01:59:59"), N), false)

-- NWS observation text -> WMO code
eq("obs cloudy", W.obsCode("Cloudy"), 3); eq("obs mostly cloudy", W.obsCode("Mostly Cloudy"), 3)
eq("obs partly", W.obsCode("Partly Cloudy"), 2); eq("obs clear", W.obsCode("Clear"), 0); eq("obs sunny", W.obsCode("Sunny"), 0)
eq("obs light rain+fog", W.obsCode("Light Rain and Fog/Mist"), 61); eq("obs heavy rain", W.obsCode("Heavy Rain"), 65)
eq("obs showers", W.obsCode("Showers in Vicinity"), 80); eq("obs drizzle", W.obsCode("Light Drizzle"), 53)
eq("obs snow", W.obsCode("Light Snow"), 71); eq("obs freezing", W.obsCode("Freezing Rain"), 66)
eq("obs thunder", W.obsCode("Thunderstorms and Rain"), 95); eq("obs fog", W.obsCode("Fog/Mist"), 45)
eq("obs haze", W.obsCode("Haze"), 45); eq("obs unknown", W.obsCode("Funnel Cloud?"), nil); eq("obs empty", W.obsCode(""), nil)

-- small helpers
eq("aqi good", W.aqiLevel(50), "Good"); eq("aqi moderate", W.aqiLevel(51), "Moderate")
eq("aqi hazardous", W.aqiLevel(400), "Hazardous")
eq("compass N", W.compass(359), "N"); eq("compass SW", W.compass(225), "SW"); eq("compass nil", W.compass(nil), "")
eq("uv high", W.uvLevel(7), "High")
eq("unknown weather code", (W.describe(1234, true)), "—")
eq("night icon", select(2, W.describe(0, false)) ~= select(2, W.describe(0, true)), true)

print(string.format("%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)

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

-- precipSummary
local function m15(values, units)
    local t = {}
    for i = 1, #values do t[i] = string.format("2026-11-05T%02d:%02d", 14 + math.floor((45 + 15 * (i - 1)) / 60), (45 + 15 * (i - 1)) % 60) end
    return { current = { weather_code = 3 }, minutely_15 = { time = t, precipitation = values },
        minutely_15_units = { precipitation = units or "mm" } }
end
eq("rain starting", W.precipSummary(m15{ 0, 0, 0.4, 1 }, hm), "Rain starting around 15:15")
eq("rain stopping", W.precipSummary(m15{ 0.5, 0, 0, 0 }, hm), "Rain stopping around 15:00")
eq("rain all window", W.precipSummary(m15{ 0.5, 0.3, 0.2, 0.2 }, hm), "Rain for the next 2 hours")
eq("drizzle below threshold", W.precipSummary(m15{ 0, 0.05, 0.05, 0 }, hm), nil)
eq("inch units", W.precipSummary(m15({ 0, 0.005 }, "inch"), hm), "Rain starting around 15:00")
local snow = m15{ 0, 0.3 }; snow.current.weather_code = 73
eq("snow wording", W.precipSummary(snow, hm), "Snow starting around 15:00")
local hourly = m15{ 0, 0, 0, 0 }
hourly.hourly = { time = {}, weather_code = {}, precipitation_probability = {} }
for i = 1, 13 do
    hourly.hourly.time[i] = string.format("2026-11-05T%02d:00", 14 + i - 1)
    hourly.hourly.weather_code[i] = (i == 6) and 63 or 3
    hourly.hourly.precipitation_probability[i] = (i == 6) and 80 or 10
end
eq("rain likely later", W.precipSummary(hourly, hm), "Rain likely around 19:00")
hourly.hourly.precipitation_probability[6] = 40
eq("low probability ignored", W.precipSummary(hourly, hm), nil)
eq("no minutely, no hourly", W.precipSummary({ current = { weather_code = 0 } }, hm), nil)

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

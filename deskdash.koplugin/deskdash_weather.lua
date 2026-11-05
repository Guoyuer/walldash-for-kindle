--[[--
Weather data for the desk dashboard: IP geolocation (ip-api.com) + forecast (Open-Meteo).
Uses the system curl (known to work on the Kindle) and KOReader's rapidjson.
]]
local logger = require("logger")
local ok_json, rapidjson = pcall(require, "rapidjson")
local json = ok_json and rapidjson or require("json")

local Weather = {}

local function curl(url, headers)
    -- Clear KOReader's LD_LIBRARY_PATH so the system curl uses the system OpenSSL, not KOReader's bundled one.
    local p = io.popen("LD_LIBRARY_PATH= curl -s -f -m 20 " .. (headers or "") .. " '" .. url .. "' 2>/tmp/deskdash_curl.err")
    if not p then return nil end
    local body = p:read("*a")
    p:close()
    if body == nil or body == "" then return nil end
    return body
end

--- UTF-8 for a BMP code point (LuaJIT has no \u{} escapes).
local function U(cp)
    return string.char(0xE0 + math.floor(cp / 4096), 0x80 + math.floor(cp / 64) % 64, 0x80 + cp % 64)
end

-- WMO weather code -> { text, day icon, night icon } (icons are Nerd Font "weather" glyphs)
local SUN, MOON = U(0xE30D), U(0xE32B)
local PART_DAY, PART_NIGHT = U(0xE302), U(0xE37E)
local CLOUD, FOG = U(0xE312), U(0xE313)
local DRIZZLE, RAIN, SHOWERS = U(0xE31B), U(0xE318), U(0xE319)
local SLEET, SNOW, THUNDER = U(0xE316), U(0xE31A), U(0xE31D)
Weather.ICON = {
    thermometer = U(0xE350), humidity = U(0xE373), wind = U(0xE34B),
    uv = SUN, sunrise = U(0xE34C), sunset = U(0xE34D),
    umbrella = U(0xE37C), smog = U(0xE36D),
    warning = U(0xF071), battery_low = U(0xF243), battery_empty = U(0xF244),   -- FontAwesome
}

local CODES = {
    [0] = { "Clear", SUN, MOON },
    [1] = { "Mostly Clear", PART_DAY, PART_NIGHT },
    [2] = { "Partly Cloudy", PART_DAY, PART_NIGHT },
    [3] = { "Cloudy", CLOUD },
    [45] = { "Fog", FOG }, [48] = { "Fog", FOG },
    [51] = { "Light Drizzle", DRIZZLE }, [53] = { "Drizzle", DRIZZLE }, [55] = { "Heavy Drizzle", DRIZZLE },
    [56] = { "Freezing Drizzle", SLEET }, [57] = { "Freezing Drizzle", SLEET },
    [61] = { "Light Rain", RAIN }, [63] = { "Rain", RAIN }, [65] = { "Heavy Rain", RAIN },
    [66] = { "Freezing Rain", SLEET }, [67] = { "Freezing Rain", SLEET },
    [71] = { "Light Snow", SNOW }, [73] = { "Snow", SNOW }, [75] = { "Heavy Snow", SNOW }, [77] = { "Snow Grains", SNOW },
    [80] = { "Showers", SHOWERS }, [81] = { "Showers", SHOWERS }, [82] = { "Heavy Showers", SHOWERS },
    [85] = { "Snow Showers", SNOW }, [86] = { "Snow Showers", SNOW },
    [95] = { "Thunderstorm", THUNDER }, [96] = { "Thunderstorm", THUNDER }, [99] = { "Thunderstorm", THUNDER },
}

function Weather.describe(code, is_day)
    local c = CODES[code] or { "—", CLOUD }
    local icon = (is_day == false and c[3]) or c[2]
    return c[1], icon
end

function Weather.compass(deg)
    if not deg then return "" end
    local dirs = { "N", "NE", "E", "SE", "S", "SW", "W", "NW" }
    return dirs[math.floor((deg % 360) / 45 + 0.5) % 8 + 1]
end

function Weather.uvLevel(uv)
    if not uv then return "" end
    if uv < 3 then return "Low" elseif uv < 6 then return "Moderate"
    elseif uv < 8 then return "High" elseif uv < 11 then return "Very High" end
    return "Extreme"
end

--- Returns { city, lat, lon, offset } or nil. offset = seconds east of UTC, incl. DST.
function Weather.locate()
    local body = curl("http://ip-api.com/json/?fields=status,city,lat,lon,offset")
    if not body then return nil end
    local ok, t = pcall(json.decode, body)
    if ok and type(t) == "table" and t.status == "success" then
        return { city = t.city, lat = t.lat, lon = t.lon, offset = t.offset }
    end
    logger.warn("deskdash: locate failed", body)
end

--- Fetches the forecast. Returns a table, or nil + error.
function Weather.fetch(lat, lon, units)
    local url = string.format(
        "https://api.open-meteo.com/v1/forecast?latitude=%.4f&longitude=%.4f"
        .. "&current=temperature_2m,apparent_temperature,relative_humidity_2m,dew_point_2m,weather_code,"
        .. "wind_speed_10m,wind_direction_10m,wind_gusts_10m,is_day"
        .. "&minutely_15=precipitation&forecast_minutely_15=8"
        .. "&hourly=temperature_2m,weather_code,precipitation_probability,is_day"
        .. "&daily=weather_code,temperature_2m_max,temperature_2m_min,precipitation_probability_max,precipitation_sum,sunrise,sunset,uv_index_max"
        .. "&timezone=auto&forecast_days=7&forecast_hours=13%s",
        lat, lon, units == "imperial" and "&temperature_unit=fahrenheit&wind_speed_unit=mph&precipitation_unit=inch" or "")
    local body = curl(url)
    if not body then return nil, "no response" end
    local ok, t = pcall(json.decode, body)
    if not ok or type(t) ~= "table" or not t.current then
        logger.warn("deskdash: bad forecast", body and body:sub(1, 200))
        return nil, "bad response"
    end
    return t
end

--- US AQI from Open-Meteo's air-quality API. Returns { aqi, pm2_5 } or nil.
function Weather.airQuality(lat, lon)
    local body = curl(string.format(
        "https://air-quality-api.open-meteo.com/v1/air-quality?latitude=%.4f&longitude=%.4f&current=us_aqi,pm2_5", lat, lon))
    local ok, t = pcall(json.decode, body or "")
    if ok and type(t) == "table" and t.current and t.current.us_aqi then
        return { aqi = t.current.us_aqi, pm2_5 = t.current.pm2_5 }
    end
end

function Weather.aqiLevel(aqi)
    if aqi <= 50 then return "Good" elseif aqi <= 100 then return "Moderate"
    elseif aqi <= 150 then return "Unhealthy (sensitive)" elseif aqi <= 200 then return "Unhealthy"
    elseif aqi <= 300 then return "Very Unhealthy" end
    return "Hazardous"
end

--- Active US National Weather Service alerts for a point: list of { event, ends = "2026-11-05T18:00:00-05:00" }
--- (most severe first), {} if none, nil on error (e.g. outside the US).
local SEVERITY = { Extreme = 1, Severe = 2, Moderate = 3, Minor = 4 }
function Weather.alerts(lat, lon)
    local body = curl(string.format("https://api.weather.gov/alerts/active?point=%.4f,%.4f", lat, lon),
        "-H 'User-Agent: deskdash-kindle' -H 'Accept: application/geo+json'")
    local ok, t = pcall(json.decode, body or "")
    if not (ok and type(t) == "table" and type(t.features) == "table") then return nil end
    local list = {}
    for _, f in ipairs(t.features) do
        local p = f.properties or {}
        if p.event then
            table.insert(list, { event = p.event, ends = p.ends or p.expires, rank = SEVERITY[p.severity] or 5 })
        end
    end
    table.sort(list, function(a, b) return a.rank < b.rank end)
    return list
end

--- Moon phase at a UTC epoch: name, illuminated fraction (0..1), icon.
local MOON_ICON0 = 0xE38D   -- Weather Icons wi-moon-new .. 27 more phases, in order
function Weather.moon(t)
    local f = ((t - 947182440) / 86400 / 29.530588853) % 1   -- 947182440 = new moon 2000-01-06 18:14 UTC
    local names = { { 0.034, "New Moon" }, { 0.216, "Waxing Crescent" }, { 0.284, "First Quarter" },
        { 0.466, "Waxing Gibbous" }, { 0.534, "Full Moon" }, { 0.716, "Waning Gibbous" },
        { 0.784, "Last Quarter" }, { 0.966, "Waning Crescent" }, { 1.01, "New Moon" } }
    local name
    for _, n in ipairs(names) do if f < n[1] then name = n[2]; break end end
    return name, (1 - math.cos(2 * math.pi * f)) / 2, U(MOON_ICON0 + math.floor(f * 28 + 0.5) % 28)
end

return Weather

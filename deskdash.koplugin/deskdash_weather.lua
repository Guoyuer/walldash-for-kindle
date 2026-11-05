--[[--
Weather data for the desk dashboard: IP geolocation (ip-api.com) + forecast (Open-Meteo).
Uses the system curl (known to work on the Kindle) and KOReader's rapidjson.
]]
local logger = require("logger")
local ok_json, rapidjson = pcall(require, "rapidjson")
local json = ok_json and rapidjson or require("json")

local Weather = {}

local function curl(url)
    -- Clear KOReader's LD_LIBRARY_PATH so the system curl uses the system OpenSSL, not KOReader's bundled one.
    local p = io.popen("LD_LIBRARY_PATH= curl -s -m 20 '" .. url .. "' 2>/tmp/deskdash_curl.err")
    if not p then return nil end
    local body = p:read("*a")
    p:close()
    if body == nil or body == "" then return nil end
    return body
end

--- UTF-8 for a BMP code point (LuaJIT has no \u{} escapes).
function Weather.U(cp)
    return string.char(0xE0 + math.floor(cp / 4096), 0x80 + math.floor(cp / 64) % 64, 0x80 + cp % 64)
end
local U = Weather.U

-- WMO weather code -> { text, day icon, night icon } (icons are Nerd Font "weather" glyphs)
local SUN, MOON = U(0xE30D), U(0xE32B)
local PART_DAY, PART_NIGHT = U(0xE302), U(0xE37E)
local CLOUD, FOG = U(0xE312), U(0xE313)
local DRIZZLE, RAIN, SHOWERS = U(0xE31B), U(0xE318), U(0xE319)
local SLEET, SNOW, THUNDER = U(0xE316), U(0xE31A), U(0xE31D)
Weather.ICON = {
    thermometer = U(0xE350), humidity = U(0xE373), wind = U(0xE34B),
    uv = SUN, sunrise = U(0xE34C), sunset = U(0xE34D), rain = U(0xE371),
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
        .. "&current=temperature_2m,apparent_temperature,relative_humidity_2m,weather_code,wind_speed_10m,wind_direction_10m,is_day"
        .. "&hourly=temperature_2m,weather_code,precipitation_probability,is_day"
        .. "&daily=weather_code,temperature_2m_max,temperature_2m_min,precipitation_probability_max,sunrise,sunset,uv_index_max"
        .. "&timezone=auto&forecast_days=7&forecast_hours=13%s",
        lat, lon, units == "imperial" and "&temperature_unit=fahrenheit&wind_speed_unit=mph" or "")
    local body = curl(url)
    if not body then return nil, "no response" end
    local ok, t = pcall(json.decode, body)
    if not ok or type(t) ~= "table" or not t.current then
        logger.warn("deskdash: bad forecast", body and body:sub(1, 200))
        return nil, "bad response"
    end
    t.fetched_at = os.time()
    return t
end

return Weather

--[[--
Weather data for the desk dashboard: IP geolocation (ip-api.com) + forecast (Open-Meteo).
Uses the system curl (known to work on the Kindle) and KOReader's rapidjson.
]]
local logger = require("logger")
local ok_json, rapidjson = pcall(require, "rapidjson")
local json = ok_json and rapidjson or require("json")

local Weather = {}

local function shellQuote(value)
    return "'" .. value:gsub("'", "'\\''") .. "'"
end

local function curl(url, headers)
    -- Clear KOReader's LD_LIBRARY_PATH so the system curl uses the system OpenSSL, not KOReader's bundled one.
    local p = io.popen("LD_LIBRARY_PATH= curl -s -f -m 20 " .. (headers or "") .. " " .. shellQuote(url) .. " 2>/tmp/deskdash_curl.err")
    if not p then return nil end
    local body = p:read("*a")
    p:close()
    if body == nil or body == "" then return nil end
    return body
end

--- Runs requests ({ url = , headers = }) at the same time, so Wi-Fi stays on for the slowest one instead of
--- the sum. Returns the bodies in order (nil for a failed request). prefix names the temporary files.
function Weather.curlAll(requests, prefix)
    local cmd = { "export LD_LIBRARY_PATH=;" }
    for i, r in ipairs(requests) do
        cmd[#cmd + 1] = string.format("curl -s -f -m 20 %s %s >%s 2>/dev/null &",
            r.headers or "", shellQuote(r.url), shellQuote(prefix .. i))
    end
    cmd[#cmd + 1] = "wait"
    os.execute(table.concat(cmd, " "))
    local bodies = {}
    for i = 1, #requests do
        local f = io.open(prefix .. i, "rb")
        if f then
            local body = f:read("*a")
            f:close()
            if body ~= "" then bodies[i] = body end
        end
        os.remove(prefix .. i)
    end
    return bodies
end

local function decode(body)
    local ok, t = pcall(json.decode, body or "")
    if ok and type(t) == "table" then return t end
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
    warning = U(0xF071), settings = U(0xF013),   -- FontAwesome
    battery_full = U(0xF240), battery_three_quarters = U(0xF241), battery_half = U(0xF242),
    battery_low = U(0xF243), battery_empty = U(0xF244),
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
    if ok and type(t) == "table" and t.status == "success" and type(t.lat) == "number" and type(t.lon) == "number" then
        return { city = type(t.city) == "string" and t.city or nil, lat = t.lat, lon = t.lon,
            offset = type(t.offset) == "number" and t.offset or nil }
    end
    logger.warn("deskdash: IP geolocation failed")
end

local CURRENT = { "temperature_2m", "apparent_temperature", "relative_humidity_2m", "dew_point_2m",
    "weather_code", "wind_speed_10m", "wind_direction_10m", "wind_gusts_10m", "is_day" }
local HOURLY = { "temperature_2m", "weather_code", "precipitation_probability", "is_day" }
local DAILY = { "weather_code", "temperature_2m_max", "temperature_2m_min", "precipitation_sum" }
-- 15-minute precipitation for the nowcast. Each value is the sum over the 15 minutes ending at its timestamp.
-- best_match is NOAA RRFS in North America (native 15-minute output); NBM's 15-minute values are interpolated from
-- its hourly ones, so the nowcast always uses best_match.
local MINUTELY = { "precipitation" }
local MINUTELY_STEPS = 13   -- the first step has usually ended already; 12 more = 3 h (battery fetches hourly)
local HOURLY_STEPS = 27     -- the hourly chart's 24 h + its precipitation (i + 1) + 1 h of cache age + 1
local DEFAULT_MODEL, NBM = "_best_match", "_ncep_nbm_conus"

local function forecastSection(section, fields, suffix)
    if type(section) ~= "table" or type(section.time) ~= "table" or #section.time == 0 then return nil end
    for i = 1, #section.time do
        if not Weather.parseWallTime(section.time[i]) then return nil end
    end
    local selected = { time = section.time }
    for _, field in ipairs(fields) do
        local series = section[field .. suffix]
        if type(series) ~= "table" then return nil end
        for i = 1, #section.time do
            if type(series[i]) ~= "number" then return nil end
        end
        selected[field] = series
    end
    return selected
end

local function sunTimes(series, count)
    local times = {}
    if type(series) == "table" then
        for i = 1, count do times[i] = Weather.parseWallTime(series[i]) end
    end
    return times
end

-- All forecast pages use the same model. Outside NBM coverage the API can return unsuffixed default fields.
function Weather.selectForecast(t)
    local suffix = type(t.hourly) == "table" and t.hourly.temperature_2m and "" or DEFAULT_MODEL
    local hourly = forecastSection(t.hourly, HOURLY, NBM)
    local daily = forecastSection(t.daily, DAILY, NBM)
    if not (hourly and daily) then
        hourly = forecastSection(t.hourly, HOURLY, suffix)
        daily = forecastSection(t.daily, DAILY, suffix)
    end
    if not (hourly and daily) then return nil, "incomplete forecast" end

    daily.sunrise = sunTimes(t.daily["sunrise" .. suffix], #daily.time)
    daily.sunset = sunTimes(t.daily["sunset" .. suffix], #daily.time)
    local uv = t.daily["uv_index_max" .. suffix]
    daily.uv_index_max = {}
    if type(uv) == "table" then
        for i = 1, #daily.time do
            if type(uv[i]) == "number" then daily.uv_index_max[i] = uv[i] end
        end
    end
    local units = type(t.daily_units) == "table" and t.daily_units or {}
    local precipitation_unit = units["precipitation_sum" .. suffix]
    local wind_unit = type(t.current_units) == "table" and t.current_units.wind_speed_10m
    local source = type(t.current) == "table" and t.current or {}
    local current = {}
    for _, field in ipairs(CURRENT) do
        local value = source[field]
        if type(value) == "number" then current[field] = value end
    end
    local minutely = forecastSection(t.minutely_15, MINUTELY, suffix)
    if minutely then
        local snow = t.minutely_15["snowfall" .. suffix]
        minutely.snowfall = {}
        for i = 1, #minutely.time do
            minutely.snowfall[i] = type(snow) == "table" and type(snow[i]) == "number" and snow[i] or 0
        end
        local munits = type(t.minutely_15_units) == "table" and t.minutely_15_units or {}
        minutely.unit = munits["precipitation" .. suffix] == "inch" and "inch" or "mm"
    end
    return {
        hourly = hourly, daily = daily, current = current, minutely = minutely,
        daily_units = { precipitation_sum = type(precipitation_unit) == "string" and precipitation_unit or nil },
        current_units = { wind_speed_10m = type(wind_unit) == "string" and wind_unit or nil },
        utc_offset_seconds = type(t.utc_offset_seconds) == "number" and t.utc_offset_seconds or nil,
    }
end

function Weather.forecastRequest(lat, lon, units)
    return { url = string.format(
        "https://api.open-meteo.com/v1/forecast?latitude=%.4f&longitude=%.4f"
        .. "&current=" .. table.concat(CURRENT, ",")
        .. "&hourly=" .. table.concat(HOURLY, ",")
        .. "&daily=" .. table.concat(DAILY, ",") .. ",sunrise,sunset,uv_index_max"
        .. "&minutely_15=" .. table.concat(MINUTELY, ",") .. ",snowfall&forecast_minutely_15=" .. MINUTELY_STEPS
        .. "&models=best_match,ncep_nbm_conus"
        .. "&timezone=auto&forecast_days=7&forecast_hours=" .. HOURLY_STEPS .. "%s",
        lat, lon, units == "imperial" and "&temperature_unit=fahrenheit&wind_speed_unit=mph&precipitation_unit=inch" or "") }
end

--- Forecast response body -> table, or nil + error.
function Weather.parseForecast(body)
    if not body then return nil, "no response" end
    local t = decode(body)
    if not t or type(t.current) ~= "table" then return nil, "bad response" end
    return Weather.selectForecast(t)
end

--- Current US AQI estimate from Open-Meteo's CAMS model.
function Weather.airQualityRequest(lat, lon)
    return { url = string.format(
        "https://air-quality-api.open-meteo.com/v1/air-quality?latitude=%.4f&longitude=%.4f&current=us_aqi", lat, lon) }
end

function Weather.parseAirQuality(body)
    local t = decode(body)
    local c = t and t.current
    if type(c) == "table" and type(c.us_aqi) == "number" then
        return c.us_aqi
    end
end

function Weather.aqiLevel(aqi)
    if aqi <= 50 then return "Good" elseif aqi <= 100 then return "Moderate"
    elseif aqi <= 150 then return "Unhealthy (sensitive)" elseif aqi <= 200 then return "Unhealthy"
    elseif aqi <= 300 then return "Very Unhealthy" end
    return "Hazardous"
end

local NWS_HEADERS = "-H 'User-Agent: deskdash-kindle' -H 'Accept: application/geo+json'"
local function nwsRequest(path)
    return { url = "https://api.weather.gov" .. path, headers = NWS_HEADERS }
end
local function nws(path)
    local r = nwsRequest(path)
    return decode(curl(r.url, r.headers))
end

--- NWS observation text -> headline, rest (or nil) for the home page's two condition lines. NWS joins every reported
--- phenomenon with " and " ("Heavy Thunderstorms and Heavy Rain and Thunderstorms and Hail and Fog/Mist"), strongest
--- first. Parts repeated inside another ("Thunderstorms" in "Heavy Thunderstorms") are dropped. The headline skips
--- wind, and sky/visibility when there is precipitation, and keeps leading parts while they fit in max_len characters;
--- everything else goes to rest, joined with " · ": "Light Rain and Fog/Mist" -> "Light Rain", "Fog/Mist".
local PRECIP_WORDS = { "rain", "snow", "drizzle", "thunder", "hail", "sleet", "pellets", "shower", "freezing",
                       "ice", "squall", "graupel", "precipitation", "funnel", "tornado" }
local WIND_PARTS = { windy = true, breezy = true }
function Weather.shortText(text, max_len)
    max_len = max_len or 20
    text = (text or ""):gsub("%s+", " "):gsub("^ ", ""):gsub(" $", "")   -- NWS sometimes sends "Light  Snow"
    local parts = {}
    for p in (text .. " and "):gmatch("(.-) and ") do
        if p ~= "" then table.insert(parts, p) end
    end
    if #parts <= 1 then return text end
    -- Thunder decides the icon (obsCode), so lead with it: "Light Rain and Thunderstorms" -> "Thunderstorms".
    for i = 2, #parts do
        if parts[i]:lower():find("thunder", 1, true) and not parts[1]:lower():find("thunder", 1, true) then
            table.insert(parts, 1, table.remove(parts, i))
            break
        end
    end
    local function precip(p)
        local s = p:lower()
        for _, w in ipairs(PRECIP_WORDS) do
            if s:find(w, 1, true) then return true end
        end
    end
    local unique = {}
    for i, p in ipairs(parts) do
        local dup = false
        for j, q in ipairs(parts) do
            -- a part repeated inside another (or an exact repeat earlier on) adds nothing
            if j ~= i and (q == p and j < i or q ~= p and q:find(p, 1, true)) then dup = true end
        end
        if not dup then table.insert(unique, p) end
    end
    local any_precip = false
    for _, p in ipairs(unique) do any_precip = any_precip or precip(p) end
    local candidates = {}
    for _, p in ipairs(unique) do
        if not WIND_PARTS[p:lower()] and (precip(p) or not any_precip) then table.insert(candidates, p) end
    end
    local head = { candidates[1] or unique[1] }   -- "Windy and Breezy" has no candidate
    local len = #head[1]
    for i = 2, #candidates do
        if len + 5 + #candidates[i] > max_len then break end
        table.insert(head, candidates[i])
        len = len + 5 + #candidates[i]
    end
    local in_head, rest = {}, {}
    for _, p in ipairs(head) do in_head[p] = true end
    for _, p in ipairs(unique) do
        if not in_head[p] then table.insert(rest, p) end
    end
    return table.concat(head, " and "), #rest > 0 and table.concat(rest, " · ") or nil
end

--- NWS observation text ("Mostly Cloudy", "Light Rain and Fog/Mist", ...) -> WMO weather code, or nil if unknown.
function Weather.obsCode(text)
    local s = (text or ""):lower()
    if s == "" then return nil end
    local function has(w) return s:find(w, 1, true) ~= nil end
    -- "Unknown Precipitation (and Fog)": the station can't tell rain from snow; the model can.
    if has("unknown") then return nil end
    if has("thunder") then return 95 end
    if has("freezing") or has("sleet") or has("ice pellets") then return 66 end
    if has("snow") then return has("light") and 71 or (has("heavy") and 75 or 73) end
    if has("drizzle") then return 53 end
    if has("rain") or has("shower") then
        if has("shower") then return 80 end
        return has("light") and 61 or (has("heavy") and 65 or 63)
    end
    if has("fog") or has("mist") or has("haze") or has("smoke") then return 45 end
    if has("overcast") or has("mostly cloudy") or s == "cloudy" then return 3 end
    if has("partly") or has("mostly sunny") or has("mostly clear") then return 2 end
    if has("clear") or has("sunny") or has("fair") then return 0 end
end

--- NWS station nearest to lat/lon (US only), or nil. Two requests; the caller caches the result.
function Weather.findStation(lat, lon)
    local pt = nws(string.format("/points/%.4f,%.4f", lat, lon))
    local url = pt and pt.properties and pt.properties.observationStations
    local path = type(url) == "string" and url:match("^https://api%.weather%.gov(/gridpoints/[A-Z]+/%-?%d+,%-?%d+/stations)$")
    local st = path and nws(path .. "?limit=1")
    local f = st and st.features and st.features[1]
    local station = f and f.properties and f.properties.stationIdentifier
    if type(station) == "string" and station:match("^[A-Z0-9]+$") then return station end
end

function Weather.observationRequest(station)
    return nwsRequest("/stations/" .. station .. "/observations/latest")
end

--- Latest-observation body -> { text, code, t = UTC epoch, station } or nil.
function Weather.parseObservation(body, station)
    local o = decode(body)
    local p = o and o.properties
    if not (p and type(p.textDescription) == "string" and p.textDescription ~= "" and type(p.timestamp) == "string") then
        return nil
    end
    -- The station timestamp is already in UTC, so parsing its clock fields gives a UTC epoch.
    local observed_at = Weather.parseWallTime(p.timestamp:sub(1, 16))
    if not observed_at then return nil end
    return { text = p.textDescription, code = Weather.obsCode(p.textDescription),
             t = observed_at, station = station }
end

--- Active US National Weather Service alerts for a point: list of { event, ends = "2026-11-05T18:00:00-05:00" }
--- (most severe first), {} if none, nil on error (e.g. outside the US).
local SEVERITY = { Extreme = 1, Severe = 2, Moderate = 3, Minor = 4 }
function Weather.alertsRequest(lat, lon)
    return nwsRequest(string.format("/alerts/active?point=%.4f,%.4f", lat, lon))
end

function Weather.parseAlerts(body)
    local t = decode(body)
    if not (t and type(t.features) == "table") then return nil end
    local list = {}
    for _, f in ipairs(t.features) do
        local p = f.properties or {}
        if type(p.event) == "string" then
            local ends = type(p.ends) == "string" and p.ends or p.expires
            table.insert(list, { event = p.event, ends = type(ends) == "string" and ends or nil, rank = SEVERITY[p.severity] or 5 })
        end
    end
    table.sort(list, function(a, b) return a.rank < b.rank end)
    return list
end

--- Encode YYYY-MM-DDTHH:MM (or a date at noon) as if the clock fields were UTC.
--- Format with os.date("!..."). Callers must handle any time-zone offset before parsing.
function Weather.parseWallTime(s)
    if type(s) ~= "string" then return nil end
    local y, m, d, H, M = s:match("^(%d%d%d%d)-(%d%d)-(%d%d)T(%d%d):(%d%d)$")
    if not y then y, m, d = s:match("^(%d%d%d%d)-(%d%d)-(%d%d)$") end
    if not y then return nil end
    y, m, d = tonumber(y), tonumber(m), tonumber(d)
    if m <= 2 then y = y - 1 end
    local era = math.floor(y / 400)
    local yoe = y - era * 400
    local doy = math.floor((153 * (m + (m > 2 and -3 or 9)) + 2) / 5) + d - 1
    local days = era * 146097 + yoe * 365 + math.floor(yoe / 4) - math.floor(yoe / 100) + doy - 719468
    return days * 86400 + (tonumber(H) or 12) * 3600 + (tonumber(M) or 0) * 60
end
local parseWallTime = Weather.parseWallTime

-- Open-Meteo timestamps the probability at the end of the interval; the hourly row is labelled by its start.
function Weather.hourlyPrecipChance(h, i)
    local chance = h.precipitation_probability[i + 1]
    return math.floor(chance / 5 + 0.5) * 5
end

function Weather.firstForecastHour(h, now)
    for i = 1, #h.time - 1 do
        if parseWallTime(h.time[i + 1]) > now then return i end
    end
    return #h.time
end

--- Index of the first forecast date on or after today, plus whether it matches today.
function Weather.firstForecastDay(daily, local_now)
    local today = os.date("!%Y-%m-%d", local_now)
    for i, date in ipairs(daily.time) do
        if date >= today then return i, date == today end
    end
end

--- Summarize the first high-probability interval starting within the next three hours.
function Weather.precipSummary(h, now, fmt, template)
    if not h then return nil end
    for i = Weather.firstForecastHour(h, now), #h.time - 1 do
        local starts = parseWallTime(h.time[i])
        if starts >= now + 3 * 3600 then break end
        local p = Weather.hourlyPrecipChance(h, i)
        if p >= 60 then
            return string.format(template or "%s–%s · %d%% precip", fmt(starts), fmt(parseWallTime(h.time[i + 1])), p)
        end
    end
end

--- 15-minute precipitation ({ time, precipitation, snowfall, unit }) -> what happens next at "local" epoch now, or nil
--- when it stays dry: { kind = "start" | "stop" | "steady", minutes = n, snow = bool }. start: dry now, wet in n
--- minutes; stop: wet now, dry in n minutes; steady: wet for the rest of the window (n minutes, whole quarter hours).
--- Values are sums over the 15 minutes ending at their timestamp; >= 0.1 mm in 15 minutes counts as wet.
local NOWCAST_MM = 0.1
function Weather.nowcast(m, now)
    if not (m and m.time) then return nil end
    local inch = m.unit == "inch"
    local threshold = (inch and NOWCAST_MM / 25.4 or NOWCAST_MM) * 0.99   -- the API rounds the amounts
    local ends, wet, first = {}, {}, nil
    for i = 1, #m.time do
        ends[i] = parseWallTime(m.time[i])
        wet[i] = m.precipitation[i] >= threshold
        if not first and ends[i] > now then first = i end
    end
    if not first then return nil end
    -- Snow when most of the run's water fell as snow (7 cm of snow ~ 10 mm of water; 7 inch ~ 1 inch).
    local function snowy(from)
        local water, snow_water = 0, 0
        for i = from, #m.time do
            if not wet[i] then break end
            water = water + m.precipitation[i]
            snow_water = snow_water + (m.snowfall[i] or 0) * (inch and 1 / 7 or 10 / 7)
        end
        return snow_water >= water / 2
    end
    local function round5(seconds) return math.max(5, math.floor(seconds / 300 + 0.5) * 5) end
    if wet[first] then
        for i = first + 1, #m.time do
            if not wet[i] then return { kind = "stop", minutes = round5(ends[i - 1] - now), snow = snowy(first) } end
        end
        local left = math.floor((ends[#m.time] - now) / 900) * 15
        return left >= 15 and { kind = "steady", minutes = left, snow = snowy(first) } or nil
    end
    for i = first + 1, #m.time do
        if wet[i] then return { kind = "start", minutes = round5(ends[i] - 900 - now), snow = snowy(i) } end
    end
end

--- "25 min", "1 h 30 min", "2 h"; tr translates the templates.
function Weather.duration(minutes, tr)
    tr = tr or function(s) return s end
    if minutes < 60 then return string.format(tr("%d min"), minutes) end
    local h, m = math.floor(minutes / 60), minutes % 60
    if m == 0 then return string.format(tr("%d h"), h) end
    return string.format(tr("%d h %d min"), h, m)
end

local NOWCAST_TEXT = {
    start = { "Rain in ~%s", "Snow in ~%s" },
    stop = { "Rain stopping in ~%s", "Snow stopping in ~%s" },
    steady = { "Rain for the next %s", "Snow for the next %s" },
}
function Weather.nowcastText(nc, tr)
    if not nc then return nil end
    tr = tr or function(s) return s end
    return string.format(tr(NOWCAST_TEXT[nc.kind][nc.snow and 2 or 1]), Weather.duration(nc.minutes, tr))
end

--- Most severe alert that hasn't ended at "local" epoch now, e.g. "Wind Advisory until 18:00", or nil.
function Weather.activeAlert(alerts, now, fmt, template)
    for _, a in ipairs(alerts or {}) do
        local ends = type(a.ends) == "string" and parseWallTime(a.ends:sub(1, 16))
        if not ends then return a.event end
        if ends > now then return string.format(template or "%s until %s", a.event, fmt(ends)) end
    end
end

--- Is "local" epoch t inside the night window night = { from = h, to = h } (local hours, [from, to))?
function Weather.isNight(t, night)
    local h = tonumber(os.date("!%H", t))
    return h >= night.from and h < night.to
end

--- Seconds from "local" epoch t to the next wake-up: the next minute, or at night the next multiple of night.step
--- minutes (never past the end of the night).
function Weather.secondsToNextWake(t, night)
    local m, s = tonumber(os.date("!%M", t)), tonumber(os.date("!%S", t))
    local step = Weather.isNight(t, night) and night.step or 1
    return (step - m % step) * 60 - s
end

--- Seconds from "local" epoch t to the next weather slot: wall-clock minutes offset, offset + step, ... (step divides
--- 60), at least gap seconds away. E.g. step 30, offset 3 -> :03 and :33, a few minutes after NWS stations report.
function Weather.secondsToSlot(t, step, offset, gap)
    local s, o = step * 60, offset * 60
    return (math.floor((t + gap - o) / s) + 1) * s + o - t
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

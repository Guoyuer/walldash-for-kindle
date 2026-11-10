local ffiutil = require("ffi/util")
local buffer = require("string.buffer")
local logger = require("logger")
local time = require("ui/time")
local Bench = require("deskdash_benchmark")
local Weather = require("deskdash_weather")

local Job = {}
local PATH = "/tmp/deskdash_weather."

-- Polls 4x a second: Wi-Fi is the most expensive thing the dashboard does, so don't keep it on waiting for a poll.
local function waitForWifi()
    local deadline = time.now() + time.s(30)
    repeat
        local p = io.popen("timeout -s KILL 3 lipc-get-prop com.lab126.wifid cmState 2>/dev/null")
        local state = p and p:read("*l")
        if p then p:close() end
        if state == "CONNECTED" then return true end
        ffiutil.usleep(250000)
    until time.now() >= deadline
    logger.warn("deskdash: Wi-Fi not connected after 30 s")
    return false
end

-- opts: settings, offset, station, kindle, benchmark, want_aq
local function collect(opts, pid)
    local settings = opts.settings
    local sample = Bench.start(opts.benchmark, "weather")
    local wifi_started = time.now()
    local connected = not opts.kindle or waitForWifi()
    local result = { wifi_s = time.to_number(time.since(wifi_started)) }
    Bench.mark(sample, "wifi")
    if not connected then
        Bench.finish(sample)
        result.phases = sample.phases
        return result
    end

    local lat, lon = settings.lat, settings.lon
    if not (lat and lon and opts.offset) then
        local loc = Weather.locate()
        if loc then
            lat, lon = lat or loc.lat, lon or loc.lon
            result.location = loc
        end
    end
    Bench.mark(sample, "locate")
    if lat and lon then
        local station = opts.station or Weather.findStation(lat, lon)   -- once; the dashboard caches it
        result.station = station
        Bench.mark(sample, "station")
        local requests = { Weather.forecastRequest(lat, lon, settings.units), Weather.alertsRequest(lat, lon) }
        local obs_i, aq_i
        if station then table.insert(requests, Weather.observationRequest(station)); obs_i = #requests end
        if opts.want_aq then table.insert(requests, Weather.airQualityRequest(lat, lon)); aq_i = #requests end
        local bodies = Weather.curlAll(requests, PATH .. pid .. ".http.")
        Bench.mark(sample, "http")
        local data, err = Weather.parseForecast(bodies[1])
        if not data then logger.warn("deskdash: fetch failed", err) end
        result.data = data
        result.alerts = Weather.parseAlerts(bodies[2])
        result.obs = obs_i and Weather.parseObservation(bodies[obs_i], station)
        result.aq = aq_i and Weather.parseAirQuality(bodies[aq_i])
    end
    Bench.finish(sample)
    result.phases = sample.phases   -- the dashboard adds them to its hourly metrics
    return result
end

function Job.start(opts)
    return ffiutil.runInSubProcess(function(pid)
        local result = collect(opts, pid)
        local encoded = buffer.encode(result)
        local file = assert(io.open(PATH .. pid, "wb"))
        file:write(encoded)
        file:close()
    end)
end

-- Read only after the child has exited. A temporary file avoids pipe-buffer stalls.
function Job.take(pid, discard)
    if not ffiutil.isSubProcessDone(pid) then return false end
    local path = PATH .. pid
    if discard then
        os.remove(path)
        -- A cancelled worker may have left one file for each of its four parallel requests.
        for i = 1, 4 do os.remove(path .. ".http." .. i) end
        return true
    end
    local file = io.open(path, "rb")
    if not file then return true end
    local encoded = file:read("*a")
    file:close()
    os.remove(path)
    local ok, result = pcall(buffer.decode, encoded)
    return true, ok and type(result) == "table" and result or nil
end

function Job.cancel(pid)
    ffiutil.terminateSubProcess(pid)
end

return Job

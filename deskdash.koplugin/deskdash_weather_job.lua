local ffiutil = require("ffi/util")
local buffer = require("string.buffer")
local logger = require("logger")
local time = require("ui/time")
local Bench = require("deskdash_benchmark")
local Weather = require("deskdash_weather")

local Job = {}
local PATH = "/tmp/deskdash_weather."

local function waitForWifi()
    local deadline = time.now() + time.s(30)
    repeat
        local p = io.popen("lipc-get-prop com.lab126.wifid cmState 2>/dev/null")
        local state = p and p:read("*l")
        if p then p:close() end
        if state == "CONNECTED" then return true end
        os.execute("sleep 1")
    until time.now() >= deadline
    logger.warn("deskdash: Wi-Fi not connected after 30 s")
    return false
end

local function collect(settings, offset, station, kindle, benchmark)
    local sample = Bench.start(benchmark, "weather")
    local wifi_started = time.now()
    local connected = not kindle or waitForWifi()
    local result = { wifi_s = time.to_number(time.since(wifi_started)) }
    Bench.mark(sample, "wifi")
    if not connected then
        Bench.finish(sample)
        return result
    end

    local lat, lon = settings.lat, settings.lon
    if not (lat and lon and offset) then
        local loc = Weather.locate()
        if loc then
            lat, lon = lat or loc.lat, lon or loc.lon
            result.location = loc
        end
    end
    Bench.mark(sample, "locate")
    if lat and lon then
        local data, err = Weather.fetch(lat, lon, settings.units)
        result.data = data
        Bench.mark(sample, "forecast")
        if not data then logger.warn("deskdash: fetch failed", err) end
        result.alerts = Weather.alerts(lat, lon)
        Bench.mark(sample, "alerts")
        if data then
            result.aq = Weather.airQuality(lat, lon)
            Bench.mark(sample, "aqi")
            local cache = { station = station }
            result.obs = Weather.observation(lat, lon, cache)
            result.station = cache.station
            Bench.mark(sample, "observation")
        end
    end
    Bench.finish(sample)
    return result
end

function Job.start(settings, offset, station, kindle, benchmark)
    return ffiutil.runInSubProcess(function(pid)
        local result = collect(settings, offset, station, kindle, benchmark)
        local encoded = buffer.encode(result)
        local file = assert(io.open(PATH .. pid, "wb"))
        file:write(encoded)
        file:close()
    end)
end

-- Read only after the child has exited. A temporary file avoids pipe-buffer stalls.
function Job.take(pid)
    if not ffiutil.isSubProcessDone(pid) then return false end
    local path = PATH .. pid
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

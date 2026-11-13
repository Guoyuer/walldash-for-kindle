--[[--
Full-screen dashboard widget: 4 swipeable pages (Now / Hourly / 7-Day / Details).
Swipe left/right: change page. Long-press: close. Tap: refresh now.
]]
local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local InputContainer = require("ui/widget/container/inputcontainer")
local LeftContainer = require("ui/widget/container/leftcontainer")
local LineWidget = require("ui/widget/linewidget")
local OverlapGroup = require("ui/widget/overlapgroup")
local RightContainer = require("ui/widget/container/rightcontainer")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Widget = require("ui/widget/widget")
local logger = require("logger")
local time = require("ui/time")
local Weather = require("deskdash_weather")
local Bench = require("deskdash_benchmark")
local WeatherJob = require("deskdash_weather_job")
local Chinese = require("deskdash_chinese")
local Curve = require("deskdash_curve")
local parseWallTime = Weather.parseWallTime
local Screen = Device.screen

local BLACK = Blitbuffer.COLOR_BLACK
local WHITE = Blitbuffer.COLOR_WHITE
-- E-ink contrast is low: keep "secondary" text dark and rules/tracks clearly visible.
local GRAY = Blitbuffer.Color8(0x33)   -- secondary text
local LIGHT = Blitbuffer.Color8(0x99)  -- separators, range-bar track
local FILL = Blitbuffer.Color8(0xCC)   -- area under the hourly temperature curve

local SANS, BOLD, ICONS = "NotoSans-Regular.ttf", "NotoSans-Bold.ttf", "nerdfonts/symbols.ttf"
local HEAVY = BOLD   -- big numerals (KOReader can't see the Kindle's Amazon Ember)

local PAGES = 4
local IDLE_RETURN = 120          -- seconds on another page before returning to "Now"
-- Weather fetches run at fixed wall-clock minutes, a few minutes after NWS stations' hourly reports (~:51-:56).
-- Each one switches Wi-Fi on for ~10 s, the most expensive thing in battery mode, so it is half as often there.
local WEATHER_STEP = 15          -- minutes between fetches when plugged in
local WEATHER_STEP_BATTERY = 60  -- minutes between fetches on battery (stations and NBM update hourly)
local WEATHER_SLOT = 3           -- slot offset in minutes: :03, :18, :33, :48 (battery: :03)
local WEATHER_GAP = 5 * 60       -- a manual refresh doesn't trigger another fetch within this many seconds
local WEATHER_RETRY_MAX = 15 * 60  -- failed automatic fetches back off from 1 min to this
local WEATHER_TIMEOUT = time.s(120) -- Wi-Fi, location, station discovery and forecast combined
local AQ_EVERY = 55 * 60         -- the CAMS AQI estimate is hourly; fetch it at most this often
local FLASH_EVERY = 30           -- flashing full refresh when the minute is a multiple of this
-- Battery mode: on battery, suspend to RAM between minute updates (e-ink keeps the picture).
local AWAKE_AFTER_INPUT = 60     -- stay awake this long after a touch / power-button wake
local LOW_BATTERY = 20           -- % at which a "charge me" badge appears (on battery only)
local POWER_LOG = "/mnt/us/deskdash_power.csv"   -- hourly power stats; analyse with tools/power.py
local METRICS_LOG = "/mnt/us/deskdash_metrics.csv"   -- hourly per-phase timings; tools/power.py --metrics
local BAT = "/sys/class/power_supply/bd71827_bat/"
-- Night (local hours [from, to)): wake only every `step` minutes and don't fetch the weather.
local NIGHT = { from = 2, to = 5, step = 10 }
local RTC = "/dev/rtc1"          -- the wake-capable RTC on the PW4 (snvs)
local RTC_ERROR = "/tmp/deskdash_rtcwake.err"
local SUSPEND_FAILURE_LIMIT = 3
local ROTATION_FILE = "/tmp/deskdash_rotation"

-- Font:getFace() scales sizes by DPI; we think in screen pixels.
local SCALE = Screen:scaleBySize(1000) / 1000
local face_cache = {}
local function face(name, px)
    local key = name .. "@" .. px
    if face_cache[key] == nil then
        local pt = math.floor(px / SCALE + 0.5)
        face_cache[key] = Font:getFace(name, pt) or Font:getFace(BOLD, pt) or false
    end
    return face_cache[key] or nil
end

local function txt(text, fname, px, color, max_w)
    return TextWidget:new{ text = text, face = face(fname, px), fgcolor = color or BLACK, padding = 0, max_width = max_w }
end
-- Like txt(), but shrinks the font (down to min_px) to fit max_w instead of ellipsizing; truncates only below min_px.
local function fitTxt(text, fname, px, color, max_w, min_px)
    local w = txt(text, fname, px, color)
    local tw = w:getSize().w
    if tw <= max_w then return w end
    w:free()
    -- Glyph widths don't scale exactly linearly (hinting, point-size rounding), so step down until it fits.
    local fit = math.max(min_px, math.floor(px * max_w / tw))
    w = txt(text, fname, fit)
    while fit > min_px and w:getSize().w > max_w do
        w:free()
        fit = math.max(min_px, fit - 2)
        w = txt(text, fname, fit)
    end
    w:free()
    return txt(text, fname, fit, color, max_w)
end
local function vspan(h) return VerticalSpan:new{ width = h } end
local function hspan(w) return HorizontalSpan:new{ width = w } end
local function box(w, h, widget, align)
    local C = (align == "left" and LeftContainer) or (align == "right" and RightContainer) or CenterContainer
    return C:new{ dimen = Geom:new{ w = w, h = h }, widget }
end
-- FrameContainer:getSize() ignores width/height, so give frames a fixed-size child instead.
local function fixed(w, h, widget)
    local og = OverlapGroup:new{ dimen = Geom:new{ w = w, h = h } }
    if widget then table.insert(og, widget) end
    return og
end
local function deg(v) return v and string.format("%d°", math.floor(v + 0.5)) or "--" end

-- A widget that paints itself with draw(bb, x, y) (Blitbuffer has rectangles and circles but no lines).
local Canvas = Widget:extend{ w = 0, h = 0, draw = nil }
function Canvas:getSize() return Geom:new{ w = self.w, h = self.h } end
function Canvas:paintTo(bb, x, y)
    self.dimen = Geom:new{ x = x, y = y, w = self.w, h = self.h }
    self.draw(bb, x, y)
end

-- Places widget in an OverlapGroup centred on x (clamped to [0, w]) with its top at y.
local function place(group, widget, x, y, w)
    local ww = widget:getSize().w
    widget.overlap_offset = { math.floor(math.max(0, math.min(w - ww, x - ww / 2))), math.floor(y) }
    table.insert(group, widget)
end

local Dashboard = InputContainer:extend{
    covers_fullscreen = true,
    settings = nil,  -- { units=, clock_24h=, lat=, lon=, city= }
}

function Dashboard:layoutScreen()
    self.W, self.H = Screen:getWidth(), Screen:getHeight()
    self.landscape = self.W > self.H
    self.dimen = Geom:new{ x = 0, y = 0, w = self.W, h = self.H }
    self.ges_events = {
        Swipe = { GestureRange:new{ ges = "swipe", range = self.dimen } },
        Tap = { GestureRange:new{ ges = "tap", range = self.dimen } },
        -- Closing needs a deliberate long-press, so a stray swipe on the wall can't exit.
        Hold = { GestureRange:new{ ges = "hold", range = self.dimen } },
    }
end

function Dashboard:applyOrientation()
    local mode = self.settings.landscape and Screen.DEVICE_ROTATED_CLOCKWISE or Screen.DEVICE_ROTATED_UPRIGHT
    if Screen:getRotationMode() ~= mode then Screen:setRotationMode(mode) end
    self:layoutScreen()
end

function Dashboard:init()
    self.previous_rotation = Screen:getRotationMode()
    self:applyOrientation()
    self.page = 1
    self.last_touch = os.time()
    self._tick = function() self:onTick() end
    self._poll = function() self:pollCommand() end
    self._sleep = function() self:sleepUntilNextMinute() end
    self._ready = function() self:reportReady() end
    self._initial_fetch = function() self:refreshWeather() end
    self._check_weather = function() self:checkWeather() end
    self.next_fetch_at = math.huge
    self:resetPowerStats()
    self.pw.ac = self:onExternalPower()
    if Device:isKindle() then   -- a crash while locked would leave the touchscreen dead
        local f = io.open("/proc/touch", "w")
        if f then f:write("unlock"); f:close() end
    end
    self:rebuild()
    self:takePower()
    self:scheduleTick()
end

function Dashboard:writeRotation()
    local file = io.open(ROTATION_FILE, "w")
    if file then
        file:write(Screen:getRotationMode(), "\n")
        file:close()
    end
end

function Dashboard:onShow()
    UIManager:nextTick(self._ready)
end

function Dashboard:reportReady()
    if self.power_failed then
        self:onClose()
        return
    end
    self:writeRotation()
    UIManager:forceRePaint()
    UIManager:waitForVSync()
    logger.info("deskdash: dashboard up")   -- deploy verifies the painted screen independently of weather
    UIManager:scheduleIn(1, self._initial_fetch)
    UIManager:scheduleIn(1, self._poll)
end

-- Debug/remote control: next|prev|refresh|weather ready|close|quit|restart|sleep|demo|demo off|page N|tap X Y.
-- ("demo" shows fake alert/rain/low-battery notices and a two-line condition, to check their layout.)
-- ("sleep" forces one battery-mode sleep even when plugged in; "restart" reloads KOReader + plugin quickly.)
-- (KOReader grabs the touchscreen, so injected touches can't reach it.)
local CMD_FILE = "/tmp/deskdash_cmd"
local ACK_FILE = "/tmp/deskdash_ack"

local function writeCommandAck(id, ok)
    local file = io.open(ACK_FILE .. ".new", "w")
    if file then
        file:write(id, " ", ok and "ok" or "error", "\n")
        file:close()
        os.rename(ACK_FILE .. ".new", ACK_FILE)
    end
end

function Dashboard:ackCommand(id, ok, sample)
    UIManager:forceRePaint()
    Bench.mark(sample, "submit")
    UIManager:waitForVSync()
    Bench.mark(sample, "epdc_wait")
    Bench.finish(sample, self.pw.stats)
    writeCommandAck(id, ok)
end

function Dashboard:pollCommand()
    local f = io.open(CMD_FILE, "r")
    if f then
        local cmd = (f:read("*a") or ""):gsub("%s+$", "")
        f:close()
        os.remove(CMD_FILE)
        local id, request = cmd:match("^@(%x+) (.+)$")
        if id then
            cmd = request
            self.last_touch = os.time()
        end
        local handled = true
        local kind = cmd == "refresh" and "refresh_input" or "command"
        local sample = Bench.start(self.benchmark and (id or cmd == "refresh"), kind)
        logger.info("deskdash: command", cmd)
        if cmd == "bench on" or cmd == "bench off" then self.benchmark = cmd == "bench on"
        elseif cmd == "sleep" then
            self.last_touch, self.force_sleep = 0, true
            UIManager:unschedule(self._tick)
            self:onTick()
        elseif cmd == "flush" then self:logPower("flush")   -- write the hourly power/metrics rows now
        elseif cmd == "demo" or cmd == "demo off" then self.demo = (cmd == "demo"); self:redraw("full")
        elseif cmd == "next" then self:onSwipe(nil, { direction = "west" })
        elseif cmd == "prev" then self:onSwipe(nil, { direction = "east" })
        elseif cmd == "refresh" then self:onTap()
        elseif cmd == "weather ready" then
            if self.next_fetch_at == math.huge then self:refreshWeather() end
        elseif cmd == "close" then
            if id then self.after_close = function() self:ackCommand(id, true) end end
            self:onClose()
            return
        elseif cmd == "quit" or cmd == "restart" then
            -- quit: clean exit (menu > Exit), koreader.sh restores the Kindle UI (slow).
            -- restart: exit code 85, koreader.sh just relaunches KOReader (fast; used by deploy).
            self.after_close = cmd == "quit" and UIManager.quit or UIManager.restartKOReader
            self:onClose()
            return
        elseif cmd:match("^page [1-4]$") then
            self.page, self.show_settings = tonumber(cmd:sub(6)), nil
            self:redraw("partial")
        else
            local x, y = cmd:match("^tap (%d+) (%d+)$")
            handled = x ~= nil
            if handled then self:onTap(nil, { pos = { x = tonumber(x), y = tonumber(y) } }) end
        end
        Bench.mark(sample, "dispatch")
        if id and (cmd == "refresh" or cmd == "weather ready") and self.weather_job then
            self.weather_job.ack = id
            Bench.finish(sample, self.pw.stats)
        elseif id then
            self:ackCommand(id, handled and self.page_ok, sample)
        else
            Bench.finish(sample, self.pw.stats)
        end
    end
    UIManager:scheduleIn(1, self._poll)
end

local function commandOK(rc)
    return rc == 0 or rc == true
end

local function setPowerProperty(service, property, value)
    local rc = os.execute("timeout -s KILL 3 lipc-set-prop com.lab126." .. service .. " " .. property .. " " .. value)
    if commandOK(rc) then return true end
    logger.warn("deskdash: failed to set", property, value, rc)
    return false
end

local function getPowerProperty(service, property)
    local p = io.popen("timeout -s KILL 3 lipc-get-prop com.lab126." .. service .. " " .. property .. " 2>/dev/null")
    if not p then return end
    local value = p:read("*l")
    p:close()
    return value
end

-- Keeps the stock powerd from suspending by itself; the dashboard does its own rtcwake cycles. KOReader's
-- autosuspend plugin is disabled by main.lua (this Kindle is only a wall clock), so there's nothing else to hand over.
function Dashboard:takePower()
    if not Device:isKindle() then return end
    self.power_failed = not setPowerProperty("powerd", "preventScreenSaver", 1)
end

-- ---------------------------------------------------------------- data

function Dashboard:refreshWeather(manual)
    if self.weather_job then return end
    local job = { initial = self.next_fetch_at == math.huge, manual = manual, units = self.settings.units }
    self.pw.fetches = self.pw.fetches + 1
    self:setWifi(true)
    local pid, err = WeatherJob.start{ settings = self.settings, offset = self.offset, station = self.station,
        kindle = Device:isKindle(), benchmark = self.benchmark,
        want_aq = manual or not self.aq_at or os.time() - self.aq_at >= AQ_EVERY }
    if not pid then
        logger.warn("deskdash: weather worker failed to start", err)
        self:finishWeather(job)
        return
    end
    job.pid = pid
    job.deadline = time.now() + WEATHER_TIMEOUT
    self.weather_job = job
    UIManager:scheduleIn(0.25, self._check_weather)
end

function Dashboard:finishWeather(job, result)
    if result then
        self.pw.wifi = self.pw.wifi + result.wifi_s
        for _, phase in ipairs(result.phases or {}) do Bench.add(self.pw.stats, "weather." .. phase[1], phase[2]) end
        local loc, s = result.location, self.settings
        if loc then
            s.lat, s.lon, s.city = s.lat or loc.lat, s.lon or loc.lon, s.city or loc.city
            self.offset = loc.offset
        end
        self.data = result.data or self.data
        self.alerts = result.alerts or self.alerts
        if result.aq then self.aq, self.aq_at = result.aq, os.time() end
        self.obs = result.obs or self.obs
        self.station = result.station or self.station
    end
    if result and result.data then
        self.weather_retry = nil
    else
        self.pw.fails = self.pw.fails + 1
        self.weather_retry = math.min((self.weather_retry or 30) * 2, WEATHER_RETRY_MAX)
    end
    local step = self:onExternalPower() and WEATHER_STEP or WEATHER_STEP_BATTERY
    self.next_fetch_at = os.time()
        + (self.weather_retry or Weather.secondsToSlot(self:localNow(), step, WEATHER_SLOT, WEATHER_GAP))
    logger.info("deskdash: next weather at", os.date("!%H:%M", self.next_fetch_at - os.time() + self:localNow()))
    if job.initial then self:logPower("start") end
    self:redraw(job.manual and "full" or "ui")
    -- The units setting changed while this request was in flight: its values are in the old units.
    if result and result.data and job.units ~= self.settings.units then
        UIManager:nextTick(function() self:refreshWeather(true) end)
    end
    if job.ack then self:ackCommand(job.ack, self.page_ok) end
end

local function discardWeather(pid)
    if not WeatherJob.take(pid, true) then UIManager:scheduleIn(0.25, discardWeather, pid) end
end

function Dashboard:checkWeather()
    local job = self.weather_job
    if not job then return end
    local done, result = WeatherJob.take(job.pid)
    if not done and time.now() < job.deadline then
        UIManager:scheduleIn(0.25, self._check_weather)
        return
    end
    self.weather_job = nil
    if not done then
        logger.warn("deskdash: weather worker timed out")
        WeatherJob.cancel(job.pid)
        discardWeather(job.pid)
    elseif not result then
        logger.warn("deskdash: weather worker returned no result")
    end
    Bench.mark(self.wake_sample, "weather_wait")
    self:finishWeather(job, result)
    Bench.mark(self.wake_sample, "weather_redraw")
    self:finishWake()
end

-- Battery mode switches Wi-Fi off between weather fetches (it otherwise reassociates at every minute wake).
-- Only Wi-Fi we switched off ourselves is switched back on.
function Dashboard:setWifi(on)
    if not Device:isKindle() then return end
    if on and self.wifi_off then
        if setPowerProperty("cmd", "wirelessEnable", 1) then self.wifi_off = nil end
    elseif not on and not self.wifi_off then
        if getPowerProperty("cmd", "wirelessEnable") == "1" and setPowerProperty("cmd", "wirelessEnable", 0) then
            self.wifi_off = true
        end
    end
end

local function readFile(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local v = f:read("*l"); f:close()
    return v
end

function Dashboard:onExternalPower()
    return readFile("/sys/class/power_supply/bd71827_ac/online") == "1"
end

function Dashboard:batteryLevel()
    return tonumber(readFile("/sys/class/power_supply/bd71827_bat/capacity") or "")
end

-- ---------------------------------------------------------------- power stats
-- Counters live in memory; one CSV row per hour (and on plug/unplug). Awake time comes for free: KOReader's
-- monotonic clock doesn't advance during suspend, so its delta between two rows is the time spent awake.
-- charge_mAh is the fuel gauge's coulomb counter: its drop per hour is the average current in mA.
-- It only has 1 mAh steps, so cc also logs the gauge's raw counter (BD71827 registers 0x79-0x7C, big-endian,
-- decreasing while discharging); tools/power.py turns its change into mA.
local POWER_HEADER = "time,event,pct,charge_mAh,mV,ac,temp_C,wall_s,awake_s,wakes,early,fetches,fails,wifi_s,cc\n"

local function rawCoulombCounter()
    local f = io.open(BAT .. "registers", "r")
    if not f then return "" end
    local regs = f:read("*a"); f:close()
    local v = 0
    for a = 0x79, 0x7C do
        local byte = regs:match(string.format("%%[0x%02X%%] = (%%x%%x)", a))
        if not byte then return "" end
        v = v * 256 + tonumber(byte, 16)
    end
    return string.format("%d", v)
end

-- CPU ticks (1/100 s) since boot: this process (user+system) and the whole system (busy, total).
-- Neither advances while suspended.
local function cpuTicks()
    local own, busy, total = 0, 0, 0
    local f = io.open("/proc/self/stat", "r")
    if f then
        local fields = {}
        for v in (f:read("*l") or ""):gsub("^.*%) ", ""):gmatch("%S+") do fields[#fields + 1] = v end
        f:close()
        own = (tonumber(fields[12]) or 0) + (tonumber(fields[13]) or 0)   -- utime, stime
    end
    f = io.open("/proc/stat", "r")
    if f then
        local i = 0
        for v in (f:read("*l") or ""):gmatch("%d+") do
            i = i + 1
            total = total + tonumber(v)
            if i ~= 4 and i ~= 5 then busy = busy + tonumber(v) end   -- idle, iowait
        end
        f:close()
    end
    return own, busy, total
end

-- Hourly metrics, long format (time,event,metric,n,sum,max) so new metrics need no new columns.
-- Values are ms unless the name says otherwise; counts have sum = n. Written next to the power row.
local METRICS_HEADER = "time,event,metric,n,sum,max\n"

function Dashboard:resetPowerStats()
    local own, busy, total = cpuTicks()
    self.pw = { t = os.time(), mono = time.now(), wakes = 0, early = 0, fetches = 0, fails = 0, wifi = 0,
        ac = self.pw and self.pw.ac, stats = {}, cpu = { own, busy, total } }
end

function Dashboard:logMetrics(stamp, event)
    local pw = self.pw
    local own, busy, total = cpuTicks()
    Bench.add(pw.stats, "cpu.koreader", (own - pw.cpu[1]) * 10)
    Bench.add(pw.stats, "cpu.system_busy", (busy - pw.cpu[2]) * 10)
    Bench.add(pw.stats, "cpu.system_total", (total - pw.cpu[3]) * 10)
    local f = io.open(METRICS_LOG, "a")
    if not f then return end
    if f:seek("end") == 0 then f:write(METRICS_HEADER) end
    local keys = {}
    for k in pairs(pw.stats) do keys[#keys + 1] = k end
    table.sort(keys)
    for _, k in ipairs(keys) do
        local v = pw.stats[k]
        f:write(string.format("%s,%s,%s,%d,%.1f,%.1f\n", stamp, event, k, v.n, v.sum, v.max))
    end
    f:close()
end

function Dashboard:logPower(event)
    if not Device:isKindle() then return end
    local pw = self.pw
    local f = io.open(POWER_LOG, "a+")   -- a+: read the header, writes still append
    if f then
        if f:seek("end") == 0 then
            f:write(POWER_HEADER)
        else   -- older column layout: keep it as .old and start a new file
            f:seek("set")
            if (f:read("*l") or "") .. "\n" ~= POWER_HEADER then
                f:close()
                os.rename(POWER_LOG, POWER_LOG .. ".old")
                f = io.open(POWER_LOG, "a")
                if not f then return self:resetPowerStats() end
                f:write(POWER_HEADER)
            else
                f:seek("end")
            end
        end
        local stamp = os.date("!%Y-%m-%d %H:%M", self:localNow())
        local num = function(name, div) local v = tonumber(readFile(BAT .. name) or ""); return v and v / div or "" end
        f:write(string.format("%s,%s,%s,%s,%s,%d,%s,%d,%.1f,%d,%d,%d,%d,%.1f,%s\n",
            stamp, event, readFile(BAT .. "capacity") or "",
            num("charge_now", 1000), num("voltage_now", 1000), self:onExternalPower() and 1 or 0, readFile(BAT .. "temp") or "",
            os.time() - pw.t, time.to_number(time.since(pw.mono)), pw.wakes, pw.early, pw.fetches, pw.fails, pw.wifi,
            rawCoulombCounter()))
        f:close()
        self:logMetrics(stamp, event)
    end
    self:resetPowerStats()
end

-- Called every minute: a row on the hour, and whenever the charger is plugged in / pulled out.
function Dashboard:powerTick()
    local ac = self:onExternalPower()
    if ac ~= self.pw.ac then
        self.pw.ac = ac
        self.suspend_failures = nil
        self:logPower(ac and "plug" or "unplug")
    elseif os.date("!%M", self:localNow()) == "00" then
        self:logPower("hour")
    end
end

-- Match the forecast's local clock fields. Use os.time() for elapsed time and UTC timestamps.
function Dashboard:localNow()
    local now = os.time()
    local offset = (self.data and self.data.utc_offset_seconds) or self.offset
    if offset then return now + offset end
    -- Before geolocation, use the Kindle's configured time zone for the first paint.
    return parseWallTime(os.date("%Y-%m-%dT%H:%M", now)) + now % 60
end

function Dashboard:hhmm(t, omit_period)
    if self.settings.clock_24h then return os.date("!%H:%M", t) end
    local format = omit_period and "!%I:%M" or "!%I:%M %p"
    return (os.date(format, t):gsub("^0", ""))
end

function Dashboard:tr(label)
    return self.settings.language == "zh" and Chinese[label] or label
end

-- ---------------------------------------------------------------- pages

function Dashboard:dots()
    local g = HorizontalGroup:new{ align = "center" }
    for i = 1, PAGES do
        if i > 1 then table.insert(g, hspan(22)) end
        table.insert(g, FrameContainer:new{
            radius = 10, bordersize = 2, padding = 0, margin = 0,
            color = BLACK, background = (i == self.page) and BLACK or WHITE, fixed(16, 16),
        })
    end
    return g
end

local SETTING_ROWS = {
    { key = "language", label = "语言 / Language", options = { { "中文", "zh" }, { "English", "en" } } },
    { key = "clock_24h", label = "Time format", options = { { "12 h", false }, { "24 h", true } } },
    -- Open-Meteo switches wind (km/h, mph) and precipitation (mm, inch) together with the temperature unit.
    { key = "units", label = "Units", options = { { "°C", "metric" }, { "°F", "imperial" } } },
    { key = "landscape", label = "Orientation", options = { { "Portrait", false }, { "Landscape", true } } },
}
local PANEL_W, PANEL_H, PANEL_TOP, SETTING_ROW_H = 760, 492, 90, 92
local SETTING_LABEL_W, SETTING_CHOICE_W = 290, 210
local PANEL_CONTENT_W = SETTING_LABEL_W + 2 * SETTING_CHOICE_W
local PANEL_CONTENT_H = PANEL_TOP + #SETTING_ROWS * SETTING_ROW_H
local FOOTER_H, FOOTER_BOTTOM, GEAR_W, GEAR_RIGHT = 88, 26, 100, 20

function Dashboard:settingsPanel()
    local rows = VerticalGroup:new{ align = "center", box(PANEL_CONTENT_W, PANEL_TOP, txt(self:tr("Settings"), BOLD, 44)) }
    for _, row in ipairs(SETTING_ROWS) do
        local controls = HorizontalGroup:new{ align = "center",
            box(SETTING_LABEL_W, SETTING_ROW_H, txt(self:tr(row.label), BOLD, 30), "left") }
        for _, option in ipairs(row.options) do
            local selected = self.settings[row.key] == option[2]
            table.insert(controls, FrameContainer:new{
                bordersize = 2, radius = 8, padding = 0, margin = 0, color = BLACK,
                background = selected and BLACK or WHITE,
                box(SETTING_CHOICE_W - 4, 62, txt(self:tr(option[1]), BOLD, 32, selected and WHITE or BLACK)),
            })
        end
        table.insert(rows, controls)
    end
    return FrameContainer:new{
        bordersize = 3, radius = 18, padding = 0, margin = 0, color = BLACK, background = WHITE,
        overlap_offset = { math.floor((self.W - PANEL_W) / 2), math.floor((self.H - PANEL_H) / 2) },
        fixed(PANEL_W - 6, PANEL_H - 6, box(PANEL_W - 6, PANEL_H - 6, rows)),
    }
end

function Dashboard:onSettingsTap(pos)
    local x = pos.x - math.floor((self.W - PANEL_CONTENT_W) / 2) - SETTING_LABEL_W
    local y = pos.y - math.floor((self.H - PANEL_CONTENT_H) / 2) - PANEL_TOP
    local row = SETTING_ROWS[math.floor(y / SETTING_ROW_H) + 1]
    if row and x >= 0 and x < 2 * SETTING_CHOICE_W then
        local key, value = row.key, row.options[1 + math.floor(x / SETTING_CHOICE_W)][2]
        if self.settings[key] ~= value then
            self.settings[key] = value
            G_reader_settings:saveSetting("deskdash_" .. key, value)
            G_reader_settings:flush()
            if key == "landscape" then
                self.show_settings = nil
                self:applyOrientation()
                self:writeRotation()
            end
            self:redraw("full")
            if key == "units" then self:refreshWeather(true) end   -- forecast values come in the requested units
        end
    elseif pos.x < (self.W - PANEL_W) / 2 or pos.x >= (self.W + PANEL_W) / 2
        or pos.y < (self.H - PANEL_H) / 2 or pos.y >= (self.H + PANEL_H) / 2 then
        self.show_settings = nil
        self:redraw("ui")
    end
end

function Dashboard:footer()
    local footer = OverlapGroup:new{
        dimen = Geom:new{ w = self.W, h = FOOTER_H },
        overlap_offset = { 0, self.H - FOOTER_H - FOOTER_BOTTOM },
        box(self.W, FOOTER_H, self:dots()),
        box(GEAR_W, FOOTER_H, txt(Weather.ICON.settings, ICONS, 38)),
    }
    footer[2].overlap_offset = { self.W - GEAR_W - GEAR_RIGHT, 0 }
    return footer
end

function Dashboard:header(title)
    local s = self.settings
    return VerticalGroup:new{ align = "center",
        vspan(self.landscape and 22 or 38),
        txt(self:tr(title), BOLD, 46, BLACK),
        vspan(8),
        txt((s.city or "") .. "  ·  " .. self:hhmm(self:localNow()), SANS, 34, GRAY, self.W - 80),
        vspan(self.landscape and 18 or 30),
    }
end

-- Current conditions: the nearest NWS station's observation if it's recent and understood (models often get the
-- sky wrong: "Clear" under an overcast sky), else Open-Meteo's modelled weather code.
local OBS_MAX_AGE = 2 * 3600
function Dashboard:currentConditions()
    local c, o = self.data.current, self.obs
    if o and o.code and os.time() - o.t < OBS_MAX_AGE then
        local label, icon = Weather.describe(o.code, c.is_day == 1)
        if self.settings.language == "zh" then return self:tr(label), icon end
        local head, rest = Weather.shortText(o.text)
        return head, icon, rest
    end
    local label, icon = Weather.describe(c.weather_code, c.is_day == 1)
    return self:tr(label), icon
end

function Dashboard:pageNow()
    local t, d = self:localNow(), self.data
    local wide = self.landscape
    local column_w = wide and math.floor((self.W - 72) / 2) or self.W - 72
    local date = os.date("!%A, %b ", t) .. tonumber(os.date("!%d", t))
    if self.settings.language == "zh" then
        date = string.format("%d月%d日 %s", tonumber(os.date("!%m", t)), tonumber(os.date("!%d", t)), self:tr(os.date("!%A", t)))
    end
    local function fmt(at) return self:hhmm(at) end
    local alert_format, precip_format = self:tr("%s until %s"), self:tr("%s–%s · %d%% precip")
    local alert = Weather.activeAlert(self.alerts, t, fmt, alert_format)
    local tr = function(s) return self:tr(s) end
    -- The 15-minute nowcast when it has something to say, else the first likely-wet hour.
    local precip = d and (Weather.nowcastText(Weather.nowcast(d.minutely, t), tr)
        or Weather.precipSummary(d.hourly, t, fmt, precip_format))
    if self.demo then
        local midnight = t - t % 86400
        alert = string.format(alert_format, "Wind Advisory", fmt(midnight + 18 * 3600))
        precip = Weather.nowcastText({ kind = "start", minutes = 25 }, tr)
    end
    local extra = (alert and 1 or 0) + (precip and 1 or 0)   -- make room for the notice lines
    -- Leave space beside the clock for the period marker in 12-hour mode.
    local clock_px = wide and (self.settings.clock_24h and 244 or 226) or (self.settings.clock_24h and 400 or 350) - 30 * extra
    local clock = HorizontalGroup:new{ align = "bottom", txt(self:hhmm(t, true), HEAVY, clock_px) }
    if not self.settings.clock_24h then
        table.insert(clock, hspan(16))
        table.insert(clock, VerticalGroup:new{ txt(os.date("!%p", t), BOLD, wide and 34 or 46), vspan(wide and 54 or 77) })
    end
    local clock_block = VerticalGroup:new{ align = "center", clock,
        vspan(wide and -20 or -36),   -- reclaim the clock font's blank space below the digits
        fitTxt(date, BOLD, wide and 58 or 82, BLACK, wide and math.floor(self.W / 2) - 56 or self.W - 64, wide and 40 or 56),
    }
    local weather = VerticalGroup:new{ align = "center" }
    if d then
        local c, daily = d.current, d.daily
        local day_index, is_today = Weather.firstForecastDay(daily, t)
        local cond, icon, cond_rest = self:currentConditions()
        if self.demo and self.settings.language ~= "zh" then   -- the widest real NWS text, as two lines
            cond, cond_rest = Weather.shortText("Heavy Thunderstorms and Heavy Rain and Hail and Fog/Mist")
        end
        local glyph = txt(icon, ICONS, wide and 174 or 246 - 20 * extra)
        -- Nerd Font weather glyphs can extend past their reported width.
        local gap = wide and 105 or 140
        local temp_px = wide and 198 or 288 - 20 * extra
        local temp = deg(c.temperature_2m)
        local temperature = txt(temp, HEAVY, temp_px)
        local available = column_w - glyph:getSize().w - gap - 8  -- allow for font-size rounding
        local temp_w = temperature:getSize().w
        if temp_w > available then
            temperature = txt(temp, HEAVY, math.floor(temp_px * available / temp_w))
        end
        table.insert(weather, HorizontalGroup:new{ align = "center", glyph, hspan(gap), temperature })
        table.insert(weather, vspan(wide and -20 or 6 - 3 * extra))
        -- NWS observation text is split into a headline and the rest ("Light Rain" / "Fog/Mist").
        local cond_w = wide and math.floor(self.W / 2) - 56 or self.W - 80
        table.insert(weather, fitTxt(cond, BOLD, wide and 56 or 84, BLACK, cond_w, wide and 36 or 52))
        if cond_rest then
            table.insert(weather, vspan(wide and -4 or -8))
            table.insert(weather, fitTxt(cond_rest, BOLD, wide and 34 or 50, BLACK, cond_w, wide and 26 or 36))
        end
        table.insert(weather, vspan(8))
        local hi = is_today and daily.temperature_2m_max[day_index]
        local lo = is_today and daily.temperature_2m_min[day_index]
        table.insert(weather, txt(self:tr("H") .. " " .. deg(hi) .. "    " .. self:tr("L") .. " " .. deg(lo), BOLD, wide and 48 or 80))
    elseif self.next_fetch_at == math.huge then
        table.insert(weather, txt(self:tr("Loading weather…"), BOLD, 56, GRAY))
    else
        table.insert(weather, txt(self:tr("Weather unavailable"), BOLD, 56, GRAY))
        table.insert(weather, txt(self:tr("Check Wi-Fi · tap to retry"), SANS, 40, GRAY))
    end
    local g = VerticalGroup:new{ align = "center" }
    if wide then
        local column_h = math.max(clock_block:getSize().h, weather:getSize().h)
        table.insert(g, HorizontalGroup:new{ box(column_w, column_h, clock_block), box(column_w, column_h, weather) })
    else
        table.insert(g, clock_block)
        table.insert(g, vspan(42 - 16 * extra))
        table.insert(g, weather)
    end
    local I = Weather.ICON
    if alert or precip then table.insert(g, vspan(wide and 36 or 20)) end
    if alert then
        table.insert(g, HorizontalGroup:new{ align = "center", txt(I.warning, ICONS, 40), hspan(16),
            fitTxt(alert, BOLD, 40, BLACK, self.W - 160, 30) })   -- "Tropical Cyclone Local Statement until …"
    end
    if precip then
        table.insert(g, HorizontalGroup:new{ align = "center", txt(I.umbrella, ICONS, 40, GRAY), hspan(16),
            fitTxt(precip, SANS, 40, GRAY, self.W - 160, 30) })
    end
    return g
end

function Dashboard:pageHourly()
    local g = VerticalGroup:new{ align = "center" }
    local h = self.data and self.data.hourly
    if not h then table.insert(g, txt(self:tr("No data"), SANS, 48, GRAY)); return g end
    local now = self:localNow()
    local first = Weather.firstForecastHour(h, now)
    if first > #h.time - 2 then table.insert(g, txt(self:tr("Forecast unavailable"), SANS, 48, GRAY)); return g end
    table.insert(g, self:hourlyChart(h, first))
    return g
end

-- Next 24 hours, like Apple Weather: icons every 3 h, a smooth temperature curve with the area below it filled,
-- a time axis (a thin line at midnight) and hourly precipitation-chance bars.
local CHART_HOURS, LABEL_EVERY = 24, 3
local PRECIP_LABEL_MIN = 20   -- % below which a 3-hour block's number is left blank
local BLEND_HOURS = 4     -- the current temperature's offset from the forecast fades out over this many hours
function Dashboard:hourlyChart(h, first)
    local wide, W = self.landscape, self.W
    local n = math.min(CHART_HOURS, #h.time - first)   -- hourlyPrecipChance reads i + 1
    -- Sizes for reading across a room; curve_h and bar_h are fallbacks, the chart normally fills body_h.
    local S = wide and { icon_h = 84, icon = 60, label_h = 62, curve_h = 250, temp = 46, axis_h = 54, axis = 34,
                         gap = 22, title_h = 40, title = 26, bar_label_h = 54, bar_h = 110, pct = 36 }
                   or { icon_h = 108, icon = 76, label_h = 80, curve_h = 380, temp = 58, axis_h = 64, axis = 40,
                         gap = 36, title_h = 50, title = 30, bar_label_h = 64, bar_h = 200, pct = 42 }
    local margin = wide and 90 or 56
    local inner = wide and 50 or 46   -- half a label: the first and last points sit this far inside the margins
    local x0, x1 = margin + inner, W - margin - inner
    local function xAt(k) return x0 + k * (x1 - x0) / (CHART_HOURS - 1) end

    -- The first point is "now": the current temperature instead of the hour's forecast. The forecast's error now
    -- carries over into the next hours, so the difference fades out over BLEND_HOURS instead of a jump at hour 1.
    local current = self.data.current.temperature_2m
    local delta = current and current - h.temperature_2m[first] or 0
    local temps, times, icons, chances = {}, {}, {}, {}
    local any_precip = false
    for k = 0, n - 1 do
        local i = first + k
        times[k] = parseWallTime(h.time[i])
        -- Whole degrees, like the labels.
        temps[k + 1] = math.floor(h.temperature_2m[i] + delta * math.max(0, 1 - k / BLEND_HOURS) + 0.5)
        local _, icon = Weather.describe(h.weather_code[i], h.is_day and h.is_day[i] == 1)
        icons[k] = icon
        chances[k] = Weather.hourlyPrecipChance(h, i)
        any_precip = any_precip or chances[k] > 0
    end
    local _, now_icon = self:currentConditions()
    icons[0] = now_icon

    -- Fill the space between the page title and the footer (self.body_h): the fixed rows keep their size, the curve
    -- and the bars share the rest.
    local fixed = S.icon_h + S.label_h + 10 + S.axis_h + S.gap + S.title_h
    if self.body_h then
        if any_precip then
            local flex = self.body_h - fixed - S.bar_label_h - 4
            S.curve_h = math.floor(flex * 0.62)
            S.bar_h = flex - S.curve_h
        else
            S.curve_h = self.body_h - fixed - 20
        end
    end
    local icon_top = 0
    local curve_top = icon_top + S.icon_h + S.label_h
    local curve_bottom = curve_top + S.curve_h
    local axis_top = curve_bottom + 10
    local title_top = axis_top + S.axis_h + S.gap
    local bars_top = title_top + S.title_h + S.bar_label_h
    local bars_bottom = bars_top + S.bar_h
    local total_h = bars_bottom + 4
    if not any_precip then total_h = title_top + S.title_h + 20 end

    -- The curve goes through the labelled 3-hour points (and the last hour) only, so points labelled alike sit level
    -- and rounding the hours in between doesn't add steps or notches.
    local cx, cy = {}, {}
    for k = 0, n - 1 do
        if k % LABEL_EVERY == 0 or k == n - 1 then cx[#cx + 1], cy[#cy + 1] = k + 1, temps[k + 1] end
    end
    local f = Curve.monotone(cy, cx)
    -- At least 6 °C (11 °F) of height, so a steady day doesn't look like a cliff. The extra height goes below the
    -- curve (into the fill), so the warmest point stays just under the icons instead of leaving a gap there.
    local lo, hi = Curve.range(temps)
    lo = math.min(lo, hi - (self.settings.units == "imperial" and 11 or 6))
    local function yAt(v) return curve_bottom - 18 - (v - lo) / (hi - lo) * (S.curve_h - 36) end
    local midnights = {}
    for k = 1, n - 1 do
        if os.date("!%H", times[k]) == "00" then midnights[#midnights + 1] = k end
    end

    local og = OverlapGroup:new{ dimen = Geom:new{ w = W, h = total_h } }
    local line_w = wide and 4 or 5
    table.insert(og, Canvas:new{ w = W, h = total_h, draw = function(bb, x, y)
        -- midnight: a short tick across the baseline down to the axis, where the day's name stands
        for _, k in ipairs(midnights) do
            bb:paintRect(x + math.floor(xAt(k)), y + curve_bottom - 24, 3, 24 + 10 + S.axis_h - 12, GRAY)
        end
        -- fill and curve, one pixel column at a time
        local last_x = math.floor(xAt(n - 1))
        local prev
        for px = math.floor(x0), last_x do
            local v = f(1 + (px - x0) / (x1 - x0) * (CHART_HOURS - 1))
            local py = math.floor(yAt(v) + 0.5)
            bb:paintRect(x + px, y + py, 1, curve_bottom - py, FILL)
            local top, bottom = py, py
            if prev then top, bottom = math.min(prev, py), math.max(prev, py) end
            bb:paintRect(x + px, y + top - math.floor(line_w / 2), 1, bottom - top + line_w, BLACK)
            prev = py
        end
        bb:paintRect(x + math.floor(x0), y + curve_bottom, last_x - math.floor(x0) + 1, 2, LIGHT)   -- baseline
        -- dots on the labelled points; "now" is a white dot with a black ring
        for k = LABEL_EVERY, n - 1, LABEL_EVERY do
            bb:paintCircle(x + math.floor(xAt(k)), y + math.floor(yAt(temps[k + 1]) + 0.5), wide and 6 or 7, BLACK)
        end
        local r = wide and 11 or 13
        local cx, cy = x + math.floor(x0), y + math.floor(yAt(temps[1]) + 0.5)
        bb:paintCircle(cx, cy, r, WHITE)
        bb:paintCircle(cx, cy, r, BLACK, 4)
        if any_precip then   -- precipitation-chance bars
            local bw = math.max(6, math.floor((x1 - x0) / (CHART_HOURS - 1) * 0.55))
            bb:paintRect(x + math.floor(x0 - bw / 2), y + bars_bottom, last_x - math.floor(x0) + bw, 2, LIGHT)
            for k = 0, n - 1 do
                local bh = math.floor(chances[k] / 100 * S.bar_h + 0.5)
                if bh > 0 then
                    bb:paintRect(x + math.floor(xAt(k) - bw / 2), y + bars_bottom - bh, bw, bh, GRAY)
                end
            end
        end
    end })

    -- Midnight's day name goes on the time axis just right of its tick, replacing a clock label it would overlap.
    -- Within an hour of "Now" there's no room on the axis: it sits on the fill just above the baseline instead.
    local now_label = txt(self:tr("Now"), BOLD, S.axis)
    local now_right = x0 + now_label:getSize().w / 2
    local days = {}   -- { left, right } of day names on the axis
    local weekday_format = self.settings.language == "zh" and "!%A" or "!%a"
    for _, k in ipairs(midnights) do
        local name = self:tr(os.date(weekday_format, times[k]))
        local left = math.floor(xAt(k)) + 12
        local day = txt(name, BOLD, S.axis)
        if left < now_right + 10 then
            day:free()
            day = txt(name, BOLD, S.axis - 8, GRAY)
            day.overlap_offset = { left, curve_bottom - day:getSize().h - 6 }
        else
            day.overlap_offset = { left, axis_top + 6 }
            days[#days + 1] = { left = left, right = left + day:getSize().w }
        end
        table.insert(og, day)
    end
    local clock_24h = self.settings.clock_24h
    for k = 0, n - 1, LABEL_EVERY do
        local x = xAt(k)
        place(og, txt(icons[k], ICONS, S.icon), x, icon_top + (S.icon_h - S.icon * 1.2) / 2, W)
        -- Above the highest bit of curve under the label, so a steep neighbour doesn't run through it.
        local temp = txt(deg(temps[k + 1]), BOLD, S.temp)
        local half = temp:getSize().w / 2 / (x1 - x0) * (CHART_HOURS - 1)
        local peak = math.huge
        for s = -10, 10 do
            local at = math.max(0, math.min(n - 1, k + s / 10 * half))
            peak = math.min(peak, yAt(f(1 + at)))
        end
        place(og, temp, x, peak - temp:getSize().h - 10, W)
        if k == 0 then
            place(og, now_label, x, axis_top + 6, W)
        else
            local label = txt(clock_24h and os.date("!%H:%M", times[k]) or (os.date("!%I %p", times[k]):gsub("^0", "")),
                SANS, S.axis, GRAY)
            local half, clash = label:getSize().w / 2, false
            for _, d in ipairs(days) do
                if x - half < d.right + 10 and x + half > d.left - 10 then clash = true end
            end
            if clash then label:free() else place(og, label, x, axis_top + 6, W) end
        end
        -- One row of numbers above the bars, aligned with the time axis: the highest chance in each 3-hour block
        -- (so a peak between two labels isn't missed); blank below PRECIP_LABEL_MIN.
        local block = 0
        for j = k, math.min(k + LABEL_EVERY - 1, n - 1) do block = math.max(block, chances[j]) end
        if any_precip and block >= PRECIP_LABEL_MIN then
            place(og, txt(block .. "%", SANS, S.pct, GRAY), x, bars_top - S.bar_label_h, W)
        end
    end
    local title = txt(self:tr(any_precip and "CHANCE OF PRECIP" or "No precipitation in the next 24 h"),
        BOLD, S.title, GRAY)
    if any_precip then
        title.overlap_offset = { margin, title_top }
        table.insert(og, title)
    else
        place(og, title, W / 2, title_top, W)
    end
    return og
end

function Dashboard:rangeBar(w, lo, hi, min_all, max_all, now_t)
    local span = math.max(max_all - min_all, 1)
    local x0 = math.floor((lo - min_all) / span * w)
    local x1 = math.max(math.floor((hi - min_all) / span * w), x0 + 14)
    local og = OverlapGroup:new{ dimen = Geom:new{ w = w, h = 16 },
        FrameContainer:new{ width = w, height = 12, radius = 6, bordersize = 0, padding = 0, background = LIGHT, vspan(0),
            overlap_offset = { 0, 2 } },
        FrameContainer:new{ width = x1 - x0, height = 12, radius = 6, bordersize = 0, padding = 0, background = BLACK, vspan(0),
            overlap_offset = { x0, 2 } },
    }
    if now_t then -- current-temperature marker (white dot with black ring), like Apple's
        local xn = math.floor((now_t - min_all) / span * w)
        table.insert(og, FrameContainer:new{ width = 16, height = 16, radius = 8, bordersize = 3, padding = 0,
            color = BLACK, background = WHITE, vspan(0), overlap_offset = { math.max(0, math.min(w - 16, xn - 8)), 0 } })
    end
    return og
end

function Dashboard:pageDaily()
    local g = VerticalGroup:new{ align = "center" }
    local d = self.data and self.data.daily
    if not d then table.insert(g, txt(self:tr("No data"), SANS, 48, GRAY)); return g end
    local first, is_today = Weather.firstForecastDay(d, self:localNow())
    if not first then table.insert(g, txt(self:tr("Forecast unavailable"), SANS, 48, GRAY)); return g end
    local last = math.min(first + 6, #d.time)
    local min_all, max_all = math.huge, -math.huge
    for i = first, last do
        min_all = math.min(min_all, d.temperature_2m_min[i]); max_all = math.max(max_all, d.temperature_2m_max[i])
    end
    local rowW, rowH = self.W - 120, self.landscape and 105 or 157
    local barWidth = rowW - 170 - 110 - 120 - 28 - 28 - 120
    for i = first, last do
        local _, icon = Weather.describe(d.weather_code[i], true)
        local today = i == first and is_today
        local weekday_format = self.settings.language == "zh" and "!%A" or "!%a"
        local day = today and self:tr("Today") or self:tr(os.date(weekday_format, parseWallTime(d.time[i])))
        table.insert(g, HorizontalGroup:new{ align = "center",
            box(170, rowH, txt(day, today and BOLD or SANS, 54), "left"),
            box(110, rowH, txt(icon, ICONS, 66)),
            box(120, rowH, txt(deg(d.temperature_2m_min[i]), SANS, 52, GRAY), "right"),
            hspan(28),
            box(barWidth, rowH,
                self:rangeBar(barWidth, d.temperature_2m_min[i], d.temperature_2m_max[i],
                    min_all, max_all, today and self.data.current.temperature_2m)),
            hspan(28),
            box(120, rowH, txt(deg(d.temperature_2m_max[i]), BOLD, 52), "left"),
        })
        if i < last then table.insert(g, LineWidget:new{ dimen = Geom:new{ w = rowW, h = 2 }, background = LIGHT }) end
    end
    return g
end

function Dashboard:tile(icon, label, value, sub, w, h)
    local wide = self.landscape
    local border, pl, pt = 3, wide and 20 or 32, wide and 0 or 18
    local text_w = w - 2 * border - pl - 16
    local inner_w, inner_h = w - 2 * border - pl, h - 2 * border - pt
    local content = VerticalGroup:new{ align = "left",
        -- The wind and sunset glyphs are ~10 px wider than the others: leave room so they don't touch the label.
        HorizontalGroup:new{ align = "center", box(60, 44, txt(icon, ICONS, 40, GRAY), "left"),
            fitTxt(self:tr(label), BOLD, wide and 25 or 32, GRAY, text_w - 60, wide and 20 or 24) },
        vspan(2),
        -- Landscape tiles are narrow: "0.25 inch", "125.4 mm", "12:59 PM" don't fit at full size.
        fitTxt(value, HEAVY, wide and 68 or 82, BLACK, text_w, wide and 44 or 56),
        fitTxt(sub or " ", SANS, wide and 27 or 36, GRAY, text_w, wide and 20 or 26),
    }
    return FrameContainer:new{
        radius = 28, bordersize = border, color = BLACK, background = WHITE,
        padding = 0, padding_left = pl, padding_top = pt, margin = 0,
        wide and box(inner_w, inner_h, content, "left") or fixed(inner_w, inner_h, content),
    }
end

function Dashboard:pageDetails()
    local g = VerticalGroup:new{ align = "center" }
    local d = self.data
    if not d then table.insert(g, txt(self:tr("No data"), SANS, 48, GRAY)); return g end
    local W, c, day, I = Weather, d.current, d.daily, Weather.ICON
    local units = (type(d.current_units) == "table" and d.current_units.wind_speed_10m) or "km/h"
    if units == "mp/h" then units = "mph" end   -- Open-Meteo's spelling
    local punits = d.daily_units.precipitation_sum or "mm"
    local columns, th, gap = self.landscape and 4 or 2, self.landscape and 340 or 263, 22
    local tw = math.floor((self.W - 80 - (columns - 1) * gap) / columns)
    local now = self:localNow()
    local today, is_today = W.firstForecastDay(day, now)
    if not is_today then today = nil end
    local tomorrow, is_tomorrow = W.firstForecastDay(day, now + 86400)
    if not is_tomorrow then tomorrow = nil end
    local diff = c.apparent_temperature and c.temperature_2m and (c.apparent_temperature - c.temperature_2m)
    local function amount(v)
        if not v then return "--" end
        return (punits == "inch" and string.format("%.2f", v) or string.format("%g", math.floor(v * 10 + 0.5) / 10)) .. " " .. punits
    end
    -- Sun: show the next event big and the other one small (like iOS).
    local rise, set = day.sunrise[today], day.sunset[today]
    local sun_label, sun_icon, sun_value, sun_sub = "SUN", I.sunrise, "--", self:tr("Unavailable")
    if rise and now < rise then
        sun_label, sun_value = "SUNRISE", self:hhmm(rise)
        sun_sub = set and (self:tr("Sunset") .. " " .. self:hhmm(set))
    elseif set and now < set then
        sun_label, sun_icon, sun_value = "SUNSET", I.sunset, self:hhmm(set)
        sun_sub = rise and (self:tr("Sunrise") .. " " .. self:hhmm(rise))
    elseif day.sunrise[tomorrow] then
        sun_label, sun_value = "SUNRISE", self:hhmm(day.sunrise[tomorrow])
        sun_sub = set and (self:tr("Sunset") .. " " .. self:hhmm(set))
    end
    local moon_name, moon_lit, moon_icon = W.moon(os.time())
    local aq = self.aq
    local uv = day.uv_index_max[today]
    local tiles = {
        self:tile(I.thermometer, "FEELS LIKE", deg(c.apparent_temperature),
            diff and math.abs(diff) >= 2 and self:tr(diff < 0 and "Colder than actual" or "Warmer than actual"), tw, th),
        self:tile(I.humidity, "HUMIDITY", c.relative_humidity_2m and (math.floor(c.relative_humidity_2m + 0.5) .. "%") or "--",
            c.dew_point_2m and (self:tr("Dew point") .. " " .. deg(c.dew_point_2m)), tw, th),
        self:tile(I.wind, "WIND", c.wind_speed_10m and tostring(math.floor(c.wind_speed_10m + 0.5)) or "--",
            c.wind_speed_10m and (units .. " " .. self:tr(W.compass(c.wind_direction_10m))
            .. (c.wind_gusts_10m and (" · " .. self:tr("Gusts") .. " " .. math.floor(c.wind_gusts_10m + 0.5)) or "")), tw, th),
        self:tile(I.uv, "UV MAX TODAY", type(uv) == "number" and tostring(math.floor(uv + 0.5)) or "--",
            self:tr(type(uv) == "number" and W.uvLevel(uv) or "Unavailable"), tw, th),
        self:tile(I.umbrella, "PRECIP FORECAST", amount(day.precipitation_sum[today]),
            self:tr("Tomorrow") .. " " .. amount(day.precipitation_sum[tomorrow]), tw, th),
        self:tile(I.smog, "AQI ESTIMATE", aq and tostring(math.floor(aq + 0.5)) or "--",
            self:tr(aq and W.aqiLevel(aq) or "Unavailable"), tw, th),
        self:tile(sun_icon, sun_label, sun_value, sun_sub, tw, th),
        self:tile(moon_icon, "MOON", math.floor(moon_lit * 100 + 0.5) .. "%", self:tr(moon_name), tw, th),
    }
    for first = 1, #tiles, columns do
        if first > 1 then table.insert(g, vspan(gap)) end
        local row = HorizontalGroup:new{}
        for i = first, first + columns - 1 do
            if i > first then table.insert(row, hspan(gap)) end
            table.insert(row, tiles[i])
        end
        table.insert(g, row)
    end
    return g
end

-- Battery percentage on pages 2–4; page 1 only shows the low-battery warning.
function Dashboard:batteryBadge()
    local pct = self.demo and 15 or (Device:isKindle() and self:batteryLevel())
    if not pct then return nil end
    local low = self.demo or (pct <= LOW_BATTERY and not self:onExternalPower())
    if not low then
        if self.page == 1 then return nil end
        local I = Weather.ICON
        local icon = pct > 87 and I.battery_full or pct > 62 and I.battery_three_quarters
            or pct > 37 and I.battery_half or pct > 12 and I.battery_low or I.battery_empty
        return HorizontalGroup:new{ align = "center", overlap_offset = { 40, self.H - 96 },
            txt(icon, ICONS, 30, GRAY), hspan(24), txt(pct .. "%", SANS, 34, GRAY) }
    end
    local I = Weather.ICON
    return HorizontalGroup:new{ align = "center", overlap_offset = { 40, self.H - 96 },
        txt(pct <= 5 and I.battery_empty or I.battery_low, ICONS, 40), hspan(24),
        txt(pct .. "%  " .. self:tr("Charge me"), BOLD, 34) }
end

local PAGE_TITLES = { nil, "HOURLY FORECAST", "7-DAY FORECAST", "DETAILS" }

function Dashboard:rebuild()
    local builders = { self.pageNow, self.pageHourly, self.pageDaily, self.pageDetails }
    -- Pages 2-4: the title sits at the same height on every page; the content is centred in the space below it
    -- (body_h, down to the footer), which the hourly chart fills.
    local header, header_h
    if self.page ~= 1 then
        header = self:header(PAGE_TITLES[self.page])
        header_h = header:getSize().h
        self.body_h = self.H - header_h - FOOTER_H - FOOTER_BOTTOM - 10
    end
    local ok, content = pcall(builders[self.page], self)
    self.page_ok = ok
    if not ok then
        logger.err("deskdash: page build failed", content)
        content = VerticalGroup:new{ align = "center", vspan(350), txt(self:tr("Something went wrong"), BOLD, 56),
            txt(tostring(content):sub(1, 60), SANS, 28, GRAY, self.W - 80) }
    end
    local page = OverlapGroup:new{ dimen = Geom:new{ w = self.W, h = self.H } }
    if header then
        table.insert(page, box(self.W, header_h, header))
        local body = CenterContainer:new{ dimen = Geom:new{ w = self.W, h = self.body_h }, ignore_if_over = "height",
            VerticalGroup:new{ align = "center", content } }
        body.overlap_offset = { 0, header_h }
        table.insert(page, body)
    else
        table.insert(page, CenterContainer:new{ dimen = Geom:new{ w = self.W, h = self.H - 88 }, ignore_if_over = "height",
            VerticalGroup:new{ align = "center", content } })
    end
    if self.page ~= 1 then table.insert(page, self:footer()) end
    local badge = self:batteryBadge()
    if badge then table.insert(page, badge) end
    if self.show_settings then table.insert(page, self:settingsPanel()) end
    self[1] = FrameContainer:new{
        width = self.W, height = self.H, background = WHITE, bordersize = 0, padding = 0, margin = 0, page,
    }
end

-- ---------------------------------------------------------------- refresh & input

function Dashboard:redraw(mode)
    self:rebuild()
    UIManager:setDirty(self, mode or "ui")
end

function Dashboard:scheduleTick()
    local sec = tonumber(os.date("%S"))
    UIManager:scheduleIn(60 - sec + 0.3, self._tick)
end

function Dashboard:onTick()
    local sample = self.wake_sample or Bench.start(self.benchmark, "wake")
    if self.resumed_at then   -- rtcwake returned -> this tick started
        Bench.add(self.pw.stats, "resume.to_tick", time.to_ms(time.now() - self.resumed_at))
        self.resumed_at = nil
    end
    self:powerTick()
    if self.page ~= 1 and os.time() - self.last_touch >= IDLE_RETURN then
        self.page, self.show_settings = 1, nil
    end
    local now = self:localNow()
    if not Weather.isNight(now, NIGHT) and os.time() >= self.next_fetch_at then self:refreshWeather() end
    Bench.mark(sample, "tick_and_weather")
    -- On battery the minute repaint uses "fast" (DU, ~260 ms) instead of "ui" (AUTO -> GC16 for anti-aliased
    -- digits, ~450 ms): only changed pixels are driven, so static gray text keeps its levels; the new digits lose
    -- their gray edges until the flashing full refresh every FLASH_EVERY minutes.
    local mode = tonumber(os.date("!%M", now)) % FLASH_EVERY == 0 and "full"
        or (self:canSleep() and "fast" or "ui")
    Bench.add(self.pw.stats, "refresh." .. mode, 1)
    self:redraw(mode)
    self:scheduleTick()
    self.wake_sample = sample
    Bench.mark(sample, "build")
    if self.weather_job and sample then sample.kind = "weather_wake" end
    self:finishWake()
end

function Dashboard:finishWake()
    if not self:canSleep() then
        self.wake_sample = nil
        self:restore()   -- staying awake (e.g. charger plugged in): undo the battery-mode light/Wi-Fi off
    elseif not self.weather_job then
        UIManager:nextTick(self._sleep)
    end
end

-- Development: while this file exists the dashboard never sleeps, so SSH stays reachable on battery
-- (on-device test scripts still suspend by themselves). In /tmp, so a reboot clears it.
local STAY_AWAKE_FLAG = "/tmp/deskdash_awake"

local function exists(path)
    local f = io.open(path, "r")
    if f then f:close() end
    return f ~= nil
end

function Dashboard:canSleep()
    if not (self.settings.battery_mode and Device:isKindle()) then return false end
    if self.force_sleep then return true end   -- `sleep` command: one real cycle, even plugged in or with the dev flag
    return self.page == 1 and not exists(STAY_AWAKE_FLAG)
        and os.time() - self.last_touch >= AWAKE_AFTER_INPUT and not self:onExternalPower()
end

-- Suspend to RAM until the next minute. KOReader's timers use a clock that stops while suspended,
-- so the pending tick is replaced by a direct call after waking.
function Dashboard:sleepUntilNextMinute()
    local sample = self.wake_sample
    self.wake_sample = nil
    if self.weather_job or not self:canSleep() then return end
    local secs = Weather.secondsToNextWake(self:localNow(), NIGHT)   -- next minute, or next 10 minutes at night
    -- A forced cycle with the dev flag (benchmarks) sleeps only 6 s, so samples don't wait for the minute.
    if self.force_sleep and exists(STAY_AWAKE_FLAG) then secs = 6 end
    self.force_sleep = nil
    if secs < 5 then return end   -- too close to the minute; the regular tick handles it
    UIManager:unschedule(self._tick)
    -- Paint now and let the e-ink refresh finish (an interrupted refresh leaves ghosting).
    UIManager:forceRePaint()
    Bench.mark(sample, "submit")
    UIManager:waitForVSync()
    Bench.mark(sample, "epdc_wait")
    -- The frontlight comes back on at every resume, so switch it off while in battery mode;
    -- it (and Wi-Fi) are turned back on only when staying awake (power button, charger).
    if not exists(STAY_AWAKE_FLAG) then self:setWifi(false) end   -- dev flag: keep SSH between forced cycles
    local powerd = Device:hasFrontlight() and Device.powerd
    if powerd and powerd:isFrontlightOn() then
        powerd:turnOffFrontlight()
        self.light_off = true
    end
    -- KOReader's Kindle powerd defers the hardware write to a later UI tick, which doesn't come before rtcwake,
    -- and its idea of the light can drift from the hardware. Make sure the LED is really off while asleep.
    for _, fl in ipairs(powerd and powerd.fl_intensity_files or {}) do
        if tonumber(readFile(fl) or "0") ~= 0 then
            local f = io.open(fl, "w")
            if f then f:write("0"); f:close() end
        end
    end
    Bench.mark(sample, "radios")
    -- The PW4 kernel synchronizes filesystems on suspend entry.
    -- Touch stays locked (gt9xx asleep, powered off) across minute wakes: it can't wake the device and nobody
    -- can use it in a 2 s wake, and each lock/unlock costs ~60/150 ms of driver sleeps (gt9xx.c). restore()
    -- unlocks it whenever the dashboard stays awake. Locked also measured ~0.5 mA lower in suspend.
    self:setTouch(false)
    -- time.now() is monotonic (stops while suspended), so suspend_resume_awake is only the awake part of rtcwake.
    local was_on_ac = self.pw.ac
    local wall_start, awake_start = os.time(), time.now()
    local rc = os.execute(string.format("rtcwake -d %s -m mem -s %d >/dev/null 2>%s", RTC, secs, RTC_ERROR))
    local elapsed = os.time() - wall_start
    local early = secs - elapsed
    local slept = elapsed - time.to_number(time.since(awake_start))
    Bench.mark(sample, "suspend_resume_awake")
    Bench.finish(sample, self.pw.stats)
    self.resumed_at = time.now()
    -- A successful return can still mean an immediate kernel wake. Allow for the wall clock's one-second resolution.
    local failed = not commandOK(rc)
    if failed or (early > 2 and slept < 1 and was_on_ac == self:onExternalPower()) then
        Bench.add(self.pw.stats, "suspend.failed", 1)
        self.suspend_failures = (self.suspend_failures or 0) + 1
        if failed then
            logger.warn("deskdash: rtcwake failed", rc, readFile(RTC_ERROR) or "")
        else
            logger.warn("deskdash: rtcwake returned without sustained sleep")
        end
        self:setTouch(true)
        if self.suspend_failures >= SUSPEND_FAILURE_LIMIT then
            logger.warn("deskdash: closing dashboard after repeated suspend failures")
            self.power_failed = true
            self:onClose()
        else
            self:scheduleTick()
        end
        return
    end
    self.suspend_failures = nil
    self.pw.wakes = self.pw.wakes + 1
    if early > 2 then
        self.pw.early = self.pw.early + 1
        -- Woken before the alarm (e.g. power button or USB) -> stay interactive for a while.
        logger.info("deskdash: woke", early, "s early")
        self:restore()
        self.last_touch = os.time()
        self:scheduleTick()
    else
        UIManager:nextTick(self._tick)
    end
end

-- /proc/touch: "lock" puts the gt9xx to sleep and cuts its power, "unlock" resets and wakes it.
function Dashboard:setTouch(on)
    if not Device:isKindle() or (not on) == (self.touch_locked or false) then return end
    local f = io.open("/proc/touch", "w")
    if not f then return end
    local written = f:write(on and "unlock" or "lock")
    local closed = f:close()
    if written and closed then self.touch_locked = not on or nil end
end

function Dashboard:restore()
    self:setTouch(true)
    if self.light_off then
        self.light_off = nil
        Device.powerd:turnOnFrontlight()
    end
    self:setWifi(true)
end

function Dashboard:onSwipe(_, ges)
    self.last_touch = os.time()
    self.suspend_failures = nil
    if self.show_settings then return true end
    local dir = ges.direction
    if dir == "west" or dir == "east" then
        self.page = (self.page - 1 + (dir == "west" and 1 or -1)) % PAGES + 1
        self:redraw("partial")
    end
    return true
end

function Dashboard:onHold()
    if self.show_settings then
        self.show_settings = nil
        self:redraw("ui")
    else
        self:onClose()
    end
    return true
end

function Dashboard:onTap(_, ges)
    self.last_touch = os.time()
    self.suspend_failures = nil
    local pos = ges and ges.pos
    if pos and self.show_settings then
        self:onSettingsTap(pos)
        return true
    end
    if pos and self.page ~= 1 and pos.x >= self.W - GEAR_W - GEAR_RIGHT
        and pos.y >= self.H - FOOTER_H - FOOTER_BOTTOM then
        self.show_settings = true
        self:redraw("ui")
        return true
    end
    self:refreshWeather(true)
    return true
end

function Dashboard:onClose()
    UIManager:close(self, "full")
    return true
end

function Dashboard:onCloseWidget()
    UIManager:unschedule(self._tick)
    UIManager:unschedule(self._poll)
    UIManager:unschedule(self._sleep)
    UIManager:unschedule(self._ready)
    UIManager:unschedule(self._initial_fetch)
    UIManager:unschedule(self._check_weather)
    local job = self.weather_job
    if job then
        self.weather_job = nil
        WeatherJob.cancel(job.pid)
        discardWeather(job.pid)
        if job.ack then writeCommandAck(job.ack, false) end
    end
    self:logPower("close")
    self:restore()
    os.remove(ROTATION_FILE)
    if Screen:getRotationMode() ~= self.previous_rotation then Screen:setRotationMode(self.previous_rotation) end
    if Device:isKindle() then setPowerProperty("powerd", "preventScreenSaver", 0) end
    self.on_closed(self)
    if self.after_close then UIManager:nextTick(self.after_close, UIManager) end
end

return Dashboard

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
local logger = require("logger")
local time = require("ui/time")
local Weather = require("deskdash_weather")
local Chinese = require("deskdash_chinese")
local parseWallTime = Weather.parseWallTime
local Screen = Device.screen

local BLACK = Blitbuffer.COLOR_BLACK
local WHITE = Blitbuffer.COLOR_WHITE
-- E-ink contrast is low: keep "secondary" text dark and rules/tracks clearly visible.
local GRAY = Blitbuffer.Color8(0x33)   -- secondary text
local LIGHT = Blitbuffer.Color8(0x99)  -- separators, range-bar track

local SANS, BOLD, ICONS = "NotoSans-Regular.ttf", "NotoSans-Bold.ttf", "nerdfonts/symbols.ttf"
local HEAVY = BOLD   -- big numerals (KOReader can't see the Kindle's Amazon Ember)

local PAGES = 4
local IDLE_RETURN = 120          -- seconds on another page before returning to "Now"
local WEATHER_EVERY = 15 * 60    -- seconds between forecast fetches
local FLASH_EVERY = 30           -- flashing full refresh when the minute is a multiple of this
-- Battery mode: on battery, suspend to RAM between minute updates (e-ink keeps the picture).
local AWAKE_AFTER_INPUT = 60     -- stay awake this long after a touch / power-button wake
local LOW_BATTERY = 20           -- % at which a "charge me" badge appears (on battery only)
local POWER_LOG = "/mnt/us/deskdash_power.csv"   -- hourly power stats; analyse with tools/power.py
local BAT = "/sys/class/power_supply/bd71827_bat/"
-- Night (local hours [from, to)): wake only every `step` minutes and don't fetch the weather.
local NIGHT = { from = 2, to = 5, step = 10 }
local RTC = "/dev/rtc1"          -- the wake-capable RTC on the PW4 (snvs)
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
    self._initial_fetch = function()
        self:refreshWeather()
        self:logPower("start")   -- the first fetch supplies the local time
        self:redraw("ui")
    end
    self.next_fetch_at = math.huge
    self:keepAwake(true)
    self:resetPowerStats()
    self.pw.ac = self:onExternalPower()
    self:rebuild()
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
    self:writeRotation()
    UIManager:forceRePaint()
    UIManager:waitForVSync()
    logger.info("deskdash: dashboard up")   -- deploy verifies the painted screen independently of weather
    UIManager:scheduleIn(1, self._initial_fetch)
    UIManager:scheduleIn(1, self._poll)
end

-- Debug/remote control: next|prev|refresh|close|quit|restart|sleep|demo|demo off|page N|tap X Y.
-- ("demo" shows fake alert/rain/low-battery notices, to check their layout.)
-- ("sleep" forces one battery-mode sleep even when plugged in; "restart" reloads KOReader + plugin quickly.)
-- (KOReader grabs the touchscreen, so injected touches can't reach it.)
local CMD_FILE = "/tmp/deskdash_cmd"
local ACK_FILE = "/tmp/deskdash_ack"

function Dashboard:ackCommand(id, ok)
    UIManager:forceRePaint()
    UIManager:waitForVSync()
    local file = io.open(ACK_FILE .. ".new", "w")
    if file then
        file:write(id, " ", ok and "ok" or "error", "\n")
        file:close()
        os.rename(ACK_FILE .. ".new", ACK_FILE)
    end
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
        logger.info("deskdash: command", cmd)
        if cmd == "sleep" then self.last_touch = 0; self.force_sleep = true; UIManager:nextTick(self._sleep)
        elseif cmd == "demo" or cmd == "demo off" then self.demo = (cmd == "demo"); self:redraw("full")
        elseif cmd == "next" then self:onSwipe(nil, { direction = "west" })
        elseif cmd == "prev" then self:onSwipe(nil, { direction = "east" })
        elseif cmd == "refresh" then self:onTap()
        elseif cmd == "close" then
            self:onClose()
            if id then self:ackCommand(id, true) end
            return
        elseif cmd == "quit" or cmd == "restart" then
            -- quit: clean exit (menu > Exit), koreader.sh restores the Kindle UI (slow).
            -- restart: exit code 85, koreader.sh just relaunches KOReader (fast; used by deploy).
            self:onClose()
            if cmd == "quit" then UIManager:quit() else UIManager:restartKOReader() end
            return
        elseif cmd:match("^page [1-4]$") then
            self.page, self.show_settings = tonumber(cmd:sub(6)), nil
            self:redraw("partial")
        else
            local x, y = cmd:match("^tap (%d+) (%d+)$")
            handled = x ~= nil
            if handled then self:onTap(nil, { pos = { x = tonumber(x), y = tonumber(y) } }) end
        end
        if id then self:ackCommand(id, handled and self.page_ok) end
    end
    UIManager:scheduleIn(1, self._poll)
end

function Dashboard:keepAwake(on)
    if Device:isKindle() then
        os.execute("lipc-set-prop com.lab126.powerd preventScreenSaver " .. (on and "1" or "0"))
    end
end

-- ---------------------------------------------------------------- data

function Dashboard:refreshWeather()
    local W, s = Weather, self.settings
    local started_at = os.time()
    self.next_fetch_at = started_at + 60  -- retry on the next eligible minute tick if this fetch fails
    self.pw.fetches = self.pw.fetches + 1
    self:setWifi(true)
    if not self:waitForWifi() then
        self.pw.fails = self.pw.fails + 1
        return
    end
    if not (s.lat and s.lon) or not self.offset then
        local loc = W.locate()
        if loc then
            s.lat, s.lon, s.city = s.lat or loc.lat, s.lon or loc.lon, s.city or loc.city
            self.offset = loc.offset
        end
    end
    local ok = false
    if s.lat and s.lon then
        local data, err = W.fetch(s.lat, s.lon, s.units)
        if data then self.data = data; ok = true else logger.warn("deskdash: fetch failed", err) end
        self.alerts = W.alerts(s.lat, s.lon) or self.alerts
        if ok then
            self.aq = W.airQuality(s.lat, s.lon) or self.aq
            self.nws = self.nws or {}
            self.obs = W.observation(s.lat, s.lon, self.nws) or self.obs
        end
    end
    if ok then
        self.next_fetch_at = os.time() + WEATHER_EVERY
    else
        self.pw.fails = self.pw.fails + 1
    end
end

-- Battery mode switches Wi-Fi off between weather fetches (it otherwise reassociates at every minute wake).
-- Only Wi-Fi we switched off ourselves is switched back on.
function Dashboard:setWifi(on)
    if not Device:isKindle() then return end
    if on and self.wifi_off then
        self.wifi_off = nil
        os.execute("lipc-set-prop com.lab126.cmd wirelessEnable 1")
    elseif not on and not self.wifi_off then
        local p = io.popen("lipc-get-prop com.lab126.cmd wirelessEnable 2>/dev/null")
        local v = p and p:read("*l"); if p then p:close() end
        if v == "1" then
            self.wifi_off = true
            os.execute("lipc-set-prop com.lab126.cmd wirelessEnable 0")
        end
    end
end

-- Wi-Fi needs ~2 s to reassociate after a suspend, ~10 s after being switched on; wait for it (up to 30 s).
function Dashboard:waitForWifi()
    if not Device:isKindle() then return true end
    local t0 = os.time()
    local t_mono = time.now()
    while os.time() - t0 < 30 do
        local p = io.popen("lipc-get-prop com.lab126.wifid cmState 2>/dev/null")
        local state = p and p:read("*l"); if p then p:close() end
        if state == "CONNECTED" then
            if os.time() > t0 then logger.info("deskdash: wifi up after", os.time() - t0, "s") end
            self.pw.wifi = self.pw.wifi + time.to_number(time.since(t_mono))
            return true
        end
        os.execute("sleep 1")
    end
    self.pw.wifi = self.pw.wifi + time.to_number(time.since(t_mono))
    logger.warn("deskdash: wifi not connected after 30 s")
    return false
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
local POWER_HEADER = "time,event,pct,charge_mAh,mV,ac,temp_C,wall_s,awake_s,wakes,early,fetches,fails,wifi_s\n"

function Dashboard:resetPowerStats()
    self.pw = { t = os.time(), mono = time.now(), wakes = 0, early = 0, fetches = 0, fails = 0, wifi = 0, ac = self.pw and self.pw.ac }
end

function Dashboard:logPower(event)
    if not Device:isKindle() then return end
    local pw = self.pw
    local f = io.open(POWER_LOG, "a")
    if f then
        if f:seek("end") == 0 then f:write(POWER_HEADER) end
        local num = function(name, div) local v = tonumber(readFile(BAT .. name) or ""); return v and v / div or "" end
        f:write(string.format("%s,%s,%s,%s,%s,%d,%s,%d,%.1f,%d,%d,%d,%d,%.1f\n",
            os.date("!%Y-%m-%d %H:%M", self:localNow()), event, readFile(BAT .. "capacity") or "",
            num("charge_now", 1000), num("voltage_now", 1000), self:onExternalPower() and 1 or 0, readFile(BAT .. "temp") or "",
            os.time() - pw.t, time.to_number(time.since(pw.mono)), pw.wakes, pw.early, pw.fetches, pw.fails, pw.wifi))
        f:close()
    end
    self:resetPowerStats()
end

-- Called every minute: a row on the hour, and whenever the charger is plugged in / pulled out.
function Dashboard:powerTick()
    local ac = self:onExternalPower()
    if ac ~= self.pw.ac then
        self.pw.ac = ac
        self:logPower(ac and "plug" or "unplug")
    elseif os.date("!%M", self:localNow()) == "00" then
        self:logPower("hour")
    end
end

-- Match the forecast's local clock fields. Use os.time() for elapsed time and UTC timestamps.
function Dashboard:localNow()
    local off = (self.data and self.data.utc_offset_seconds) or self.offset or 0
    return os.time() + off   -- "local" epoch; always format with "!"
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
    { key = "landscape", label = "Orientation", options = { { "Portrait", false }, { "Landscape", true } } },
}
local PANEL_W, PANEL_H, PANEL_TOP, SETTING_ROW_H = 760, 400, 90, 92
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
        return self.settings.language == "zh" and self:tr(label) or o.text, icon
    end
    local label, icon = Weather.describe(c.weather_code, c.is_day == 1)
    return self:tr(label), icon
end

function Dashboard:pageNow()
    local t, d = self:localNow(), self.data
    local wide = self.landscape
    local date = os.date("!%A, %b ", t) .. tonumber(os.date("!%d", t))
    if self.settings.language == "zh" then
        date = string.format("%d月%d日 %s", tonumber(os.date("!%m", t)), tonumber(os.date("!%d", t)), self:tr(os.date("!%A", t)))
    end
    local function fmt(at) return self:hhmm(at) end
    local alert_format, precip_format = self:tr("%s until %s"), self:tr("%s–%s · %d%% precip")
    local alert = Weather.activeAlert(self.alerts, t, fmt, alert_format)
    local precip = d and Weather.precipSummary(d.hourly, t, fmt, precip_format)
    if self.demo then
        local midnight = t - t % 86400
        alert = string.format(alert_format, "Wind Advisory", fmt(midnight + 18 * 3600))
        precip = string.format(precip_format, fmt(midnight + 16 * 3600), fmt(midnight + 17 * 3600), 70)
    end
    local extra = (alert and 1 or 0) + (precip and 1 or 0)   -- make room for the notice lines
    -- Leave space beside the clock for the period marker in 12-hour mode.
    local clock_px = wide and 244 or (self.settings.clock_24h and 400 or 350) - 30 * extra
    local clock = HorizontalGroup:new{ align = "bottom", txt(self:hhmm(t, true), HEAVY, clock_px) }
    if not self.settings.clock_24h then
        table.insert(clock, hspan(16))
        table.insert(clock, VerticalGroup:new{ txt(os.date("!%p", t), BOLD, wide and 34 or 46), vspan(wide and 54 or 77) })
    end
    local clock_block = VerticalGroup:new{ align = "center", clock,
        vspan(wide and -20 or -36),   -- reclaim the clock font's blank space below the digits
        txt(date, BOLD, wide and 58 or 82, BLACK, wide and math.floor(self.W / 2) - 56 or self.W - 64),
    }
    local weather = VerticalGroup:new{ align = "center" }
    if d then
        local c, daily = d.current, d.daily
        local day_index, is_today = Weather.firstForecastDay(daily, t)
        local cond, icon = self:currentConditions()
        table.insert(weather, HorizontalGroup:new{ align = "center",
            txt(icon, ICONS, wide and 174 or 246 - 20 * extra), hspan(wide and 32 or 60),
            txt(deg(c.temperature_2m), HEAVY, wide and 198 or 288 - 20 * extra) })
        table.insert(weather, vspan(wide and -20 or 6 - 3 * extra))
        table.insert(weather, txt(cond, BOLD, wide and 56 or 84, BLACK, wide and math.floor(self.W / 2) - 56 or self.W - 80))
        table.insert(weather, vspan(8))
        local hi = is_today and daily.temperature_2m_max[day_index]
        local lo = is_today and daily.temperature_2m_min[day_index]
        table.insert(weather, txt(self:tr("H") .. " " .. deg(hi) .. "    " .. self:tr("L") .. " " .. deg(lo), BOLD, wide and 48 or 80))
    else
        table.insert(weather, txt(self:tr("Weather unavailable"), BOLD, 56, GRAY))
        table.insert(weather, txt(self:tr("Check Wi-Fi · tap to retry"), SANS, 40, GRAY))
    end
    local g = VerticalGroup:new{ align = "center" }
    if wide then
        local column_w = math.floor((self.W - 72) / 2)
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
            txt(alert, BOLD, 40, BLACK, self.W - 160) })
    end
    if precip then
        table.insert(g, HorizontalGroup:new{ align = "center", txt(I.umbrella, ICONS, 40, GRAY), hspan(16),
            txt(precip, SANS, 40, GRAY, self.W - 160) })
    end
    return g
end

function Dashboard:pageHourly()
    local g = self:header("HOURLY FORECAST")
    local h = self.data and self.data.hourly
    if not h then table.insert(g, txt(self:tr("No data"), SANS, 48, GRAY)); return g end
    local now = self:localNow()
    local first = Weather.firstForecastHour(h, now)
    local last = math.min(first + 11, #h.time - 1)
    if first > last then table.insert(g, txt(self:tr("Forecast unavailable"), SANS, 48, GRAY)); return g end
    local wide = self.landscape
    local rowW, rowH = wide and math.floor((self.W - 124) / 2) or self.W - 88, wide and 120 or 92
    local timeW, iconW, precipW = wide and 230 or 280, wide and 130 or 170, wide and 130 or 180
    local left, right = VerticalGroup:new{}, VerticalGroup:new{}
    local left_end = wide and math.min(first + 5, last) or last
    for i = first, last do
        local t = parseWallTime(h.time[i])
        local is_now = i == first and t <= now
        local _, icon = Weather.describe(h.weather_code[i], h.is_day and h.is_day[i] == 1)
        local temperature = h.temperature_2m[i]
        if is_now then
            _, icon = self:currentConditions()
            temperature = self.data.current.temperature_2m
        end
        local p = Weather.hourlyPrecipChance(h, i)
        local label = is_now and self:tr("Now") or self:hhmm(t)
        local column = i <= left_end and left or right
        table.insert(column, HorizontalGroup:new{ align = "center",
            box(timeW, rowH, txt(label, is_now and BOLD or SANS, self.settings.clock_24h and 54 or 46), "left"),
            box(iconW, rowH, txt(icon, ICONS, 68)),
            box(precipW, rowH, txt(p .. "%", SANS, 46, GRAY), "right"),
            box(rowW - timeW - iconW - precipW, rowH, txt(deg(temperature), BOLD, 58), "right"),
        })
        if i ~= left_end and i < last then
            table.insert(column, LineWidget:new{ dimen = Geom:new{ w = rowW, h = 2 }, background = LIGHT })
        end
    end
    table.insert(g, wide and HorizontalGroup:new{ left, hspan(36), fixed(rowW, right:getSize().h, right) } or left)
    return g
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
    local g = self:header("7-DAY FORECAST")
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
        HorizontalGroup:new{ align = "center", box(50, 44, txt(icon, ICONS, 40, GRAY), "left"),
            txt(self:tr(label), BOLD, wide and 25 or 32, GRAY, text_w - 50) },
        vspan(2),
        txt(value, HEAVY, wide and 68 or 82, BLACK, text_w),
        txt(sub or " ", SANS, wide and 27 or 36, GRAY, text_w),
    }
    return FrameContainer:new{
        radius = 28, bordersize = border, color = BLACK, background = WHITE,
        padding = 0, padding_left = pl, padding_top = pt, margin = 0,
        wide and box(inner_w, inner_h, content, "left") or fixed(inner_w, inner_h, content),
    }
end

function Dashboard:pageDetails()
    local g = self:header("DETAILS")
    local d = self.data
    if not d then table.insert(g, txt(self:tr("No data"), SANS, 48, GRAY)); return g end
    local W, c, day, I = Weather, d.current, d.daily, Weather.ICON
    local units = (type(d.current_units) == "table" and d.current_units.wind_speed_10m) or "km/h"
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

-- Low-battery warning in the bottom-left corner, level with the page dots (only on battery, at <= LOW_BATTERY %).
function Dashboard:batteryBadge()
    local pct = self.demo and 15 or (Device:isKindle() and self:batteryLevel())
    if not self.demo and (not pct or pct > LOW_BATTERY or self:onExternalPower()) then return nil end
    local I = Weather.ICON
    return HorizontalGroup:new{ align = "center", overlap_offset = { 40, self.H - 96 },
        txt(pct <= 5 and I.battery_empty or I.battery_low, ICONS, 40), hspan(24),
        txt(pct .. "%  " .. self:tr("Charge me"), BOLD, 34) }
end

function Dashboard:rebuild()
    local builders = { self.pageNow, self.pageHourly, self.pageDaily, self.pageDetails }
    local ok, content = pcall(builders[self.page], self)
    self.page_ok = ok
    if not ok then
        logger.err("deskdash: page build failed", content)
        content = VerticalGroup:new{ align = "center", vspan(350), txt(self:tr("Something went wrong"), BOLD, 56),
            txt(tostring(content):sub(1, 60), SANS, 28, GRAY, self.W - 80) }
    end
    local page = OverlapGroup:new{ dimen = Geom:new{ w = self.W, h = self.H },
        CenterContainer:new{ dimen = Geom:new{ w = self.W, h = self.H - (self.page == 1 and 88 or 120) }, ignore_if_over = "height",
            VerticalGroup:new{ align = "center", content } },
    }
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
    self:powerTick()
    if self.page ~= 1 and os.time() - self.last_touch >= IDLE_RETURN then
        self.page, self.show_settings = 1, nil
    end
    local now = self:localNow()
    if not Weather.isNight(now, NIGHT) and os.time() >= self.next_fetch_at then self:refreshWeather() end
    self:redraw(tonumber(os.date("!%M", now)) % FLASH_EVERY == 0 and "full" or "ui")
    self:scheduleTick()
    if self:canSleep() then
        UIManager:nextTick(self._sleep)
    else
        self:restore()   -- staying awake (e.g. charger plugged in): undo the battery-mode light/Wi-Fi off
    end
end

function Dashboard:canSleep()
    return self.settings.battery_mode and Device:isKindle() and self.page == 1
        and os.time() - self.last_touch >= AWAKE_AFTER_INPUT and (self.force_sleep or not self:onExternalPower())
end

-- Suspend to RAM until the next minute. KOReader's timers use a clock that stops while suspended,
-- so the pending tick is replaced by a direct call after waking.
function Dashboard:sleepUntilNextMinute()
    if not self:canSleep() then return end
    self.force_sleep = nil
    local secs = Weather.secondsToNextWake(self:localNow(), NIGHT)   -- next minute, or next 10 minutes at night
    if secs < 5 then return end   -- too close to the minute; the regular tick handles it
    local target = os.time() + secs
    UIManager:unschedule(self._tick)
    -- Paint now and let the e-ink refresh finish (an interrupted refresh leaves ghosting).
    UIManager:forceRePaint()
    UIManager:waitForVSync()
    -- The frontlight comes back on at every resume, so switch it off while in battery mode;
    -- it (and Wi-Fi) are turned back on only when staying awake (power button, charger).
    self:setWifi(false)
    local powerd = Device:hasFrontlight() and Device.powerd
    if powerd and powerd:isFrontlightOn() then
        powerd:turnOffFrontlight()
        self.light_off = true
    end
    os.execute(string.format("sync; rtcwake -d %s -m mem -s %d >/dev/null 2>&1", RTC, secs))
    local early = target - os.time()
    self.pw.wakes = self.pw.wakes + 1
    if early > 2 then
        self.pw.early = self.pw.early + 1
        -- woken before the alarm: power button (or suspend refused) -> stay interactive for a while
        logger.info("deskdash: woke", early, "s early")
        self:restore()
        self.last_touch = os.time()
        self:scheduleTick()
    else
        UIManager:nextTick(self._tick)
    end
end

function Dashboard:restore()
    if self.light_off then
        self.light_off = nil
        Device.powerd:turnOnFrontlight()
    end
    self:setWifi(true)
end

function Dashboard:onSwipe(_, ges)
    self.last_touch = os.time()
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
    self:refreshWeather()
    self:redraw("full")
    return true
end

function Dashboard:onClose()
    self:logPower("close")
    self:restore()
    self:keepAwake(false)
    UIManager:close(self, "full")
    return true
end

function Dashboard:onCloseWidget()
    UIManager:unschedule(self._tick)
    UIManager:unschedule(self._poll)
    UIManager:unschedule(self._sleep)
    UIManager:unschedule(self._ready)
    UIManager:unschedule(self._initial_fetch)
    os.remove(ROTATION_FILE)
    if Screen:getRotationMode() ~= self.previous_rotation then Screen:setRotationMode(self.previous_rotation) end
end

return Dashboard

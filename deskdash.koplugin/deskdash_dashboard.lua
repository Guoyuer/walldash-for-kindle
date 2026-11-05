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
local FLASH_EVERY = 30           -- minutes between flashing full refreshes
-- Battery mode: on battery, suspend to RAM between minute updates (e-ink keeps the picture).
local AWAKE_AFTER_INPUT = 60     -- stay awake this long after a touch / power-button wake
local RTC = "/dev/rtc1"          -- the wake-capable RTC on the PW4 (snvs)

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
    weather = nil,   -- Weather module, injected
    settings = nil,  -- { units=, clock_24h=, lat=, lon=, city= }
}

function Dashboard:init()
    self.W, self.H = Screen:getWidth(), Screen:getHeight()
    self.dimen = Geom:new{ x = 0, y = 0, w = self.W, h = self.H }
    self.ges_events = {
        Swipe = { GestureRange:new{ ges = "swipe", range = self.dimen } },
        Tap = { GestureRange:new{ ges = "tap", range = self.dimen } },
        -- Closing needs a deliberate long-press, so a stray swipe on the wall can't exit.
        Hold = { GestureRange:new{ ges = "hold", range = self.dimen } },
    }
    self.page = 1
    self.minutes = 0
    self.last_touch = os.time()
    self._tick = function() self:onTick() end
    self._poll = function() self:pollCommand() end
    self._sleep = function() self:sleepUntilNextMinute() end
    self:keepAwake(true)
    self:refreshWeather()
    self:rebuild()
    self:scheduleTick()
    UIManager:scheduleIn(1, self._poll)
end

-- Debug/remote control: write one of next|prev|refresh|close|quit|restart|sleep|page N to this file.
-- ("sleep" forces one battery-mode sleep even when plugged in; "restart" reloads KOReader + plugin quickly.)
-- (KOReader grabs the touchscreen, so injected touches can't reach it.)
local CMD_FILE = "/tmp/deskdash_cmd"
function Dashboard:pollCommand()
    local f = io.open(CMD_FILE, "r")
    if f then
        local cmd = (f:read("*a") or ""):gsub("%s+$", "")
        f:close()
        os.remove(CMD_FILE)
        logger.info("deskdash: command", cmd)
        if cmd == "sleep" then self.last_touch = 0; self.force_sleep = true; UIManager:nextTick(self._sleep)
        elseif cmd == "next" then self:onSwipe(nil, { direction = "west" })
        elseif cmd == "prev" then self:onSwipe(nil, { direction = "east" })
        elseif cmd == "refresh" then self:onTap()
        elseif cmd == "close" then self:onClose(); return
        elseif cmd == "quit" or cmd == "restart" then
            -- quit: clean exit (menu > Exit), koreader.sh restores the Kindle UI (slow).
            -- restart: exit code 85, koreader.sh just relaunches KOReader (fast; used by deploy).
            self:onClose()
            if cmd == "quit" then UIManager:quit() else UIManager:restartKOReader() end
            return
        elseif cmd:match("^page %d$") then self.page = tonumber(cmd:sub(6)); self:redraw("partial") end
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
    local W, s = self.weather, self.settings
    if not (s.lat and s.lon) or not self.offset then
        local loc = W.locate()
        if loc then
            s.lat, s.lon, s.city = s.lat or loc.lat, s.lon or loc.lon, s.city or loc.city
            self.offset = loc.offset
        end
    end
    self:setWifi(true)
    self:waitForWifi()
    local ok = false
    if s.lat and s.lon then
        local data, err = W.fetch(s.lat, s.lon, s.units)
        if data then self.data = data; ok = true else logger.warn("deskdash: fetch failed", err) end
    end
    -- On failure, try again at the next minute instead of waiting a full WEATHER_EVERY.
    self.fetched_at = ok and os.time() or (os.time() - WEATHER_EVERY + 60)
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
    if not Device:isKindle() then return end
    local t0 = os.time()
    while os.time() - t0 < 30 do
        local p = io.popen("lipc-get-prop com.lab126.wifid cmState 2>/dev/null")
        local state = p and p:read("*l"); if p then p:close() end
        if state == "CONNECTED" then
            if os.time() > t0 then logger.info("deskdash: wifi up after", os.time() - t0, "s") end
            return
        end
        os.execute("sleep 1")
    end
    logger.warn("deskdash: wifi not connected after 30 s")
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

function Dashboard:now()
    local off = (self.data and self.data.utc_offset_seconds) or self.offset or 0
    return os.time() + off   -- "local" epoch; always format with "!"
end

function Dashboard:hhmm(t)
    if self.settings.clock_24h then return os.date("!%H:%M", t) end
    return (os.date("!%I:%M", t):gsub("^0", ""))
end

local function parseISO(s) -- "2026-11-05T13:00" or "2026-11-05" -> "local" epoch (as if UTC)
    local y, m, d, H, M = s:match("(%d+)-(%d+)-(%d+)T?(%d*):?(%d*)")
    local t = os.time{ year = y, month = m, day = d, hour = tonumber(H) or 12, min = tonumber(M) or 0 }
    -- os.time() reads the table as local time; undo the system TZ so results behave like UTC
    local utc = os.date("!*t", t); utc.isdst = false
    return t + (t - os.time(utc))
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

function Dashboard:header(title)
    local s = self.settings
    return VerticalGroup:new{ align = "center",
        vspan(70),
        txt(title, BOLD, 46, BLACK),
        vspan(8),
        txt((s.city or "") .. "  ·  " .. self:hhmm(self:now()), SANS, 34, GRAY),
        vspan(40),
    }
end

function Dashboard:pageNow()
    local t, d = self:now(), self.data
    local date = os.date("!%A, %B ", t) .. tonumber(os.date("!%d", t))
    local g = VerticalGroup:new{ align = "center",
        vspan(70),
        txt(self.settings.city or " ", SANS, 40, GRAY),
        txt(self:hhmm(t), HEAVY, 330),
        txt(date, BOLD, 64),
        vspan(70),
    }
    if d then
        local c, today = d.current, d.daily
        local cond, icon = self.weather.describe(c.weather_code, c.is_day == 1)
        table.insert(g, HorizontalGroup:new{ align = "center",
            txt(icon, ICONS, 190), hspan(90), txt(deg(c.temperature_2m), HEAVY, 210) })
        table.insert(g, vspan(30))
        table.insert(g, txt(cond, BOLD, 66))
        table.insert(g, vspan(14))
        table.insert(g, txt("H " .. deg(today.temperature_2m_max[1]) .. "    L " .. deg(today.temperature_2m_min[1]), SANS, 54, GRAY))
    else
        table.insert(g, txt("Weather unavailable", BOLD, 56, GRAY))
        table.insert(g, txt("Check Wi-Fi · tap to retry", SANS, 40, GRAY))
    end
    return g
end

function Dashboard:pageHourly()
    local g = self:header("HOURLY FORECAST")
    local h = self.data and self.data.hourly
    if not h then table.insert(g, txt("No data", SANS, 48, GRAY)); return g end
    local rowW, rowH = self.W - 160, 88
    for i = 1, math.min(12, #h.time) do
        local t = parseISO(h.time[i])
        local _, icon = self.weather.describe(h.weather_code[i], h.is_day and h.is_day[i] == 1)
        local p = h.precipitation_probability and h.precipitation_probability[i]
        local label = (i == 1) and "Now" or self:hhmm(t)
        table.insert(g, HorizontalGroup:new{ align = "center",
            box(260, rowH, txt(label, i == 1 and BOLD or SANS, 50), "left"),
            box(170, rowH, txt(icon, ICONS, 64)),
            box(200, rowH, txt((p and p >= 10) and (p .. "%") or "", SANS, 40, GRAY), "right"),
            box(rowW - 630, rowH, txt(deg(h.temperature_2m[i]), BOLD, 54), "right"),
        })
        if i < 12 then table.insert(g, LineWidget:new{ dimen = Geom:new{ w = rowW, h = 2 }, background = LIGHT }) end
    end
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
    if not d then table.insert(g, txt("No data", SANS, 48, GRAY)); return g end
    local n = math.min(7, #d.time)
    local min_all, max_all = math.huge, -math.huge
    for i = 1, n do
        min_all = math.min(min_all, d.temperature_2m_min[i]); max_all = math.max(max_all, d.temperature_2m_max[i])
    end
    local rowW, rowH = self.W - 120, 132
    for i = 1, n do
        local _, icon = self.weather.describe(d.weather_code[i], true)
        local p = d.precipitation_probability_max and d.precipitation_probability_max[i]
        local day = (i == 1) and "Today" or os.date("!%a", parseISO(d.time[i]))
        table.insert(g, HorizontalGroup:new{ align = "center",
            box(170, rowH, txt(day, i == 1 and BOLD or SANS, 50), "left"),
            box(110, rowH, VerticalGroup:new{ align = "center", txt(icon, ICONS, 60),
                txt((p and p >= 20) and (p .. "%") or " ", SANS, 28, GRAY) }),
            box(120, rowH, txt(deg(d.temperature_2m_min[i]), SANS, 48, GRAY), "right"),
            hspan(28),
            box(rowW - 170 - 110 - 120 - 28 - 28 - 120, rowH,
                self:rangeBar(rowW - 170 - 110 - 120 - 28 - 28 - 120, d.temperature_2m_min[i], d.temperature_2m_max[i],
                    min_all, max_all, i == 1 and self.data.current.temperature_2m or nil)),
            hspan(28),
            box(120, rowH, txt(deg(d.temperature_2m_max[i]), BOLD, 48), "left"),
        })
        if i < n then table.insert(g, LineWidget:new{ dimen = Geom:new{ w = rowW, h = 2 }, background = LIGHT }) end
    end
    return g
end

function Dashboard:tile(icon, label, value, sub, w, h)
    local border, pl, pt = 3, 32, 26
    return FrameContainer:new{
        radius = 28, bordersize = border, color = BLACK, background = WHITE,
        padding = 0, padding_left = pl, padding_top = pt, margin = 0,
        fixed(w - 2 * border - pl, h - 2 * border - pt, VerticalGroup:new{ align = "left",
            HorizontalGroup:new{ align = "center", box(54, 50, txt(icon, ICONS, 40, GRAY), "left"), txt(label, BOLD, 32, GRAY) },
            vspan(10),
            txt(value, HEAVY, 96),
            vspan(4),
            txt(sub or " ", SANS, 34, GRAY, w - 60),
        }),
    }
end

function Dashboard:pageDetails()
    local g = self:header("DETAILS")
    local d = self.data
    if not d then table.insert(g, txt("No data", SANS, 48, GRAY)); return g end
    local W, c, day, I = self.weather, d.current, d.daily, self.weather.ICON
    local units = (d.current_units and d.current_units.wind_speed_10m) or "km/h"
    local tw, th, gap = math.floor((self.W - 80 - 36) / 2), 300, 36
    local sunrise, sunset = parseISO(day.sunrise[1]), parseISO(day.sunset[1])
    local diff = c.apparent_temperature - c.temperature_2m
    local tiles = {
        self:tile(I.thermometer, "FEELS LIKE", deg(c.apparent_temperature),
            math.abs(diff) < 2 and "Similar to actual" or (diff < 0 and "Colder than actual" or "Warmer than actual"), tw, th),
        self:tile(I.humidity, "HUMIDITY", math.floor(c.relative_humidity_2m + 0.5) .. "%", nil, tw, th),
        self:tile(I.wind, "WIND", tostring(math.floor(c.wind_speed_10m + 0.5)),
            units .. "  " .. W.compass(c.wind_direction_10m), tw, th),
        self:tile(I.uv, "UV INDEX", tostring(math.floor(day.uv_index_max[1] + 0.5)), W.uvLevel(day.uv_index_max[1]), tw, th),
        self:tile(I.sunrise, "SUNRISE", self:hhmm(sunrise), nil, tw, th),
        self:tile(I.sunset, "SUNSET", self:hhmm(sunset), nil, tw, th),
    }
    for r = 0, 2 do
        table.insert(g, HorizontalGroup:new{ tiles[r * 2 + 1], hspan(gap), tiles[r * 2 + 2] })
        if r < 2 then table.insert(g, vspan(gap)) end
    end
    return g
end

function Dashboard:rebuild()
    local builders = { self.pageNow, self.pageHourly, self.pageDaily, self.pageDetails }
    local ok, content = pcall(builders[self.page], self)
    if not ok then
        logger.err("deskdash: page build failed", content)
        content = VerticalGroup:new{ align = "center", vspan(500), txt("Something went wrong", BOLD, 56),
            txt(tostring(content):sub(1, 60), SANS, 28, GRAY, self.W - 80) }
    end
    self[1] = FrameContainer:new{
        width = self.W, height = self.H, background = WHITE, bordersize = 0, padding = 0, margin = 0,
        OverlapGroup:new{ dimen = Geom:new{ w = self.W, h = self.H },
            CenterContainer:new{ dimen = Geom:new{ w = self.W, h = self.H - 120 }, ignore_if_over = "height",
                overlap_offset = { 0, 0 }, VerticalGroup:new{ align = "center", content } },
            CenterContainer:new{ dimen = Geom:new{ w = self.W, h = 40 }, overlap_offset = { 0, self.H - 90 }, self:dots() },
        },
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
    self.minutes = self.minutes + 1
    if self.page ~= 1 and os.time() - self.last_touch >= IDLE_RETURN then self.page = 1 end
    if os.time() - (self.fetched_at or 0) >= WEATHER_EVERY then self:refreshWeather() end
    self:redraw(self.minutes % FLASH_EVERY == 0 and "full" or "ui")
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
    local secs = 60 - tonumber(os.date("%S"))
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
    if early > 2 then
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
    local dir = ges.direction
    if dir == "west" or dir == "east" then
        self.page = (self.page - 1 + (dir == "west" and 1 or -1)) % PAGES + 1
        self:redraw("partial")
    end
    return true
end

function Dashboard:onHold()
    self:onClose()
    return true
end

function Dashboard:onTap()
    self.last_touch = os.time()
    self:refreshWeather()
    self:redraw("full")
    return true
end

function Dashboard:onClose()
    UIManager:unschedule(self._tick)
    UIManager:unschedule(self._poll)
    UIManager:unschedule(self._sleep)
    self:restore()
    self:keepAwake(false)
    UIManager:close(self, "full")
    return true
end

function Dashboard:onCloseWidget()
    UIManager:unschedule(self._tick)
    UIManager:unschedule(self._poll)
    UIManager:unschedule(self._sleep)
end

return Dashboard

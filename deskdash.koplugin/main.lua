--[[--
Desk dashboard plugin: turns KOReader into a wall clock + weather display.

Menu: Tools > Desk dashboard. Opens automatically when KOReader starts (toggle in the menu).
]]
local Dispatcher = require("dispatcher")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local _ = require("gettext")

-- Plugin-local modules must be required while the plugin is being loaded.
local Dashboard = require("deskdash_dashboard")
local Weather = require("deskdash_weather")

local DeskDash = WidgetContainer:extend{
    name = "deskdash",
    is_doc_only = false,
}

local function setting(key, default)
    local v = G_reader_settings:readSetting("deskdash_" .. key)
    if v == nil then return default end
    return v
end

function DeskDash:init()
    Dispatcher:registerAction("deskdash_show", {
        category = "none", event = "ShowDeskDash", title = _("Desk dashboard"), general = true,
    })
    self.ui.menu:registerToMainMenu(self)
    -- Auto-open once per KOReader run, on top of whatever KOReader opened (file browser or last book).
    if setting("autostart", true) and not DeskDash._autostarted then
        DeskDash._autostarted = true
        UIManager:scheduleIn(1, function() self:onShowDeskDash() end)
    end
end

function DeskDash:addToMainMenu(menu_items)
    menu_items.deskdash = {
        text = _("Desk dashboard"),
        sorting_hint = "tools",
        sub_item_table = {
            { text = _("Open dashboard"), callback = function() self:onShowDeskDash() end },
            {
                text = _("Open when KOReader starts"),
                checked_func = function() return setting("autostart", true) end,
                callback = function() G_reader_settings:saveSetting("deskdash_autostart", not setting("autostart", true)) end,
            },
            {
                text = _("24-hour clock"),
                checked_func = function() return setting("clock_24h", true) end,
                callback = function() G_reader_settings:saveSetting("deskdash_clock_24h", not setting("clock_24h", true)) end,
            },
            {
                text = _("Fahrenheit / mph"),
                checked_func = function() return setting("units", "metric") == "imperial" end,
                callback = function()
                    G_reader_settings:saveSetting("deskdash_units", setting("units", "metric") == "imperial" and "metric" or "imperial")
                end,
            },
        },
    }
end

function DeskDash:onShowDeskDash()
    if self.dash then return true end
    self.dash = Dashboard:new{
        weather = Weather,
        settings = {
            units = setting("units", "metric"),
            clock_24h = setting("clock_24h", true),
            lat = setting("lat", nil), lon = setting("lon", nil), city = setting("city", nil),
        },
    }
    local orig_close = self.dash.onClose
    self.dash.onClose = function(d) orig_close(d); self.dash = nil; return true end
    UIManager:show(self.dash, "full")
    return true
end

return DeskDash

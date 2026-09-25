--[[--
Bigme HiBreak front-light control plugin.

Drives the TI LM3630A dual-string LED driver through direct sysfs I/O
(zero process fork latency) with automatic fallback to a root helper
script installed on demand to /data/local/tmp/bigme_light.sh.

The helper is embedded in this file (base64) and installed by the plugin
itself through Magisk, so no PC or manual adb push is required. The user
only needs to grant root (superuser) once when Magisk prompts.

Runtime features:
  - Direct sysfs I/O (chmod 666 on init) for <1ms response on gestures
  - Magisk root fallback when direct sysfs access is restricted
  - Power management: automatically turns off LEDs on sleep and restores on wake
  - Touch presets (Day, Reading, Night, Off) and dual steppers
  - Pre-warms `su` on init so root fallback isn't slow

Hardware (Bigme HiBreak / B6):
  /sys/bus/i2c/devices/2-0036/lm3630a_cold_light   (0-255)
  /sys/bus/i2c/devices/2-0036/lm3630a_warm_light   (0-255)

@module koplugin.bigmelight
--]]--

local ButtonDialog = require("ui/widget/buttondialog")
local DataStorage = require("datastorage")
local Dispatcher = require("dispatcher")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local LuaSettings = require("luasettings")
local Notification = require("ui/widget/notification")
local SpinWidget = require("ui/widget/spinwidget")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local ffiUtil = require("ffi/util")
local logger = require("logger")
local _ = require("gettext")
local T = ffiUtil.template

local HELPER_PATH = "/data/local/tmp/bigme_light.sh"
local DEV_PATH = "/sys/bus/i2c/devices/2-0036"
local COLD_NODE = DEV_PATH .. "/lm3630a_cold_light"
local WARM_NODE = DEV_PATH .. "/lm3630a_warm_light"
local MAX_VAL = 255

-- Built-in presets; users can edit these and add their own (persisted to settings)
local DEFAULT_PRESETS = {
    { name = _("☀️ Daytime"), cold = 80, warm = 0 },
    { name = _("📖 Reading"), cold = 50, warm = 60 },
    { name = _("🌙 Bedtime"), cold = 0, warm = 50 },
}

-- Embedded helper script (bigme_light.sh). Kept in sync with helper/bigme_light.sh.
local HELPER_B64 = "IyEvc3lzdGVtL2Jpbi9zaAojIEJpZ21lIEhpQnJlYWsgLyBCNiBmcm9udC1saWdodCBoZWxwZXIgKFRJIExNMzYzMEEpLgojCiMgVGhpcyBmaWxlIGlzIGEgcmVmZXJlbmNlIGNvcHkuIFRoZSBwbHVnaW4gZW1iZWRzIGl0IChiYXNlNjQpIGluIG1haW4ubHVhIGFuZAojIGluc3RhbGxzIGl0IHRvIC9kYXRhL2xvY2FsL3RtcC9iaWdtZV9saWdodC5zaCBvbiBkZW1hbmQsIHNvIHVzZXJzIG5ldmVyIG5lZWQKIyB0byBwbGFjZSBpdCBtYW51YWxseS4KIwojIFVzYWdlOgojICAgYmlnbWVfbGlnaHQuc2ggcmVhZF9jb2xkIHwgcmVhZF93YXJtCiMgICBiaWdtZV9saWdodC5zaCBzZXRfY29sZCA8MC0yNTU+IHwgc2V0X3dhcm0gPDAtMjU1PgojICAgYmlnbWVfbGlnaHQuc2ggb2ZmCkRFVj0vc3lzL2J1cy9pMmMvZGV2aWNlcy8yLTAwMzYKY2FzZSAiJDEiIGluCiAgcmVhZF9jb2xkKSAgY2F0ICIkREVWL2xtMzYzMGFfY29sZF9saWdodCIgOzsKICByZWFkX3dhcm0pICBjYXQgIiRERVYvbG0zNjMwYV93YXJtX2xpZ2h0IiA7OwogIHNldF9jb2xkKSAgIGVjaG8gIiQyIiA+ICIkREVWL2xtMzYzMGFfY29sZF9saWdodCIgOzsKICBzZXRfd2FybSkgICBlY2hvICIkMiIgPiAiJERFVi9sbTM2MzBhX3dhcm1fbGlnaHQiIDs7CiAgc2V0X2JvdGgpICAgZWNobyAiJDIiID4gIiRERVYvbG0zNjMwYV9jb2xkX2xpZ2h0IgogICAgICAgICAgICAgIGVjaG8gIiQzIiA+ICIkREVWL2xtMzYzMGFfd2FybV9saWdodCIgOzsKICBvZmYpICAgICAgICBlY2hvIDAgPiAiJERFVi9sbTM2MzBhX2NvbGRfbGlnaHQiCiAgICAgICAgICAgICAgZWNobyAwID4gIiRERVYvbG0zNjMwYV93YXJtX2xpZ2h0IiA7OwogIGluaXRfcGVybXMpIGNobW9kIDY2NiAiJERFVi9sbTM2MzBhX2NvbGRfbGlnaHQiICIkREVWL2xtMzYzMGFfd2FybV9saWdodCIgMj4vZGV2L251bGwgOzsKICAqKSAgICAgICAgICBlY2hvICJ1bmtub3duIiA7Owplc2FjCg=="

-- Direct sysfs I/O flag
local direct_io_ok = false

local function try_direct_write(path, val)
    local f = io.open(path, "w")
    if f then
        f:write(tostring(val))
        f:close()
        return true
    end
    return false
end

local function try_direct_read(path)
    local f = io.open(path, "r")
    if f then
        local val = f:read("*number")
        f:close()
        return val
    end
    return nil
end

-- Run a command through root and return trimmed stdout (or nil on failure).
local function su_line(cmd)
    local handle = io.popen(string.format("su -c \"%s\" 2>/dev/null", cmd))
    if not handle then return nil end
    local out = handle:read("*l")
    handle:close()
    return out
end

-- Warm up su daemon so subsequent calls are fast (~50ms vs ~300ms)
local su_warm = false
local function warm_su()
    if su_warm then return end
    os.execute("su -c 'echo 1' >/dev/null 2>&1")
    su_warm = true
end

local function has_root()
    return su_line("echo 1") == "1"
end

local function driver_present()
    return su_line(string.format("test -e %s && echo yes || echo no", COLD_NODE)) == "yes"
end

local function helper_installed()
    return su_line(string.format("test -x %s && echo yes || echo no", HELPER_PATH)) == "yes"
end

-- Configure permissions for zero-latency direct sysfs I/O
local function init_direct_io()
    os.execute(string.format("su -c 'chmod 666 %s %s && (magiskpolicy --live \"allow untrusted_app_all sysfs file { read write open getattr }\" 2>/dev/null || magiskpolicy --live \"allow untrusted_app_30 sysfs file { read write open getattr }\" 2>/dev/null || supolicy --live \"allow untrusted_app sysfs file { read write open getattr }\" 2>/dev/null)' 2>/dev/null", COLD_NODE, WARM_NODE))
    local test_val = try_direct_read(COLD_NODE)
    if test_val ~= nil and try_direct_write(COLD_NODE, test_val) then
        direct_io_ok = true
        logger.info("BigmeLight: direct sysfs I/O active (zero latency)")
    else
        direct_io_ok = false
        logger.info("BigmeLight: direct sysfs I/O unavailable, using root helper")
    end
    return direct_io_ok
end

-- Install or repair the embedded helper script through root.
local function install_helper()
    local cmd = string.format(
        "echo %s | base64 -d > %s && chmod 755 %s && chmod 666 %s %s 2>/dev/null",
        HELPER_B64, HELPER_PATH, HELPER_PATH, COLD_NODE, WARM_NODE)
    os.execute(string.format("su -c '%s'", cmd))
    init_direct_io()
    return helper_installed()
end

-- Write to driver (prefers direct I/O for zero latency, falls back to su)
local function set_cold(v)
    if direct_io_ok and try_direct_write(COLD_NODE, v) then
        return
    end
    os.execute(string.format("su -c '%s set_cold %d'", HELPER_PATH, v))
end

local function set_warm(v)
    if direct_io_ok and try_direct_write(WARM_NODE, v) then
        return
    end
    os.execute(string.format("su -c '%s set_warm %d'", HELPER_PATH, v))
end

local function set_both(c, w)
    if direct_io_ok and try_direct_write(COLD_NODE, c) and try_direct_write(WARM_NODE, w) then
        return
    end
    os.execute(string.format("su -c '%s set_both %d %d'", HELPER_PATH, c, w))
end

-- Read from driver (direct I/O or su read)
local function read_val(what)
    local node = (what == "cold") and COLD_NODE or WARM_NODE
    if direct_io_ok then
        local val = try_direct_read(node)
        if val ~= nil then return val end
    end
    local handle = io.popen(string.format("su -c '%s read_%s'", HELPER_PATH, what))
    if not handle then return nil end
    local result = handle:read("*number")
    handle:close()
    return result
end

-- Plugin class
local BigmeLight = WidgetContainer:extend{
    name = "bigmelight",
    settings_file = DataStorage:getSettingsDir() .. "/bigmelight.lua",
    settings = nil,
    current_cold = 0,
    current_warm = 0,
    gesture_step = 10,
    turn_off_on_suspend = true,
    _initialized = false,
    _suspended_cold = nil,
    _suspended_warm = nil,
    root_ok = false,
    driver_ok = false,
    helper_ok = false,
}

function BigmeLight:init()
    self.settings = LuaSettings:open(self.settings_file)
    self.gesture_step = self.settings:readSetting("gesture_step") or 10
    local suspend_setting = self.settings:readSetting("turn_off_on_suspend")
    if suspend_setting ~= nil then
        self.turn_off_on_suspend = suspend_setting
    else
        self.turn_off_on_suspend = true
    end

    -- User presets; seeded with the built-ins on first run
    self.presets = self.settings:readSetting("presets")
    if not self.presets then
        self.presets = {}
        for _, p in ipairs(DEFAULT_PRESETS) do
            table.insert(self.presets, { name = p.name, cold = p.cold, warm = p.warm })
        end
        self.settings:saveSetting("presets", self.presets)
        self.settings:flush()
    end

    self:onDispatcherRegisterActions()
    self.ui.menu:registerToMainMenu(self)

    -- Defer hardware access to avoid blocking KOReader init
    UIManager:scheduleIn(0.5, function() self:_postInit() end)
end

function BigmeLight:_postInit()
    warm_su()

    self.root_ok = has_root()
    if not self.root_ok then
        logger.warn("BigmeLight: root not available")
        self:_notify(_("Bigme Light: root required (grant Magisk superuser)"))
        return
    end

    self.driver_ok = driver_present()
    if not self.driver_ok then
        logger.warn("BigmeLight: LM3630A driver not found")
        self:_notify(_("Bigme Light: LM3630A light driver not found"))
        return
    end

    self.helper_ok = helper_installed()
    if not self.helper_ok then
        self.helper_ok = install_helper()
        if self.helper_ok then
            self:_notify(_("Bigme Light: helper installed"))
        else
            logger.warn("BigmeLight: helper install failed")
            self:_notify(_("Bigme Light: helper install failed"))
            return
        end
    end

    -- Try direct sysfs I/O optimization
    init_direct_io()

    -- Read current hardware state
    self.current_cold = read_val("cold") or 0
    self.current_warm = read_val("warm") or 0
    self._initialized = true
    logger.dbg("BigmeLight: ready, cold=", self.current_cold, "warm=", self.current_warm, "direct_io=", direct_io_ok)

    -- Hook KOReader Device.powerd so built-in swipe gestures and frontlight menu sliders control LM3630A directly
    local Device = require("device")
    if Device and Device.powerd then
        local powerd = Device.powerd
        Device.hasNaturalLight = function() return true end

        powerd.frontlightIntensityHW = function(_)
            return math.floor((self.current_cold / MAX_VAL) * 100)
        end
        powerd.setIntensityHW = function(_, intensity)
            local cold_val = math.floor((intensity / 100) * MAX_VAL)
            self.current_cold = cold_val
            set_cold(cold_val)
        end
        powerd.frontlightWarmthHW = function(_)
            return math.floor((self.current_warm / MAX_VAL) * 100)
        end
        powerd.setWarmthHW = function(_, warmth)
            local warm_val = math.floor((warmth / 100) * MAX_VAL)
            self.current_warm = warm_val
            set_warm(warm_val)
        end
        powerd.turnOffFrontlightHW = function(_)
            set_both(0, 0)
        end
        powerd.turnOnFrontlightHW = function(_)
            set_both(self.current_cold, self.current_warm)
        end
    end
end

function BigmeLight:_ensureReady()
    if not self.root_ok then
        self:_notify(_("Bigme Light: root required (grant Magisk superuser)"))
        return false
    end
    if not self.driver_ok then
        self:_notify(_("Bigme Light: LM3630A light driver not found"))
        return false
    end
    if not self._initialized then
        self:_notify(_("Bigme Light: still initializing..."))
        return false
    end
    return true
end

-- --- Power Management (Sleep / Wake) ---

function BigmeLight:onSuspend()
    if not self.turn_off_on_suspend then return end
    self._suspended_cold = self.current_cold
    self._suspended_warm = self.current_warm
    if self.settings then
        self.settings:saveSetting("last_active_cold", self.current_cold)
        self.settings:saveSetting("last_active_warm", self.current_warm)
        self.settings:flush()
    end
    if (self.current_cold and self.current_cold > 0) or (self.current_warm and self.current_warm > 0) then
        set_both(0, 0)
        logger.dbg("BigmeLight: device suspended; turned off LEDs")
    end
end

function BigmeLight:onResume()
    if not self.turn_off_on_suspend then return end
    local cold = self._suspended_cold or (self.settings and self.settings:readSetting("last_active_cold"))
    local warm = self._suspended_warm or (self.settings and self.settings:readSetting("last_active_warm"))
    if cold and warm and (cold > 0 or warm > 0) then
        set_both(cold, warm)
        self.current_cold = cold
        self.current_warm = warm
        logger.dbg("BigmeLight: device resumed; restored cold=", self.current_cold, "warm=", self.current_warm)
    end
    self._suspended_cold = nil
    self._suspended_warm = nil
end

-- --- Dispatcher Actions ---

function BigmeLight:onDispatcherRegisterActions()
    Dispatcher:registerAction("bigme_cold_up",
        {category="incrementalnumber", min=1, max=MAX_VAL,
         event="BigmeColdUp", title=_("Bigme: ❄️ increase cool light"), screen=true})
    Dispatcher:registerAction("bigme_cold_down",
        {category="incrementalnumber", min=1, max=MAX_VAL,
         event="BigmeColdDown", title=_("Bigme: ❄️ decrease cool light"), screen=true})
    Dispatcher:registerAction("bigme_warm_up",
        {category="incrementalnumber", min=1, max=MAX_VAL,
         event="BigmeWarmUp", title=_("Bigme: 🔥 increase warm light"), screen=true})
    Dispatcher:registerAction("bigme_warm_down",
        {category="incrementalnumber", min=1, max=MAX_VAL,
         event="BigmeWarmDown", title=_("Bigme: 🔥 decrease warm light"), screen=true})
    Dispatcher:registerAction("bigme_light_dialog",
        {category="none", event="BigmeShowLightDialog",
         title=_("Bigme: light control dialog"), screen=true})
    Dispatcher:registerAction("bigme_light_off",
        {category="none", event="BigmeLightOff",
         title=_("Bigme: turn off all lights"), screen=true})
    Dispatcher:registerAction("bigme_light_toggle",
        {category="none", event="BigmeLightToggle",
         title=_("Bigme: toggle front light"), screen=true})
    Dispatcher:registerAction("bigme_preset_day",
        {category="none", event="BigmePresetDay",
         title=_("Bigme: preset Daytime (cold 80, warm 0)"), screen=true})
    Dispatcher:registerAction("bigme_preset_read",
        {category="none", event="BigmePresetRead",
         title=_("Bigme: preset Reading (cold 50, warm 60)"), screen=true})
    Dispatcher:registerAction("bigme_preset_night",
        {category="none", event="BigmePresetNight",
         title=_("Bigme: preset Bedtime (cold 0, warm 50)"), screen=true})
    Dispatcher:registerAction("bigme_eink_center",
        {category="none", event="BigmeEinkCenter",
         title=_("Bigme: EinkCenter panel"), screen=true})
end

-- --- Event Handlers ---

function BigmeLight:onBigmeColdUp(arg)
    if not self:_ensureReady() then return true end
    local step = self.gesture_step
    if type(arg) == "number" then step = arg
    elseif type(arg) == "table" and type(arg[1]) == "number" then step = arg[1] end
    self.current_cold = math.min(MAX_VAL, self.current_cold + step)
    set_cold(self.current_cold)
    local pct = math.floor((self.current_cold / MAX_VAL) * 100 + 0.5)
    self:_notify_debounced(T(_("❄️ Cool: %1/255 (%2%)"), self.current_cold, pct))
    return true
end

function BigmeLight:onBigmeColdDown(arg)
    if not self:_ensureReady() then return true end
    local step = self.gesture_step
    if type(arg) == "number" then step = arg
    elseif type(arg) == "table" and type(arg[1]) == "number" then step = arg[1] end
    self.current_cold = math.max(0, self.current_cold - step)
    set_cold(self.current_cold)
    local pct = math.floor((self.current_cold / MAX_VAL) * 100 + 0.5)
    self:_notify_debounced(T(_("❄️ Cool: %1/255 (%2%)"), self.current_cold, pct))
    return true
end

function BigmeLight:onBigmeWarmUp(arg)
    if not self:_ensureReady() then return true end
    local step = self.gesture_step
    if type(arg) == "number" then step = arg
    elseif type(arg) == "table" and type(arg[1]) == "number" then step = arg[1] end
    self.current_warm = math.min(MAX_VAL, self.current_warm + step)
    set_warm(self.current_warm)
    local pct = math.floor((self.current_warm / MAX_VAL) * 100 + 0.5)
    self:_notify_debounced(T(_("🔥 Warm: %1/255 (%2%)"), self.current_warm, pct))
    return true
end

function BigmeLight:onBigmeWarmDown(arg)
    if not self:_ensureReady() then return true end
    local step = self.gesture_step
    if type(arg) == "number" then step = arg
    elseif type(arg) == "table" and type(arg[1]) == "number" then step = arg[1] end
    self.current_warm = math.max(0, self.current_warm - step)
    set_warm(self.current_warm)
    local pct = math.floor((self.current_warm / MAX_VAL) * 100 + 0.5)
    self:_notify_debounced(T(_("🔥 Warm: %1/255 (%2%)"), self.current_warm, pct))
    return true
end

function BigmeLight:onBigmeLightOff()
    if not self:_ensureReady() then return true end
    set_both(0, 0)
    self.current_cold = 0
    self.current_warm = 0
    self:_notify(_("Lights off"))
    return true
end

function BigmeLight:onBigmeLightToggle()
    if not self:_ensureReady() then return true end
    self.current_cold = read_val("cold") or 0
    self.current_warm = read_val("warm") or 0

    if self.current_cold == 0 and self.current_warm == 0 then
        local saved_cold = self.settings:readSetting("last_cold") or 70
        local saved_warm = self.settings:readSetting("last_warm") or 60
        set_both(saved_cold, saved_warm)
        self.current_cold = saved_cold
        self.current_warm = saved_warm
        self:_notify(T(_("Lights on: ❄️%1 🔥%2"), saved_cold, saved_warm))
    else
        self.settings:saveSetting("last_cold", self.current_cold)
        self.settings:saveSetting("last_warm", self.current_warm)
        self.settings:flush()
        set_both(0, 0)
        self.current_cold = 0
        self.current_warm = 0
        self:_notify(_("Lights off"))
    end
    return true
end

function BigmeLight:applyPreset(c, w, name)
    if not self:_ensureReady() then return end
    self.current_cold = c
    self.current_warm = w
    set_both(c, w)
    self:_notify(T(_("%1: ❄️%2 🔥%3"), name, c, w))
end

function BigmeLight:onBigmePresetDay()
    self:applyPreset(80, 0, _("Daytime"))
    return true
end

function BigmeLight:onBigmePresetRead()
    self:applyPreset(50, 60, _("Reading"))
    return true
end

function BigmeLight:onBigmePresetNight()
    self:applyPreset(0, 50, _("Bedtime"))
    return true
end

--- Custom preset management (add / edit / delete, persisted to settings)

function BigmeLight:_savePresets()
    self.settings:saveSetting("presets", self.presets)
    self.settings:flush()
end

-- Apply the preset at index i (bounds-checked)
function BigmeLight:applyPresetAt(i)
    local p = self.presets[i]
    if not p then return end
    self:applyPreset(p.cold, p.warm, p.name)
end

function BigmeLight:deletePreset(i)
    local p = self.presets[i]
    if not p then return end
    table.remove(self.presets, i)
    self:_savePresets()
    self:_notify(T(_("Preset removed: %1"), p.name))
end

-- Create or update a preset; nil i means append
function BigmeLight:savePreset(i, name, cold, warm)
    local entry = { name = name, cold = cold, warm = warm }
    if i then
        self.presets[i] = entry
    else
        table.insert(self.presets, entry)
    end
    self:_savePresets()
    self:_notify(T(_("Preset saved: %1"), name))
end

function BigmeLight:onBigmeEinkCenter()
    warm_su()
    os.execute("su -c 'content call --uri content://com.xrz.SettingProvider --method setting_einkcenter' >/dev/null 2>&1")
    return true
end

-- --- UI Dialogs ---

function BigmeLight:onBigmeShowLightDialog()
    if not self:_ensureReady() then return true end

    self.current_cold = read_val("cold") or self.current_cold
    self.current_warm = read_val("warm") or self.current_warm

    local dialog
    local function get_title()
        local c_pct = math.floor((self.current_cold / MAX_VAL) * 100 + 0.5)
        local w_pct = math.floor((self.current_warm / MAX_VAL) * 100 + 0.5)
        return T(_("❄️ Cool: %1/255 (%2%)  |  🔥 Warm: %3/255 (%4%)"),
            self.current_cold, c_pct, self.current_warm, w_pct)
    end

    local function refresh_title()
        if dialog and dialog.setTitle then
            dialog:setTitle(get_title())
        end
    end

    local step = self.gesture_step
    dialog = ButtonDialog:new{
        title = get_title(),
        buttons = {
            -- Row 1: Cool Coarse Steps
            {
                { text = T(_("❄️ Cool -%1"), step), callback = function()
                    self.current_cold = math.max(0, self.current_cold - step)
                    set_cold(self.current_cold)
                    refresh_title()
                    local pct = math.floor((self.current_cold / MAX_VAL) * 100 + 0.5)
                    self:_notify_debounced(T(_("❄️ Cool: %1/255 (%2%)"), self.current_cold, pct))
                end },
                { text = T(_("❄️ Cool +%1"), step), callback = function()
                    self.current_cold = math.min(MAX_VAL, self.current_cold + step)
                    set_cold(self.current_cold)
                    refresh_title()
                    local pct = math.floor((self.current_cold / MAX_VAL) * 100 + 0.5)
                    self:_notify_debounced(T(_("❄️ Cool: %1/255 (%2%)"), self.current_cold, pct))
                end },
            },
            -- Row 2: Cool Fine Steps
            {
                { text = _("❄️ Cool -2 (Fine)"), callback = function()
                    self.current_cold = math.max(0, self.current_cold - 2)
                    set_cold(self.current_cold)
                    refresh_title()
                    local pct = math.floor((self.current_cold / MAX_VAL) * 100 + 0.5)
                    self:_notify_debounced(T(_("❄️ Cool: %1/255 (%2%)"), self.current_cold, pct))
                end },
                { text = _("❄️ Cool +2 (Fine)"), callback = function()
                    self.current_cold = math.min(MAX_VAL, self.current_cold + 2)
                    set_cold(self.current_cold)
                    refresh_title()
                    local pct = math.floor((self.current_cold / MAX_VAL) * 100 + 0.5)
                    self:_notify_debounced(T(_("❄️ Cool: %1/255 (%2%)"), self.current_cold, pct))
                end },
            },
            -- Row 3: Warm Coarse Steps
            {
                { text = T(_("🔥 Warm -%1"), step), callback = function()
                    self.current_warm = math.max(0, self.current_warm - step)
                    set_warm(self.current_warm)
                    refresh_title()
                    local pct = math.floor((self.current_warm / MAX_VAL) * 100 + 0.5)
                    self:_notify_debounced(T(_("🔥 Warm: %1/255 (%2%)"), self.current_warm, pct))
                end },
                { text = T(_("🔥 Warm +%1"), step), callback = function()
                    self.current_warm = math.min(MAX_VAL, self.current_warm + step)
                    set_warm(self.current_warm)
                    refresh_title()
                    local pct = math.floor((self.current_warm / MAX_VAL) * 100 + 0.5)
                    self:_notify_debounced(T(_("🔥 Warm: %1/255 (%2%)"), self.current_warm, pct))
                end },
            },
            -- Row 4: Warm Fine Steps
            {
                { text = _("🔥 Warm -2 (Fine)"), callback = function()
                    self.current_warm = math.max(0, self.current_warm - 2)
                    set_warm(self.current_warm)
                    refresh_title()
                    local pct = math.floor((self.current_warm / MAX_VAL) * 100 + 0.5)
                    self:_notify_debounced(T(_("🔥 Warm: %1/255 (%2%)"), self.current_warm, pct))
                end },
                { text = _("🔥 Warm +2 (Fine)"), callback = function()
                    self.current_warm = math.min(MAX_VAL, self.current_warm + 2)
                    set_warm(self.current_warm)
                    refresh_title()
                    local pct = math.floor((self.current_warm / MAX_VAL) * 100 + 0.5)
                    self:_notify_debounced(T(_("🔥 Warm: %1/255 (%2%)"), self.current_warm, pct))
                end },
            },
            -- Row 5: Presets (Day / Read)
            {
                { text = _("☀️ Daytime (80 / 0)"), callback = function()
                    self:applyPreset(80, 0, _("Daytime"))
                    refresh_title()
                end },
                { text = _("📖 Reading (50 / 60)"), callback = function()
                    self:applyPreset(50, 60, _("Reading"))
                    refresh_title()
                end },
            },
            -- Row 6: Presets (Bedtime / Off)
            {
                { text = _("🌙 Bedtime (0 / 50)"), callback = function()
                    self:applyPreset(0, 50, _("Bedtime"))
                    refresh_title()
                end },
                { text = _("🌑 All Off"), callback = function()
                    self:onBigmeLightOff()
                    refresh_title()
                end },
            },
            -- Row 7: Precision Spinners
            {
                { text = _("❄️ Dial Cool Spinner..."), callback = function()
                    UIManager:close(dialog)
                    self:showSpinDialog("cold")
                end },
                { text = _("🔥 Dial Warm Spinner..."), callback = function()
                    UIManager:close(dialog)
                    self:showSpinDialog("warm")
                end },
            },
            -- Row 8: Exact Set & Save
            {
                { text = _("✏️ Set Exact Number..."), callback = function()
                    UIManager:close(dialog)
                    self:showExactSelectionDialog()
                end },
                { text = _("⭐ Save Preset..."), callback = function()
                    UIManager:close(dialog)
                    self:showSavePresetDialog()
                end },
            },
            -- Row 9: Close
            {
                { text = _("Close"), is_enter_default = true, callback = function()
                    UIManager:close(dialog)
                end },
            },
        },
    }
    UIManager:show(dialog)
    return true
end

function BigmeLight:showSavePresetDialog()
    local dialog
    dialog = InputDialog:new{
        title = _("Save Preset"),
        input = "",
        input_hint = _("Preset name"),
        description = T(_("Saves current values: ❄️ %1 / 🔥 %2"), self.current_cold, self.current_warm),
        buttons = {
            {
                { text = _("Cancel"), callback = function()
                    UIManager:close(dialog)
                end },
                { text = _("Save"), is_enter_default = true, callback = function()
                    local name = dialog:getInputText()
                    if name and name ~= "" then
                        UIManager:close(dialog)
                        self:savePreset(nil, name, self.current_cold, self.current_warm)
                    else
                        UIManager:show(InfoMessage:new{
                            text = _("Enter a name for the preset"),
                            timeout = 2,
                        })
                    end
                end },
            },
        },
    }
    UIManager:show(dialog)
end

function BigmeLight:showSpinDialog(channel)
    local is_cold = (channel == "cold")
    local cur_val = is_cold and self.current_cold or self.current_warm
    local title = is_cold and _("❄️ Cool Light Dial (White)") or _("🔥 Warm Light Dial (Amber)")
    local info = is_cold and _("Adjust White LED channel level (0-255)") or _("Adjust Warm LED channel level (0-255)")

    local spin = SpinWidget:new{
        title_text = title,
        info_text = info,
        value = cur_val,
        value_min = 0,
        value_max = MAX_VAL,
        value_step = 1,
        value_hold_step = 5,
        ok_text = _("Set"),
        default_value = cur_val,
        callback = function(spin)
            if is_cold then
                self.current_cold = spin.value
                set_cold(spin.value)
            else
                self.current_warm = spin.value
                set_warm(spin.value)
            end
            self:_notify_debounced(T(_("❄️%1 🔥%2"), self.current_cold, self.current_warm))
        end,
    }
    UIManager:show(spin)
end

function BigmeLight:showExactSelectionDialog()
    local select_dialog
    select_dialog = ButtonDialog:new{
        title = _("Set Exact Channel Value"),
        buttons = {
            {
                { text = T(_("❄️ Cool (Current: %1)"), self.current_cold), callback = function()
                    UIManager:close(select_dialog)
                    self:showExactInputDialog("cold")
                end },
                { text = T(_("🔥 Warm (Current: %1)"), self.current_warm), callback = function()
                    UIManager:close(select_dialog)
                    self:showExactInputDialog("warm")
                end },
            },
            {
                { text = _("Cancel"), is_enter_default = true, callback = function()
                    UIManager:close(select_dialog)
                end },
            }
        }
    }
    UIManager:show(select_dialog)
end

function BigmeLight:showExactInputDialog(channel)
    local is_cold = (channel == "cold")
    local cur_val = is_cold and self.current_cold or self.current_warm
    local title = is_cold and _("Set Exact ❄️ Cool Light (0-255)") or _("Set Exact 🔥 Warm Light (0-255)")
    local hint = is_cold and _("❄️ Cool (0-255)") or _("🔥 Warm (0-255)")

    local dialog
    dialog = InputDialog:new{
        title = title,
        input = tostring(cur_val),
        input_hint = hint,
        description = is_cold and T(_("Current 🔥 Warm: %1/255"), self.current_warm) or T(_("Current ❄️ Cool: %1/255"), self.current_cold),
        buttons = {
            {
                { text = _("Cancel"), callback = function()
                    UIManager:close(dialog)
                end },
                { text = _("Set"), is_enter_default = true, callback = function()
                    local val = tonumber(dialog:getInputText())
                    if val and val >= 0 and val <= MAX_VAL then
                        if is_cold then
                            self.current_cold = val
                            set_cold(val)
                        else
                            self.current_warm = val
                            set_warm(val)
                        end
                        UIManager:close(dialog)
                        self:_notify(T(_("❄️%1 🔥%2"), self.current_cold, self.current_warm))
                    else
                        UIManager:show(InfoMessage:new{
                            text = _("Enter a number between 0 and 255"),
                            timeout = 2,
                        })
                    end
                end },
            },
        },
    }
    UIManager:show(dialog)
end

-- --- Setup and Health Checks ---

function BigmeLight:checkSetup()
    local root = has_root()
    local driver = root and driver_present()
    local helper = driver and helper_installed()
    local direct = driver and init_direct_io()

    self.root_ok = root
    self.driver_ok = driver
    self.helper_ok = helper

    local lines = {
        T(_("Root (Magisk): %1"), root and _("OK") or _("MISSING")),
        T(_("LM3630A driver: %1"), driver and _("OK") or _("MISSING")),
        T(_("Helper script: %1"), helper and _("OK") or _("MISSING")),
        T(_("Direct sysfs I/O: %1"), direct and _("ACTIVE (fastest)") or _("FALLBACK (via root)")),
    }
    if not root then
        lines[#lines + 1] = _("\nGrant superuser to KOReader in Magisk, then run Install / update helper.")
    elseif not driver then
        lines[#lines + 1] = _("\nThis device does not expose the Bigme LM3630A front-light driver.")
    elseif not helper then
        lines[#lines + 1] = _("\nRun Install / update helper to install it.")
    else
        lines[#lines + 1] = T(_("\nStatus: ❄️%1 🔥%2"), self.current_cold, self.current_warm)
    end

    UIManager:show(InfoMessage:new{
        title = _("Bigme Light setup"),
        text = table.concat(lines, "\n"),
    })
end

function BigmeLight:installOrUpdateHelper()
    if not has_root() then
        self.root_ok = false
        UIManager:show(InfoMessage:new{
            title = _("Bigme Light setup"),
            text = _("Root required (Magisk).\n\nGrant superuser to KOReader in Magisk, then try again."),
        })
        return
    end
    self.root_ok = true

    if not driver_present() then
        self.driver_ok = false
        UIManager:show(InfoMessage:new{
            title = _("Bigme Light setup"),
            text = _("LM3630A light driver not found on this device."),
        })
        return
    end
    self.driver_ok = true

    local ok = install_helper()
    self.helper_ok = ok
    if ok then
        self.current_cold = read_val("cold") or 0
        self.current_warm = read_val("warm") or 0
        self._initialized = true
        UIManager:show(InfoMessage:new{
            title = _("Bigme Light setup"),
            text = T(_("Helper installed to:\n%1\nDirect I/O: %2\nStatus: ❄️%3 🔥%4"),
                HELPER_PATH, direct_io_ok and _("ACTIVE") or _("FALLBACK"), self.current_cold, self.current_warm),
        })
    else
        UIManager:show(InfoMessage:new{
            title = _("Bigme Light setup"),
            text = _("Helper install failed.\n\nCheck that Magisk granted root and try again."),
        })
    end
end

-- --- Menu ---

-- Build the dynamic "Quick presets" submenu from self.presets
function BigmeLight:buildPresetMenuItems()
    local items = {}
    for i, p in ipairs(self.presets) do
        local idx = i  -- capture for callbacks
        table.insert(items, {
            text = T(_("%1  (❄️ %2 / 🔥 %3)"), p.name, p.cold, p.warm),
            keep_menu_open = true,
            callback = function() self:applyPresetAt(idx) end,
            hold_callback = function()
                self:showEditPresetDialog(idx)
            end,
        })
    end
    table.insert(items, {
        text = _("＋ Add preset..."),
        keep_menu_open = true,
        callback = function() self:showSavePresetDialog() end,
    })
    return items
end

function BigmeLight:showEditPresetDialog(idx)
    local p = self.presets[idx]
    if not p then return end
    local dialog
    dialog = InputDialog:new{
        title = T(_("Edit preset: %1"), p.name),
        input = p.name,
        input_hint = _("Preset name"),
        description = T(_("Values: ❄️ %1 / 🔥 %2"), p.cold, p.warm),
        buttons = {
            {
                { text = _("Delete"), callback = function()
                    UIManager:close(dialog)
                    self:deletePreset(idx)
                end },
                { text = _("Apply values"), callback = function()
                    UIManager:close(dialog)
                    self:applyPresetAt(idx)
                end },
                { text = _("Save"), is_enter_default = true, callback = function()
                    local name = dialog:getInputText()
                    if name and name ~= "" then
                        UIManager:close(dialog)
                        self:savePreset(idx, name, p.cold, p.warm)
                    else
                        UIManager:show(InfoMessage:new{
                            text = _("Enter a name for the preset"),
                            timeout = 2,
                        })
                    end
                end },
            },
        },
    }
    UIManager:show(dialog)
end

function BigmeLight:addToMainMenu(menu_items)
    menu_items.bigmelight = {
        text = _("Bigme Light"),
        sub_item_table = {
            {
                text = _("Light control dialog"),
                keep_menu_open = true,
                callback = function() self:onBigmeShowLightDialog() end,
            },
            {
                text = _("Quick presets"),
                sub_item_table_func = function()
                    return self:buildPresetMenuItems()
                end,
            },
            {
                text = T(_("Step size: %1"), self.gesture_step),
                keep_menu_open = true,
                callback = function()
                    local spin = SpinWidget:new{
                        title_text = _("Gesture step size"),
                        info_text = _([[How much the light changes per swipe gesture (1-50).]]),
                        value = self.gesture_step,
                        value_min = 1,
                        value_max = 50,
                        value_step = 1,
                        value_hold_step = 5,
                        ok_text = _("Set"),
                        default_value = 10,
                        callback = function(spin)
                            self.gesture_step = spin.value
                            self.settings:saveSetting("gesture_step", spin.value)
                            self.settings:flush()
                            self:_notify(T(_("Step size set to %1"), spin.value))
                        end,
                    }
                    UIManager:show(spin)
                end,
            },
            {
                text = _("Turn off on sleep"),
                checked_func = function() return self.turn_off_on_suspend end,
                callback = function()
                    self.turn_off_on_suspend = not self.turn_off_on_suspend
                    self.settings:saveSetting("turn_off_on_suspend", self.turn_off_on_suspend)
                    self.settings:flush()
                end,
            },
            {
                text = _("EinkCenter panel"),
                callback = function() self:onBigmeEinkCenter() end,
            },
            separator = true,
            {
                text = _("Install / update helper"),
                keep_menu_open = true,
                callback = function() self:installOrUpdateHelper() end,
            },
            {
                text = _("Check setup"),
                keep_menu_open = true,
                callback = function() self:checkSetup() end,
            },
            {
                text_func = function()
                    if self._initialized then
                        local mode = direct_io_ok and _("Direct") or _("Root")
                        return T(_("Status: ❄️%1 🔥%2 (%3)"), self.current_cold, self.current_warm, mode)
                    else
                        return _("Status: initializing...")
                    end
                end,
                enabled_func = function() return false end,
            },
            {
                text = _("Refresh from hardware"),
                callback = function()
                    if self:_ensureReady() then
                        self.current_cold = read_val("cold") or 0
                        self.current_warm = read_val("warm") or 0
                        self:_notify(T(_("❄️%1 🔥%2"), self.current_cold, self.current_warm))
                    end
                end,
            },
        },
    }
end

function BigmeLight:_notify(text)
    Notification:notify(text, Notification.SOURCE_ALWAYS_SHOW, true)
end

-- Coalesce rapid gesture notifications into a single update (fewer e-ink refreshes).
function BigmeLight:_notify_debounced(text)
    self._pending_notify = text
    if self._notify_scheduled then return end
    self._notify_scheduled = true
    UIManager:scheduleIn(0.1, function()
        self._notify_scheduled = false
        if self._pending_notify then
            Notification:notify(self._pending_notify, Notification.SOURCE_ALWAYS_SHOW, true)
            self._pending_notify = nil
        end
    end)
end

function BigmeLight:onFlushSettings()
    if self.settings then
        self.settings:flush()
    end
end

return BigmeLight

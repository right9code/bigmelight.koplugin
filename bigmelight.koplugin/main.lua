--[[--
Bigme HiBreak front-light control plugin.

Drives the TI LM3630A dual-string LED driver through a small root helper
script installed on demand to /data/local/tmp/bigme_light.sh.

The helper is embedded in this file (base64) and installed by the plugin
itself through Magisk, so no PC or manual adb push is required. The user
only needs to grant root (superuser) once when Magisk prompts.

Runtime notes:
  - Pre-warms `su` on init so the first gesture isn't slow
  - Uses os.execute() for writes (fast, no read overhead)
  - Requires root (Magisk); the driver nodes are kernel-provided

Hardware (Bigme HiBreak / B6):
  /sys/bus/i2c/devices/2-0036/lm3630a_cold_light   (0-255)
  /sys/bus/i2c/devices/2-0036/lm3630a_warm_light   (0-255)

@module koplugin.bigmelight
--]]--

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
local MAX_VAL = 255

-- Embedded helper script (bigme_light.sh). Kept in sync with the repo copy.
local HELPER_B64 = "IyEvc3lzdGVtL2Jpbi9zaApERVY9L3N5cy9idXMvaTJjL2RldmljZXMvMi0wMDM2CmNhc2UgIiQxIiBpbgogIHJlYWRfY29sZCkgIGNhdCAiJERFVi9sbTM2MzBhX2NvbGRfbGlnaHQiIDs7CiAgcmVhZF93YXJtKSAgY2F0ICIkREVWL2xtMzYzMGFfd2FybV9saWdodCIgOzsKICBzZXRfY29sZCkgICBlY2hvICIkMiIgPiAiJERFVi9sbTM2MzBhX2NvbGRfbGlnaHQiIDs7CiAgc2V0X3dhcm0pICAgZWNobyAiJDIiID4gIiRERVYvbG0zNjMwYV93YXJtX2xpZ2h0IiA7OwogIG9mZikgICAgICAgIGVjaG8gMCA+ICIkREVWL2xtMzYzMGFfY29sZF9saWdodCIKICAgICAgICAgICAgICBlY2hvIDAgPiAiJERFVi9sbTM2MzBhX3dhcm1fbGlnaHQiIDs7CiAgKikgICAgICAgICAgZWNobyAidW5rbm93biIgOzsKZXNhYwo="

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
    return su_line(string.format("test -e %s/lm3630a_cold_light && echo yes || echo no", DEV_PATH)) == "yes"
end

local function helper_installed()
    return su_line(string.format("test -x %s && echo yes || echo no", HELPER_PATH)) == "yes"
end

-- Install or repair the embedded helper script through root.
local function install_helper()
    local cmd = string.format(
        "echo %s | base64 -d > %s && chmod 755 %s",
        HELPER_B64, HELPER_PATH, HELPER_PATH)
    os.execute(string.format("su -c '%s'", cmd))
    return helper_installed()
end

-- Write to driver (fire-and-forget, no wait needed)
local function set_cold(v)
    os.execute(string.format("su -c '%s set_cold %d'", HELPER_PATH, v))
end

local function set_warm(v)
    os.execute(string.format("su -c '%s set_warm %d'", HELPER_PATH, v))
end

local function set_both(c, w)
    os.execute(string.format("su -c '%s set_cold %d && %s set_warm %d'", HELPER_PATH, c, HELPER_PATH, w))
end

-- Read from driver (needs result, so use io.popen)
local function read_val(what)
    local handle = io.popen(string.format("su -c '%s read_%s'", HELPER_PATH, what))
    if not handle then return nil end
    local result = handle:read("*number")
    handle:close()
    return result
end

-- Plugin
local BigmeLight = WidgetContainer:extend{
    name = "bigmelight",
    settings_file = DataStorage:getSettingsDir() .. "/bigmelight.lua",
    settings = nil,
    current_cold = 0,
    current_warm = 0,
    gesture_step = 10,
    _initialized = false,
    root_ok = false,
    driver_ok = false,
    helper_ok = false,
}

function BigmeLight:init()
    self.settings = LuaSettings:open(self.settings_file)
    self.gesture_step = self.settings:readSetting("gesture_step") or 10

    self:onDispatcherRegisterActions()
    self.ui.menu:registerToMainMenu(self)

    -- Defer hardware access to avoid blocking init
    UIManager:scheduleIn(0.5, function() self:_postInit() end)
end

function BigmeLight:_postInit()
    -- Pre-warm su so gestures are fast from the start
    warm_su()

    self.root_ok = has_root()
    if not self.root_ok then
        logger.warn("BigmeLight: root not available")
        Notification:notify(_("Bigme Light: root required (grant Magisk superuser)"))
        return
    end

    self.driver_ok = driver_present()
    if not self.driver_ok then
        logger.warn("BigmeLight: LM3630A driver not found")
        Notification:notify(_("Bigme Light: LM3630A light driver not found"))
        return
    end

    self.helper_ok = helper_installed()
    if not self.helper_ok then
        self.helper_ok = install_helper()
        if self.helper_ok then
            Notification:notify(_("Bigme Light: helper installed"))
        else
            logger.warn("BigmeLight: helper install failed")
            Notification:notify(_("Bigme Light: helper install failed"))
            return
        end
    end

    -- Read current hardware state
    self.current_cold = read_val("cold") or 0
    self.current_warm = read_val("warm") or 0
    self._initialized = true
    logger.dbg("BigmeLight: ready, cold=", self.current_cold, "warm=", self.current_warm)
end

function BigmeLight:_ensureReady()
    if not self.root_ok then
        Notification:notify(_("Bigme Light: root required (grant Magisk superuser)"))
        return false
    end
    if not self.driver_ok then
        Notification:notify(_("Bigme Light: LM3630A light driver not found"))
        return false
    end
    if not self._initialized then
        Notification:notify(_("Bigme Light: still initializing..."))
        return false
    end
    return true
end

function BigmeLight:onDispatcherRegisterActions()
    Dispatcher:registerAction("bigme_cold_up",
        {category="incrementalnumber", min=1, max=MAX_VAL,
         event="BigmeColdUp", title=_("Bigme: increase cold light"), screen=true})
    Dispatcher:registerAction("bigme_cold_down",
        {category="incrementalnumber", min=1, max=MAX_VAL,
         event="BigmeColdDown", title=_("Bigme: decrease cold light"), screen=true})
    Dispatcher:registerAction("bigme_warm_up",
        {category="incrementalnumber", min=1, max=MAX_VAL,
         event="BigmeWarmUp", title=_("Bigme: increase warm light"), screen=true})
    Dispatcher:registerAction("bigme_warm_down",
        {category="incrementalnumber", min=1, max=MAX_VAL,
         event="BigmeWarmDown", title=_("Bigme: decrease warm light"), screen=true})
    Dispatcher:registerAction("bigme_light_dialog",
        {category="none", event="BigmeShowLightDialog",
         title=_("Bigme: light control dialog"), screen=true})
    Dispatcher:registerAction("bigme_light_off",
        {category="none", event="BigmeLightOff",
         title=_("Bigme: turn off all lights"), screen=true})
    Dispatcher:registerAction("bigme_light_toggle",
        {category="none", event="BigmeLightToggle",
         title=_("Bigme: toggle front light"), screen=true})
    Dispatcher:registerAction("bigme_eink_center",
        {category="none", event="BigmeEinkCenter",
         title=_("Bigme: EinkCenter panel"), screen=true})
end

-- --- Event handlers ---

function BigmeLight:onBigmeColdUp(arg)
    if not self:_ensureReady() then return true end
    local step = self.gesture_step
    if type(arg) == "number" then step = arg
    elseif type(arg) == "table" and type(arg[1]) == "number" then step = arg[1] end
    self.current_cold = math.min(MAX_VAL, self.current_cold + step)
    set_cold(self.current_cold)
    self:_notify("Cold: " .. self.current_cold .. "/255")
    return true
end

function BigmeLight:onBigmeColdDown(arg)
    if not self:_ensureReady() then return true end
    local step = self.gesture_step
    if type(arg) == "number" then step = arg
    elseif type(arg) == "table" and type(arg[1]) == "number" then step = arg[1] end
    self.current_cold = math.max(0, self.current_cold - step)
    set_cold(self.current_cold)
    self:_notify("Cold: " .. self.current_cold .. "/255")
    return true
end

function BigmeLight:onBigmeWarmUp(arg)
    if not self:_ensureReady() then return true end
    local step = self.gesture_step
    if type(arg) == "number" then step = arg
    elseif type(arg) == "table" and type(arg[1]) == "number" then step = arg[1] end
    self.current_warm = math.min(MAX_VAL, self.current_warm + step)
    set_warm(self.current_warm)
    self:_notify("Warm: " .. self.current_warm .. "/255")
    return true
end

function BigmeLight:onBigmeWarmDown(arg)
    if not self:_ensureReady() then return true end
    local step = self.gesture_step
    if type(arg) == "number" then step = arg
    elseif type(arg) == "table" and type(arg[1]) == "number" then step = arg[1] end
    self.current_warm = math.max(0, self.current_warm - step)
    set_warm(self.current_warm)
    self:_notify("Warm: " .. self.current_warm .. "/255")
    return true
end

function BigmeLight:onBigmeLightOff()
    if not self:_ensureReady() then return true end
    os.execute(string.format("su -c '%s off'", HELPER_PATH))
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
        self:_notify(T(_("Lights on: cold=%1 warm=%2"), saved_cold, saved_warm))
    else
        self.settings:saveSetting("last_cold", self.current_cold)
        self.settings:saveSetting("last_warm", self.current_warm)
        self.settings:flush()
        os.execute(string.format("su -c '%s off'", HELPER_PATH))
        self.current_cold = 0
        self.current_warm = 0
        self:_notify(_("Lights off"))
    end
    return true
end

-- --- EinkCenter panel ---

function BigmeLight:onBigmeEinkCenter()
    warm_su()
    local handle = io.popen("su -c 'content call --uri content://com.xrz.SettingProvider --method setting_einkcenter'")
    if handle then handle:close() end
    return true
end

-- --- Dialog ---

function BigmeLight:onBigmeShowLightDialog()
    if not self:_ensureReady() then return true end

    self.current_cold = read_val("cold") or 0
    self.current_warm = read_val("warm") or 0

    local dialog
    dialog = InputDialog:new{
        title = _("Bigme Front Light"),
        input = tostring(self.current_cold),
        input_hint = _("Cold (0-255)"),
        description = T(_("Warm: %1/255"), self.current_warm),
        buttons = {
            {
                { text = _("Off"), callback = function()
                    UIManager:close(dialog)
                    self:onBigmeLightOff()
                end },
                { text = _("Warm-"), callback = function()
                    self.current_warm = math.max(0, self.current_warm - self.gesture_step)
                    set_warm(self.current_warm)
                    self.current_cold = read_val("cold") or self.current_cold
                    dialog.description = T(_("Warm: %1/255"), self.current_warm)
                    dialog:setInputText(tostring(self.current_cold))
                end },
                { text = _("Warm+"), callback = function()
                    self.current_warm = math.min(MAX_VAL, self.current_warm + self.gesture_step)
                    set_warm(self.current_warm)
                    self.current_cold = read_val("cold") or self.current_cold
                    dialog.description = T(_("Warm: %1/255"), self.current_warm)
                    dialog:setInputText(tostring(self.current_cold))
                end },
            },
            {
                { text = _("Set"), is_enter_default = true, callback = function()
                    local val = tonumber(dialog:getInputText())
                    if val and val >= 0 and val <= MAX_VAL then
                        self.current_cold = val
                        set_cold(val)
                        self:_notify(T(_("Cold: %1, Warm: %2"), self.current_cold, self.current_warm))
                        UIManager:close(dialog)
                    else
                        UIManager:show(InfoMessage:new{
                            text = _("Enter a value between 0 and 255"),
                            timeout = 2,
                        })
                    end
                end },
            },
        },
    }
    UIManager:show(dialog)
    return true
end

-- --- Setup helpers ---

function BigmeLight:checkSetup()
    local root = has_root()
    local driver = root and driver_present()
    local helper = driver and helper_installed()

    self.root_ok = root
    self.driver_ok = driver
    self.helper_ok = helper

    local lines = {
        T(_("Root (Magisk): %1"), root and _("OK") or _("MISSING")),
        T(_("LM3630A driver: %1"), driver and _("OK") or _("MISSING")),
        T(_("Helper script: %1"), helper and _("OK") or _("MISSING")),
    }
    if not root then
        lines[#lines + 1] = _("Grant superuser to KOReader in Magisk, then run Install / update helper.")
    elseif not driver then
        lines[#lines + 1] = _("This device does not expose the Bigme LM3630A front-light driver.")
    elseif not helper then
        lines[#lines + 1] = _("Run Install / update helper to install it.")
    else
        lines[#lines + 1] = T(_("Status: cold=%1 warm=%2"), self.current_cold, self.current_warm)
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
            text = T(_("Helper installed to:\n%1\n\nStatus: cold=%2 warm=%3"), HELPER_PATH, self.current_cold, self.current_warm),
        })
    else
        UIManager:show(InfoMessage:new{
            title = _("Bigme Light setup"),
            text = _("Helper install failed.\n\nCheck that Magisk granted root and try again."),
        })
    end
end

-- --- Menu ---

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
                            Notification:notify(T(_("Step size set to %1"), spin.value))
                        end,
                    }
                    UIManager:show(spin)
                end,
            },
            {
                text = _("All off"),
                callback = function() self:onBigmeLightOff() end,
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
                        return T(_("Status: cold=%1 warm=%2"), self.current_cold, self.current_warm)
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
                        Notification:notify(T(_("Cold: %1, Warm: %2"), self.current_cold, self.current_warm))
                    end
                end,
            },
        },
    }
end

function BigmeLight:_notify(text)
    Notification:notify(text)
end

function BigmeLight:onFlushSettings()
    if self.settings then
        self.settings:flush()
    end
end

return BigmeLight

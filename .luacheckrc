-- Luacheck config for the Bigme Light KOReader plugin.
-- KOReader injects these globals; the plugin requires them at runtime.
std = "luajit"

globals = {
    "WidgetContainer",
    "ButtonDialog",
    "DataStorage",
    "Dispatcher",
    "InfoMessage",
    "InputDialog",
    "LuaSettings",
    "Notification",
    "SpinWidget",
    "UIManager",
    "logger",
    "_",
    "T",
}

-- KOReader's gettext/ffi.template helpers are used throughout
ignore = {
    "212/_",   -- unused argument _
    "213/_",   -- unused loop variable _
    "542",     -- empty if branch (idiomatic KOReader guards)
}

max_line_length = 140

-- The embedded base64 helper (line ~55) and the magiskpolicy su command are
-- intentionally single-line; KOReader event handlers always take (self, arg).
files["bigmelight.koplugin/main.lua"] = {
    globals = { "BigmeLight" },
    ignore = { "212/self", "213/self", "631" },
}

local _ = require("gettext")
return {
    fullname = _("Bigme Light Control"),
    description = _([[Control the Bigme HiBreak front light (cold/warm) via menu or swipe gestures.
Requires root (Magisk). Direct zero-latency sysfs I/O, sleep power management, and user-editable presets.]]),
    version = "1.2.0",
}

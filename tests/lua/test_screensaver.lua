-- Screen savers (needs PROGMAN31LUA_DATA with SSSTARS.SCR and SSFLYWIN.SCR):
-- Control Panel's settings start Starfield after the idle delay, a key
-- ends it; Flying Windows draws its Wingdings windows; the savers are
-- listed in C:\WINDOWS only; SystemParametersInfo keeps the settings.

local opts = ...
local failures = 0
local function check(name, cond, msg)
    if not cond then
        failures = failures + 1
        host.log("FAIL " .. name .. (msg and (": " .. msg) or ""))
    else
        host.log("ok   " .. name)
    end
end

-- the largest run of one non-black colour along any row: Flying Windows'
-- flags are many pixels wide, its fallback dots one or two
local function widestRun(path)
    local f = io.open(path, "rb")
    if not f then return 0 end
    local d = f:read("a")
    f:close()
    local off, w, h, bpp = string.unpack("<I4", d, 11), string.unpack("<i4", d, 19), string.unpack("<i4", d, 23),
        string.unpack("<I2", d, 29)
    if bpp ~= 24 and bpp ~= 32 then return -1 end
    local bytes = bpp // 8
    local stride = ((w * bytes + 3) // 4) * 4
    local best = 0
    for y = 0, math.abs(h) - 1, 3 do
        local run, last = 0, nil
        for x = 0, w - 1 do
            local p = off + y * stride + x * bytes + 1
            local c = d:sub(p, p + 2)
            if c ~= "\0\0\0" and c == last then run = run + 1 else run = 1 end
            last = c
            if c ~= "\0\0\0" and run > best then best = run end
        end
    end
    return best
end

local found = {}
local shot = os.tmpname()
opts.script = {
    {at = 2500, fn = function(user)
        local dosfs = require("win16.dosfs")
        local inWin, inSys = 0, 0
        for _, e in ipairs(dosfs.find("C:\\WINDOWS\\*.SCR")) do inWin = inWin + 1 end
        for _, e in ipairs(dosfs.find("C:\\WINDOWS\\SYSTEM\\*.SCR")) do inSys = inSys + 1 end
        found.inWin, found.inSys = inWin, inSys
        -- SPI_SETSCREENSAVETIMEOUT / ACTIVE, then read them back
        local ss = require("win16.screensave")
        ss.parameters(15, 2, nil, 0)
        ss.parameters(17, 1, nil, 0)
        found.timeout, found.active = ss.timeout(), ss.active()
        local p = require("win16.profile")
        p.set(p.resolve("SYSTEM.INI"), "boot", "SCRNSAVE.EXE", "SSSTARS.SCR")
        ss.lastInput = host.ticks()
    end},
    {at = 3800, fn = function(user) found.early = require("win16.screensave").running() end},
    {at = 6000, fn = function(user) found.started = require("win16.screensave").running() end},
    {at = 6100, ev = {"key", 0x20, 1, 0, 57}}, {at = 6120, ev = {"key", 0x20, 0, 0, 57}},
    {at = 7000, fn = function(user)
        found.ended = not require("win16.screensave").running()
        local ss = require("win16.screensave")
        ss.parameters(17, 0, nil, 0)
        require("win16.launch").run("C:\\WINDOWS\\SSFLYWIN.SCR /s", 1)
    end},
    {at = 10000, shot = shot},
    {at = 10100, fn = function(user) found.flags = widestRun(shot); os.remove(shot) end},
    {at = 10200, ev = {"key", 0x20, 1, 0, 57}}, {at = 10220, ev = {"key", 0x20, 0, 0, 57}},
}
opts["exit-after"] = 11000
opts["no-logo"] = true
local ok, err = pcall(require("boot").run, opts)
if not ok and not (type(err) == "table" and err.quit) then error(err, 0) end

check("savers in C:\\WINDOWS", found.inWin == 4, tostring(found.inWin))
check("none in SYSTEM", found.inSys == 0, tostring(found.inSys))
check("SPI timeout", found.timeout == 2, tostring(found.timeout))
check("SPI active", found.active == true)
check("not before the delay", found.early == false)
check("starts after the delay", found.started == true)
check("a key ends it", found.ended == true)
check("Flying Windows draws flags", (found.flags or 0) >= 8, tostring(found.flags))
host.log(failures == 0 and "screensaver: all passed" or ("screensaver: " .. failures .. " failed"))
return failures == 0 and 0 or 1

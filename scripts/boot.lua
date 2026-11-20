-- Startup: find the Windows 3.1 files, show the Windows 3.1 logo screen
-- (VGALOGO.RLE, the picture WIN.COM shows while Windows loads), bring up the
-- Win16 layer and run PROGMAN.EXE on the recompiler.

local boot = {}

local isWindows = host.platform() == "Windows"
local sep = isWindows and "\\" or "/"

local function findCi(dir, name)
    local list = host.list(dir)
    if not list then return nil end
    for _, e in ipairs(list) do
        if e.name:upper() == name then return dir .. sep .. e.name end
    end
end

-- A folder holding PROGMAN.EXE or PROGMAN.EX_ (itself, or a WINDOWS folder in it).
local function hasProgman(dir)
    if not dir or not host.stat(dir) then return nil end
    if findCi(dir, "PROGMAN.EXE") or findCi(dir, "PROGMAN.EX_") then return dir end
    local w = findCi(dir, "WINDOWS")
    if w and (findCi(w, "PROGMAN.EXE") or findCi(w, "PROGMAN.EX_")) then return w end
end

function boot.findData(opt)
    if type(opt) == "string" then return hasProgman(opt), opt end
    local base = host.base_path()
    local tries = {base .. "data", base:sub(1, -2)}
    if isWindows then
        for c = string.byte("C"), string.byte("Z") do
            tries[#tries + 1] = string.char(c) .. ":\\"
        end
    end
    for _, d in ipairs(tries) do
        local f = hasProgman(d)
        if f then return f end
    end
end

-- Reads a file from the data folder, as installed or compressed (X.EX_).
function boot.dataFile(dir, name)
    if not dir then return nil end
    local p = findCi(dir, name) or findCi(dir, name:sub(1, -2) .. "_")
    if not p then
        -- an installed WINDOWS folder keeps drivers and fonts in SYSTEM
        local sys = findCi(dir, "SYSTEM")
        p = sys and (findCi(sys, name) or findCi(sys, name:sub(1, -2) .. "_"))
    end
    if not p then return nil end
    return host.read(p, true)
end

-- ---- the logo -------------------------------------------------------------------------

-- Shows VGALOGO.RLE (a 4-bit RLE bitmap) centred on black, scaled to the
-- screen's height as it filled a 640x480 VGA screen, rebranded (logo.lua).
local function showLogo(data, shot)
    local rle = boot.dataFile(data, "VGALOGO.RLE")
    if not rle or rle:sub(1, 2) ~= "BM" then return false end
    local id, w, h = fb.dib(rle:sub(15))
    if not id then return false end
    local fonts = {}
    local serif = boot.dataFile(data, "SERIFE.FON")
    local m = serif and require("recomp.ne").parse(serif, "SERIFE.FON")
    if m then
        for _, r in ipairs(m:resourcesOf(8)) do fonts[#fonts + 1] = m:resourceBytes(r) end
    end
    local ok, err = pcall(require("logo").rebrand, id, w, h, fonts)
    if not ok then host.log("logo: " .. tostring(err)) end
    local sw, sh = fb.size(0)
    fb.clip(nil)
    fb.patblt(0, 0, 0, sw, sh, 0xF0, 0x000000)
    local k = sh / 480
    local dw, dh = math.floor(w * k + 0.5), math.floor(h * k + 0.5)
    fb.stretchblt(0, (sw - dw) // 2, (sh - dh) // 2, dw, dh, id, 0, 0, w, h, 0xCC, 0, 0, 0)
    fb.free(id)
    if shot then fb.save_bmp(0, shot) end
    host.present()
    return true
end

-- Waits until `ms` have passed since `since` (a click or key skips it).
local function hold(since, ms)
    while host.ticks() - since < ms do
        for _, e in ipairs(host.pump(30)) do
            if e[1] == "quit" then return false end
            if e[1] == "down" or (e[1] == "key" and e[3] == 1) then return true end
        end
    end
    return true
end

-- A plain screen for when the files can't be found.
local function noData(msg)
    local text = "Program Manager needs your Windows 3.1 files.\n\n" .. msg ..
        "\n\nStart it with --data <folder>: an installed WINDOWS folder, or the Windows 3.1\n" ..
        "setup disks or CD (where PROGMAN.EXE is stored as PROGMAN.EX_)."
    host.log(text)
    if host.headless then return 0 end
    host.message_box("Program Manager", text)
    return 1
end

function boot.run(opts)
    local sw, sh = 800, 600
    if type(opts.screen) == "string" then
        local w, h = opts.screen:match("^(%d+)x(%d+)$")
        if w then sw, sh = tonumber(w), tonumber(h) end
    end
    host.window(sw, sh, "Program Manager")
    local started = host.ticks()

    local data = boot.findData(opts.data)
    if not data then
        if opts["exit-after"] then return 0 end
        return noData(type(opts.data) == "string" and ("PROGMAN.EXE was not found in " .. opts.data) or
            "PROGMAN.EXE was not found.")
    end

    local logo = not opts["no-logo"] and showLogo(data, type(opts["logo-shot"]) == "string" and opts["logo-shot"])
    if opts["logo-shot"] then return 0 end

    local home = type(opts.home) == "string" and opts.home or host.pref_path():gsub("[\\/]$", "")
    host.mkdir(home)
    if opts.fresh then
        local w = findCi(home, "WINDOWS")
        if w then
            for _, e in ipairs(host.list(w) or {}) do
                if not e.dir then host.remove(w .. sep .. e.name) end
            end
        end
    end

    local win16 = require("win16")
    local ok, err = pcall(win16.init, {data = data, home = home, screenW = sw, screenH = sh, opts = opts})
    if not ok then
        host.log(tostring(err))
        if not host.headless then host.message_box("Program Manager", tostring(err)) end
        return 1
    end
    if logo and not opts["exit-after"] and not host.headless then
        if not hold(started, 2500) then return 0 end
    end
    return win16.run()
end

return boot

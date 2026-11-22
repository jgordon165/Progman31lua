-- Starting programs from Program Manager (WinExec, ShellExecute).
--
-- The Windows 3.1 programs can't run on 64-bit Windows, so each starts
-- either the original itself, recompiled alongside Program Manager ("*",
-- as Control Panel does), or a modern counterpart, from [Programs] in
-- PROGMAN31.INI (in Program Manager's Windows folder; edit it to choose
-- your own). Any other program or document is started by the host: modern
-- programs run as themselves.

local dosfs = require("win16.dosfs")
local profile = require("win16.profile")

local launch = {}

local INI = "PROGMAN31.INI"

-- Windows 3.1 program -> what to start instead ("" = nothing equivalent)
launch.defaults = {
    ["NOTEPAD.EXE"] = "notepad.exe", ["CALC.EXE"] = "calc.exe", ["WRITE.EXE"] = "write.exe",
    ["PBRUSH.EXE"] = "mspaint.exe", ["WINFILE.EXE"] = "explorer.exe", ["CONTROL.EXE"] = "*",
    ["PRINTMAN.EXE"] = "ms-settings:printers", ["CLIPBRD.EXE"] = "ms-settings:clipboard",
    ["CHARMAP.EXE"] = "charmap.exe", ["SOUNDREC.EXE"] = "ms-settings:sound", ["MPLAYER.EXE"] = "wmplayer.exe",
    ["CLOCK.EXE"] = "ms-clock:", ["CALENDAR.EXE"] = "outlookcal:", ["CARDFILE.EXE"] = "",
    ["TERMINAL.EXE"] = "wt.exe", ["RECORDER.EXE"] = "", ["PIFEDIT.EXE"] = "", ["SETUP.EXE"] = "ms-settings:",
    ["WINTUTOR.EXE"] = "", ["PACKAGER.EXE"] = "", ["SOL.EXE"] = "solitairepack.exe",
    ["WINMINE.EXE"] = "ms-windows-store://pdp/?productid=9WZDNCRFHWCN", ["DOSPRMPT.PIF"] = "cmd.exe",
    ["COMMAND.COM"] = "cmd.exe", ["WINHELP.EXE"] = "", ["TASKMAN.EXE"] = "taskmgr.exe",
    ["SYSEDIT.EXE"] = "notepad.exe", ["REGEDIT.EXE"] = "regedit.exe", ["DRWATSON.EXE"] = "",
    ["WINVER.EXE"] = "winver.exe", ["README.WRI"] = "write.exe",
}

-- Entries that changed from a modern program to the recompiled original
-- since an older PROGMAN31.INI was written.
launch.upgrades = {["CONTROL.EXE"] = "control.exe"}

function launch.installDefaults()
    local path = dosfs.windows .. "\\" .. INI
    if dosfs.exists(path) then
        for k, old in pairs(launch.upgrades) do
            if (profile.get(path, "Programs", k) or ""):lower() == old then
                profile.set(path, "Programs", k, launch.defaults[k])
                profile.flush(path)
            end
        end
        return
    end
    local lines = {"; Progman31lua: what starts when you run a Windows 3.1 program from Program Manager.",
                   "; Change the right-hand side to any program, document or URL; leave it empty to do nothing.",
                   "; * runs the original Windows 3.1 program itself, recompiled.",
                   "[Programs]"}
    local keys = {}
    for k in pairs(launch.defaults) do keys[#keys + 1] = k end
    table.sort(keys)
    for _, k in ipairs(keys) do lines[#lines + 1] = k .. "=" .. launch.defaults[k] end
    dosfs.write(path, table.concat(lines, "\r\n") .. "\r\n")
    profile.flush(path)
end

-- Splits a command line into the program and its parameters.
local function split(cmd)
    cmd = cmd:gsub("^%s+", "")
    local prog, rest = cmd:match('^"([^"]*)"%s*(.*)$')
    if not prog then prog, rest = cmd:match("^(%S+)%s*(.*)$") end
    return prog or "", rest or ""
end

-- The host equivalent of a DOS file: a real file, or a 3.1 file from the
-- setup disk copied (expanded) into the Windows folder first.
local function hostFileFor(full)
    local hp = dosfs.hostFile(full)
    if hp then return hp end
    local bytes = dosfs.read(full)
    if bytes and dosfs.write(full, bytes) then return dosfs.hostFile(full) end
end

local function mapped(name)
    local v = profile.get(dosfs.windows .. "\\" .. INI, "Programs", name)
    if v == nil then v = launch.defaults[name] end
    return v
end

-- A program found beside this one (the sister ports: solitairepack.exe, ...)
local function besideUs(exe)
    local base = host.base_path()
    local p = base .. exe
    if host.stat(p) then return p end
    local sep = host.platform() == "Windows" and "\\" or "/"
    local sib = base .. ".." .. sep .. exe:gsub("%.exe$", "") .. sep .. exe
    if host.stat(sib) then return sib end
end

local function start(file, params, dir, show)
    if host.headless then
        launch.last = {file = file, params = params, dir = dir}
        return true
    end
    local ok = host.launch(file, params or "", dir or "", show or 1)
    return ok
end

-- WinExec: returns > 31 on success, as Windows does.
function launch.run(cmd, show)
    local prog, params = split(cmd)
    if prog == "" then return 2 end
    local shell = require("win16.shell")
    local full = shell.resolve(prog)
    local name = (full or dosfs.full(prog)):match("([^\\]+)$")
    -- a Windows 3.1 program?
    local m = mapped(name)
    if m ~= nil and (full == nil or full:sub(1, #dosfs.windows) == dosfs.windows) then
        if m == "" then return 11 end
        if m == "*" then
            return require("win16.kernel").exec(full or (dosfs.windows .. "\\" .. name), params, show)
        end
        local target = m
        if m:lower() == "solitairepack.exe" then target = besideUs(m) or m end
        -- a document parameter in C:\WINDOWS goes as its host path
        local p = params
        if p ~= "" then
            local pf = shell.resolve(p) or (dosfs.exists(p) and dosfs.full(p))
            if pf then p = hostFileFor(pf) or p end
        elseif name == "README.WRI" and full then
            p = hostFileFor(full) or ""
        end
        if p:find(" ") and not p:match('^"') then p = '"' .. p .. '"' end
        return start(target, p, nil, show) and 33 or 2
    end
    if not full then return 2 end
    -- screen savers are Windows 3.1 programs too, run recompiled
    if name:upper():match("%.SCR$") then
        return require("win16.kernel").exec(full, params, show)
    end
    local hp = hostFileFor(full)
    if not hp then return 2 end
    local data = dosfs.read(full)
    if data and data:sub(1, 2) == "MZ" then
        local h = string.unpack("<I4", data, 0x3D)
        if h and data:sub(h + 1, h + 2) == "NE" then
            -- another 16-bit Windows program: it can't run on the host
            return 11
        end
    end
    return start(hp, params, nil, show) and 33 or 2
end

function launch.shellExecute(op, file, params, dir, show)
    if not file then return 2 end
    local cmd = file
    if params and params ~= "" then cmd = file .. " " .. params end
    local shell = require("win16.shell")
    local full = shell.resolve(file)
    if full and not full:upper():match("%.EXE$") and not full:upper():match("%.COM$") and not full:upper():match("%.PIF$") then
        local exe = shell.association(full)
        if exe then return launch.run(exe .. " " .. full, show) end
        local hp = hostFileFor(full)
        return hp and (start(hp, "", nil, show) and 33 or 31) or 2
    end
    if not full and (file:match("^%a+:") and not file:match("^%a:")) then
        return start(file, params, dir, show) and 33 or 2   -- a URL
    end
    return launch.run(cmd, show)
end

function launch.help(file, cmd, data)
    host.log("WinHelp(" .. tostring(file) .. ") — Windows Help isn't available")
end

return launch

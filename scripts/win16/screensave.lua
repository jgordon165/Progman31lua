-- Screen savers, as Windows 3.1 ran them. Control Panel's Desktop applet
-- sets them: the saver in SYSTEM.INI ([boot] SCRNSAVE.EXE=SSSTARS.SCR),
-- the delay and whether one is on in WIN.INI ([windows] ScreenSaveTimeOut,
-- ScreenSaveActive). When there has been no input for the delay, the
-- active window is sent WM_SYSCOMMAND SC_SCREENSAVE, and DefWindowProc
-- starts the saver (`/s`), recompiled like the other Windows programs.

local user = require("win16.user")
local profile = require("win16.profile")
local dosfs = require("win16.dosfs")

local WM = user.WM
local SC_SCREENSAVE = 0xF140

local ss = {}

ss.lastInput = host.ticks()

local function winIni() return profile.resolve(nil) end
local function systemIni() return profile.resolve("SYSTEM.INI") end

local function truthy(v)
    v = (v or ""):lower()
    return v == "1" or v == "yes" or v == "true" or v == "on"
end

function ss.active() return truthy(profile.get(winIni(), "windows", "ScreenSaveActive")) end
function ss.timeout()
    return tonumber((profile.get(winIni(), "windows", "ScreenSaveTimeOut") or ""):match("%d+") or "") or 120
end

-- The saver SYSTEM.INI names, as a path under C:\WINDOWS (or nil).
function ss.saver()
    local v = profile.get(systemIni(), "boot", "SCRNSAVE.EXE")
    v = v and v:match("^%s*(%S+)")
    if not v or v == "" or v:lower() == "(none)" then return nil end
    if not v:find("[\\:]") then v = dosfs.windows .. "\\" .. v end
    return v
end

-- SystemParametersInfo for actions 14-17.
function ss.parameters(action, param, p, winini)
    local save = winini & 1 ~= 0
    if action == 14 then          -- SPI_GETSCREENSAVETIMEOUT
        if p then mem.ww(p, ss.timeout()) end
    elseif action == 15 then      -- SPI_SETSCREENSAVETIMEOUT
        ss.setTimeout = param
        profile.set(winIni(), "windows", "ScreenSaveTimeOut", tostring(param))
        if save then profile.flush(winIni()) end
    elseif action == 16 then      -- SPI_GETSCREENSAVEACTIVE
        if p then mem.ww(p, ss.active() and 1 or 0) end
    elseif action == 17 then      -- SPI_SETSCREENSAVEACTIVE
        profile.set(winIni(), "windows", "ScreenSaveActive", param ~= 0 and "1" or "0")
        if save then profile.flush(winIni()) end
    end
    ss.lastInput = host.ticks()
    return 1
end

-- Is a saver showing? (its task is running)
function ss.running()
    local t = ss.task
    if not t then return false end
    for _, x in ipairs(require("win16.tasks").list) do
        if x == t then return true end
    end
    ss.task = nil
    return false
end

-- Start the saver now (DefWindowProc's SC_SCREENSAVE).
function ss.start()
    if ss.running() then return end
    local path = ss.saver()
    if not path or not dosfs.exists(path) then return end
    local launch = require("win16.launch")
    local before = {}
    local tasks = require("win16.tasks")
    for _, t in ipairs(tasks.list) do before[t] = true end
    launch.run(path .. " /s", 1)
    for _, t in ipairs(tasks.list) do
        if not before[t] then ss.task = t end
    end
end

-- Called with each host input event.
function ss.input()
    ss.lastInput = host.ticks()
end

-- Called while idle: time to start the saver?
function ss.check()
    if ss.running() or not ss.active() then return end
    local t = ss.timeout()
    if t <= 0 or host.ticks() - ss.lastInput < t * 1000 then return end
    ss.lastInput = host.ticks()      -- once per idle spell
    if not ss.saver() then return end
    local w = user.active
    if w and not w.destroyed then
        user.post(w, WM.SYSCOMMAND, SC_SCREENSAVE, 0)
    else
        ss.start()
    end
end

ss.SC_SCREENSAVE = SC_SCREENSAVE
return ss

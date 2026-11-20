-- Control Panel (needs PROGMAN31LUA_DATA with CONTROL.EXE and MAIN.CPL):
-- Program Manager starts the original CONTROL.EXE as a second task, Color
-- opens, the Hotdog Stand scheme is picked and applied (live, and to
-- WIN.INI), Date/Time opens, and Control Panel closes again.

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

local found = {}
local function topNamed(user, text)
    for _, c in ipairs(user.desktop.children) do
        if c.text == text and not c.destroyed and c.visible then return c end
    end
end
local function dbl(t, x, y)
    return {at = t, ev = {"move", x, y}}, {at = t + 10, ev = {"down", x, y, 1, 1}}, {at = t + 20, ev = {"up", x, y, 1, 1}},
           {at = t + 60, ev = {"down", x, y, 1, 2}}, {at = t + 70, ev = {"up", x, y, 1, 2}}
end
-- an applet's icon in Control Panel's window: x, y on the screen
local function iconAt(user, col, row)
    local cp = topNamed(user, "Control Panel")
    local ox, oy = user.clientOrigin(cp)
    return ox + 45 + col * 85, oy + 30 + row * 56
end

local s = {
    {at = 3000, fn = function(user)
        found.exec = require("win16.launch").run("CONTROL.EXE", 1)
    end},
    {at = 4000, fn = function(user)
        found.cp = topNamed(user, "Control Panel")
        found.tasks = #require("win16.tasks").list
        if found.cp then
            local x, y = iconAt(user, 0, 0)
            for _, st in ipairs({dbl(0, x, y)}) do
                user.input[#user.input + 1] = {kind = st.ev[1], e = st.ev, t = host.ticks()}
            end
        end
    end},
    {at = 5000, fn = function(user) found.color = topNamed(user, "Color") ~= nil end},
    {at = 5100, ev = {"char", string.byte("H")}},
    {at = 5600, ev = {"key", 0x0D, 1, 0, 28}}, {at = 5620, ev = {"key", 0x0D, 0, 0, 28}},
    {at = 6500, fn = function(user)
        found.background = user.sysColors[1]
        found.colorClosed = topNamed(user, "Color") == nil
        if found.cp then
            local x, y = iconAt(user, 0, 2)
            for _, st in ipairs({dbl(0, x, y)}) do
                user.input[#user.input + 1] = {kind = st.ev[1], e = st.ev, t = host.ticks()}
            end
        end
    end},
    {at = 7500, fn = function(user)
        local d = topNamed(user, "Date & Time")
        found.datetime = d ~= nil
        if d then
            for _, c in ipairs(d.children) do
                if c.class.name == "EDIT" and c.id == 0x2C2 then found.year = c.text end
            end
            user.post(d, 0x111, 2, 0)   -- Cancel
        end
    end},
    {at = 8000, fn = function(user)
        local cp = topNamed(user, "Control Panel")
        if cp then user.post(cp, 0x10, 0, 0) end   -- WM_CLOSE
    end},
    {at = 9000, fn = function(user)
        found.closed = topNamed(user, "Control Panel") == nil
        found.tasksAfter = #require("win16.tasks").list
    end},
}
opts.script = s
opts["exit-after"] = 9500
opts["no-logo"] = true
local rc = require("boot").run(opts)
check("Program Manager ran to the end", rc == 0, tostring(rc))
check("CONTROL.EXE started as a task", (found.exec or 0) > 31 and found.tasks == 2, tostring(found.exec) .. " tasks " .. tostring(found.tasks))
check("Control Panel's window is there", found.cp ~= nil)
check("Color opened", found.color)
check("the Hotdog Stand scheme was applied", found.colorClosed and found.background == 0xFFFF00,
    string.format("%s %06X", tostring(found.colorClosed), found.background or 0))
local profile = require("win16.profile")
local bg = profile.get(profile.resolve(nil), "colors", "Background")
check("and saved to WIN.INI", bg and bg:match("^255 255 0"), tostring(bg))
check("Date & Time opened with this year", found.datetime and found.year == os.date("%y"), tostring(found.year))
check("Control Panel closed, its task ended", found.closed and found.tasksAfter == 1, tostring(found.tasksAfter))

host.log(failures == 0 and "control: all passed" or (failures .. " FAILED"))
return failures == 0 and 0 or 1

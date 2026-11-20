-- Program Manager itself, end to end (needs PROGMAN31LUA_DATA: a Windows 3.1
-- folder or setup disk). From an empty home: first-run Setup must make the
-- groups; then File > Run, double-clicking an item, and dragging an item to
-- another group are driven with scripted input and checked.

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

local launches = {}
local function click(t, x, y, n)
    return {at = t, ev = {"move", x, y}}, {at = t + 20, ev = {"down", x, y, 1, n or 1}}, {at = t + 50, ev = {"up", x, y, 1, n or 1}}
end
local steps = {}
local function add(...) for _, v in ipairs({...}) do steps[#steps + 1] = v end end
local function record(tag)
    return {fn = function()
        local l = require("win16.launch").last
        launches[tag] = l and l.file or nil
        require("win16.launch").last = nil
    end}
end
local function at(t, st) st.at = t; return st end

-- File > Run, "notepad", Enter
add({at = 7000, ev = {"key", 0x12, 1, 0, 0}}, {at = 7020, ev = {"key", 0x46, 1, 0, 0}},
    {at = 7040, ev = {"key", 0x46, 0, 0, 0}}, {at = 7060, ev = {"key", 0x12, 0, 0, 0}})
add({at = 7400, ev = {"char", string.byte("r")}})
for i, c in ipairs({"n", "o", "t", "e", "p", "a", "d"}) do add({at = 7800 + i * 30, ev = {"char", string.byte(c)}}) end
add({at = 8200, ev = {"key", 0x0D, 1, 0, 0}}, {at = 8230, ev = {"key", 0x0D, 0, 0, 0}})
add(at(8800, record("run")))
-- double-click Clipboard Viewer in Main
add(click(9000, 316, 110))
add(click(9120, 316, 110, 2))
add(at(9800, record("dblclick")))
-- drag Read Me onto the Games icon
add({at = 10000, ev = {"move", 90, 180}}, {at = 10020, ev = {"down", 90, 180, 1, 1}})
for i = 1, 10 do add({at = 10050 + i * 30, ev = {"move", 90 + i * 2, 180 + i * 39}}) end
add({at = 10500, ev = {"up", 112, 568, 1, 1}})

opts.script = steps
opts["exit-after"] = 12000
opts["no-logo"] = true
local rc = require("boot").run(opts)
check("Program Manager ran to the end", rc == 0, tostring(rc))

-- what Setup and Program Manager left in C:\WINDOWS
local sep = host.platform() == "Windows" and "\\" or "/"
local win = opts.home .. sep .. "WINDOWS" .. sep
local ini = host.read(win .. "PROGMAN.INI") or ""
check("PROGMAN.INI lists four groups", ini:find("Group1=C:\\WINDOWS\\MAIN.GRP", 1, true) and ini:find("Group4=", 1, true), ini)
local main = host.read(win .. "MAIN.GRP") or ""
check("MAIN.GRP is a group file", main:sub(1, 4) == "PMCC", main:sub(1, 4))
check("MAIN.GRP has File Manager", main:find("File Manager", 1, true) ~= nil)
check("File > Run started Notepad", launches.run == "notepad.exe", tostring(launches.run))
check("double-clicking Clipboard Viewer started its stand-in", launches.dblclick == "ms-settings:clipboard", tostring(launches.dblclick))
local games = host.read(win .. "GAMES.GRP") or ""
main = host.read(win .. "MAIN.GRP") or ""
check("dragging Read Me moved it to Games", games:find("Read Me", 1, true) ~= nil and not main:find("Read Me", 1, true))

host.log(failures == 0 and "progman: all passed" or (failures .. " FAILED"))
return failures == 0 and 0 or 1

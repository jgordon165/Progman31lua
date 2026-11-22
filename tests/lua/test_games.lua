-- The Games group from the games folder (needs PROGMAN31LUA_DATA). Run in
-- phases, one Program Manager each, sharing a home:
--   --phase setup    first run with a games folder: Games is its shortcuts
--   --phase sync     the folder changed: the group follows it
--   --phase plain    first run without a games folder: Setup's Games group
--   --phase upgrade  then with one: Solitaire and Minesweeper give way

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

local dir = debug.getinfo(1, "S").source:match("^@(.*[\\/])") or "./"
local fixture = dofile(dir .. "games_fixture.lua")
local sep = fixture.sep
local phase = opts.phase
local folder = opts.home .. "-games"

-- unit checks that need no Program Manager
if phase == "setup" then
    local dosfs = require("win16.dosfs")
    fixture.build(folder)
    local byAlias = dosfs.shortNames(folder)
    check("long folder names get 8.3 aliases", byAlias["ONEMUS~1"] and byAlias["ONEMUS~1"].name == "One Must Fall 2097")
    check("8.3 names stay as they are", byAlias["RAPTOR"] and byAlias["RAPTOR"].name == "Raptor")
    local games = require("win16.games")
    local l = games.parseLnk(fixture.lnk("C:\\Games\\X\\x.exe", "x.ico", "..\\x.exe"))
    check("a .lnk's target", l and l.target == "C:\\Games\\X\\x.exe", l and tostring(l.target))
    check("a .lnk's icon location", l and l.icon == "x.ico" and l.relative == "..\\x.exe", l and tostring(l.icon))
    local u = games.parseUrl(fixture.url("steam://rungameid/1", "C:\\a.ico"))
    check("a .url's icon", u.target == "steam://rungameid/1" and u.icon == "C:\\a.ico")
elseif phase == "sync" then
    fixture.rmtree(folder .. sep .. "Raptor")
    host.mkdir(folder .. sep .. "Tetris")
    host.write(folder .. sep .. "Tetris" .. sep .. "Tetris.lnk", fixture.lnk("C:\\Games\\Tetris\\tetrispack.exe"))
    -- One Must Fall's icon changes: red to blue (the item keeps its name)
    host.write(folder .. sep .. "One Must Fall 2097" .. sep .. "omf.ico", fixture.ico(0x0000E0))
elseif phase == "plain" then
    fixture.rmtree(folder)
elseif phase == "upgrade" then
    fixture.build(folder)
end

if phase ~= "plain" then opts.games = folder end
opts["exit-after"] = 6000
opts["no-logo"] = true
local rc = require("boot").run(opts)
check("Program Manager ran to the end", rc == 0, tostring(rc))

local win = opts.home .. sep .. "WINDOWS" .. sep
local games = require("win16.games")
local g = games.readGroup("C:\\WINDOWS\\GAMES.GRP")
check("GAMES.GRP is there", g ~= nil)
g = g or {items = {}}
local items = {}
for _, it in ipairs(g.items) do items[it.name] = it.command end
local function names()
    local t = {}
    for _, it in ipairs(g.items) do t[#t + 1] = it.name .. "=" .. it.command end
    return table.concat(t, "; ")
end

if phase == "setup" or phase == "upgrade" then
    check("One Must Fall 2097 is in Games", items["One Must Fall 2097"] == "C:\\WINDOWS\\GAMES\\ONEMUS~1\\ONEMUS~1.LNK", names())
    check("Raptor is in Games", items["Raptor"] == "C:\\WINDOWS\\GAMES\\RAPTOR\\RAPTOR.LNK", names())
    check("a .url two folders down is in Games", items["MegaRace, the Movie"] == "C:\\WINDOWS\\GAMES\\STEAMG~1\\MEGARACE\\MEGARA~1.URL", names())
    check("only the shortcuts", #g.items == 3, names())
    check("no Solitaire or Minesweeper", not items["Solitaire"] and not items["Minesweeper"], names())
    -- the icons: One Must Fall's red circle (.lnk), MegaRace's green one (.url)
    local data = host.read(win .. "GAMES.GRP", false) or ""
    check("a .lnk's icon was read", data:find(string.rep("\153", 8), 1, true) ~= nil, "no red in GAMES.GRP")
    check("a .url's icon was read", data:find(string.rep("\170", 8), 1, true) ~= nil, "no green in GAMES.GRP")
    -- running one starts the shortcut itself
    local launch = require("win16.launch")
    launch.last = nil
    local rc = launch.run("C:\\WINDOWS\\GAMES\\ONEMUS~1\\ONEMUS~1.LNK", 1)
    local f = launch.last and launch.last.file or ""
    check("running an item starts its shortcut", rc > 31 and f:sub(-#"One Must Fall 2097.lnk") == "One Must Fall 2097.lnk", f)
elseif phase == "sync" then
    check("Raptor's gone", items["Raptor"] == nil, names())
    check("Tetris was added", items["Tetris"] == "C:\\WINDOWS\\GAMES\\TETRIS\\TETRIS.LNK", names())
    check("One Must Fall 2097 stays", items["One Must Fall 2097"] ~= nil, names())
    check("three items", #g.items == 3, names())
    local data = host.read(win .. "GAMES.GRP", false) or ""
    check("a changed icon is updated", data:find(string.rep("\204", 8), 1, true) ~= nil and
        not data:find(string.rep("\153", 8), 1, true), "One Must Fall's icon is still red")
elseif phase == "plain" then
    check("Setup's Solitaire without a games folder", items["Solitaire"] ~= nil, names())
end

host.log(failures == 0 and ("games " .. phase .. ": all passed") or (failures .. " FAILED"))
return failures == 0 and 0 or 1

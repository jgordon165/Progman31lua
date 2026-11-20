-- First run: Program Manager starts with no groups, as it did before
-- Windows Setup filled it. Setup did that by talking to Program Manager
-- over DDE ([CreateGroup(Main)], [AddItem(WINFILE.EXE,File Manager)], ...),
-- from the [progman.groups] section of SETUP.INF. This does the same, from
-- the user's SETUP.INF (or the same list built in when there isn't one),
-- so Program Manager builds and saves its own .GRP files.

local api = require("win16.api")
local dosfs = require("win16.dosfs")
local kernel = require("win16.kernel")
local user = require("win16.user")

local WM = user.WM
local W = user.W

local setup = {}

-- The groups of Windows 3.1's Setup, in its order.
local BUILTIN = {
    {name = "Main", items = {
        {"File Manager", "WINFILE.EXE"}, {"Control Panel", "CONTROL.EXE"}, {"Print Manager", "PRINTMAN.EXE"},
        {"Clipboard Viewer", "CLIPBRD.EXE"}, {"MS-DOS Prompt", "DOSPRMPT.PIF", "PROGMAN.EXE", "9"},
        {"Windows Setup", "SETUP.EXE"}, {"PIF Editor", "PIFEDIT.EXE"}, {"Read Me", "README.WRI"}}},
    {name = "Accessories", items = {
        {"Write", "WRITE.EXE"}, {"Paintbrush", "PBRUSH.EXE"}, {"Terminal", "TERMINAL.EXE"}, {"Notepad", "NOTEPAD.EXE"},
        {"Recorder", "RECORDER.EXE"}, {"Cardfile", "CARDFILE.EXE"}, {"Calendar", "CALENDAR.EXE"},
        {"Calculator", "CALC.EXE"}, {"Clock", "CLOCK.EXE"}, {"Object Packager", "PACKAGER.EXE"},
        {"Character Map", "CHARMAP.EXE"}, {"Media Player", "MPLAYER.EXE"}, {"Sound Recorder", "SOUNDREC.EXE"}}},
    {name = "Games", items = {{"Solitaire", "SOL.EXE"}, {"Minesweeper", "WINMINE.EXE"}}},
    {name = "StartUp", items = {}},
}

-- Reads [progman.groups] and its group sections from SETUP.INF.
local function fromInf(text)
    local sections, order = {}, {}
    local cur
    for line in (text .. "\n"):gmatch("([^\n]*)\n") do
        line = line:gsub("\r", ""):gsub("^%s+", "")
        local s = line:match("^%[([^%]]+)%]")
        if s then
            cur = s:lower()
            sections[cur] = sections[cur] or {}
            order[#order + 1] = cur
        elseif cur and line ~= "" and not line:match("^;") then
            local t = sections[cur]
            t[#t + 1] = line
        end
    end
    local list = sections["progman.groups"]
    if not list then return nil end
    -- the Setup groups, in Windows 3.1's display order: Main, Accessories, Games, StartUp
    local groups = {}
    for _, line in ipairs(list) do
        local key, val = line:match("^(%S+)%s*=%s*(.-)%s*$")
        if key then
            local name = val:match("^([^,]+)")
            local items = {}
            for _, l in ipairs(sections[key:lower()] or {}) do
                local fields = {}
                for f in (l .. ","):gmatch('%s*("?[^,]-"?)%s*,') do fields[#fields + 1] = (f:gsub('^"(.*)"$', "%1")) end
                if fields[1] and fields[2] and fields[2] ~= "" then
                    items[#items + 1] = {fields[1], fields[2], fields[3] ~= "" and fields[3] or nil, fields[4] ~= "" and fields[4] or nil}
                end
            end
            groups[#groups + 1] = {name = name, items = items}
        end
    end
    local rank = {MAIN = 1, ACCESSORIES = 2, GAMES = 3, STARTUP = 4}
    table.sort(groups, function(a, b) return (rank[a.name:upper()] or 9) < (rank[b.name:upper()] or 9) end)
    return #groups > 0 and groups or nil
end

function setup.commands()
    local inf = dosfs.read(dosfs.system .. "\\SETUP.INF")
    local groups = inf and fromInf(inf) or BUILTIN
    -- with a games folder, the Games group is its shortcuts instead
    local games = require("win16.games")
    if games.hostDir() then
        local items = {}
        for _, w in ipairs(games.scan()) do items[#items + 1] = {w.name, w.command} end
        local found = false
        for i, g in ipairs(groups) do
            if g.name:upper() == games.GROUP:upper() then groups[i] = {name = g.name, items = items}; found = true end
        end
        if not found then table.insert(groups, math.min(3, #groups + 1), {name = games.GROUP, items = items}) end
    end
    local cmds = {}
    for _, g in ipairs(groups) do
        cmds[#cmds + 1] = "[CreateGroup(" .. g.name .. ")]"
        for _, it in ipairs(g.items) do
            local args = it[2] .. "," .. games.arg(it[1])
            if it[3] then args = args .. "," .. it[3] .. "," .. (it[4] or "0") end
            cmds[#cmds + 1] = "[AddItem(" .. args .. ")]"
        end
    end
    -- as after Setup: Main open, the other groups minimized at the bottom
    for _, g in ipairs(groups) do
        if g.name:upper() ~= "MAIN" then cmds[#cmds + 1] = "[ShowGroup(" .. g.name .. ",2)]" end
    end
    cmds[#cmds + 1] = "[ShowGroup(Main,1)]"
    return cmds
end

function setup.start(done)
    return setup.converse(setup.commands(), done)
end

-- Runs a DDE conversation from a hidden window of our own, one command
-- per acknowledgement, while Program Manager's own message loop runs.
function setup.converse(cmds, done)
    local state = {i = 0, server = nil}
    local client
    local function sendNext()
        state.i = state.i + 1
        local cmd = cmds[state.i]
        if not cmd then
            user.post(state.server, WM.DDE_TERMINATE, client.handle, 0)
            if done then done() end
            return
        end
        local h = kernel.galloc(0x2042, #cmd + 1)   -- GMEM_DDESHARE | GMEM_MOVEABLE | ZEROINIT
        mem.write(kernel.glin(h), cmd .. "\0")
        state.pending = h
        user.post(state.server, WM.DDE_EXECUTE, client.handle, api.mklong(0, h))
    end
    local proc = user.luaProc("SetupDdeClient", function(hwnd, msg, wp, lp)
        if msg == WM.DDE_ACK then
            if not state.server then
                state.server = W(wp)
                for _, a in ipairs({lp & 0xFFFF, lp >> 16}) do
                    if user.atomRefs[a] then api.byName["USER.GLOBALDELETEATOM"].fn(a) end
                end
                return 0
            end
            local h = lp >> 16
            if h == state.pending then kernel.gfree(h); state.pending = nil end
            if (lp & 0x8000) == 0 then
                host.log("Setup: Program Manager didn't accept " .. tostring(cmds[state.i]))
            end
            sendNext()
            return 0
        elseif msg == WM.DDE_TERMINATE then
            return 0
        end
        return user.defwnd.proc(hwnd, msg, wp, lp)
    end)
    user.registerClass({name = "Progman31Setup", proc = proc})
    client = user.create("Progman31Setup", "Setup", 0, 0, 0, 0, 0, nil, 0, 0, 0, 0)
    if not client then return false end
    -- WM_DDE_INITIATE to every top-level window: PROGMAN / PROGMAN
    local app = user.addAtom("PROGMAN")
    local topic = user.addAtom("PROGMAN")
    local list = {}
    for _, c in ipairs(user.desktop.children) do if c ~= client then list[#list + 1] = c end end
    for _, c in ipairs(list) do
        if not state.server then user.send(c, WM.DDE_INITIATE, client.handle, api.mklong(app, topic)) end
    end
    if not state.server then
        host.log("Setup: Program Manager didn't answer DDE")
        if done then done() end
        return false
    end
    host.log(string.format("Setup: sending Program Manager %d commands", #cmds))
    sendNext()
    return true
end

return setup

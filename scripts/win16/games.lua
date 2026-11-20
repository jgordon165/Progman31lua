-- The Games group shows the games folder beside the program: every
-- shortcut (.lnk, .url) in it or in the folders inside it becomes an item.
-- The folder appears to Program Manager as C:\WINDOWS\GAMES, long names
-- as 8.3 aliases (C:\WINDOWS\GAMES\ONEMUS~1\ONEMUS~1.LNK), and the group
-- is brought up to date over DDE each time Program Manager starts: items
-- for shortcuts that are gone are deleted, new ones added, the rest (and
-- anything the user added by hand) left where they are.

local dosfs = require("win16.dosfs")
local profile = require("win16.profile")

local games = {}

games.MOUNT = "C:\\WINDOWS\\GAMES"
games.GROUP = "Games"
games.EXTENSIONS = {LNK = true, URL = true}
games.MAX_DEPTH = 4
-- Setup's own Games items, replaced by the folder's
games.SETUP_ITEMS = {["SOL.EXE"] = true, ["WINMINE.EXE"] = true}

local isWindows = host.platform() == "Windows"
local sep = isWindows and "\\" or "/"

local hostDir

-- Mounts the games folder (default: "games" beside the program; --games
-- <dir> to choose another). Returns its host path, or nil without one.
function games.init(opt)
    hostDir = nil
    local dir = type(opt) == "string" and opt or nil
    if not dir then
        local base = host.base_path()
        dir = base .. "games"
        if not host.stat(dir) then
            local found = dosfs.findCi(base:gsub("[\\/]$", ""), "games")
            if found then dir = found end
        end
    end
    dir = dir:gsub("[\\/]$", "")
    local st = host.stat(dir)
    if not st or not st.dir then dosfs.mount(games.MOUNT, nil); return nil end
    hostDir = dir
    dosfs.mount(games.MOUNT, dir)
    return dir
end

function games.hostDir() return hostDir end

-- The shortcuts in the games folder: {name=, command=, host=}, sorted by name.
function games.scan()
    local out = {}
    if not hostDir then return out end
    local function walk(dir, dos, depth)
        local _, names = dosfs.shortNames(dir)
        for _, n in ipairs(names) do
            local e = n.entry
            if e.dir then
                if depth < games.MAX_DEPTH then walk(dir .. sep .. e.name, dos .. "\\" .. n.alias, depth + 1) end
            else
                local ext = (e.name:match("%.([^.]+)$") or ""):upper()
                if games.EXTENSIONS[ext] then
                    local name = e.name:sub(1, #e.name - #ext - 1):gsub("%s+$", "")
                    if #name > 40 then name = name:sub(1, 40) end
                    out[#out + 1] = {name = name, command = dos .. "\\" .. n.alias, host = dir .. sep .. e.name}
                end
            end
        end
    end
    walk(hostDir, games.MOUNT, 1)
    table.sort(out, function(a, b)
        local x, y = a.name:upper(), b.name:upper()
        if x ~= y then return x < y end
        return a.command < b.command
    end)
    return out
end

-- ---- shortcuts --------------------------------------------------------------------

local function utf16(s)
    local out = {}
    local i = 1
    while i + 1 <= #s do
        local c = string.unpack("<I2", s, i)
        i = i + 2
        if c == 0 then break end
        if c >= 0xD800 and c <= 0xDBFF and i + 1 <= #s then
            local lo = string.unpack("<I2", s, i)
            if lo >= 0xDC00 and lo <= 0xDFFF then
                c = 0x10000 + ((c - 0xD800) << 10) + (lo - 0xDC00)
                i = i + 2
            end
        end
        out[#out + 1] = utf8.char(c)
    end
    return table.concat(out)
end

local function latin1(s)
    s = s:match("^([^%z]*)") or ""
    return (s:gsub("[\128-\255]", function(c) return utf8.char(c:byte()) end))
end

local function cstrAt(data, off)
    return data:match("^([^%z]*)", off + 1) or ""
end

local function wstrAt(data, off)
    return utf16(data:sub(off + 1))
end

local function expand(s)
    return (s:gsub("%%([^%%]+)%%", function(v) return os.getenv(v) or os.getenv(v:upper()) end))
end

local function dirOf(p) return p:match("^(.*)[\\/][^\\/]*$") or "." end

local function absolute(p, base)
    if p == "" then return nil end
    if p:match("^%a:[\\/]") or p:match("^[\\/]") then return p end
    if sep == "/" then p = p:gsub("\\", "/") end
    return base .. sep .. p:gsub("^%.[\\/]", "")
end

-- Parses a Windows shortcut (.lnk): returns {target=, icon=, iconIndex=}
-- with host paths, as far as the link says.
function games.parseLnk(data)
    if #data < 0x4C or string.unpack("<I4", data, 1) ~= 0x4C then return nil end
    local flags = string.unpack("<I4", data, 0x15)
    local iconIndex = string.unpack("<i4", data, 0x39)
    local unicode = flags & 0x80 ~= 0
    local pos = 0x4C
    local r = {iconIndex = iconIndex}
    if flags & 0x1 ~= 0 then
        pos = pos + 2 + string.unpack("<I2", data, pos + 1)
    end
    if flags & 0x2 ~= 0 and pos + 28 <= #data then
        local size, hsize, liFlags = string.unpack("<I4I4I4", data, pos + 1)
        local localOff, _, suffixOff = string.unpack("<I4I4I4", data, pos + 17)
        if liFlags & 1 ~= 0 then
            local base, suffix
            if hsize >= 0x24 then
                local lu, su = string.unpack("<I4I4", data, pos + 29)
                if lu > 0 then base = wstrAt(data, pos + lu) end
                if su > 0 then suffix = wstrAt(data, pos + su) end
            end
            base = base or latin1(cstrAt(data, pos + localOff))
            suffix = suffix or latin1(cstrAt(data, pos + suffixOff))
            if base ~= "" then r.target = base .. suffix end
        end
        pos = pos + size
    end
    local strings = {}
    for _, f in ipairs({{0x4, "name"}, {0x8, "relative"}, {0x10, "workdir"}, {0x20, "args"}, {0x40, "icon"}}) do
        if flags & f[1] ~= 0 and pos + 2 <= #data then
            local n = string.unpack("<I2", data, pos + 1)
            local bytes = unicode and n * 2 or n
            local raw = data:sub(pos + 3, pos + 2 + bytes)
            strings[f[2]] = unicode and utf16(raw .. "\0\0") or latin1(raw)
            pos = pos + 2 + bytes
        end
    end
    r.relative, r.workdir, r.args = strings.relative, strings.workdir, strings.args
    r.icon = strings.icon
    -- extra data: targets and icons with environment variables in them
    while pos + 8 <= #data do
        local size, sig = string.unpack("<I4I4", data, pos + 1)
        if size < 8 then break end
        if sig == 0xA0000001 or sig == 0xA0000007 then
            local w = utf16(data:sub(pos + 9 + 260, pos + size))
            local a = latin1(data:sub(pos + 9, pos + 8 + 260))
            local v = w ~= "" and w or a
            if v ~= "" then
                if sig == 0xA0000001 then r.envTarget = v else r.envIcon = v end
            end
        end
        pos = pos + size
    end
    return r
end

-- Parses an Internet shortcut (.url): {target=url, icon=, iconIndex=}.
function games.parseUrl(text)
    local r = {}
    local inSection = false
    for line in (text .. "\n"):gmatch("([^\r\n]*)\r?\n") do
        local s = line:match("^%s*%[(.-)%]")
        if s then
            inSection = s:lower() == "internetshortcut"
        elseif inSection then
            local k, v = line:match("^%s*([^=]-)%s*=%s*(.-)%s*$")
            if k then
                k = k:lower()
                if k == "url" then r.target = v
                elseif k == "iconfile" then r.icon = v
                elseif k == "iconindex" then r.iconIndex = tonumber(v) end
            end
        end
    end
    return r
end

-- Where a shortcut's icon comes from: a list of {path=, index=} host
-- files to try in turn.
function games.iconSources(path)
    local data = host.read(path, false)
    if not data then return {} end
    local ext = (path:match("%.([^.\\/]+)$") or ""):upper()
    local base = dirOf(path)
    local out = {}
    local function add(p, index)
        if not p or p == "" then return end
        p = expand(p):gsub('^"(.*)"$', "%1")
        if p:match("^%a+://") then return end
        p = absolute(p, base)
        if p and host.stat(p) and not host.stat(p).dir then out[#out + 1] = {path = p, index = index or 0} end
    end
    if ext == "LNK" then
        local l = games.parseLnk(data)
        if not l then return out end
        add(l.envIcon, l.iconIndex)
        add(l.icon, l.iconIndex)
        add(l.envTarget, 0)
        add(l.target, 0)
        if l.relative then add(l.relative, 0) end
    elseif ext == "URL" then
        local u = games.parseUrl(data)
        add(u.icon, u.iconIndex or 0)
    end
    return out
end

-- ---- keeping the group up to date ---------------------------------------------------

-- The group file of the group called `name`, from PROGMAN.INI: its DOS path.
local function groupFile(name)
    local ini = dosfs.windows .. "\\PROGMAN.INI"
    for _, k in ipairs(profile.keys(ini, "Groups")) do
        if k:upper():match("^GROUP%d+$") then
            local f = profile.get(ini, "Groups", k)
            local g = f and games.readGroup(f)
            if g and g.name:upper() == name:upper() then return f, g end
        end
    end
end

-- Reads a Windows 3.1 .GRP file: {name=, show=, items={{name=, command=}}}.
function games.readGroup(dos)
    local data = dosfs.read(dos)
    if not data or #data < 34 or data:sub(1, 4) ~= "PMCC" then return nil end
    local function str(off) return off > 0 and cstrAt(data, off) or "" end
    local show = string.unpack("<I2", data, 9)
    local g = {name = str(string.unpack("<I2", data, 23)), show = show, items = {}}
    local count = string.unpack("<I2", data, 33)
    for i = 0, count - 1 do
        local at = 34 + i * 2
        if at + 2 > #data then break end
        local off = string.unpack("<I2", data, at + 1)
        if off > 0 and off + 24 <= #data then
            local pName, pCommand = string.unpack("<I2I2", data, off + 19)
            g.items[#g.items + 1] = {name = str(pName), command = str(pCommand)}
        end
    end
    return g
end

-- A DDE argument: quoted when it holds anything the command parser splits on.
local function arg(s)
    if s:find('[,()%[%]"]') or s:match("^%s") or s:match("%s$") then
        return '"' .. s:gsub('"', "'") .. '"'
    end
    return s
end
games.arg = arg

-- The DDE commands that bring the Games group up to date (nil: nothing to do).
function games.syncCommands()
    if not hostDir then return nil end
    local wanted = games.scan()
    local _, g = groupFile(games.GROUP)
    local have = {}
    -- the commands act on the current group: make it Games
    local cmds = {g and ("[ShowGroup(" .. games.GROUP .. ",1)]") or ("[CreateGroup(" .. games.GROUP .. ")]")}
    local changed = not g
    local mount = games.MOUNT .. "\\"
    if g then
        local want = {}
        for _, w in ipairs(wanted) do want[w.command:upper()] = w end
        for _, it in ipairs(g.items) do
            local c = dosfs.full((it.command:match('^"([^"]*)"') or it.command:match("^(%S*)")) or "")
            local exe = c:match("([^\\]+)$") or ""
            local ours = c:sub(1, #mount) == mount
            if (ours and not (want[c] and want[c].name == it.name)) or (not ours and games.SETUP_ITEMS[exe]) then
                cmds[#cmds + 1] = "[DeleteItem(" .. arg(it.name) .. ")]"
                changed = true
            elseif ours then
                have[c] = true
            end
        end
    end
    for _, w in ipairs(wanted) do
        if not have[w.command:upper()] then
            cmds[#cmds + 1] = "[AddItem(" .. w.command .. "," .. arg(w.name) .. ")]"
            changed = true
        end
    end
    if not changed then return nil end
    -- as it was: minimized groups stay minimized (without taking the focus)
    local show = 7
    if g and (g.show == 1 or g.show == 3) then show = g.show end
    cmds[#cmds + 1] = "[ShowGroup(" .. games.GROUP .. "," .. show .. ")]"
    return cmds
end

-- Runs the update over DDE once Program Manager is idle.
function games.sync(done)
    local cmds = games.syncCommands()
    if not cmds then
        if done then done() end
        return false
    end
    host.log(string.format("Games: updating the Games group from %s", hostDir))
    return require("win16.setup").converse(cmds, done)
end

return games

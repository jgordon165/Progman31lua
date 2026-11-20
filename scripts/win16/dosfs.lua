-- The DOS file system Program Manager sees.
--
--   C:\WINDOWS (and below) -> <home>\WINDOWS, a per-user folder holding
--                             PROGMAN.INI, WIN.INI and the .GRP files. Reads
--                             fall back to the Windows 3.1 files (--data):
--                             C:\WINDOWS\NOTEPAD.EXE comes from the setup
--                             disk's NOTEPAD.EX_, expanded, read-only.
--   mounted folders        -> a host folder shown under a DOS path
--                             (C:\WINDOWS\GAMES is the games folder beside
--                             the program), long names as 8.3 aliases
--                             (MEGARA~1.LNK) as Windows 95 makes them
--   other paths            -> the real drives on Windows (C:\Program Files\...
--                             is the real one); elsewhere C:\ is the home folder.
--
-- Files are read whole into memory when opened and written back on close.

local dosfs = {}

local windowsHost = nil   -- <home>/WINDOWS
local homeRoot = nil
local dataDir = nil
local isWindows = host.platform() == "Windows"
local sep = isWindows and "\\" or "/"

dosfs.windows = "C:\\WINDOWS"
dosfs.system = "C:\\WINDOWS\\SYSTEM"
dosfs.cwd = "C:\\WINDOWS"

function dosfs.init(home, data)
    homeRoot = home
    windowsHost = home .. sep .. "WINDOWS"
    host.mkdir(windowsHost)
    host.mkdir(windowsHost .. sep .. "SYSTEM")
    dataDir = data
end

function dosfs.dataDir() return dataDir end
function dosfs.windowsHost() return windowsHost end

-- Upper-cases, turns / into \, resolves . and .., and makes the path absolute
-- against the current directory.
function dosfs.full(p)
    p = (p or ""):gsub("/", "\\")
    local drive = p:match("^(%a):")
    local rest
    if drive then
        rest = p:sub(3)
        if rest:sub(1, 1) ~= "\\" then
            if drive:upper() == dosfs.cwd:sub(1, 1) then rest = dosfs.cwd:sub(3) .. "\\" .. rest else rest = "\\" .. rest end
        end
    else
        drive = dosfs.cwd:sub(1, 1)
        if p:sub(1, 1) == "\\" then rest = p else rest = dosfs.cwd:sub(3) .. "\\" .. p end
    end
    local parts = {}
    for part in rest:gmatch("[^\\]+") do
        if part == ".." then parts[#parts] = nil
        elseif part ~= "." then parts[#parts + 1] = part end
    end
    return drive:upper() .. ":\\" .. table.concat(parts, "\\"):upper()
end

-- Finds name in a host folder ignoring case (the host may be case-sensitive).
local function findCi(dir, name)
    local list = host.list(dir)
    if not list then return nil end
    local want = name:upper()
    for _, e in ipairs(list) do
        if e.name:upper() == want then return dir .. sep .. e.name, e end
    end
end
dosfs.findCi = findCi

-- ---- mounted folders ------------------------------------------------------------

local mounts = {}   -- {dos = "C:\\WINDOWS\\GAMES", host = "/.../games"}

function dosfs.mount(dos, hostDir)
    local full = dosfs.full(dos)
    for i = #mounts, 1, -1 do if mounts[i].dos == full then table.remove(mounts, i) end end
    if hostDir then mounts[#mounts + 1] = {dos = full, host = hostDir} end
end


-- The 8.3 names of a host folder's entries: returns alias -> entry and an
-- array of {alias=, entry=} in name order. A name that is already 8.3 is
-- its own alias; others are BASE~N.EXT.
function dosfs.shortNames(dir)
    local list = host.list(dir) or {}
    table.sort(list, function(a, b) return a.name:upper() < b.name:upper() end)
    local byAlias, out = {}, {}
    local pending = {}
    for _, e in ipairs(list) do
        local up = e.name:upper()
        local b, x = up:match("^([^.]+)%.?([^.]*)$")
        if b and #b <= 8 and #x <= 3 and not (b .. x):find("[^%w_!#%$%%&'%(%)@%^`{}~%-]") and not byAlias[up] then
            byAlias[up] = e
            out[#out + 1] = {alias = up, entry = e}
        else
            pending[#pending + 1] = e
        end
    end
    for _, e in ipairs(pending) do
        local up = e.name:upper()
        local ext = up:match("%.([^.]*)$") or ""
        local base = ext ~= "" and up:sub(1, #up - #ext - 1) or up
        base = base:gsub("[^%w_!#%$%%&'%(%)@%^`{}~%-]", "")
        ext = ext:gsub("[^%w_!#%$%%&'%(%)@%^`{}~%-]", ""):sub(1, 3)
        if base == "" then base = "_" end
        local alias
        for n = 1, 99999 do
            local tail = "~" .. n
            alias = base:sub(1, 8 - #tail) .. tail .. (ext ~= "" and ("." .. ext) or "")
            if not byAlias[alias] then break end
        end
        byAlias[alias] = e
        out[#out + 1] = {alias = alias, entry = e}
    end
    table.sort(out, function(a, b) return a.entry.name:upper() < b.entry.name:upper() end)
    return byAlias, out
end

local function mountOf(full)
    for _, m in ipairs(mounts) do
        if full == m.dos or full:sub(1, #m.dos + 1) == m.dos .. "\\" then return m end
    end
end

local function underWindows(full)
    local w = dosfs.windows
    return full == w or full:sub(1, #w + 1) == w .. "\\"
end

-- The host path for a DOS path (existing components matched ignoring case;
-- new ones upper case). For C:\WINDOWS\..., the home folder.
function dosfs.hostPath(dos)
    local full = dosfs.full(dos)
    local dir, rel
    local m = mountOf(full)
    if m then
        dir = m.host
        for part in full:sub(#m.dos + 2):gmatch("[^\\]+") do
            local e = dosfs.shortNames(dir)[part]
            dir = e and (dir .. sep .. e.name) or findCi(dir, part) or (dir .. sep .. part)
        end
        return dir
    end
    if underWindows(full) then
        dir, rel = windowsHost, full:sub(#dosfs.windows + 2)
    elseif isWindows then
        dir, rel = full:sub(1, 2), full:sub(4)
    else
        if full:sub(1, 1) ~= "C" then return nil end
        dir, rel = homeRoot, full:sub(4)
    end
    for part in rel:gmatch("[^\\]+") do
        local found = findCi(dir, part)
        dir = found or (dir .. sep .. part)
    end
    return dir
end

-- For a file in C:\WINDOWS that isn't there: the same file from the setup
-- disk, or its compressed form (NOTEPAD.EX_). Returns the expanded bytes.
-- Setup files that Windows keeps in SYSTEM only (Control Panel looks for
-- SETUP.INF and CONTROL.INF there, and finds its applets there)
local SYSTEM_ONLY = {INF = true, CPL = true}

local function fromData(full)
    if not dataDir or not underWindows(full) then return nil end
    local name = full:match("([^\\]+)$")
    if not name then return nil end
    local ext = name:upper():match("%.(%w+)$")
    if ext and SYSTEM_ONLY[ext] and full:upper() ~= (dosfs.system .. "\\" .. name):upper() then return nil end
    local p = findCi(dataDir, name)
    if not p then
        local sub = findCi(dataDir, "WINDOWS")
        if sub then p = findCi(sub, name) end
    end
    if not p and #name >= 2 then
        local packed = name:sub(1, -2) .. "_"
        if not name:find("%.") then packed = nil end
        if packed then p = findCi(dataDir, packed) end
    end
    if not p then return nil end
    return host.read(p, true)
end

function dosfs.exists(dos)
    local full = dosfs.full(dos)
    local hp = dosfs.hostPath(full)
    if hp and host.stat(hp) then return true, host.stat(hp).dir end
    return fromData(full) ~= nil, false
end

-- The bytes of a file (from the home or the setup disk). nil when missing.
function dosfs.read(dos)
    local full = dosfs.full(dos)
    local hp = dosfs.hostPath(full)
    if hp then
        local st = host.stat(hp)
        if st and not st.dir then return host.read(hp, false) end
    end
    return fromData(full)
end

function dosfs.write(dos, bytes)
    local hp = dosfs.hostPath(dos)
    if not hp then return false end
    return host.write(hp, bytes)
end

-- ---- open files -------------------------------------------------------------------

local files = {}       -- handle -> {path=, data=, pos=, writable=, dirty=}
local nextHandle = 5   -- 0..4 are the DOS standard handles

-- mode: 0 read, 1 write, 2 read/write; create: truncate or make a new file.
function dosfs.open(dos, mode, create)
    local full = dosfs.full(dos)
    local data
    if create then
        data = ""
        if not dosfs.write(full, "") then return nil, 3 end   -- path not found
    else
        data = dosfs.read(full)
        if not data then return nil, 2 end                    -- file not found
    end
    local h = nextHandle
    while files[h] do h = h + 1 end
    nextHandle = h + 1
    files[h] = {path = full, data = data, pos = 0, writable = create or mode ~= 0, dirty = create}
    return h
end

function dosfs.file(h) return files[h] end

function dosfs.close(h)
    local f = files[h]
    if not f then return false end
    files[h] = nil
    if h < nextHandle then nextHandle = math.max(5, h) end
    if f.dirty then dosfs.write(f.path, f.data) end
    return true
end

function dosfs.readh(h, n)
    local f = files[h]
    if not f then return nil end
    local s = f.data:sub(f.pos + 1, f.pos + n)
    f.pos = f.pos + #s
    return s
end

function dosfs.writeh(h, s)
    local f = files[h]
    if not f or not f.writable then return nil end
    if #s == 0 then   -- a zero-byte write truncates at the position
        f.data = f.data:sub(1, f.pos)
    else
        if f.pos > #f.data then f.data = f.data .. string.rep("\0", f.pos - #f.data) end
        f.data = f.data:sub(1, f.pos) .. s .. f.data:sub(f.pos + #s + 1)
        f.pos = f.pos + #s
    end
    f.dirty = true
    return #s
end

function dosfs.seek(h, off, origin)
    local f = files[h]
    if not f then return nil end
    local p = origin == 0 and off or origin == 1 and f.pos + off or #f.data + off
    if p < 0 then return nil end
    f.pos = p
    return p
end

-- ---- directories --------------------------------------------------------------------

-- Lists a directory matching a DOS wildcard (*.EXE, NAME?.*). Returns
-- {name=, dir=, size=} entries.
function dosfs.find(pattern)
    local full = dosfs.full(pattern)
    local dir, spec = full:match("^(.*)\\([^\\]*)$")
    if dir:sub(-1) == ":" then dir = dir .. "\\" end
    local hp = dosfs.hostPath(dir)
    local out, seen = {}, {}
    local mounted = mountOf(dir)
    local function match(name)
        local n, e = name:match("^([^.]*)%.?(.*)$")
        local sn, se = spec:match("^([^.]*)%.?(.*)$")
        local function m(a, p)
            if p == "*" then return true end
            if #p < #a and not p:find("%*") then return false end
            for i = 1, math.max(#a, #p) do
                local pc = p:sub(i, i)
                if pc == "*" then return true end
                if pc ~= "?" and pc ~= a:sub(i, i) then return false end
            end
            return true
        end
        return m(n, sn) and m(e, se)
    end
    local entries = hp and host.list(hp) or {}
    if mounted and hp then
        local _, names = dosfs.shortNames(hp)
        entries = {}
        for _, n in ipairs(names) do entries[#entries + 1] = {name = n.alias, dir = n.entry.dir, size = n.entry.size} end
    end
    for _, e in ipairs(entries) do
        local up = e.name:upper()
        if #up <= 12 and match(up) then
            out[#out + 1] = {name = up, dir = e.dir, size = e.size}
            seen[up] = true
        end
    end
    if not mounted and underWindows(dir .. "\\X") and dataDir then
        for _, e in ipairs(host.list(dataDir) or {}) do
            local up = e.name:upper()
            if up:sub(-1) == "_" and not e.dir then
                local bytes = nil
                local real = up   -- the setup name; the expanded name needs the header
                local p = dataDir .. sep .. e.name
                local head = host.read(p, false)
                if head then real = host.expanded_name(head, up):upper() end
                if not seen[real] and match(real) then
                    out[#out + 1] = {name = real, dir = false, size = e.size}
                    seen[real] = true
                end
                bytes = nil
            elseif not e.dir and not seen[up] and match(up) then
                out[#out + 1] = {name = up, dir = false, size = e.size}
                seen[up] = true
            end
        end
    end
    table.sort(out, function(a, b) return a.name < b.name end)
    return out
end

function dosfs.remove(dos) local hp = dosfs.hostPath(dos); return hp and host.remove(hp) end
function dosfs.rename(a, b)
    local ha, hb = dosfs.hostPath(a), dosfs.hostPath(b)
    return ha and hb and host.rename(ha, hb)
end
function dosfs.mkdir(dos) local hp = dosfs.hostPath(dos); return hp and host.mkdir(hp) end

-- For launching: the host file a DOS program path names, when it exists there.
function dosfs.hostFile(dos)
    local hp = dosfs.hostPath(dos)
    if hp and host.stat(hp) then return hp end
end

return dosfs

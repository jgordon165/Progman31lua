-- SHELL.DLL: starting programs and documents, icons from files
-- (ExtractIcon and friends, from 16-bit programs, modern ones and .ICO
-- files), the About box, and file drops.

local api = require("win16.api")
local cpu = require("recomp.cpu")
local dosfs = require("win16.dosfs")
local gdi = require("win16.gdi")
local kernel = require("win16.kernel")
local ne = require("recomp.ne")
local pe = require("win16.pe")
local profile = require("win16.profile")
local res = require("win16.resources")
local user = require("win16.user")

local def = api.def
local ww = mem.ww

local shell = {}

-- A program's full DOS path: as given, or found in the current folder, the
-- Windows folder, SYSTEM, or on the PATH (here: the same).
function shell.resolve(name)
    if not name or name == "" then return nil end
    name = name:gsub('^"(.*)"$', "%1")
    local function try(p)
        local full = dosfs.full(p)
        local ok, isdir = dosfs.exists(full)
        if ok and not isdir then return full end
        if not full:match("%.[^\\]*$") then
            for _, ext in ipairs({".EXE", ".COM", ".PIF", ".BAT"}) do
                ok, isdir = dosfs.exists(full .. ext)
                if ok and not isdir then return full .. ext end
            end
        end
    end
    if name:find("[\\:/]") then return try(name) end
    return try(name) or try(dosfs.windows .. "\\" .. name) or try(dosfs.system .. "\\" .. name)
end

-- The program a document opens with: [Extensions] in WIN.INI ("txt=notepad.exe ^.txt").
function shell.association(path)
    local ext = path:match("%.([^.\\]+)$")
    if not ext then return nil end
    local v = profile.get(profile.resolve(nil), "Extensions", ext)
    if not v then return nil end
    return (v:match("^(%S+)"))
end

-- Icons in a file's bytes: returns count, and a function index -> HICON
-- (false: not a program or icon file).
local function iconsOfData(data, name)
    if data:sub(1, 2) == "MZ" then
        local m = ne.parse(data, name)
        if m then
            local groups = res.iconGroups(m)
            return #groups, function(i)
                local g = groups[i + 1]
                if not g then return nil end
                return res.iconFromModule(m, g.id or g.name)
            end
        end
        if pe.isPE(data) then
            return pe.iconCount(data), function(i)
                local bytes = pe.iconBytes(data, i, gdi)
                return bytes and res.newIcon(bytes)
            end
        end
        return 0, function() return nil end
    end
    if #data >= 6 and string.unpack("<I2I2", data, 1) == 0 and string.unpack("<I2", data, 3) == 1 then
        return 1, function(i)
            if i ~= 0 then return nil end
            local bytes = pe.icoBytes(data, gdi)
            return bytes and res.newIcon(bytes) or (res.iconFromIco(data, 0))
        end
    end
    return false
end

-- A shortcut's one icon: the one it names, else its target's.
local function iconsOfShortcut(hostPath)
    local sources = require("win16.games").iconSources(hostPath)
    return 1, function(i)
        if i ~= 0 then return nil end
        for _, src in ipairs(sources) do
            -- (a huge single-file game isn't read whole just for its icon)
            local st = host.stat(src.path)
            local data = st and (st.size or 0) <= 256 * 1024 * 1024 and host.read(src.path, false)
            local n, get
            if data then n, get = iconsOfData(data, src.path:match("([^\\/]+)$")) end
            if n and n > 0 then
                local idx = src.index or 0
                local h
                if idx < 0 and data:sub(1, 2) == "MZ" and pe.isPE(data) then
                    local bytes = pe.iconBytes(data, idx, gdi)
                    h = bytes and res.newIcon(bytes)
                else
                    h = get(idx >= 0 and idx < n and idx or 0)
                end
                if h then return h end
            end
        end
        return nil
    end
end

-- Icons in a file: returns count, and a function index -> HICON.
local function iconsOf(path)
    local full = shell.resolve(path)
    if not full then return nil end
    local ext = (full:match("%.([^.\\]+)$") or "")
    if ext == "LNK" or ext == "URL" then
        local hp = dosfs.hostFile(full)
        if hp then return iconsOfShortcut(hp) end
    end
    local data = dosfs.read(full)
    if not data then return nil end
    return iconsOfData(data, full)
end

function shell.extractIcon(path, index)
    local n, get = iconsOf(path)
    if n == nil then return 0 end          -- no such file
    if n == false then return 1 end        -- not a program or icon file
    if index == 0xFFFF or index == -1 then return n end
    return get(index) or 0
end

def("SHELL", 34, "ExtractIcon", "h s w", function(inst, file, index)
    return shell.extractIcon(file, index)
end)

-- InternalExtractIcon(inst, file, first, count): a global block of HICONs
def("SHELL", 39, "InternalExtractIcon", "h s w w", function(inst, file, first, count)
    local n, get = iconsOf(file or "")
    if not n or n == false or n == 0 then return 0 end
    count = math.min(count, n - first)
    if count <= 0 then return 0 end
    local h = kernel.galloc(0x40, count * 2)
    local lin = kernel.glin(h)
    for i = 0, count - 1 do ww(lin + i * 2, get(first + i) or 0) end
    return h
end)

-- ExtractAssociatedIcon(inst, lpIconPath, lpiIcon): the file's own icon,
-- else its program's, else a default.
def("SHELL", 36, "ExtractAssociatedIcon", "h p p", function(inst, pPath, pIndex)
    if not pPath then return 0 end
    local path = mem.cstr(pPath)
    local idx = pIndex and mem.rw(pIndex) or 0
    local h = shell.extractIcon(path, idx)
    if h > 1 then return h end
    local exe = shell.association(path)
    if exe then
        local full = shell.resolve(exe)
        if full then
            h = shell.extractIcon(full, 0)
            if h > 1 then
                api.putstr(pPath, full, 128)
                if pIndex then ww(pIndex, 0) end
                return h
            end
        end
    end
    -- the default document / DOS program icons are Program Manager's own
    local m = user.module
    if m then
        local isProg = path:upper():match("%.EXE$") or path:upper():match("%.COM$") or path:upper():match("%.PIF$") or
            path:upper():match("%.BAT$")
        local groups = res.iconGroups(m)
        local which = isProg and 9 or 3
        local g = groups[which + 1] or groups[1]
        if g then
            h = res.iconFromModule(m, g.id or g.name)
            if h then
                api.putstr(pPath, "C:\\WINDOWS\\PROGMAN.EXE", 128)
                if pIndex then ww(pIndex, which) end
                return h
            end
        end
    end
    return res.systemIcon(32512) or 0
end)

def("SHELL", 20, "ShellExecute", "h s s s s i", function(hwnd, op, file, params, dir, show)
    local launch = require("win16.launch")
    return launch.shellExecute(op, file, params, dir, show)
end)
def("SHELL", 21, "FindExecutable", "s s p", function(file, dir, result)
    if not file then return 2 end
    local full = shell.resolve(file)
    if not full then return 2 end
    local exe = full
    -- shortcuts start themselves (and carry their own icons)
    local ext = full:upper():match("%.(%w+)$")
    if ext ~= "EXE" and ext ~= "COM" and ext ~= "LNK" and ext ~= "URL" then
        local a = shell.association(full)
        if not a then return 31 end
        exe = shell.resolve(a) or a
    end
    api.putstr(result, exe, 128)
    return 33
end)

def("SHELL", 22, "ShellAbout", "h s s h", function(hwnd, app, other, icon)
    local owner = user.W(hwnd)
    if owner then owner = user.topLevel(owner) end
    local title = "About " .. ((app or "Program Manager"):gsub("#.*", ""))
    local text = (app or "Program Manager"):gsub("^.*#", "") .. "\n" ..
        "Microsoft Windows Version 3.1\nCopyright \169 1985-1992 Microsoft Corp.\n\n" ..
        (other and other ~= "" and (other .. "\n\n") or "") ..
        "Running on Progman31lua: recompiled from x86 to Lua."
    user.messageBox(owner, text, title, 0x40)
    return 1
end)

def("SHELL", 37, "DoEnvironmentSubst", "p w:l", function(p, n)
    if not p then return 0 end
    local s = mem.cstr(p)
    local env = {WINDIR = dosfs.windows, PATH = dosfs.windows .. ";" .. dosfs.system, COMSPEC = "C:\\COMMAND.COM"}
    local out = s:gsub("%%(%w+)%%", function(k) return env[k:upper()] or ("%" .. k .. "%") end)
    if #out < n then
        mem.write(p, out .. "\0")
        return api.mklong(#out, 1)
    end
    return api.mklong(#s, 0)
end)

-- File drops from the host aren't wired yet: Program Manager registers, nothing arrives.
def("SHELL", 9, "DragAcceptFiles", "h w:v", function() end)
def("SHELL", 11, "DragQueryFile", "h w p w", function() return 0 end)
def("SHELL", 12, "DragFinish", "h:v", function() end)
def("SHELL", 13, "DragQueryPoint", "h p", function() return 0 end)
def("SHELL", 102, "RegisterShellHook", "h w", function() return 0 end)

return shell

-- Icons, cursors, bitmaps and strings from NE modules: Program Manager's
-- own, the display driver's (the system icons and the window-frame
-- bitmaps, OBM_*), USER.EXE's, and other programs' (ExtractIcon).

local cpu = require("recomp.cpu")
local ne = require("recomp.ne")
local gdi = require("win16.gdi")
local kernel = require("win16.kernel")
local handles = require("win16.handles")

local res = {}

res.system = {}    -- the display driver and USER.EXE modules, searched in order

-- Picks the entry of an icon group (RT_GROUP_ICON) closest to 32x32 in 16
-- colours, as Windows 3.1 on VGA did. Returns its RT_ICON id.
local function bestIcon(dir)
    local count = string.unpack("<I2", dir, 5)
    local best, bscore
    for i = 0, count - 1 do
        local at = 7 + i * 14
        local w, h, colors = dir:byte(at), dir:byte(at + 1), dir:byte(at + 2)
        local planes, bits = string.unpack("<I2I2", dir, at + 4)
        local id = string.unpack("<I2", dir, at + 12)
        if w == 0 then w = 256 end
        if h == 0 then h = 256 end
        local ncol = colors ~= 0 and colors or (1 << ((bits or 4) * (planes or 1)))
        local score = math.abs(w - 32) * 4 + math.abs(h - 32) * 4 + (ncol == 16 and 0 or ncol < 16 and 2 or 3)
        if not bscore or score < bscore then best, bscore = id, score end
    end
    return best
end

-- An HICON (a global block in the internal format) made from bytes.
function res.newIcon(bytes)
    local h = kernel.galloc(0x42, #bytes)
    mem.write(kernel.glin(h), bytes)
    kernel.global(h).icon = true
    return h
end

-- The icon of a group resource in a module: an HICON, or nil.
function res.iconFromModule(mod, key)
    local dir = mod:resource(14, key)
    if not dir then return nil end
    local id = bestIcon(dir)
    local dib = id and mod:resource(3, id)
    if not dib then return nil end
    local bytes = gdi.iconFromResource(dib)
    return bytes and res.newIcon(bytes)
end

-- Every icon group of a module, in order (ExtractIcon's indexes).
function res.iconGroups(mod)
    return mod:resourcesOf(14)
end

-- The icons of a .ICO file: an HICON for entry `index`, and the count.
function res.iconFromIco(data, index)
    if #data < 6 then return nil, 0 end
    local reserved, kind, count = string.unpack("<I2I2I2", data, 1)
    if reserved ~= 0 or kind ~= 1 then return nil, 0 end
    if index < 0 then return nil, 1 end
    -- one icon per file in Windows 3.1's sense: the best entry of the file
    local best, bscore
    for i = 0, count - 1 do
        local at = 7 + i * 16
        local w, h = data:byte(at), data:byte(at + 1)
        local off = string.unpack("<I4", data, at + 12)
        local score = math.abs((w == 0 and 256 or w) - 32) + math.abs((h == 0 and 256 or h) - 32)
        if not bscore or score < bscore then best, bscore = off, score end
    end
    if not best then return nil, 0 end
    local bytes = gdi.iconFromResource(data:sub(best + 1))
    return bytes and res.newIcon(bytes), 1
end

local loadedIcons = {}   -- "module:key" -> HICON (LoadIcon shares them)

-- System icons (IDI_*), from the display driver or USER.EXE.
function res.systemIcon(key)
    local k = "SYS:" .. tostring(key)
    if loadedIcons[k] then return loadedIcons[k] end
    for _, m in ipairs(res.system) do
        local h = res.iconFromModule(m, key)
        if h then loadedIcons[k] = h; return h end
    end
    -- IDI_APPLICATION fallback: a plain white window
    if key == 32512 then
        local h = res.newIcon(res.plainIcon())
        loadedIcons[k] = h
        return h
    end
end

function res.moduleIcon(mod, key)
    local k = (mod.name or "?") .. ":" .. tostring(key)
    if loadedIcons[k] then return loadedIcons[k] end
    local h = res.iconFromModule(mod, key)
    if h then loadedIcons[k] = h end
    return h
end

-- A 32x32 icon of a window with a blue caption, for when there's none.
function res.plainIcon()
    local w, h = 32, 32
    local andRows, xorRows = {}, {}
    for y = 0, h - 1 do
        local a, x = {}, {}
        for bx = 0, 3 do
            local byte = 0
            for k = 0, 7 do
                local px = bx * 8 + k
                if not (px >= 2 and px < 30 and y >= 4 and y < 28) then byte = byte | (0x80 >> k) end
            end
            a[#a + 1] = string.char(byte)
        end
        for px = 0, 31, 2 do
            local function c(xx)
                if not (xx >= 2 and xx < 30 and y >= 4 and y < 28) then return 0 end
                if xx == 2 or xx == 29 or y == 4 or y == 27 then return 0 end
                if y < 9 then return 4 end
                return 15
            end
            x[#x + 1] = string.char((c(px) << 4) | c(px + 1))
        end
        andRows[#andRows + 1] = table.concat(a)
        xorRows[#xorRows + 1] = table.concat(x)
    end
    return string.pack("<i2i2I2I2I2BB", 16, 16, 32, 32, 16, 1, 4) .. table.concat(andRows) .. table.concat(xorRows)
end

-- ---- cursors -----------------------------------------------------------------------------
-- The host draws the mouse pointer, so a cursor is just which one.

local CURSOR_NAMES = {[32512] = "arrow", [32513] = "ibeam", [32514] = "wait", [32515] = "cross",
                      [32516] = "arrow", [32640] = "sizeall", [32641] = "arrow", [32642] = "sizenwse",
                      [32643] = "sizenesw", [32644] = "sizewe", [32645] = "sizens"}
local cursors = {}
function res.cursor(key)
    local name = CURSOR_NAMES[key] or "arrow"
    if not cursors[name] then cursors[name] = handles.new({kind = "cursor", name = name}) end
    return cursors[name]
end

-- ---- bitmaps (OBM_*) -------------------------------------------------------------------------

local obm = {}
-- A surface for a display-driver bitmap, or nil.
function res.obm(id)
    if obm[id] ~= nil then return obm[id] or nil end
    for _, m in ipairs(res.system) do
        local b = m:resource(2, id)
        if b then
            local sid, w, h = fb.dib(b)
            if sid then obm[id] = {surface = sid, w = w, h = h}; return obm[id] end
        end
    end
    obm[id] = false
    return nil
end

-- ---- menus, accelerators, dialogs: raw resource bytes ---------------------------------------------

function res.find(mod, rtype, key)
    if not mod then return nil end
    return mod:resource(rtype, key)
end

return res

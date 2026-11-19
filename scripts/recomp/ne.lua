-- 16-bit Windows "New Executable" files, parsed in Lua: the segments and
-- relocations the loader needs, the entry table, and the resources
-- (PROGMAN.EXE itself, and the other modules whose icons, cursors, bitmaps
-- and fonts the Win16 layer reads: USER.EXE, VGA.DRV, SHELL.DLL, fonts).

local ne = {}

local u8 = function(s, at) return s:byte(at + 1) end
local function u16(s, at) return string.unpack("<I2", s, at + 1) end
local function u32(s, at) return string.unpack("<I4", s, at + 1) end
local function pstr(s, at)
    local n = s:byte(at + 1)
    return s:sub(at + 2, at + 1 + n), at + 1 + n
end

local Module = {}
Module.__index = Module

-- Parses an NE image (a Lua string). Returns a module or nil, error.
function ne.parse(data, path)
    if #data < 0x40 or data:sub(1, 2) ~= "MZ" then return nil, "not an executable" end
    local h = u32(data, 0x3C)
    if h + 0x40 > #data or data:sub(h + 1, h + 2) ~= "NE" then return nil, "not a 16-bit Windows program" end
    local m = setmetatable({data = data, path = path, ne = h}, Module)
    m.flags = u16(data, h + 0x0C)
    m.autoData = u16(data, h + 0x0E)
    m.heap = u16(data, h + 0x10)
    m.stack = u16(data, h + 0x12)
    m.ip, m.cs = u16(data, h + 0x14), u16(data, h + 0x16)
    m.sp, m.ss = u16(data, h + 0x18), u16(data, h + 0x1A)
    local nseg, nmod = u16(data, h + 0x1C), u16(data, h + 0x1E)
    local segTab = h + u16(data, h + 0x22)
    local resTab = h + u16(data, h + 0x24)
    local resNames = h + u16(data, h + 0x26)
    local modRef = h + u16(data, h + 0x28)
    local impNames = h + u16(data, h + 0x2A)
    local entTab = h + u16(data, h + 0x04)
    local entLen = u16(data, h + 0x06)
    local nonRes = u32(data, h + 0x2C)
    local nonResLen = u16(data, h + 0x20)
    local align = u16(data, h + 0x32)
    if align == 0 then align = 9 end
    m.winver = u16(data, h + 0x3E)
    m.expver = m.winver

    m.segments = {}
    for i = 1, nseg do
        local e = segTab + (i - 1) * 8
        local off, len, fl, min = u16(data, e), u16(data, e + 2), u16(data, e + 4), u16(data, e + 6)
        m.segments[i] = {
            offset = off << align, length = (off ~= 0 and len == 0) and 0x10000 or len,
            flags = fl, minalloc = min == 0 and 0x10000 or min,
            data = (fl & 1) ~= 0, hasReloc = (fl & 0x100) ~= 0,
        }
    end

    m.modules = {}
    for i = 1, nmod do
        local o = u16(data, modRef + (i - 1) * 2)
        m.modules[i] = (pstr(data, impNames + o)):upper()
    end
    m.impNames = impNames

    -- resident and non-resident names: name -> ordinal; the first is the module name
    m.names, m.ordNames = {}, {}
    local function names(at, limit)
        local first = true
        while at < limit do
            local n = data:byte(at + 1)
            if not n or n == 0 then break end
            local s
            s, at = pstr(data, at)
            local ord = u16(data, at)
            at = at + 2
            if first and not m.name then m.name = s:upper()
            else m.names[s:upper()] = ord; m.ordNames[ord] = s end
            first = false
        end
    end
    names(resNames, modRef)
    if nonRes ~= 0 and nonRes < #data then names(nonRes, nonRes + nonResLen) end

    -- entry table: ordinal -> {seg, off, exported}
    m.entries = {}
    do
        local at, ord, stop = entTab, 1, entTab + entLen
        while at < stop do
            local count, kind = data:byte(at + 1), data:byte(at + 2)
            at = at + 2
            if count == 0 then break end
            for _ = 1, count do
                if kind == 0 then
                    -- unused ordinals
                elseif kind == 0xFF then   -- movable: flags, int 3Fh, seg, off
                    m.entries[ord] = {flags = data:byte(at + 1), seg = data:byte(at + 5), off = u16(data, at + 5)}
                    at = at + 6
                elseif kind == 0xFE then   -- constant
                    m.entries[ord] = {flags = data:byte(at + 1), seg = 0, off = u16(data, at + 1), const = true}
                    at = at + 3
                else                       -- fixed, in segment `kind`
                    m.entries[ord] = {flags = data:byte(at + 1), seg = kind, off = u16(data, at + 1)}
                    at = at + 3
                end
                ord = ord + 1
            end
        end
    end

    -- resources: {type=number|string, id=number|nil, name=string|nil, offset, length}
    m.resources = {}
    if resTab ~= resNames then
        local shift = u16(data, resTab)
        local at = resTab + 2
        local function nameAt(rel) return (pstr(data, resTab + rel)):upper() end
        while true do
            local t = u16(data, at)
            if t == 0 then break end
            local count = u16(data, at + 2)
            at = at + 8
            for _ = 1, count do
                local off, len, fl, id = u16(data, at), u16(data, at + 2), u16(data, at + 4), u16(data, at + 6)
                local r = {offset = off << shift, length = len << shift, flags = fl}
                if t & 0x8000 ~= 0 then r.type = t & 0x7FFF else r.type = nameAt(t) end
                if id & 0x8000 ~= 0 then r.id = id & 0x7FFF else r.name = nameAt(id) end
                m.resources[#m.resources + 1] = r
                at = at + 12
            end
        end
    end
    return m
end

-- The bytes of segment i as stored in the file (without its relocations).
function Module:segmentBytes(i)
    local s = self.segments[i]
    if s.offset == 0 then return "" end
    return self.data:sub(s.offset + 1, s.offset + s.length)
end

-- The relocation records of segment i:
-- {src (1 byte lo,2 seg,3 far,5 off,11 far48,13 off32), additive, kind (0 internal, 1 import ordinal,
--  2 import name, 3 osfixup), offset, a, b}
function Module:relocations(i)
    local s = self.segments[i]
    if not s.hasReloc or s.offset == 0 then return {} end
    local at = s.offset + s.length
    local n = u16(self.data, at)
    at = at + 2
    local list = {}
    for k = 1, n do
        local src, ft, off, a, b = self.data:byte(at + 1), self.data:byte(at + 2), u16(self.data, at + 2),
            u16(self.data, at + 4), u16(self.data, at + 6)
        list[k] = {src = src, kind = ft & 3, additive = (ft & 4) ~= 0, offset = off, a = a, b = b}
        at = at + 8
    end
    return list
end

-- The import name for a by-name relocation.
function Module:importName(offset)
    return (pstr(self.data, self.impNames + offset))
end

-- Finds a resource. key: number (id), "#n", or a name.
function Module:findResource(rtype, key)
    if type(key) == "string" and key:sub(1, 1) == "#" then key = tonumber(key:sub(2)) end
    if type(rtype) == "string" and rtype:sub(1, 1) == "#" then rtype = tonumber(rtype:sub(2)) end
    if type(rtype) == "string" then rtype = rtype:upper() end
    if type(key) == "string" then key = key:upper() end
    for _, r in ipairs(self.resources) do
        if r.type == rtype and ((type(key) == "number" and r.id == key) or (type(key) == "string" and r.name == key)) then
            return r
        end
    end
end

function Module:resourceBytes(r)
    return self.data:sub(r.offset + 1, r.offset + r.length)
end

function Module:resource(rtype, key)
    local r = self:findResource(rtype, key)
    return r and self:resourceBytes(r), r
end

-- Every resource of a type, in file order.
function Module:resourcesOf(rtype)
    local out = {}
    for _, r in ipairs(self.resources) do
        if r.type == rtype then out[#out + 1] = r end
    end
    return out
end

-- A string-table string (blocks of 16: block id / 16 + 1).
function Module:string(id)
    local blk = self:resource(6, (id >> 4) + 1)
    if not blk then return nil end
    local at = 0
    for i = 0, 15 do
        local n = blk:byte(at + 1)
        if not n then return nil end
        if i == (id & 15) then return n > 0 and blk:sub(at + 2, at + 1 + n) or nil end
        at = at + 1 + n
    end
end

ne.u16, ne.u32, ne.pstr = u16, u32, pstr

return ne

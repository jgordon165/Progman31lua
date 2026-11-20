-- Icons from modern (PE: 32- and 64-bit) Windows programs, so items that
-- point at today's programs show their own icons. The icon closest to
-- 32x32 is taken and reduced to Windows 3.1's 16 colours.

local pe = {}

local function u16(s, at) return string.unpack("<I2", s, at + 1) end
local function u32(s, at) return string.unpack("<I4", s, at + 1) end

-- The resource directory: returns a function to look up (type, id-or-index).
local function resources(data)
    if #data < 0x40 or data:sub(1, 2) ~= "MZ" then return nil end
    local peOff = u32(data, 0x3C)
    if peOff + 24 > #data or data:sub(peOff + 1, peOff + 4) ~= "PE\0\0" then return nil end
    local nsec = u16(data, peOff + 6)
    local optSize = u16(data, peOff + 20)
    local opt = peOff + 24
    local magic = u16(data, opt)
    local dirOff = opt + (magic == 0x20B and 112 or 96)
    local rsrcRva = u32(data, dirOff + 2 * 8)
    if rsrcRva == 0 then return nil end
    local secTab = opt + optSize
    local function rvaToOff(rva)
        for i = 0, nsec - 1 do
            local s = secTab + i * 40
            local va, vsize, raw, rawSize = u32(data, s + 12), u32(data, s + 8), u32(data, s + 20), u32(data, s + 16)
            if rva >= va and rva < va + math.max(vsize, rawSize) then return rva - va + raw end
        end
    end
    local base = rvaToOff(rsrcRva)
    if not base then return nil end
    -- entries of a directory: {id or name, isDir, offset}
    local function entries(off)
        local named, ids = u16(data, base + off + 12), u16(data, base + off + 14)
        local out = {}
        for i = 0, named + ids - 1 do
            local e = base + off + 16 + i * 8
            local name, target = u32(data, e), u32(data, e + 4)
            out[#out + 1] = {id = (name & 0x80000000 == 0) and name or nil, dir = target & 0x80000000 ~= 0,
                             off = target & 0x7FFFFFFF}
        end
        return out
    end
    local function leaf(off)
        -- the first language
        local e = entries(off)
        if #e == 0 then return nil end
        local d = e[1]
        while d.dir do
            local sub = entries(d.off)
            if #sub == 0 then return nil end
            d = sub[1]
        end
        local rva, size = u32(data, base + d.off), u32(data, base + d.off + 4)
        local o = rvaToOff(rva)
        return o and data:sub(o + 1, o + size)
    end
    local top = entries(0)
    local byType = {}
    for _, t in ipairs(top) do if t.id and t.dir then byType[t.id] = t.off end end
    return {
        list = function(rtype)
            local off = byType[rtype]
            if not off then return {} end
            return entries(off)
        end,
        get = function(rtype, id)
            local off = byType[rtype]
            if not off then return nil end
            for _, e in ipairs(entries(off)) do
                if e.id == id then return e.dir and leaf(e.off) or nil end
            end
        end,
        leaf = leaf,
    }
end

function pe.isPE(data) return resources(data) ~= nil end

-- The number of icon groups in a PE file.
function pe.iconCount(data)
    local r = resources(data)
    if not r then return 0 end
    return #r.list(14)
end

-- Converts a 24/32-bit or palettized DIB icon to the internal 4-bit format.
local function convert(dib, gdi)
    if dib:sub(1, 4) == "\137PNG" then return nil end
    local hsize = string.unpack("<I4", dib, 1)
    if hsize ~= 40 then return nil end
    local w, h2, _, bpp = string.unpack("<i4i4I2I2", dib, 5)
    if bpp <= 8 then return gdi.iconFromResource(dib) end
    local h = h2 // 2
    local stride = ((w * bpp + 31) // 32) * 4
    local andStride = ((w + 31) // 32) * 4
    local bits = 41
    local andOff = bits + stride * h
    local outW, outH = 32, 32
    local andRows, xorRows = {}, {}
    local cache = {}
    for oy = 0, outH - 1 do
        local sy = h - 1 - (oy * h // outH)
        local arow, xrow = {}, {}
        local abyte, nib = 0, nil
        for ox = 0, outW - 1 do
            local sx = ox * w // outW
            local p = bits + sy * stride + sx * (bpp // 8)
            local b, g, r = dib:byte(p, p + 2)
            local a = bpp == 32 and dib:byte(p + 3) or 255
            local transparent
            if bpp == 32 and a ~= nil then
                transparent = a < 128
            else
                local ab = dib:byte(andOff + sy * andStride + (sx >> 3)) or 0
                transparent = (ab >> (7 - (sx & 7))) & 1 == 1
            end
            local idx = 0
            if not transparent then
                local c = ((r or 0) << 16) | ((g or 0) << 8) | (b or 0)
                idx = cache[c]
                if not idx then idx = gdi.nearest16(c); cache[c] = idx end
            end
            if transparent then abyte = abyte | (0x80 >> (ox & 7)) end
            if (ox & 7) == 7 then arow[#arow + 1] = string.char(abyte); abyte = 0 end
            if nib == nil then nib = idx else xrow[#xrow + 1] = string.char((nib << 4) | idx); nib = nil end
        end
        andRows[#andRows + 1] = table.concat(arow)
        xorRows[#xorRows + 1] = table.concat(xrow)
    end
    return string.pack("<i2i2I2I2I2BB", 16, 16, 32, 32, 16, 1, 4) .. table.concat(andRows) .. table.concat(xorRows)
end

pe.dibToIcon = convert

-- The entries of an icon directory, best first: 32x32 first, then larger
-- ones (scaled down) over smaller ones; deep colour preferred for quality.
-- entry(i) returns width, height, bits per pixel, and its key.
local function ranked(count, entry)
    local list = {}
    for i = 0, count - 1 do
        local w, h, bits, key = entry(i)
        w = w == 0 and 256 or w
        local score = (w == 32 and 0 or (w > 32 and (w - 32) or (32 - w) * 4)) * 10 + ((bits or 0) >= 24 and 0 or 5)
        if w <= 128 then list[#list + 1] = {score = score, key = key, i = i} end
    end
    table.sort(list, function(a, b) if a.score ~= b.score then return a.score < b.score end return a.i < b.i end)
    return list
end

-- The internal-format bytes of icon group `index` (0-based; a negative
-- index is a resource id, as in a shortcut's icon location), or nil.
function pe.iconBytes(data, index, gdi)
    local r = resources(data)
    if not r then return nil end
    local groups = r.list(14)
    local g
    if index < 0 then
        for _, e in ipairs(groups) do if e.id == -index then g = e end end
    else
        g = groups[index + 1]
    end
    if not g then return nil end
    local dir = g.dir and r.leaf(g.off)
    if not dir or #dir < 6 then return nil end
    local count = u16(dir, 4)
    for _, c in ipairs(ranked(count, function(i)
        local at = 6 + i * 14
        return dir:byte(at + 1), dir:byte(at + 2), u16(dir, at + 6), u16(dir, at + 12)
    end)) do
        local dib = r.get(3, c.key)
        local bytes = dib and convert(dib, gdi)
        if bytes then return bytes end
    end
end

-- The internal-format bytes of the best icon in an .ICO file, or nil.
function pe.icoBytes(data, gdi)
    if #data < 6 then return nil end
    local reserved, kind, count = string.unpack("<I2I2I2", data, 1)
    if reserved ~= 0 or kind ~= 1 then return nil end
    for _, c in ipairs(ranked(count, function(i)
        local at = 6 + i * 16
        if at + 16 > #data then return 999, 999, 0, nil end
        return data:byte(at + 1), data:byte(at + 2), u16(data, at + 6), at
    end)) do
        local size, off = u32(data, c.key + 8), u32(data, c.key + 12)
        local bytes = convert(data:sub(off + 1, off + size), gdi)
        if bytes then return bytes end
    end
end

return pe

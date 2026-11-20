-- GDI drawing beyond what Program Manager uses: pens, lines, rectangles,
-- polygons and ellipses, mapping modes, regions, bitmaps from resources and
-- DIBs, pattern brushes, fonts by parameters, and the printer and font
-- calls Control Panel's applets make.

local api = require("win16.api")
local cpu = require("recomp.cpu")
local gdi = require("win16.gdi")
local handles = require("win16.handles")
local region = require("win16.region")

local def = api.def
local rw, ww, rd, wd, rb, wb = mem.rw, mem.ww, mem.rd, mem.wd, mem.rb, mem.wb
local s16 = api.s16

local function user_dirty()
    local user = package.loaded["win16.user"]
    if user then user.dirty = true end
end

local function obj(h, kind)
    local o = handles.get(h)
    if o and (not kind or o.kind == kind) then return o end
end

-- ---- mapping modes: logical -> device ---------------------------------------------------------------
-- MM_TEXT 1, MM_ISOTROPIC 7, MM_ANISOTROPIC 8 (the others are treated as text)

local function mapOf(dc)
    if not dc.map then dc.map = {mode = 1, wox = 0, woy = 0, wex = 1, wey = 1, vox = 0, voy = 0, vex = 1, vey = 1} end
    return dc.map
end

function gdi.lp(dc, x, y)
    local m = dc.map
    if not m then return x, y end
    if m.mode == 1 then return x - m.wox + m.vox, y - m.woy + m.voy end
    local dx = (x - m.wox) * m.vex // (m.wex ~= 0 and m.wex or 1) + m.vox
    local dy = (y - m.woy) * m.vey // (m.wey ~= 0 and m.wey or 1) + m.voy
    return dx, dy
end

local function pairWord(a, b) return ((b & 0xFFFF) << 16) | (a & 0xFFFF) end

def("GDI", 3, "SetMapMode", "h i", function(hdc, mode)
    local dc = gdi.dc(hdc)
    if not dc then return 0 end
    local m = mapOf(dc)
    local old = m.mode
    m.mode = mode
    if mode == 1 then m.wex, m.wey, m.vex, m.vey = 1, 1, 1, 1 end
    return old
end)
def("GDI", 81, "GetMapMode", "h", function(hdc)
    local dc = gdi.dc(hdc)
    return dc and dc.map and dc.map.mode or 1
end)
local function setPair(fields)
    return function(hdc, a, b)
        local dc = gdi.dc(hdc)
        if not dc then return 0 end
        local m = mapOf(dc)
        local old = pairWord(m[fields[1]], m[fields[2]])
        m[fields[1]], m[fields[2]] = a, b
        return old
    end
end
def("GDI", 11, "SetWindowOrg", "h i i:l", setPair({"wox", "woy"}))
def("GDI", 12, "SetWindowExt", "h i i:l", setPair({"wex", "wey"}))
def("GDI", 13, "SetViewportOrg", "h i i:l", setPair({"vox", "voy"}))
def("GDI", 14, "SetViewportExt", "h i i:l", setPair({"vex", "vey"}))
def("GDI", 94, "GetViewportExt", "h:l", function(hdc)
    local dc = gdi.dc(hdc)
    local m = dc and mapOf(dc)
    return m and pairWord(m.vex, m.vey) or 0
end)
def("GDI", 96, "GetWindowExt", "h:l", function(hdc)
    local dc = gdi.dc(hdc)
    local m = dc and mapOf(dc)
    return m and pairWord(m.wex, m.wey) or 0
end)
def("GDI", 128, "MulDiv", "i i i", function(a, b, c)
    if c == 0 then return -1 end
    local r = a * b
    local q = (math.abs(r) + math.abs(c) // 2) // math.abs(c)
    if (r < 0) ~= (c < 0) then q = -q end
    if q > 32767 or q < -32768 then return -1 end
    return q
end)

-- ---- pens and lines -----------------------------------------------------------------------------

-- PS_SOLID 0 ... PS_NULL 5
def("GDI", 61, "CreatePen", "i i l", function(style, width, color)
    return gdi.newObj({kind = "pen", color = gdi.color(color), width = math.max(width, 1), style = style,
                       null = style == 5})
end)
def("GDI", 62, "CreatePenIndirect", "p", function(lp)
    if not lp then return 0 end
    local style, width, color = rw(lp), s16(rw(lp + 2)), rd(lp + 6)
    return gdi.newObj({kind = "pen", color = gdi.color(color), width = math.max(width, 1), style = style,
                       null = style == 5})
end)

local function penOf(dc)
    local p = obj(dc.pen, "pen")
    if not p or p.null then return nil end
    return p
end

-- A line in device coordinates on the DC's surface, clip already set.
local function devLine(dc, x0, y0, x1, y1, p)
    local w = p.width or 1
    local rop2 = dc.rop2 or 13
    if w <= 1 then
        fb.line(dc.surface, x0 + dc.ox, y0 + dc.oy, x1 + dc.ox, y1 + dc.oy, rop2, p.color)
        return
    end
    -- a wide pen: the line drawn w times side by side
    local h = w // 2
    if math.abs(x1 - x0) >= math.abs(y1 - y0) then
        for k = -h, w - h - 1 do fb.line(dc.surface, x0 + dc.ox, y0 + k + dc.oy, x1 + dc.ox, y1 + k + dc.oy, rop2, p.color) end
    else
        for k = -h, w - h - 1 do fb.line(dc.surface, x0 + k + dc.ox, y0 + dc.oy, x1 + k + dc.ox, y1 + dc.oy, rop2, p.color) end
    end
end

def("GDI", 20, "MoveTo", "h i i:l", function(hdc, x, y)
    local dc = gdi.dc(hdc)
    if not dc then return 0 end
    local old = pairWord(dc.curX or 0, dc.curY or 0)
    dc.curX, dc.curY = x, y
    return old
end)
def("GDI", 19, "LineTo", "h i i", function(hdc, x, y)
    local dc = gdi.dc(hdc)
    if not dc then return 0 end
    local p = penOf(dc)
    local x0, y0 = gdi.lp(dc, dc.curX or 0, dc.curY or 0)
    local x1, y1 = gdi.lp(dc, x, y)
    dc.curX, dc.curY = x, y
    if p and gdi.useClip(dc) then
        -- LineTo leaves out the last point
        devLine(dc, x0, y0, x1, y1, p)
        fb.pixel(dc.surface, x1 + dc.ox, y1 + dc.oy, fb.pixel(dc.surface, x1 + dc.ox, y1 + dc.oy))
    end
    user_dirty()
    return 1
end)
def("GDI", 76, "GetCurrentPosition", "h:l", function(hdc)
    local dc = gdi.dc(hdc)
    return dc and pairWord(dc.curX or 0, dc.curY or 0) or 0
end)
def("GDI", 4, "SetROP2", "h i", function(hdc, r)
    local dc = gdi.dc(hdc)
    if not dc then return 0 end
    local old = dc.rop2 or 13
    dc.rop2 = r
    return old
end)


-- ---- filled shapes ------------------------------------------------------------------------------------

local function brushArg(dc)
    local b = obj(dc.brush, "brush")
    if not b or b.null then return nil end
    return gdi.fbBrush(b)
end

-- Fills a polygon (device points) with the DC's brush, even-odd or winding
-- (as alternate: Windows' default).
local function fillPoly(dc, pts, brush)
    if not brush or #pts < 3 then return end
    local miny, maxy = math.huge, -math.huge
    for _, p in ipairs(pts) do miny = math.min(miny, p[2]); maxy = math.max(maxy, p[2]) end
    for y = miny, maxy - 1 do
        local xs = {}
        local yc = y + 0.5
        for i = 1, #pts do
            local a, b = pts[i], pts[i % #pts + 1]
            if (a[2] <= yc and b[2] > yc) or (b[2] <= yc and a[2] > yc) then
                xs[#xs + 1] = a[1] + (yc - a[2]) * (b[1] - a[1]) / (b[2] - a[2])
            end
        end
        table.sort(xs)
        for i = 1, #xs - 1, 2 do
            local x0, x1 = math.floor(xs[i] + 0.5), math.floor(xs[i + 1] + 0.5)
            if x1 > x0 then fb.patblt(dc.surface, x0 + dc.ox, y + dc.oy, x1 - x0, 1, 0xF0, brush) end
        end
    end
end

local function outlinePoly(dc, pts, p)
    for i = 1, #pts do
        local a, b = pts[i], pts[i % #pts + 1]
        devLine(dc, a[1], a[2], b[1], b[2], p)
    end
end

def("GDI", 27, "Rectangle", "h i i i i", function(hdc, x0, y0, x1, y1)
    local dc = gdi.dc(hdc)
    if not dc then return 0 end
    if not gdi.useClip(dc) then return 1 end
    x0, y0 = gdi.lp(dc, x0, y0)
    x1, y1 = gdi.lp(dc, x1, y1)
    if x1 < x0 then x0, x1 = x1, x0 end
    if y1 < y0 then y0, y1 = y1, y0 end
    local p = penOf(dc)
    local inset = p and 1 or 0
    local b = brushArg(dc)
    if b and x1 - x0 > 2 * inset and y1 - y0 > 2 * inset then
        fb.patblt(dc.surface, x0 + inset + dc.ox, y0 + inset + dc.oy, x1 - x0 - 2 * inset, y1 - y0 - 2 * inset, 0xF0, b)
    end
    if p then
        local c = p.color
        local s = dc.surface
        local w = p.width or 1
        for k = 0, w - 1 do
            fb.patblt(s, x0 + dc.ox, y0 + k + dc.oy, x1 - x0, 1, 0xF0, c)
            fb.patblt(s, x0 + dc.ox, y1 - 1 - k + dc.oy, x1 - x0, 1, 0xF0, c)
            fb.patblt(s, x0 + k + dc.ox, y0 + dc.oy, 1, y1 - y0, 0xF0, c)
            fb.patblt(s, x1 - 1 - k + dc.ox, y0 + dc.oy, 1, y1 - y0, 0xF0, c)
        end
    end
    user_dirty()
    return 1
end)

def("GDI", 36, "Polygon", "h p i", function(hdc, lp, n)
    local dc = gdi.dc(hdc)
    if not dc or not lp or n < 2 then return 0 end
    if not gdi.useClip(dc) then return 1 end
    local pts = {}
    for i = 0, n - 1 do
        local x, y = gdi.lp(dc, s16(rw(lp + i * 4)), s16(rw(lp + i * 4 + 2)))
        pts[#pts + 1] = {x, y}
    end
    fillPoly(dc, pts, brushArg(dc))
    local p = penOf(dc)
    if p then outlinePoly(dc, pts, p) end
    user_dirty()
    return 1
end)
def("GDI", 37, "Polyline", "h p i", function(hdc, lp, n)
    local dc = gdi.dc(hdc)
    if not dc or not lp or n < 2 then return 0 end
    local p = penOf(dc)
    if not p or not gdi.useClip(dc) then return 1 end
    local px, py
    for i = 0, n - 1 do
        local x, y = gdi.lp(dc, s16(rw(lp + i * 4)), s16(rw(lp + i * 4 + 2)))
        if px then devLine(dc, px, py, x, y, p) end
        px, py = x, y
    end
    user_dirty()
    return 1
end)

-- an ellipse as a polygon of its outline
local function ellipsePts(x0, y0, x1, y1)
    local cx, cy = (x0 + x1) / 2, (y0 + y1) / 2
    local rx, ry = (x1 - x0) / 2, (y1 - y0) / 2
    local pts = {}
    local n = math.max(16, math.floor((rx + ry) * 1.5))
    for i = 0, n - 1 do
        local a = i * 2 * math.pi / n
        pts[#pts + 1] = {math.floor(cx + rx * math.cos(a) + 0.5), math.floor(cy + ry * math.sin(a) + 0.5)}
    end
    return pts
end
def("GDI", 24, "Ellipse", "h i i i i", function(hdc, x0, y0, x1, y1)
    local dc = gdi.dc(hdc)
    if not dc then return 0 end
    if not gdi.useClip(dc) then return 1 end
    x0, y0 = gdi.lp(dc, x0, y0)
    x1, y1 = gdi.lp(dc, x1, y1)
    local pts = ellipsePts(x0, y0, x1 - 1, y1 - 1)
    fillPoly(dc, pts, brushArg(dc))
    local p = penOf(dc)
    if p then outlinePoly(dc, pts, p) end
    user_dirty()
    return 1
end)

def("GDI", 31, "SetPixel", "h i i l:l", function(hdc, x, y, c)
    local dc = gdi.dc(hdc)
    if not dc or not gdi.useClip(dc) then return 0 end
    x, y = gdi.lp(dc, x, y)
    fb.pixel(dc.surface, x + dc.ox, y + dc.oy, gdi.color(c))
    user_dirty()
    return c
end)
def("GDI", 32, "GetPixel", "h i i:l", function(hdc, x, y)
    local dc = gdi.dc(hdc)
    if not dc then return 0 end
    x, y = gdi.lp(dc, x, y)
    local c = fb.pixel(dc.surface, x + dc.ox, y + dc.oy)
    return c and gdi.colorref(c) or 0xFFFFFFFF
end)

-- ---- regions ------------------------------------------------------------------------------------------

def("GDI", 65, "CreateRectRgnIndirect", "p", function(prc)
    local r = api.getrect(prc)
    if not r then return 0 end
    if r[3] <= r[1] or r[4] <= r[2] then return gdi.newRgn({}) end
    return gdi.newRgn({r})
end)
def("GDI", 161, "PtInRegion", "h i i", function(h, x, y)
    local o = obj(h, "rgn")
    if not o then return 0 end
    for _, r in ipairs(o.rects) do
        if x >= r[1] and x < r[3] and y >= r[2] and y < r[4] then return 1 end
    end
    return 0
end)
def("GDI", 40, "FillRgn", "h h h", function(hdc, hrgn, hbr)
    local dc = gdi.dc(hdc)
    local o = obj(hrgn, "rgn")
    local b = obj(hbr, "brush")
    if not dc or not o or not b or b.null then return 0 end
    if not gdi.useClip(dc) then return 1 end
    for _, r in ipairs(o.rects) do
        fb.patblt(dc.surface, r[1] + dc.ox, r[2] + dc.oy, r[3] - r[1], r[4] - r[2], 0xF0, gdi.fbBrush(b))
    end
    user_dirty()
    return 1
end)
def("GDI", 44, "SelectClipRgn", "h h", function(hdc, hrgn)
    local dc = gdi.dc(hdc)
    if not dc then return 0 end
    local o = obj(hrgn, "rgn")
    dc.clipRgn = o and o.rects or nil
    return 2
end)
def("GDI", 21, "ExcludeClipRect", "h i i i i", function(hdc, x0, y0, x1, y1)
    local dc = gdi.dc(hdc)
    if not dc then return 0 end
    local base = dc.clipRgn
    if not base then
        local w, h = fb.size(dc.surface)
        base = {{-dc.ox, -dc.oy, w - dc.ox, h - dc.oy}}
    end
    dc.clipRgn = region.subtract(base, {{x0, y0, x1, y1}})
    return #dc.clipRgn == 0 and 1 or 3
end)
def("GDI", 22, "IntersectClipRect", "h i i i i", function(hdc, x0, y0, x1, y1)
    local dc = gdi.dc(hdc)
    if not dc then return 0 end
    local r = {{x0, y0, x1, y1}}
    dc.clipRgn = dc.clipRgn and region.intersect(dc.clipRgn, r) or r
    return #dc.clipRgn == 0 and 1 or 2
end)

-- ---- bitmaps and brushes ------------------------------------------------------------------------------

def("GDI", 51, "CreateCompatibleBitmap", "h i i", function(hdc, w, h)
    local dc = gdi.dc(hdc)
    local mono = false
    if dc and dc.memory then
        local b = obj(dc.bitmap, "bitmap")
        mono = b and b.mono or false
    end
    return gdi.newBitmap(w, h, mono)
end)

-- A DIB (BITMAPINFOHEADER and colours, then bits) as a new bitmap.
function gdi.bitmapFromDib(info, bits)
    local id, w, h = fb.dib(info .. (bits or ""))
    if not id then return 0 end
    return gdi.newObj({kind = "bitmap", surface = id, w = w, h = h, mono = false})
end

-- BITMAPINFO at lin: its size with the colour table, width, height, bits per pixel
local function dibInfoSize(lin)
    local size = rd(lin)
    if size == 12 then   -- BITMAPCOREHEADER
        local bc = rw(lin + 10)
        return 12 + (bc <= 8 and (1 << bc) or 0) * 3, rw(lin + 4), rw(lin + 6), bc
    end
    local bitcount = rw(lin + 14)
    local used = rd(lin + 32)
    local colors = used ~= 0 and used or (bitcount <= 8 and (1 << bitcount) or 0)
    local h = rd(lin + 8)
    if h >= 0x80000000 then h = 0x100000000 - h end
    return size + colors * 4, rd(lin + 4), h, bitcount
end
gdi.dibInfoSize = dibInfoSize

-- CreateDIBitmap(hdc, header, CBM_INIT, bits, info, usage)
def("GDI", 442, "CreateDIBitmap", "h p l p p w", function(hdc, hdr, init, bits, info, usage)
    if not hdr then return 0 end
    if init & 4 == 0 or not bits or not info then
        return gdi.newBitmap(rd(hdr + 4), math.abs(s16(rw(hdr + 8))), false)
    end
    local isz, w, h, bc = dibInfoSize(info)
    local stride = ((w * bc + 31) // 32) * 4
    return gdi.bitmapFromDib(mem.read(info, isz), mem.read(bits, stride * h))
end)

-- An 8x8 pattern brush from a bitmap (a mono one in black and white).
def("GDI", 60, "CreatePatternBrush", "h", function(hbm)
    local b = obj(hbm, "bitmap")
    if not b then return 0 end
    local pat = {}
    for y = 0, 7 do
        for x = 0, 7 do
            local c = fb.pixel(b.surface, x % b.w, y % b.h) or 0
            pat[#pat + 1] = c
        end
    end
    return gdi.newObj({kind = "brush", pattern = pat, color = pat[1]})
end)
def("GDI", 150, "UnrealizeObject", "h", function() return 1 end)
def("GDI", 154, "GetNearestColor", "h l:l", function(hdc, c)
    return gdi.colorref(gdi.VGA[gdi.nearest16(gdi.color(c))])
end)

-- GetObject(h, size, buffer): BITMAP, LOGPEN, LOGBRUSH or LOGFONT
def("GDI", 82, "GetObject", "h i p", function(h, size, lp)
    local o = handles.get(h)
    if not o or not lp then return 0 end
    local out
    if o.kind == "bitmap" then
        local bpp = o.mono and 1 or 4
        out = string.pack("<i2i2i2i2BBI4", 0, o.w, o.h, ((o.w * bpp + 15) // 16) * 2, 1, bpp, 0)
    elseif o.kind == "pen" then
        out = string.pack("<I2i2i2I4", o.style or (o.null and 5 or 0), o.width or 1, 0, gdi.colorref(o.color or 0))
    elseif o.kind == "brush" then
        out = string.pack("<I2I4i2", o.null and 1 or (o.pattern and 3 or 0), gdi.colorref(o.color or 0), 0)
    elseif o.kind == "font" then
        local lf = o.lf
        if lf then out = lf
        else
            local rf = o.rf
            local face = rf and rf.face or "System"
            out = string.pack("<i2i2i2i2i2BBBBBBBB", rf and rf.m.height or 16, 0, 0, 0, o.bold and 700 or 400,
                0, 0, 0, 0, 0, 0, 0, 0) .. face .. string.rep("\0", 32 - #face)
        end
    end
    if not out then return 0 end
    out = out:sub(1, size)
    mem.write(lp, out)
    return #out
end)

-- ---- fonts ------------------------------------------------------------------------------------------

def("GDI", 56, "CreateFont", "i i i i i w w w w w w w w s", function(h, w, esc, orient, weight, italic, underline,
                                                                    strike, charset, outp, clip, quality, pitch, face)
    local mark = api.mark()
    local fp, lin = api.alloc(50)
    mem.write(lin, string.pack("<i2i2i2i2i2BBBBBBBB", h, w, esc, orient, weight, italic & 0xFF, underline & 0xFF,
        strike & 0xFF, charset & 0xFF, outp & 0xFF, clip & 0xFF, quality & 0xFF, pitch & 0xFF))
    mem.write(lin + 18, ((face or ""):sub(1, 31)) .. "\0")
    local d = api.byOrd.GDI[57]
    local r = d.fn(lin)
    api.release(mark)
    return r
end)
def("GDI", 350, "GetCharWidth", "h w w p", function(hdc, first, last, buf)
    local dc = gdi.dc(hdc)
    if not dc or not buf then return 0 end
    local f = gdi.fontObj(dc)
    for c = first, last do
        local wdt = f.rf and fb.char_width(f.rf.fid, c) or 8
        ww(buf + (c - first) * 2, wdt)
    end
    return 1
end)
-- No TrueType here: the raster fonts are what there is
def("GDI", 313, "GetRasterizerCaps", "p w", function(lp, n)
    if lp and n >= 4 then mem.write(lp, string.pack("<I2I2I2", 6, 0, 0):sub(1, n)) end
    return 1
end)
def("GDI", 119, "AddFontResource", "f", function() return 1 end)
def("GDI", 136, "RemoveFontResource", "f", function() return 1 end)
def("GDI", 310, "CreateScalableFontResource", "w s s s", function() return 0 end)

-- ---- devices: the display only (no printers) ---------------------------------------------------------------

local function displayDC(driver)
    if driver and not driver:upper():find("DISPLAY") then return 0 end
    local dc = gdi.newDC({surface = 0, ox = 0, oy = 0, info = true})
    return dc
end
def("GDI", 53, "CreateDC", "s s s p", function(driver) return displayDC(driver) end)
def("GDI", 153, "CreateIC", "s s s p", function(driver) return displayDC(driver) end)
def("GDI", 38, "Escape", "h i i f f", function() return 0 end)
def("GDI", 245, "GetSpoolJob", "w l", function() return 0 end)
def("GDI", 467, "GDI467", "f f", function() return 0 end)

return {}

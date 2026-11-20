-- GDI: device contexts, brushes, fonts (the raster fonts from the user's
-- VGASYS.FON, SSERIFE.FON and VGAFIX.FON), bitmaps, regions and text, drawn
-- with the host's fb surfaces. The screen is a 16-colour VGA-like device
-- (4 bits per pixel, one plane) to the program; pixels are stored as 24-bit.

local api = require("win16.api")
local handles = require("win16.handles")
local region = require("win16.region")

local gdi = {}
local def = api.def
local rw, ww, rb, wb = mem.rw, mem.ww, mem.rb, mem.wb
local s16 = api.s16

gdi.screenW, gdi.screenH = 640, 480

-- COLORREF (0x00BBGGRR, or 0x01 << 24 | palette index) -> fb colour (0xRRGGBB)
gdi.VGA = {[0] = 0x000000, 0x800000, 0x008000, 0x808000, 0x000080, 0x800080, 0x008080, 0xC0C0C0,
           0x808080, 0xFF0000, 0x00FF00, 0xFFFF00, 0x0000FF, 0xFF00FF, 0x00FFFF, 0xFFFFFF}
function gdi.color(c)
    if (c >> 24) == 1 then return gdi.VGA[c & 15] end
    return ((c & 0xFF) << 16) | (c & 0xFF00) | ((c >> 16) & 0xFF)
end
function gdi.colorref(c)   -- fb colour -> COLORREF
    return ((c & 0xFF) << 16) | (c & 0xFF00) | ((c >> 16) & 0xFF)
end
-- nearest of the 16 colours: the index
function gdi.nearest16(c)
    local r, g, b = c >> 16, (c >> 8) & 0xFF, c & 0xFF
    local best, bd = 0, math.huge
    for i = 0, 15 do
        local v = gdi.VGA[i]
        local dr, dg, db = r - (v >> 16), g - ((v >> 8) & 0xFF), b - (v & 0xFF)
        local d = dr * dr + dg * dg + db * db
        if d < bd then best, bd = i, d end
    end
    return best
end

-- ---- fonts ------------------------------------------------------------------------------

gdi.fonts = {}      -- {fid=, m=metrics, face=UPPER}

local function loadFon(mod)
    if not mod then return end
    for _, r in ipairs(mod:resourcesOf(8)) do
        local fid, m = fb.font(mod:resourceBytes(r))
        if fid then
            gdi.fonts[#gdi.fonts + 1] = {fid = fid, m = m, face = (m.face or ""):upper()}
        end
    end
end

local SUBST = {HELV = "MS SANS SERIF", ["TMS RMN"] = "MS SANS SERIF", ["MS SERIF"] = "MS SANS SERIF",
               ARIAL = "MS SANS SERIF", COURIER = "FIXEDSYS", ["COURIER NEW"] = "FIXEDSYS",
               ["TIMES NEW ROMAN"] = "MS SANS SERIF", TERMINAL = "FIXEDSYS"}

-- The best raster font for a LOGFONT-like request {height, weight, face, italic, underline}.
function gdi.matchFont(req)
    local face = (req.face or ""):upper()
    face = SUBST[face] or face
    if face == "" then face = (req.pitch and req.pitch & 3 == 1) and "FIXEDSYS" or "SYSTEM" end
    local h = req.height or 0
    local best, bscore
    for _, f in ipairs(gdi.fonts) do
        local score = 0
        if f.face ~= face then score = score + 10000 end
        if h ~= 0 then
            local fh = h < 0 and (f.m.height - f.m.internal_leading) or f.m.height
            local d = math.abs(fh - math.abs(h))
            if fh > math.abs(h) then d = d * 2 end   -- prefer smaller to larger, as the mapper does
            score = score + d * 10
        elseif f.face == "MS SANS SERIF" then
            score = score + math.abs(f.m.height - 13) * 10
        end
        if not bscore or score < bscore then best, bscore = f, score end
    end
    return best
end

-- ---- objects --------------------------------------------------------------------------------

local function newObj(o) return handles.new(o) end
gdi.newObj = newObj

local stock = {}
function gdi.stock(i) return stock[i] end

local function brushOf(h)
    local o = handles.get(h)
    if o and o.kind == "brush" then return o end
end

-- the fb brush argument for a brush object (nil = hollow)
function gdi.fbBrush(b)
    if not b or b.null then return nil end
    return b.pattern or b.color
end

function gdi.newBrush(color)
    return newObj({kind = "brush", color = color})
end

-- a brush for a system colour (COLOR_* + 1 as a class background works too)
gdi.sysBrushes = {}

-- ---- device contexts ---------------------------------------------------------------------------

-- dc: {kind="dc", surface=, ox, oy (device origin), clip=function -> region list
--      in surface coordinates (nil = everything), text, bk, bkMode, font, brush, bitmap, hwnd}
function gdi.newDC(t)
    t.kind = "dc"
    t.text = t.text or 0
    t.bk = t.bk or 0xFFFFFF
    t.bkMode = t.bkMode or 2
    t.font = t.font or stock[13]
    t.brush = t.brush or stock[0]
    t.pen = t.pen or stock[7]
    t.ox, t.oy = t.ox or 0, t.oy or 0
    t.rop2 = 13
    return newObj(t)
end

function gdi.dc(h) return handles.get(h, "dc") end

-- Sets fb's clip for drawing on a DC, intersected with an optional extra
-- rectangle in logical coordinates. Returns false when nothing is visible.
local function useClip(dc, extra)
    local list = dc.clipFn and dc.clipFn(dc) or nil
    if dc.clipRgn then
        local r = region.offset(dc.clipRgn, dc.ox, dc.oy)
        list = list and region.intersect(list, r) or r
    end
    if extra then
        local e = {{extra[1] + dc.ox, extra[2] + dc.oy, extra[3] + dc.ox, extra[4] + dc.oy}}
        list = list and region.intersect(list, e) or e
    end
    if list then
        if #list == 0 then return false end
        fb.clip(region.flat(list))
    else
        fb.clip(nil)
    end
    return true
end
gdi.useClip = useClip

local function fontObj(dc)
    local f = handles.get(dc.font)
    if not f or f.kind ~= "font" then f = handles.get(stock[13]) end
    return f
end
gdi.fontObj = fontObj

-- Text on a DC at logical (x, y), top-left aligned.
function gdi.textOut(dc, x, y, s, opaqueRect, clipRect)
    local f = fontObj(dc)
    if not f.rf then return 0 end
    if not useClip(dc, clipRect) then return fb.text_width(f.rf.fid, s, f.bold) end
    if opaqueRect then
        fb.patblt(dc.surface, opaqueRect[1] + dc.ox, opaqueRect[2] + dc.oy, opaqueRect[3] - opaqueRect[1],
            opaqueRect[4] - opaqueRect[2], 0xF0, dc.bk)
    end
    return fb.text(dc.surface, f.rf.fid, x + dc.ox, y + dc.oy, s, dc.text, dc.bk, dc.bkMode == 2 and not opaqueRect,
        f.bold, f.underline)
end

function gdi.textWidth(dc, s)
    local f = fontObj(dc)
    if not f.rf then return #s * 8 end
    return fb.text_width(f.rf.fid, s, f.bold)
end

function gdi.fontHeight(dc)
    local f = fontObj(dc)
    return f.rf and f.rf.m.height or 16
end

-- ---- init: stock objects -----------------------------------------------------------------------------

function gdi.init(w, h, sys)
    gdi.screenW, gdi.screenH = w, h
    loadFon(sys.sysfont)
    loadFon(sys.sansfont)
    loadFon(sys.fixfont)
    if #gdi.fonts == 0 then host.log("GDI: no fonts found (VGASYS.FON); text will not be drawn") end
    stock[0] = newObj({kind = "brush", color = 0xFFFFFF, stock = true})
    stock[1] = newObj({kind = "brush", color = 0xC0C0C0, stock = true})
    stock[2] = newObj({kind = "brush", color = 0x808080, stock = true})
    stock[3] = newObj({kind = "brush", color = 0x404040, stock = true})
    stock[4] = newObj({kind = "brush", color = 0x000000, stock = true})
    stock[5] = newObj({kind = "brush", null = true, stock = true})
    stock[6] = newObj({kind = "pen", color = 0xFFFFFF, stock = true})
    stock[7] = newObj({kind = "pen", color = 0, stock = true})
    stock[8] = newObj({kind = "pen", null = true, stock = true})
    local function stockFont(face, height)
        local rf = gdi.matchFont({face = face, height = height})
        return newObj({kind = "font", rf = rf, stock = true})
    end
    stock[10] = stockFont("Fixedsys", 0)      -- OEM_FIXED_FONT
    stock[11] = stockFont("Fixedsys", 0)      -- ANSI_FIXED_FONT
    stock[12] = stockFont("MS Sans Serif", 0) -- ANSI_VAR_FONT
    stock[13] = stockFont("System", 0)        -- SYSTEM_FONT
    stock[14] = stock[13]                     -- DEVICE_DEFAULT_FONT
    stock[15] = newObj({kind = "palette", stock = true})
    stock[16] = stock[10]                     -- SYSTEM_FIXED_FONT
    gdi.screenDC = nil
end

-- ---- API ----------------------------------------------------------------------------------------------------

def("GDI", 87, "GetStockObject", "i", function(i) return stock[i] or 0 end)

def("GDI", 66, "CreateSolidBrush", "l", function(c) return gdi.newBrush(gdi.color(c)) end)

def("GDI", 57, "CreateFontIndirect", "p", function(lf)
    if not lf then return 0 end
    local req = {height = s16(rw(lf)), weight = s16(rw(lf + 8)), italic = rb(lf + 10) ~= 0,
                 underline = rb(lf + 11) ~= 0, pitch = rb(lf + 17), face = mem.cstr(lf + 18, 32)}
    local rf = gdi.matchFont(req)
    return newObj({kind = "font", rf = rf, bold = req.weight >= 600 and rf and rf.m.weight < 600,
                   underline = req.underline, req = req})
end)

def("GDI", 69, "DeleteObject", "h", function(h)
    local o = handles.get(h)
    if not o or o.stock or o.kind == "dc" then return o ~= nil end
    if o.kind == "bitmap" and o.surface then fb.free(o.surface) end
    handles.free(h)
    return 1
end)

def("GDI", 45, "SelectObject", "h h", function(hdc, h)
    local dc = gdi.dc(hdc)
    local o = handles.get(h)
    if not dc or not o then return 0 end
    if o.kind == "brush" then local old = dc.brush; dc.brush = h; return old end
    if o.kind == "font" then local old = dc.font; dc.font = h; return old end
    if o.kind == "pen" then local old = dc.pen; dc.pen = h; return old end
    if o.kind == "bitmap" then
        if not dc.memory then return 0 end
        local old = dc.bitmap
        dc.bitmap = h
        dc.surface = o.surface
        return old
    end
    if o.kind == "rgn" then
        dc.clipRgn = o.rects
        return #o.rects == 0 and 1 or #o.rects == 1 and 2 or 3
    end
    return 0
end)

def("GDI", 1, "SetBkColor", "h l:l", function(hdc, c)
    local dc = gdi.dc(hdc)
    if not dc then return 0 end
    local old = gdi.colorref(dc.bk)
    dc.bk = gdi.color(c)
    return old
end)
def("GDI", 9, "SetTextColor", "h l:l", function(hdc, c)
    local dc = gdi.dc(hdc)
    if not dc then return 0 end
    local old = gdi.colorref(dc.text)
    dc.text = gdi.color(c)
    return old
end)
def("GDI", 2, "SetBkMode", "h i", function(hdc, m)
    local dc = gdi.dc(hdc)
    if not dc then return 0 end
    local old = dc.bkMode
    dc.bkMode = m
    return old
end)

def("GDI", 52, "CreateCompatibleDC", "h", function()
    local bm = newObj({kind = "bitmap", surface = fb.new(1, 1, true), w = 1, h = 1, mono = true, stock = true})
    local o = handles.get(bm)
    return gdi.newDC({memory = true, surface = o.surface, bitmap = bm})
end)
def("GDI", 68, "DeleteDC", "h", function(h)
    local dc = gdi.dc(h)
    if not dc then return 0 end
    handles.free(h)
    return 1
end)

local function newBitmap(w, h, mono)
    w, h = math.max(w, 1), math.max(h, 1)
    return newObj({kind = "bitmap", surface = fb.new(w, h, mono), w = w, h = h, mono = mono})
end
gdi.newBitmap = newBitmap
def("GDI", 156, "CreateDiscardableBitmap", "h i i", function(hdc, w, h)
    local dc = gdi.dc(hdc)
    local mono = false
    if dc and dc.memory then
        local b = handles.get(dc.bitmap)
        mono = b and b.mono
    end
    return newBitmap(w, h, mono)
end)
def("GDI", 48, "CreateBitmap", "i i w w p", function(w, h, planes, bits, data)
    local b = newBitmap(w, h, planes == 1 and bits == 1)
    if data and planes == 1 and bits == 1 then
        local wb = ((w + 15) // 16) * 2
        fb.bits(handles.get(b).surface, mem.read(data, wb * h), wb)
    end
    return b
end)

def("GDI", 80, "GetDeviceCaps", "h i", function(hdc, i)
    local caps = {[0] = 0x300, [2] = 1, [4] = 208, [6] = 156, [8] = gdi.screenW, [10] = gdi.screenH,
                  [12] = 4, [14] = 1, [16] = -1, [18] = 100, [20] = 0, [22] = 0, [24] = 16, [26] = 0,
                  [28] = 0, [30] = 0, [32] = 0, [34] = 0x7E00 & 0, [36] = 1, [38] = 0x0699, [40] = 36,
                  [42] = 36, [44] = 51, [88] = 96, [90] = 96, [104] = 0, [106] = 0, [108] = 0}
    local dc = gdi.dc(hdc)
    if dc and dc.memory and (i == 12 or i == 14) then
        local b = handles.get(dc.bitmap)
        if b and b.mono then return 1 end
    end
    return (caps[i] or 0) & 0xFFFF
end)

def("GDI", 29, "PatBlt", "h i i i i l", function(hdc, x, y, w, h, rop)
    local dc = gdi.dc(hdc)
    if not dc then return 0 end
    if not useClip(dc) then return 1 end
    local b = brushOf(dc.brush)
    local r3 = (rop >> 16) & 0xFF
    if (not b or b.null) and (r3 == 0xF0 or r3 == 0x5A) then return 1 end
    fb.patblt(dc.surface, x + dc.ox, y + dc.oy, w, h, r3, gdi.fbBrush(b) or 0)
    return 1
end)

def("GDI", 34, "BitBlt", "h i i i i h i i l", function(hdst, x, y, w, h, hsrc, sx, sy, rop)
    local d = gdi.dc(hdst)
    if not d then return 0 end
    local r3 = (rop >> 16) & 0xFF
    local s = gdi.dc(hsrc)
    if not useClip(d) then return 1 end
    local b = gdi.fbBrush(brushOf(d.brush)) or 0
    if not s then
        fb.patblt(d.surface, x + d.ox, y + d.oy, w, h, r3, b)
        return 1
    end
    local _, _, smono = fb.size(s.surface)
    local _, _, dmono = fb.size(d.surface)
    local text, bk = d.text, d.bk
    if not smono and dmono then bk = s.bk end
    fb.bitblt(d.surface, x + d.ox, y + d.oy, w, h, s.surface, sx + s.ox, sy + s.oy, r3, b, text, bk)
    if gdi.onImage then gdi.onImage(d, x, y, w, h) end
    return 1
end)

def("GDI", 33, "TextOut", "h i i f i", function(hdc, x, y, lp, n)
    local dc = gdi.dc(hdc)
    local l = require("recomp.cpu").flat(lp)
    if not dc or not l then return 0 end
    gdi.textOut(dc, x, y, mem.read(l, n))
    return 1
end)

-- ExtTextOut(hdc, x, y, options, lprc, lpString, count, lpDx)
def("GDI", 351, "ExtTextOut", "h i i w p f w p", function(hdc, x, y, opt, prc, lp, n)
    local dc = gdi.dc(hdc)
    if not dc then return 0 end
    local l = require("recomp.cpu").flat(lp)
    local s = (l and n > 0) and mem.read(l, n) or ""
    local rc = prc and api.getrect(prc)
    local opaque = (opt & 2) ~= 0 and rc or nil
    local clip = (opt & 4) ~= 0 and rc or nil
    if opaque and s == "" then
        if useClip(dc, clip) then
            fb.patblt(dc.surface, rc[1] + dc.ox, rc[2] + dc.oy, rc[3] - rc[1], rc[4] - rc[2], 0xF0, dc.bk)
        end
        return 1
    end
    gdi.textOut(dc, x, y, s, opaque, clip)
    return 1
end)

def("GDI", 91, "GetTextExtent", "h f i:l", function(hdc, lp, n)
    local dc = gdi.dc(hdc)
    local l = require("recomp.cpu").flat(lp)
    if not dc then return 0 end
    local s = (l and n > 0) and mem.read(l, n) or ""
    return api.mklong(gdi.textWidth(dc, s), gdi.fontHeight(dc))
end)

def("GDI", 93, "GetTextMetrics", "h p", function(hdc, tm)
    local dc = gdi.dc(hdc)
    if not dc or not tm then return 0 end
    local f = fontObj(dc)
    local m = f.rf and f.rf.m or {height = 16, ascent = 13, internal_leading = 3, external_leading = 0,
        avg_width = 7, max_width = 14, weight = 700, first_char = 32, last_char = 255, default_char = 128,
        break_char = 0, pitch_family = 0x22, charset = 0}
    local bold = f.bold and 1 or 0
    ww(tm, m.height); ww(tm + 2, m.ascent); ww(tm + 4, m.height - m.ascent)
    ww(tm + 6, m.internal_leading); ww(tm + 8, m.external_leading)
    ww(tm + 10, m.avg_width + bold); ww(tm + 12, m.max_width + bold); ww(tm + 14, f.bold and 700 or m.weight)
    wb(tm + 16, m.italic or 0); wb(tm + 17, f.underline and 1 or (m.underline or 0)); wb(tm + 18, 0)
    wb(tm + 19, m.first_char); wb(tm + 20, m.last_char); wb(tm + 21, m.default_char + m.first_char)
    wb(tm + 22, m.break_char + m.first_char); wb(tm + 23, m.pitch_family); wb(tm + 24, m.charset)
    ww(tm + 25, bold); ww(tm + 27, 96); ww(tm + 29, 96)
    return 1
end)

def("GDI", 104, "RectVisible", "h p", function(hdc, prc)
    local dc = gdi.dc(hdc)
    if not dc or not prc then return 0 end
    local r = api.getrect(prc)
    local list = dc.clipFn and dc.clipFn(dc)
    if not list then return 1 end
    local rr = {{r[1] + dc.ox, r[2] + dc.oy, r[3] + dc.ox, r[4] + dc.oy}}
    return #region.intersect(list, rr) > 0
end)

-- ---- regions --------------------------------------------------------------------------------------

function gdi.newRgn(rects) return newObj({kind = "rgn", rects = rects}) end
local function rgnType(rects)
    if #rects == 0 then return 1 end
    if #rects == 1 then return 2 end
    return 3
end
def("GDI", 64, "CreateRectRgn", "i i i i", function(x0, y0, x1, y1)
    local r = {x0, y0, x1, y1}
    return gdi.newRgn(region.empty(r) and {} or {r})
end)
def("GDI", 172, "SetRectRgn", "h i i i i:v", function(h, x0, y0, x1, y1)
    local o = handles.get(h, "rgn")
    if o then
        local r = {x0, y0, x1, y1}
        o.rects = region.empty(r) and {} or {r}
    end
end)
def("GDI", 47, "CombineRgn", "h h h i", function(hd, h1, h2, mode)
    local d, a, b = handles.get(hd, "rgn"), handles.get(h1, "rgn"), handles.get(h2, "rgn")
    if not d or not a then return 0 end
    local A, B = a.rects, b and b.rects or {}
    local out
    if mode == 1 then out = region.intersect(A, B)
    elseif mode == 2 then out = region.union(A, B)
    elseif mode == 3 then out = region.xor(A, B)
    elseif mode == 4 then out = region.subtract(A, B)
    else out = {table.unpack(A)} end
    d.rects = region.compact(out)
    return rgnType(d.rects)
end)

-- ---- icons ------------------------------------------------------------------------------------------
-- An HICON is a global memory block: a CURSORICONINFO header (hotspot x, y,
-- width, height, widthBytes, planes, bitsPixel), the AND mask (1 bit,
-- word-aligned rows, top row first), then the XOR image in the device's
-- format (here 4 bits per pixel, one plane).

local iconCache = setmetatable({}, {__mode = "k"})
local iconSurfaces = {}   -- bytes -> {and=, xor=, w, h}
local iconCount = 0

function gdi.iconBits(lin)
    local w, h = rw(lin + 4), rw(lin + 6)
    local wbX, planes, bpp = rw(lin + 8), rb(lin + 10), rb(lin + 11)
    local wbA = ((w + 15) // 16) * 2
    return w, h, wbA, wbX, planes, bpp
end

-- Surfaces for an icon's masks, cached by its bytes.
function gdi.iconSurfaces(lin)
    local w, h, wbA, wbX, planes, bpp = gdi.iconBits(lin)
    if w == 0 or h == 0 or w > 256 or h > 256 then return nil end
    local size = 12 + wbA * h + wbX * h * planes
    local bytes = mem.read(lin, size)
    local s = iconSurfaces[bytes]
    if s then return s end
    local andS = fb.new(w, h, true)
    fb.clip(nil)
    fb.bits(andS, bytes:sub(13, 12 + wbA * h), wbA)
    local xorS = fb.new(w, h, false)
    local xo = 13 + wbA * h
    for y = 0, h - 1 do
        for x = 0, w - 1 do
            local c
            if bpp == 4 and planes == 1 then
                local byte = bytes:byte(xo + y * wbX + (x >> 1))
                c = gdi.VGA[(x & 1) == 0 and (byte >> 4) or (byte & 15)]
            elseif bpp == 1 and planes == 4 then
                local idx = 0
                for p = 0, 3 do
                    local byte = bytes:byte(xo + (y * 4 + p) * wbX + (x >> 3))
                    if byte and byte & (0x80 >> (x & 7)) ~= 0 then idx = idx | (1 << p) end
                end
                c = gdi.VGA[idx]
            elseif bpp == 1 then
                local byte = bytes:byte(xo + y * wbX + (x >> 3))
                c = (byte and byte & (0x80 >> (x & 7)) ~= 0) and 0xFFFFFF or 0
            elseif bpp == 8 then
                c = gdi.VGA[(bytes:byte(xo + y * wbX + x) or 0) & 15]
            else
                c = 0
            end
            fb.pixel(xorS, x, y, c)
        end
    end
    iconCount = iconCount + 1
    if iconCount > 400 then   -- forget them all now and then
        for _, v in pairs(iconSurfaces) do fb.free(v["and"]); fb.free(v.xor) end
        iconSurfaces = {}
        iconCount = 1
    end
    s = {["and"] = andS, xor = xorS, w = w, h = h}
    iconSurfaces[bytes] = s
    return s
end

-- Draws an icon (its linear address) on a DC at logical x, y.
function gdi.drawIcon(dc, x, y, lin, dw, dh)
    local s = gdi.iconSurfaces(lin)
    if not s then return false end
    if not useClip(dc) then return true end
    dw, dh = dw or s.w, dh or s.h
    if gdi.onImage then gdi.onImage(dc, x, y, dw, dh) end
    if dw == s.w and dh == s.h then
        fb.bitblt(dc.surface, x + dc.ox, y + dc.oy, s.w, s.h, s["and"], 0, 0, 0x88, 0, 0, 0xFFFFFF)
        useClip(dc)
        fb.bitblt(dc.surface, x + dc.ox, y + dc.oy, s.w, s.h, s.xor, 0, 0, 0x66, 0, 0, 0xFFFFFF)
    else
        fb.stretchblt(dc.surface, x + dc.ox, y + dc.oy, dw, dh, s["and"], 0, 0, s.w, s.h, 0x88, 0, 0, 0xFFFFFF)
        useClip(dc)
        fb.stretchblt(dc.surface, x + dc.ox, y + dc.oy, dw, dh, s.xor, 0, 0, s.w, s.h, 0x66, 0, 0, 0xFFFFFF)
    end
    return true
end

-- Builds an HICON's bytes from an icon resource (a DIB: BITMAPINFOHEADER
-- with double height, palette, XOR rows then AND rows, bottom up).
function gdi.iconFromResource(dib, hotx, hoty)
    local hsize = string.unpack("<I4", dib, 1)
    if hsize ~= 40 then return nil end
    local w, h2, planes, bpp = string.unpack("<i4i4I2I2", dib, 5)
    local h = h2 // 2
    local ncolors = string.unpack("<I4", dib, 33)
    if ncolors == 0 and bpp <= 8 then ncolors = 1 << bpp end
    local pal = {}
    for i = 0, ncolors - 1 do
        local b, g, r = dib:byte(41 + i * 4, 43 + i * 4)
        pal[i] = (r << 16) | (g << 8) | b
    end
    local bits = 41 + ncolors * 4
    local xorStride = ((w * bpp + 31) // 32) * 4
    local andStride = ((w + 31) // 32) * 4
    local andOff = bits + xorStride * h
    local wbA = ((w + 15) // 16) * 2
    local wbX = ((w * 4 + 15) // 16) * 2
    local andRows, xorRows = {}, {}
    local idxCache = {}
    for y = 0, h - 1 do
        local src = h - 1 - y   -- DIBs are bottom-up
        local arow = dib:sub(andOff + src * andStride, andOff + src * andStride + wbA - 1)
        if #arow < wbA then arow = arow .. string.rep("\255", wbA - #arow) end
        andRows[#andRows + 1] = arow
        local xr = {}
        for x = 0, w - 1, 2 do
            local function px(xx)
                if xx >= w then return 0 end
                local v
                if bpp == 4 then
                    local byte = dib:byte(bits + src * xorStride + (xx >> 1)) or 0
                    v = (xx & 1) == 0 and (byte >> 4) or (byte & 15)
                elseif bpp == 1 then
                    local byte = dib:byte(bits + src * xorStride + (xx >> 3)) or 0
                    v = (byte >> (7 - (xx & 7))) & 1
                elseif bpp == 8 then
                    v = dib:byte(bits + src * xorStride + xx) or 0
                else
                    return 0
                end
                local c = pal[v] or 0
                local i = idxCache[c]
                if not i then i = gdi.nearest16(c); idxCache[c] = i end
                return i
            end
            xr[#xr + 1] = string.char((px(x) << 4) | px(x + 1))
        end
        local row = table.concat(xr)
        if #row < wbX then row = row .. string.rep("\0", wbX - #row) end
        xorRows[#xorRows + 1] = row
    end
    local header = string.pack("<i2i2I2I2I2BB", hotx or w // 2, hoty or h // 2, w, h, wbX, 1, 4)
    return header .. table.concat(andRows) .. table.concat(xorRows), w, h
end

return gdi

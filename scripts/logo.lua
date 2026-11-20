-- The startup screen's picture: Windows 3.1's VGALOGO.RLE from the user's
-- files, rebranded at load time as "MICROSOFT WINRETRO, Version 3.2",
-- without the copyright lines. Nothing is redrawn from scratch: the
-- letters are the logo's own (W, I, N and O from WINDOWS; R and T from
-- MICROSOFT, scaled up to WINDOWS' small-cap size; E made from
-- MICROSOFT's F), with their drop shadows regenerated. The "2" is the
-- user's MS Serif (SERIFE.FON) at the size of the "3" beside it.
--
-- RETRO is in Microsoft Works' box colours, letter for letter with "Works".
--
-- The coordinates belong to the standard VGALOGO.RLE (355 x 425); any other
-- picture is shown as it is.

local logo = {}

local BLACK, SHADOW, BG = 0x000000, 0x3F87A3, 0x3DA0C7

-- the WINDOWS line: small caps 33 rows tall, bottom serifs on row 285;
-- MICROSOFT's are 29 rows (212..240)
local SMALLCAP_SCALE = 33 / 29
local BASELINE = 285
local CUT = 158          -- everything right of WIN's N is replaced

-- R E T R O as W o r k s on the Microsoft Works box: pink, teal, lavender, magenta, orange
logo.RETRO_COLORS = {0xC9679A, 0x83C9C4, 0xA698C0, 0xC91053, 0xEE9D68}

-- the line under the version, in the copyright lines' place and style
-- (plain black small serif): MS Serif at this point size
logo.FOOTER = "WITH FATALS ENTERTAINMENT PACK"
logo.FOOTER_POINTS = 10
logo.FOOTER_TOP = 366

local function new(w, h)
    return {w = w, h = h, px = {}}
end

-- Reads the surface into a pixel table.
local function read(id, w, h)
    local img = new(w, h)
    local px = img.px
    for y = 0, h - 1 do
        local row = y * w
        for x = 0, w - 1 do px[row + x] = fb.pixel(id, x, y) end
    end
    return img
end

local function get(img, x, y)
    if x < 0 or y < 0 or x >= img.w or y >= img.h then return BG end
    return img.px[y * img.w + x]
end

local function set(img, x, y, c)
    if x < 0 or y < 0 or x >= img.w or y >= img.h then return end
    img.px[y * img.w + x] = c
end

local function count(img, x0, y0, x1, y1, c)
    local n = 0
    for y = y0, y1 do for x = x0, x1 do if get(img, x, y) == c then n = n + 1 end end end
    return n
end

-- Removes a drop shadow (the black strokes offset by d), keeping the
-- shadow-coloured edge pixels that belong to the letters themselves.
local function stripShadows(img, x0, y0, x1, y1, d)
    local drop = {}
    for y = y0, y1 do
        for x = x0, x1 do
            if get(img, x, y) == SHADOW and get(img, x - d, y - d) == BLACK then drop[#drop + 1] = {x, y} end
        end
    end
    for _, p in ipairs(drop) do set(img, p[1], p[2], BG) end
end

local function addShadows(img, x0, y0, x1, y1, d)
    local add = {}
    local ink = img.ink or {}
    for y = y0, y1 do
        for x = x0, x1 do
            local c = get(img, x, y)
            if (c == BLACK or ink[y * img.w + x]) and get(img, x + d, y + d) == BG then add[#add + 1] = {x + d, y + d} end
        end
    end
    for _, p in ipairs(add) do set(img, p[1], p[2], SHADOW) end
end

local function erase(img, x0, y0, x1, y1)
    for y = y0, y1 do for x = x0, x1 do set(img, x, y, BG) end end
end

-- A letter: the largest connected shape of non-background pixels in a
-- rectangle (bits of the neighbouring letters stay behind), trimmed to its
-- ink. skip(x, y) leaves out pixels that belong to something else.
local function grab(img, x0, y0, x1, y1, skip)
    local g = {map = {}}
    local inside = {}
    for y = y0, y1 do
        for x = x0, x1 do
            local c = get(img, x, y)
            if c ~= BG and not (skip and skip(x, y)) then inside[y * 1000 + x] = c end
        end
    end
    local seen, best = {}, {}
    for k in pairs(inside) do
        if not seen[k] then
            local comp, stack = {}, {k}
            seen[k] = true
            while #stack > 0 do
                local cur = table.remove(stack)
                comp[#comp + 1] = cur
                local cy, cx = cur // 1000, cur % 1000
                for dy = -1, 1 do
                    for dx = -1, 1 do
                        local n = (cy + dy) * 1000 + (cx + dx)
                        if inside[n] and not seen[n] then seen[n] = true; stack[#stack + 1] = n end
                    end
                end
            end
            if #comp > #best then best = comp end
        end
    end
    local minx, miny, maxx, maxy = math.huge, math.huge, -1, -1
    for _, k in ipairs(best) do
        local y, x = k // 1000, k % 1000
        g.map[#g.map + 1] = {x, y, inside[k]}
        minx, miny = math.min(minx, x), math.min(miny, y)
        maxx, maxy = math.max(maxx, x), math.max(maxy, y)
    end
    local pix = {}
    for _, p in ipairs(g.map) do pix[(p[2] - miny) * 1000 + (p[1] - minx)] = p[3] end
    return {w = maxx - minx + 1, h = maxy - miny + 1, pix = pix, y0 = miny, x0 = minx}
end

local function at(g, x, y) return g.pix[y * 1000 + x] end

-- Nearest-neighbour scaling.
local function scale(g, s)
    local w, h = math.floor(g.w * s + 0.5), math.floor(g.h * s + 0.5)
    local out = {w = w, h = h, pix = {}}
    for v = 0, h - 1 do
        for u = 0, w - 1 do
            local c = at(g, math.min(math.floor(u / s), g.w - 1), math.min(math.floor(v / s), g.h - 1))
            if c then out.pix[v * 1000 + u] = c end
        end
    end
    return out
end

-- E from F: F's top arm with its serif, turned upside down, becomes the bottom arm.
local function eFromF(f, stemRight, armRows)
    local e = {w = f.w, h = f.h, pix = {}}
    for k, c in pairs(f.pix) do e.pix[k] = c end
    for y = 0, armRows - 1 do
        for x = stemRight, f.w - 1 do
            local c = at(f, x, y)
            if c then e.pix[(f.h - 1 - y) * 1000 + x] = c end
        end
    end
    return e
end

local function mix(a, b)
    return ((((a >> 16) + (b >> 16)) // 2) << 16) | (((((a >> 8) & 0xFF) + ((b >> 8) & 0xFF)) // 2) << 8) |
           (((a & 0xFF) + (b & 0xFF)) // 2)
end

-- color: draw the letter in that colour, edge pixels too (the colours need
-- the weight against the blue)
local function paste(img, g, x, yBottom, color)
    local y0 = yBottom - g.h + 1
    img.ink = img.ink or {}
    for k, c in pairs(g.pix) do
        local gy, gx = k // 1000, k % 1000
        local px, py = x + gx, y0 + gy
        if color then
            if c == BLACK then
                c = color
                if px >= 0 and py >= 0 and px < img.w and py < img.h then img.ink[py * img.w + px] = true end
            else
                c = color
            end
        end
        set(img, px, py, c)
    end
end

-- Text in MS Serif (the size nearest `points`) as a letter-like ink mask.
local function serifText(fontBytes, points, text)
    if not fontBytes then return nil end
    local best
    for _, b in ipairs(fontBytes) do
        local fid, m = fb.font(b)
        if fid and (not best or math.abs(m.points - points) < math.abs(best.m.points - points)) then best = {fid = fid, m = m} end
    end
    if not best then return nil end
    local tw = fb.text_width(best.fid, text, false) + 8
    local th = best.m.height + 8
    local sid = fb.new(tw, th, true)
    fb.clip(nil)
    fb.patblt(sid, 0, 0, tw, th, 0xFF, 0)
    fb.text(sid, best.fid, 4, 4, text, 0, 0xFFFFFF, false, false, false)
    local tmp = new(tw, th)
    for y = 0, th - 1 do for x = 0, tw - 1 do tmp.px[y * tw + x] = (fb.pixel(sid, x, y) == 0) and BLACK or BG end end
    fb.free(sid)
    -- all of it (every letter), not just the largest shape
    local g = {w = 0, h = 0, pix = {}}
    local minx, miny, maxx, maxy = math.huge, math.huge, -1, -1
    for y = 0, th - 1 do for x = 0, tw - 1 do
        if tmp.px[y * tw + x] == BLACK then
            minx, miny = math.min(minx, x), math.min(miny, y)
            maxx, maxy = math.max(maxx, x), math.max(maxy, y)
        end
    end end
    if maxx < 0 then return nil end
    for y = miny, maxy do for x = minx, maxx do
        if tmp.px[y * tw + x] == BLACK then g.pix[(y - miny) * 1000 + (x - minx)] = BLACK end
    end end
    g.w, g.h = maxx - minx + 1, maxy - miny + 1
    return g
end

-- The ink of the "2" in MS Serif, scaled to `height` rows.
local function serifTwo(fontBytes, height)
    local g = serifText(fontBytes, 18, "2")
    if not g then return nil end
    return scale(g, height / g.h)
end

-- Edits the logo surface in place. Returns true when it was the standard
-- logo and got rebranded.
function logo.rebrand(id, w, h, fontBytes)
    if w ~= 355 or h ~= 425 then return false end
    local img = read(id, w, h)
    -- the standard picture's fingerprint: its black pixels in the two text areas
    if count(img, 50, 205, 300, 300, BLACK) ~= 4183 or count(img, 110, 305, 239, 339, BLACK) ~= 416 then
        return false
    end
    local before = {}
    for k, v in pairs(img.px) do before[k] = v end

    -- MICROSOFT WINDOWS -> MICROSOFT WINRETRO
    stripShadows(img, 50, 205, 340, 305, 4)
    local isReg = function(x, y) return x >= 277 and y >= 230 end    -- the (R) mark beside the T
    local R = grab(img, 135, 207, 158, 242)
    local T = grab(img, 256, 207, 282, 242, isReg)
    local F = grab(img, 234, 207, 255, 242)
    local O = grab(img, 183, 245, 212, 292)
    local E = eFromF(F, 10, 11)
    R, E, T = scale(R, SMALLCAP_SCALE), scale(E, SMALLCAP_SCALE), scale(T, SMALLCAP_SCALE)
    erase(img, CUT, 243, 340, 300)
    local x = CUT + 4
    local colors = logo.RETRO_COLORS
    for i, g in ipairs({R, E, T, R}) do
        paste(img, g, x, BASELINE, colors and colors[i])
        x = x + g.w + 1
    end
    paste(img, O, x, O.y0 + O.h - 1, colors and colors[5])
    addShadows(img, 50, 205, 340, 300, 4)

    -- Version 3.1 -> Version 3.2
    stripShadows(img, 110, 308, 245, 340, 2)
    erase(img, 220, 310, 236, 336)
    local two = serifTwo(fontBytes, 18)
    if two then paste(img, two, 221, 332) end
    addShadows(img, 110, 308, 245, 338, 2)

    -- no copyright lines; the footer in their place, centred on the panel
    erase(img, 55, 358, 300, 395)
    local footer = logo.FOOTER and logo.FOOTER ~= "" and serifText(fontBytes, logo.FOOTER_POINTS, logo.FOOTER)
    if footer then
        local fx = math.max(20, (w - footer.w) // 2)
        paste(img, footer, fx, logo.FOOTER_TOP + footer.h - 1)
    end

    -- write back what changed
    fb.clip(nil)
    for k, c in pairs(img.px) do
        if before[k] ~= c then fb.pixel(id, k % w, k // w, c) end
    end
    return true
end

return logo

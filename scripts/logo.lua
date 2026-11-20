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
-- (plain black small serif): MS Serif at this point size; FOOTER_SCRIPT is
-- set apart in raised gold letters in Windows 3.1's Script font (SCRIPT.FON)
logo.FOOTER = {"WITH ", "Fatals", " ENTERTAINMENT PACK"}
logo.FOOTER_SCRIPT = 2          -- which part is in script
logo.FOOTER_POINTS = 10
logo.FOOTER_BASELINE = 376
-- the script word: its first letter big and upright on the footer line,
-- the rest (joined) on a straight line above, level with the initial's top
logo.SCRIPT_INITIAL_HEIGHT = 34 -- pixels, the initial's capital height
logo.SCRIPT_REST_HEIGHT = 17    -- pixels, the rest's capital height
logo.SCRIPT_REST_GAP = 2        -- between the initial and the rest
logo.SCRIPT_PEN = 3             -- stroke thickness
logo.FOOTER_GAP = nil           -- space between the footer's pieces (nil: as wide as fits)
logo.GOLD = {base = 0xD9A82E, light = 0xFFEE99, dark = 0x6B4A08}

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

-- ---- the Script font: a Windows vector font (strokes, not bitmaps) ----

-- Parses a vector FNT: {ascent, height, first, glyphs[ch] = {width, strokes}}
-- where strokes are polylines of (x, y) from the cell's top-left.
local function vectorFont(data)
    local version = string.unpack("<I2", data, 1)
    local typ = string.unpack("<I2", data, 67)
    if typ & 1 == 0 then return nil end
    local ascent = string.unpack("<I2", data, 75)
    local height = string.unpack("<I2", data, 89)
    local first, last = data:byte(96), data:byte(97)
    local bits = string.unpack("<I4", data, 114)
    local tab = version == 0x100 and 117 or (version == 0x200 and 118 or 148)
    local f = {ascent = ascent, height = height, glyphs = {}}
    for c = first, last do
        local e = tab + (c - first) * 4
        local off, width = string.unpack("<I2I2", data, e + 1)
        local nxt = string.unpack("<I2", data, e + 5)
        local strokes, cur = {}, nil
        local x, y, k, pen = 0, 0, bits + off + 1, true
        local stop = bits + nxt
        while k <= stop do
            local a = string.unpack("b", data, k)
            if a == -128 then
                pen = false
                k = k + 1
            else
                if k + 1 > stop then break end
                local dy = string.unpack("b", data, k + 1)
                k = k + 2
                if pen then
                    if not cur then cur = {x, y}; strokes[#strokes + 1] = cur end
                    cur[#cur + 1] = x + a
                    cur[#cur + 1] = y + dy
                else
                    cur = nil
                end
                x, y = x + a, y + dy
                pen = true
            end
        end
        f.glyphs[c] = {width = width, strokes = strokes}
    end
    return f
end

-- Text drawn with a round pen: a mask {w, h, pix, baseline}. Joined:
-- where a letter's exit stroke doesn't already meet the next letter, a short
-- stroke joins it to the nearest point of that letter, so the word is one line.
local function strokeText(f, text, capHeight, pen, angle)
    local s = capHeight / f.ascent
    local r = pen / 2
    -- every letter's strokes in font units, placed along the line
    local letters = {}
    local cx = 0
    for i = 1, #text do
        local g = f.glyphs[text:byte(i)]
        if g then
            local placed = {}
            for _, st in ipairs(g.strokes) do
                local q = {}
                for j = 1, #st - 1, 2 do q[#q + 1] = cx + st[j]; q[#q + 1] = st[j + 1] end
                placed[#placed + 1] = q
            end
            letters[#letters + 1] = placed
            cx = cx + g.width
        end
    end
    local strokes = {}
    for i, placed in ipairs(letters) do
        for _, q in ipairs(placed) do strokes[#strokes + 1] = q end
        local nextL = letters[i + 1]
        if nextL and #placed > 0 then
            -- the exit: the stroke end furthest right
            local ex, ey
            for _, q in ipairs(placed) do
                for _, j in ipairs({1, #q - 1}) do
                    if not ex or q[j] > ex then ex, ey = q[j], q[j + 1] end
                end
            end
            -- the nearest point of the next letter (along its strokes)
            local bx, by, bd
            for _, q in ipairs(nextL) do
                for j = 1, #q - 3, 2 do
                    local x0, y0, x1, y1 = q[j], q[j + 1], q[j + 2], q[j + 3]
                    for t = 0, 8 do
                        local px, py = x0 + (x1 - x0) * t / 8, y0 + (y1 - y0) * t / 8
                        local d = (px - ex) ^ 2 + (py - ey) ^ 2
                        if not bd or d < bd then bx, by, bd = px, py, d end
                    end
                end
            end
            if bd and bd > 0.25 then strokes[#strokes + 1] = {ex, ey, bx, by} end
        end
    end
    -- tilted: turned about the word's middle, rising to the right
    if angle and angle ~= 0 then
        local a = math.rad(angle)
        local ca, sa = math.cos(a), math.sin(a)
        local mx, my = cx / 2, f.ascent * 0.6
        for _, st in ipairs(strokes) do
            for j = 1, #st - 1, 2 do
                local x, y = st[j] - mx, st[j + 1] - my
                st[j], st[j + 1] = mx + x * ca + y * sa, my - x * sa + y * ca
            end
        end
    end
    local pts = {}
    for _, st in ipairs(strokes) do
        for j = 1, #st - 3, 2 do
            local x0, y0, x1, y1 = st[j] * s, st[j + 1] * s, st[j + 2] * s, st[j + 3] * s
            local n = math.max(1, math.ceil(math.max(math.abs(x1 - x0), math.abs(y1 - y0)) * 2))
            for t = 0, n do
                pts[#pts + 1] = {x0 + (x1 - x0) * t / n, y0 + (y1 - y0) * t / n}
            end
        end
    end
    local pix = {}
    local minx, miny, maxx, maxy = math.huge, math.huge, -math.huge, -math.huge
    for _, p in ipairs(pts) do
        for yy = math.floor(p[2] - r), math.ceil(p[2] + r) do
            for xx = math.floor(p[1] - r), math.ceil(p[1] + r) do
                local dx, dy = xx + 0.5 - p[1], yy + 0.5 - p[2]
                if dx * dx + dy * dy <= r * r + 0.25 then
                    pix[(yy + 100) * 2000 + (xx + 100)] = true
                    minx, miny = math.min(minx, xx), math.min(miny, yy)
                    maxx, maxy = math.max(maxx, xx), math.max(maxy, yy)
                end
            end
        end
    end
    local g = {w = maxx - minx + 1, h = maxy - miny + 1, pix = {}}
    for k in pairs(pix) do
        local y, x = k // 2000 - 100, k % 2000 - 100
        g.pix[(y - miny) * 1000 + (x - minx)] = true
    end
    g.baseline = math.floor(f.ascent * s + 0.5) - miny   -- rows from the mask's top to the baseline
    return g
end

-- Raised gold: lit from the top left, a dark edge bottom right, a drop shadow.
local function pasteRaised(img, g, x, top, gold)
    local function has(u, v) return g.pix[v * 1000 + u] end
    for k in pairs(g.pix) do
        local v, u = k // 1000, k % 1000
        local sx, sy = x + u + 2, top + v + 2
        if get(img, sx, sy) == BG then set(img, sx, sy, SHADOW) end
    end
    for k in pairs(g.pix) do
        local v, u = k // 1000, k % 1000
        local c = gold.base
        if not has(u - 1, v - 1) or not has(u, v - 1) or not has(u - 1, v) then c = gold.light
        elseif not has(u + 1, v + 1) or not has(u, v + 1) or not has(u + 1, v) then c = gold.dark end
        set(img, x + u, top + v, c)
    end
end

-- Edits the logo surface in place. Returns true when it was the standard
-- logo and got rebranded.
function logo.rebrand(id, w, h, fontBytes, scriptBytes)
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
    -- WITH / F / ENTERTAINMENT PACK on the footer line, evenly spaced and
    -- centred; "atals" above it, starting just right of the F, its top level
    -- with the F's top
    local parts = type(logo.FOOTER) == "table" and logo.FOOTER or {logo.FOOTER}
    local script = scriptBytes and vectorFont(scriptBytes)
    local pieces = {}
    local rest
    for i, text in ipairs(parts) do
        local trimmed = text:gsub("^%s+", ""):gsub("%s+$", "")
        local p
        if i == logo.FOOTER_SCRIPT and script then
            p = {g = strokeText(script, trimmed:sub(1, 1), logo.SCRIPT_INITIAL_HEIGHT, logo.SCRIPT_PEN), raised = true}
            p.top = logo.FOOTER_BASELINE - p.g.baseline
            if #trimmed > 1 then
                rest = strokeText(script, trimmed:sub(2), logo.SCRIPT_REST_HEIGHT, logo.SCRIPT_PEN)
                p.rest = rest
            end
        elseif trimmed ~= "" then
            p = {g = serifText(fontBytes, logo.FOOTER_POINTS, trimmed)}
        end
        if p and p.g then pieces[#pieces + 1] = p end
    end
    -- the gaps are measured along the line of capitals (a script letter's
    -- flourishes above and below it don't count), so they look even
    local capH = 8
    local bandTop, bandBottom = logo.FOOTER_BASELINE - capH - 4, logo.FOOTER_BASELINE + 4
    for _, p in ipairs(pieces) do
        p.left, p.right = 0, p.g.w - 1
        if p.raised then
            local lo, hi = math.huge, -1
            for k in pairs(p.g.pix) do
                local v, u = k // 1000, k % 1000
                local y = p.top + v
                if y >= bandTop and y <= bandBottom then lo, hi = math.min(lo, u), math.max(hi, u) end
            end
            if hi >= 0 then p.left, p.right = lo, hi end
        end
        p.vis = p.right - p.left + 1
    end
    local visW = 0
    for _, p in ipairs(pieces) do visW = visW + p.vis end
    local room = 334 - 20 - 16
    local gaps = #pieces - 1
    local gap = logo.FOOTER_GAP or (gaps > 0 and math.min(12, math.max(4, (room - visW) // gaps)) or 0)
    local fx = (w - (visW + gap * gaps)) // 2
    for _, p in ipairs(pieces) do
        local x = fx - p.left
        if p.raised then
            pasteRaised(img, p.g, x, p.top, logo.GOLD)
            if p.rest then
                -- not joined to the initial: a small gap after its right edge
                local rx = math.min(x + p.g.w + logo.SCRIPT_REST_GAP, 334 - 4 - p.rest.w)
                pasteRaised(img, p.rest, rx, p.top, logo.GOLD)
            end
        else
            paste(img, p.g, x, logo.FOOTER_BASELINE)
        end
        fx = fx + p.vis + gap
    end
    -- write back what changed
    fb.clip(nil)
    for k, c in pairs(img.px) do
        if before[k] ~= c then fb.pixel(id, k % w, k // w, c) end
    end
    return true
end

return logo

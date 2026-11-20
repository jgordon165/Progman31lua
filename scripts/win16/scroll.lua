-- Standard window scroll bars (WS_VSCROLL / WS_HSCROLL): drawn with the
-- display driver's arrow bitmaps, tracked with auto-repeat, and the thumb
-- dragged, as in Windows 3.1. A scroll bar whose range is empty is hidden,
-- and the client area grows into its space.

local api = require("win16.api")
local region = require("win16.region")
local res = require("win16.resources")
local user = require("win16.user")

local def = api.def
local WM, COLOR = user.WM, user.COLOR
local C, MT = user.sysColors, user.metrics
local W = user.W

local OBM_UP, OBM_DN, OBM_RG, OBM_LF = 32753, 32752, 32751, 32750
local OBM_UPD, OBM_DND, OBM_RGD, OBM_LFD = 32743, 32742, 32741, 32740

local A = 17   -- arrow box size

-- The bar's rectangle in window coordinates.
local function barRect(w, vertical)
    local cl = w.cl
    if vertical then return {cl[3], cl[2] - 1, cl[3] + A, cl[4] + 1} end
    return {cl[1] - 1, cl[4], cl[3] + 1, cl[4] + A}
end

-- Thumb position along the bar (offset of its start from the bar's start), or nil.
local function thumb(sb, len)
    local track = len - 2 * A + 2
    if track < A or sb.max <= sb.min then return nil, track end
    local frac = (sb.pos - sb.min) / (sb.max - sb.min)
    return A - 1 + math.floor((track - A) * frac + 0.5), track
end

local function bevel(x, y, cw, ch)
    local fill = function(a, b, c, d, col) fb.patblt(0, a, b, c, d, 0xF0, col) end
    fill(x, y, cw, ch, 0)
    fill(x + 1, y + 1, cw - 2, ch - 2, C[COLOR.BTNFACE])
    fill(x + 1, y + 1, cw - 3, 1, 0xFFFFFF)
    fill(x + 1, y + 1, 1, ch - 3, 0xFFFFFF)
    fill(x + 1, y + ch - 2, cw - 2, 1, C[COLOR.BTNSHADOW])
    fill(x + cw - 2, y + 1, 1, ch - 2, C[COLOR.BTNSHADOW])
end

local function paintBar(w, x0, y0, vertical, pressed)
    local sb = vertical and w.vscroll or w.hscroll
    if not sb or not sb.visible then return end
    local r = barRect(w, vertical)
    local x, y = x0 + r[1], y0 + r[2]
    local cw, ch = r[3] - r[1], r[4] - r[2]
    local len = vertical and ch or cw
    fb.patblt(0, x, y, cw, ch, 0xF0, C[COLOR.SCROLLBAR])
    -- the track's frame
    fb.patblt(0, x, y, cw, 1, 0xF0, 0); fb.patblt(0, x, y + ch - 1, cw, 1, 0xF0, 0)
    fb.patblt(0, x, y, 1, ch, 0xF0, 0); fb.patblt(0, x + cw - 1, y, 1, ch, 0xF0, 0)
    local a1 = res.obm(vertical and (pressed == "a1" and OBM_UPD or OBM_UP) or (pressed == "a1" and OBM_LFD or OBM_LF))
    local a2 = res.obm(vertical and (pressed == "a2" and OBM_DND or OBM_DN) or (pressed == "a2" and OBM_RGD or OBM_RG))
    if a1 then fb.bitblt(0, x, y, a1.w, a1.h, a1.surface, 0, 0, 0xCC, 0, 0, 0xFFFFFF) else bevel(x, y, A, A) end
    if vertical then
        if a2 then fb.bitblt(0, x, y + ch - A, a2.w, a2.h, a2.surface, 0, 0, 0xCC, 0, 0, 0xFFFFFF) else bevel(x, y + ch - A, A, A) end
    else
        if a2 then fb.bitblt(0, x + cw - A, y, a2.w, a2.h, a2.surface, 0, 0, 0xCC, 0, 0, 0xFFFFFF) else bevel(x + cw - A, y, A, A) end
    end
    local pos = sb.dragPos and sb.dragPos or thumb(sb, len)
    if sb.dragPos then pos = sb.dragPos end
    if pos then
        if vertical then bevel(x, y + pos, A, A) else bevel(x + pos, y, A, A) end
    end
end

function user.paintScrollBars(w, x0, y0, pressedV, pressedH)
    local any = false
    if w.vscroll and w.vscroll.visible then paintBar(w, x0, y0, true, pressedV); any = true end
    if w.hscroll and w.hscroll.visible then paintBar(w, x0, y0, false, pressedH); any = true end
    if w.vscroll and w.vscroll.visible and w.hscroll and w.hscroll.visible then
        local cl = w.cl
        fb.patblt(0, x0 + cl[3], y0 + cl[4], A - 1, A - 1, 0xF0, C[COLOR.BTNFACE])
    end
    return any
end

local function redrawBars(w, pv, ph)
    if not user.isVisible(w) then return end
    local vis = user.visRegion(w, false)
    if #vis == 0 then return end
    fb.clip(region.flat(vis))
    local x0, y0 = user.screenPos(w)
    user.paintScrollBars(w, x0, y0, pv, ph)
    user.dirty = true
end

local function getBar(w, bar)
    if bar == 1 then
        w.vscroll = w.vscroll or {min = 0, max = 0, pos = 0, visible = false}
        return w.vscroll
    elseif bar == 0 then
        w.hscroll = w.hscroll or {min = 0, max = 0, pos = 0, visible = false}
        return w.hscroll
    end
end

-- Scroll bar controls (class SCROLLBAR) keep their state in the same shape.
user.scrollBarOf = getBar

def("USER", 62, "SetScrollPos", "h i i w", function(h, bar, pos, redraw)
    local w = W(h)
    if not w then return 0 end
    if bar == 2 then return user.scrollCtl(w, "setpos", pos, redraw) end   -- SB_CTL: a SCROLLBAR control
    local sb = getBar(w, bar)
    if not sb then return 0 end
    local old = sb.pos
    sb.pos = math.max(sb.min, math.min(sb.max, pos))
    if redraw ~= 0 and old ~= sb.pos then redrawBars(w) end
    return old
end)
def("USER", 63, "GetScrollPos", "h i", function(h, bar)
    local w = W(h)
    if not w then return 0 end
    if bar == 2 then return user.scrollCtlState(w).pos end
    local sb = getBar(w, bar)
    return sb and sb.pos or 0
end)
def("USER", 64, "SetScrollRange", "h i i i w:v", function(h, bar, lo, hi, redraw)
    local w = W(h)
    if not w then return end
    if bar == 2 then user.scrollCtl(w, "setrange", lo, hi); return end
    local sb = getBar(w, bar)
    if not sb then return end
    sb.min, sb.max = lo, hi
    sb.pos = math.max(lo, math.min(hi, sb.pos))
    local vis = hi > lo
    if vis ~= sb.visible then
        sb.visible = vis
        user.frameChanged(w)
    elseif redraw ~= 0 then
        redrawBars(w)
    end
end)
def("USER", 65, "GetScrollRange", "h i p p:v", function(h, bar, pmin, pmax)
    local w = W(h)
    local sb = w and (bar == 2 and user.scrollCtlState(w) or getBar(w, bar))
    if pmin then mem.ww(pmin, sb and sb.min & 0xFFFF or 0) end
    if pmax then mem.ww(pmax, sb and sb.max & 0xFFFF or 0) end
end)
def("USER", 266, "ShowScrollBar", "h w w:v", function(h, bar, show)
    local w = W(h)
    if not w then return end
    for _, b in ipairs(bar == 3 and {0, 1} or {bar}) do
        local sb = getBar(w, b)
        if sb then sb.visible = show ~= 0 end
    end
    user.frameChanged(w)
end)

-- Tracks a press on a window scroll bar (screen x, y).
function user.trackScrollBar(w, vertical, sx, sy)
    local sb = vertical and w.vscroll or w.hscroll
    if not sb then return end
    local msg = vertical and WM.VSCROLL or WM.HSCROLL
    local x0, y0 = user.screenPos(w)
    local r = barRect(w, vertical)
    local len = vertical and (r[4] - r[2]) or (r[3] - r[1])
    local function along(x, y) return vertical and (y - y0 - r[2]) or (x - x0 - r[1]) end
    local at = along(sx, sy)
    local tpos = thumb(sb, len)
    local part
    if at < A then part = "a1"
    elseif at >= len - A then part = "a2"
    elseif tpos and at >= tpos and at < tpos + A then part = "thumb"
    elseif tpos and at < tpos then part = "p1"
    else part = "p2" end
    local codes = {a1 = 0, a2 = 1, p1 = 2, p2 = 3}

    if part == "thumb" then
        local grab = at - tpos
        local track = len - 2 * A + 2
        local function posFor(a)
            local t = math.max(A - 1, math.min(len - 2 * A + 1, a - grab))
            local frac = (t - (A - 1)) / math.max(track - A, 1)
            return sb.min + math.floor(frac * (sb.max - sb.min) + 0.5), t
        end
        local last = sb.pos
        while true do
            local ev = user.waitInput()
            if ev.kind == "move" or ev.kind == "up" then
                local p, t = posFor(along(ev.e[2], ev.e[3]))
                sb.dragPos = t
                redrawBars(w)
                if p ~= last then
                    last = p
                    user.send(w, msg, 5, api.mklong(p, 0))       -- SB_THUMBTRACK
                end
                if ev.kind == "up" then
                    sb.dragPos = nil
                    user.send(w, msg, 4, api.mklong(p, 0))       -- SB_THUMBPOSITION
                    break
                end
            end
        end
    else
        local code = codes[part]
        local pressed = (part == "a1" or part == "a2") and part or nil
        local function press()
            user.send(w, msg, code, 0)
        end
        if vertical then redrawBars(w, pressed) else redrawBars(w, nil, pressed) end
        press()
        local nextAt = host.ticks() + 400
        local inside = true
        while true do
            local ev = user.waitInput(math.max(nextAt - host.ticks(), 1))
            if ev then
                if ev.kind == "up" then break end
                if ev.kind == "move" then
                    local a = along(ev.e[2], ev.e[3])
                    local tp = thumb(sb, len)
                    if part == "a1" then inside = a < A
                    elseif part == "a2" then inside = a >= len - A
                    elseif part == "p1" then inside = tp and a < tp and a >= A
                    else inside = tp and a >= tp + A and a < len - A end
                end
            elseif inside then
                -- auto-repeat; a page press stops when the thumb reaches the pointer
                press()
                nextAt = host.ticks() + 50
            else
                nextAt = host.ticks() + 50
            end
        end
    end
    user.buttons[1] = false
    user.send(w, msg, 8, 0)    -- SB_ENDSCROLL
    redrawBars(w)
end

return {}

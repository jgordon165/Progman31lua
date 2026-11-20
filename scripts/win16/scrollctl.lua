-- The SCROLLBAR control class (the sliders in Control Panel's Mouse,
-- Keyboard and Desktop dialogs): horizontal (SBS_HORZ) or vertical
-- (SBS_VERT), driven by SetScrollPos/SetScrollRange with SB_CTL, and
-- reporting to its parent with WM_HSCROLL/WM_VSCROLL (lParam: position,
-- and the control's handle).

local api = require("win16.api")
local gdi = require("win16.gdi")
local res = require("win16.resources")
local user = require("win16.user")

local WM, COLOR = user.WM, user.COLOR
local C = user.sysColors
local W = user.W

local SBS_VERT = 1
local OBM_UP, OBM_DN, OBM_RG, OBM_LF = 32753, 32752, 32751, 32750
local OBM_UPD, OBM_DND, OBM_RGD, OBM_LFD = 32743, 32742, 32741, 32740

local function state(w)
    if not w.sbctl then w.sbctl = {min = 0, max = 100, pos = 0, visible = true} end
    return w.sbctl
end
user.scrollCtlState = state

local function geometry(w)
    local cw, ch = w.cl[3] - w.cl[1], w.cl[4] - w.cl[2]
    local vertical = w.style & SBS_VERT ~= 0
    local len = vertical and ch or cw
    local a = vertical and cw or ch               -- arrow boxes are square
    a = math.min(a, len // 2)
    return vertical, len, a, cw, ch
end

local function thumbAt(sb, len, a)
    local track = len - 2 * a
    if track < a or sb.max <= sb.min then return nil end
    local frac = (sb.pos - sb.min) / (sb.max - sb.min)
    return a + math.floor((track - a) * frac + 0.5)
end

local function bevel(dc, x, y, cw, ch)
    local function f(a, b, c, d, col) fb.patblt(dc.surface, a + dc.ox, b + dc.oy, c, d, 0xF0, col) end
    f(x, y, cw, ch, 0)
    f(x + 1, y + 1, cw - 2, ch - 2, C[COLOR.BTNFACE])
    f(x + 1, y + 1, cw - 3, 1, C[COLOR.BTNHIGHLIGHT] or 0xFFFFFF)
    f(x + 1, y + 1, 1, ch - 3, C[COLOR.BTNHIGHLIGHT] or 0xFFFFFF)
    f(x + 1, y + ch - 2, cw - 2, 1, C[COLOR.BTNSHADOW])
    f(x + cw - 2, y + 1, 1, ch - 2, C[COLOR.BTNSHADOW])
end

-- An arrow box: the display driver's bitmap when it fits, else drawn.
local function arrow(dc, x, y, a, dir, pressed)
    local ids = {up = pressed and OBM_UPD or OBM_UP, down = pressed and OBM_DND or OBM_DN,
                 left = pressed and OBM_LFD or OBM_LF, right = pressed and OBM_RGD or OBM_RG}
    local b = res.obm(ids[dir])
    if b and b.w == a and b.h == a then
        fb.bitblt(dc.surface, x + dc.ox, y + dc.oy, a, a, b.surface, 0, 0, 0xCC, 0, 0, 0xFFFFFF)
        return
    end
    bevel(dc, x, y, a, a)
    -- a small black triangle
    local cx, cy = x + a // 2 + (pressed and 1 or 0), y + a // 2 + (pressed and 1 or 0)
    local n = math.max(2, a // 4)
    for i = 0, n - 1 do
        local col = 0
        if dir == "up" then fb.patblt(dc.surface, cx - i + dc.ox, cy - n // 2 + i + dc.oy, 2 * i + 1, 1, 0xF0, col)
        elseif dir == "down" then fb.patblt(dc.surface, cx - i + dc.ox, cy + n // 2 - i + dc.oy, 2 * i + 1, 1, 0xF0, col)
        elseif dir == "left" then fb.patblt(dc.surface, cx - n // 2 + i + dc.ox, cy - i + dc.oy, 1, 2 * i + 1, 0xF0, col)
        else fb.patblt(dc.surface, cx + n // 2 - i + dc.ox, cy - i + dc.oy, 1, 2 * i + 1, 0xF0, col) end
    end
end

local function paint(w, dc, pressed)
    local sb = state(w)
    local vertical, len, a, cw, ch = geometry(w)
    if not gdi.useClip(dc) then return end
    local function f(x, y, ww, hh, col) fb.patblt(dc.surface, x + dc.ox, y + dc.oy, ww, hh, 0xF0, col) end
    f(0, 0, cw, ch, C[COLOR.SCROLLBAR])
    f(0, 0, cw, 1, 0); f(0, ch - 1, cw, 1, 0); f(0, 0, 1, ch, 0); f(cw - 1, 0, 1, ch, 0)
    if vertical then
        arrow(dc, 0, 0, a, "up", pressed == "a1")
        arrow(dc, 0, ch - a, a, "down", pressed == "a2")
    else
        arrow(dc, 0, 0, a, "left", pressed == "a1")
        arrow(dc, cw - a, 0, a, "right", pressed == "a2")
    end
    local t = sb.dragAt or thumbAt(sb, len, a)
    if t and not w.disabled then
        if vertical then bevel(dc, 0, t, a, a) else bevel(dc, t, 0, a, a) end
    end
    user.dirty = true
end

local function redraw(w, pressed)
    if not user.isVisible(w) then return end
    local hdc = user.getDC(w, false)
    local dc = gdi.dc(hdc)
    if dc then paint(w, dc, pressed) end
    require("win16.handles").free(hdc)
end

-- Tracks a press at client (x, y) until the button comes up.
local function track(w, x, y)
    local sb = state(w)
    local vertical, len, a = geometry(w)
    local msg = vertical and WM.VSCROLL or WM.HSCROLL
    local parent = w.parent
    local function along(px, py) return vertical and py or px end
    local function send(code, pos) user.send(parent, msg, code, ((w.handle & 0xFFFF) << 16) | ((pos or 0) & 0xFFFF)) end
    local at = along(x, y)
    local t = thumbAt(sb, len, a)
    local part
    if at < a then part = "a1" elseif at >= len - a then part = "a2"
    elseif t and at >= t and at < t + a then part = "thumb"
    elseif t and at < t then part = "p1" else part = "p2" end
    local ox, oy = user.clientOrigin(w)
    if part == "thumb" then
        local grab = at - t
        local function posFor(v)
            local tt = math.max(a, math.min(len - 2 * a, v - grab))
            local frac = (tt - a) / math.max(len - 3 * a, 1)
            return sb.min + math.floor(frac * (sb.max - sb.min) + 0.5), tt
        end
        local last = sb.pos
        while true do
            local ev = user.waitInput()
            if ev.kind == "move" or ev.kind == "up" then
                local p, tt = posFor(along(ev.e[2] - ox, ev.e[3] - oy))
                sb.dragAt = tt
                redraw(w)
                if p ~= last then last = p; send(5, p) end          -- SB_THUMBTRACK
                if ev.kind == "up" then
                    sb.dragAt = nil
                    send(4, p)                                      -- SB_THUMBPOSITION
                    break
                end
            end
        end
    else
        local codes = {a1 = 0, a2 = 1, p1 = 2, p2 = 3}
        local pressed = (part == "a1" or part == "a2") and part or nil
        redraw(w, pressed)
        send(codes[part], sb.pos)
        local nextAt = host.ticks() + 400
        while true do
            local ev = user.waitInput(math.max(nextAt - host.ticks(), 1))
            if ev and ev.kind == "up" then break end
            if not ev then
                send(codes[part], sb.pos)
                nextAt = host.ticks() + 50
            end
        end
    end
    user.buttons[1] = false
    send(8, sb.pos)                                                 -- SB_ENDSCROLL
    redraw(w)
end

local function proc(hwnd, msg, wp, lp)
    local w = W(hwnd)
    if not w then return 0 end
    if msg == WM.PAINT then
        local hdc = user.beginPaint(w, nil)
        local dc = gdi.dc(hdc)
        if dc then paint(w, dc) end
        user.endPaint(w, hdc)
        return 0
    elseif msg == WM.ERASEBKGND then
        return 1
    elseif msg == WM.LBUTTONDOWN or msg == WM.LBUTTONDBLCLK then
        if w.style & 0x00010000 ~= 0 then user.setFocus(w) end      -- WS_TABSTOP
        track(w, api.s16(lp & 0xFFFF), api.s16(lp >> 16))
        return 0
    elseif msg == WM.KEYDOWN then
        local vertical = w.style & SBS_VERT ~= 0
        local m = vertical and WM.VSCROLL or WM.HSCROLL
        local code = ({[0x25] = 0, [0x26] = 0, [0x27] = 1, [0x28] = 1, [0x21] = 2, [0x22] = 3, [0x24] = 6, [0x23] = 7})[wp]
        if code then
            user.send(w.parent, m, code, ((w.handle & 0xFFFF) << 16) | (state(w).pos & 0xFFFF))
            user.send(w.parent, m, 8, ((w.handle & 0xFFFF) << 16) | (state(w).pos & 0xFFFF))
        end
        return 0
    elseif msg == WM.GETDLGCODE then
        return 0x0001   -- DLGC_WANTARROWS
    elseif msg == WM.ENABLE then
        user.invalidate(w, nil, true)
        return 0
    end
    return user.defwnd.proc(hwnd, msg, wp, lp)
end

user.registerClass({name = "SCROLLBAR", style = 0x0008, proc = user.luaProc("ScrollBarProc", proc),
                    cursor = res.cursor(32512)})

-- SetScrollPos / SetScrollRange / GetScrollPos / GetScrollRange with SB_CTL
function user.scrollCtl(w, op, a, b)
    local sb = state(w)
    if op == "setpos" then
        local old = sb.pos
        sb.pos = math.max(math.min(sb.min, sb.max), math.min(math.max(sb.min, sb.max), a))
        if b ~= 0 and old ~= sb.pos then redraw(w) end
        return old
    elseif op == "setrange" then
        sb.min, sb.max = a, b
        sb.pos = math.max(math.min(a, b), math.min(math.max(a, b), sb.pos))
        user.invalidate(w, nil, true)
    end
end

return {}

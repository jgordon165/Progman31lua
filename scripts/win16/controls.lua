-- The predefined control classes: BUTTON, STATIC, EDIT, LISTBOX and
-- COMBOBOX, in Windows 3.1's look (check boxes and radio buttons from the
-- display driver's OBM_CHECKBOXES). Their window procedures are Lua.

local api = require("win16.api")
local cpu = require("recomp.cpu")
local gdi = require("win16.gdi")
local handles = require("win16.handles")
local kernel = require("win16.kernel")
local region = require("win16.region")
local res = require("win16.resources")
local user = require("win16.user")

local WM, WS, COLOR = user.WM, user.WS, user.COLOR
local C, MT = user.sysColors, user.metrics
local W = user.W
local rw, ww, rd, wd, wb = mem.rw, mem.ww, mem.rd, mem.wd, mem.wb
local s16 = api.s16

local controls = {}

local function notify(w, code)
    if w.parent and w.parent ~= user.desktop then
        user.send(w.parent, WM.COMMAND, w.id or 0, api.mklong(w.handle, code))
    end
end
controls.notify = notify

-- WM_CTLCOLOR to the parent: the brush to paint with (the DC's colours set too)
local function ctlColor(w, hdc, kind)
    local dc = gdi.dc(hdc)
    dc.text, dc.bk = C[COLOR.WINDOWTEXT], C[COLOR.WINDOW]
    local p = w.parent
    if p and p ~= user.desktop then
        local b = user.send(p, WM.CTLCOLOR, hdc, api.mklong(w.handle, kind)) & 0xFFFF
        if b ~= 0 and handles.get(b, "brush") then return b end
    end
    return user.sysBrush(COLOR.WINDOW)
end
controls.ctlColor = ctlColor

local function size(w) return w.cl[3] - w.cl[1], w.cl[4] - w.cl[2] end

local function paintDC(w)
    local mark = api.mark()
    local _, ps = api.alloc(32)
    local hdc = user.beginPaint(w, ps)
    api.release(mark)
    local dc = gdi.dc(hdc)
    if w.font and w.font ~= 0 then dc.font = w.font end
    return hdc, dc
end

local function endPaint(w, hdc) user.endPaint(w, hdc) end

local function fillc(dc, x, y, cw, ch, color)
    if not gdi.useClip(dc) then return end
    fb.patblt(0, x + dc.ox, y + dc.oy, cw, ch, 0xF0, color)
end

local function hasFocus(w) return user.focus == w end

-- ---- BUTTON ------------------------------------------------------------------------------------------------

local BS_PUSH, BS_DEFPUSH, BS_CHECK, BS_AUTOCHECK, BS_RADIO, BS_3STATE, BS_AUTO3STATE, BS_GROUP, BS_USER, BS_AUTORADIO, BS_OWNERDRAW =
    0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 0xB
local BS_LEFTTEXT = 0x20

local function btype(w) return w.style & 0xF end

local function isRadio(w) local t = btype(w); return t == BS_RADIO or t == BS_AUTORADIO end
local function isCheck(w) local t = btype(w); return t == BS_CHECK or t == BS_AUTOCHECK or t == BS_3STATE or t == BS_AUTO3STATE end

local function drawPush(w, dc)
    local cw, ch = size(w)
    local pressed = w.btnPressed
    local def = btype(w) == BS_DEFPUSH
    local face, sh, hi = C[COLOR.BTNFACE], C[COLOR.BTNSHADOW], C[COLOR.BTNHIGHLIGHT]
    -- the parent's background shows at the cut corners
    local bg = ctlColor(w, dc.handle, 3)
    user.fillRect(dc, {0, 0, cw, ch}, bg)
    local t = def and 2 or 1
    fillc(dc, 1, 0, cw - 2, t, 0); fillc(dc, 1, ch - t, cw - 2, t, 0)
    fillc(dc, 0, 1, t, ch - 2, 0); fillc(dc, cw - t, 1, t, ch - 2, 0)
    local x0, y0, x1, y1 = t, t, cw - t, ch - t
    fillc(dc, x0, y0, x1 - x0, y1 - y0, face)
    if pressed then
        fillc(dc, x0, y0, x1 - x0, 1, sh); fillc(dc, x0, y0, 1, y1 - y0, sh)
    else
        fillc(dc, x0, y0, x1 - x0 - 1, 2, hi); fillc(dc, x0, y0, 2, y1 - y0 - 1, hi)
        fillc(dc, x0 + 1, y1 - 2, x1 - x0 - 1, 2, sh); fillc(dc, x1 - 2, y0 + 1, 2, y1 - y0 - 1, sh)
        fillc(dc, x0, y1 - 1, 1, 1, sh); fillc(dc, x1 - 1, y0, 1, 1, sh)
    end
    local text, ul = user.stripPrefix(w.text)
    local tw, th = gdi.textWidth(dc, text), gdi.fontHeight(dc)
    local tx, ty = (cw - tw) // 2 + (pressed and 1 or 0), (ch - th) // 2 + (pressed and 1 or 0)
    dc.bkMode = 1
    dc.text = w.disabled and C[COLOR.GRAYTEXT] or C[COLOR.BTNTEXT]
    user.prefixText(dc, tx, ty, w.text)
    if hasFocus(w) then user.focusRect(dc, {tx - 2, ty, tx + tw + 2, ty + th}) end
end

local function drawCheck(w, dc)
    local cw, ch = size(w)
    local bg = ctlColor(w, dc.handle, 3)
    user.fillRect(dc, {0, 0, cw, ch}, bg)
    local img = res.obm(32759)
    local bw, bh = 13, 13
    local by = (ch - bh) // 2
    local leftText = w.style & BS_LEFTTEXT ~= 0
    local bx = leftText and (cw - bw) or 0
    if img then
        bw, bh = img.w // 4, img.h // 3
        by = (ch - bh) // 2
        bx = leftText and (cw - bw) or 0
        local col = w.check or 0
        if w.btnPressed then col = col + 2 end
        local row = isRadio(w) and 1 or (btype(w) == BS_3STATE or btype(w) == BS_AUTO3STATE) and w.check == 2 and 2 or 0
        if row == 2 then col = w.btnPressed and 3 or 2 end
        if gdi.useClip(dc) then
            fb.bitblt(0, bx + dc.ox, by + dc.oy, bw, bh, img.surface, col * bw, row * bh, 0xCC, 0, 0, 0xFFFFFF)
        end
    else
        fillc(dc, bx, by, bw, bh, 0)
        fillc(dc, bx + 1, by + 1, bw - 2, bh - 2, 0xFFFFFF)
        if w.check == 1 then fillc(dc, bx + 3, by + 3, bw - 6, bh - 6, 0) end
    end
    local text = user.stripPrefix(w.text)
    local tw, th = gdi.textWidth(dc, text), gdi.fontHeight(dc)
    local tx = leftText and 0 or (bw + 4)
    local ty = (ch - th) // 2
    dc.bkMode = 1
    if w.disabled then dc.text = C[COLOR.GRAYTEXT] end
    user.prefixText(dc, tx, ty, w.text)
    if hasFocus(w) then user.focusRect(dc, {tx - 1, ty, tx + tw + 1, ty + th}) end
end

local function drawGroup(w, dc)
    local cw, ch = size(w)
    local bg = ctlColor(w, dc.handle, 3)
    local th = gdi.fontHeight(dc)
    local y = th // 2
    fillc(dc, 0, y, cw, 1, 0); fillc(dc, 0, ch - 1, cw, 1, 0)
    fillc(dc, 0, y, 1, ch - y, 0); fillc(dc, cw - 1, y, 1, ch - y, 0)
    if w.text ~= "" then
        local text = user.stripPrefix(w.text)
        local tw = gdi.textWidth(dc, text)
        user.fillRect(dc, {6, 0, 6 + tw + 4, th}, bg)
        dc.bkMode = 1
        user.prefixText(dc, 8, 0, w.text)
    end
end

local function drawOwner(w, dc, action)
    local cw, ch = size(w)
    local mark = api.mark()
    local fp, d = api.alloc(26)
    ww(d, 4); ww(d + 2, w.id or 0); ww(d + 4, 0); ww(d + 6, action or 1)
    ww(d + 8, (w.btnPressed and 1 or 0) | (w.disabled and 4 or 0) | (hasFocus(w) and 0x10 or 0))
    ww(d + 10, w.handle); ww(d + 12, dc.handle); api.setrect(d + 14, {0, 0, cw, ch}); wd(d + 22, 0)
    user.send(w.parent, WM.DRAWITEM, w.id or 0, fp)
    api.release(mark)
end

local function buttonClick(w)
    local t = btype(w)
    if t == BS_AUTOCHECK then w.check = (w.check or 0) == 1 and 0 or 1
    elseif t == BS_AUTO3STATE then w.check = ((w.check or 0) + 1) % 3
    elseif t == BS_AUTORADIO then
        -- the others of the group go off
        local p = w.parent
        local list = p.children
        local idx
        for i, c in ipairs(list) do if c == w then idx = i end end
        local function inGroup(c) return c.class.name == "BUTTON" and btype(c) == BS_AUTORADIO end
        -- group: back to the WS_GROUP start, forward until the next WS_GROUP
        local i0 = idx
        while i0 > 1 and list[i0].style & WS.GROUP == 0 and inGroup(list[i0 - 1]) do i0 = i0 - 1 end
        local i1 = idx
        while i1 < #list and list[i1 + 1].style & WS.GROUP == 0 and inGroup(list[i1 + 1]) do i1 = i1 + 1 end
        for i = i0, i1 do
            local c = list[i]
            if c ~= w and c.check == 1 then c.check = 0; user.invalidate(c, nil, true) end
        end
        w.check = 1
    end
    user.invalidate(w, nil, true)
    notify(w, 0)   -- BN_CLICKED
end
controls.buttonClick = buttonClick

local function buttonProc(hwnd, msg, wp, lp)
    local w = W(hwnd)
    if not w then return 0 end
    local t = btype(w)
    if msg == WM.CREATE then
        w.check = 0
        return 0
    elseif msg == WM.PAINT then
        local hdc, dc = paintDC(w)
        if t == BS_GROUP then drawGroup(w, dc)
        elseif t == BS_OWNERDRAW then drawOwner(w, dc, 1)
        elseif isCheck(w) or isRadio(w) then drawCheck(w, dc)
        else drawPush(w, dc) end
        endPaint(w, hdc)
        return 0
    elseif msg == WM.ERASEBKGND then
        return 1
    elseif msg == WM.GETDLGCODE then
        if t == BS_DEFPUSH then return 0x2000 | 0x10 end
        if t == BS_PUSH then return 0x2000 | 0x20 end
        if isRadio(w) then return 0x2000 | 0x40 end
        if t == BS_GROUP then return 0x100 end   -- DLGC_STATIC
        return 0x2000
    elseif msg == WM.LBUTTONDOWN or msg == WM.LBUTTONDBLCLK then
        if t == BS_GROUP then return 0 end
        user.capture = w
        w.btnPressed = true
        user.setFocus(w)
        user.invalidate(w, nil, true)
        return 0
    elseif msg == WM.MOUSEMOVE then
        if user.capture == w then
            local x, y = api.unpt(lp)
            local cw, ch = size(w)
            local inside = x >= 0 and y >= 0 and x < cw and y < ch
            if inside ~= (w.btnPressed or false) then w.btnPressed = inside; user.invalidate(w, nil, true) end
        end
        return 0
    elseif msg == WM.LBUTTONUP then
        if user.capture == w then
            user.capture = nil
            local was = w.btnPressed
            w.btnPressed = false
            user.invalidate(w, nil, true)
            if was then buttonClick(w) end
        end
        return 0
    elseif msg == WM.KEYDOWN then
        if wp == 0x20 and not w.btnPressed then w.btnPressed = true; user.invalidate(w, nil, true) end
        return 0
    elseif msg == WM.KEYUP then
        if wp == 0x20 and w.btnPressed then
            w.btnPressed = false
            user.invalidate(w, nil, true)
            buttonClick(w)
        end
        return 0
    elseif msg == WM.CHAR then
        if wp == 0x20 then return 0 end
        return user.defwnd.proc(hwnd, msg, wp, lp)
    elseif msg == WM.SETFOCUS or msg == WM.KILLFOCUS then
        if msg == WM.KILLFOCUS and w.btnPressed then w.btnPressed = false end
        user.invalidate(w, nil, true)
        if t == BS_PUSH or t == BS_DEFPUSH or t == BS_OWNERDRAW then
            notify(w, msg == WM.SETFOCUS and 6 or 7)  -- BN_SETFOCUS/BN_KILLFOCUS (3.1 sends these for owner-draw only)
        end
        return 0
    elseif msg == WM.ENABLE then
        user.invalidate(w, nil, true)
        return 0
    elseif msg == WM.SETTEXT then
        local r = user.defwnd.proc(hwnd, msg, wp, lp)
        user.invalidate(w, nil, true)
        return r
    elseif msg == 0x400 then       -- BM_GETCHECK
        return w.check or 0
    elseif msg == 0x401 then       -- BM_SETCHECK
        if w.check ~= wp then w.check = wp; user.invalidate(w, nil, true) end
        return 0
    elseif msg == 0x402 then       -- BM_GETSTATE
        return (w.check or 0) | (w.btnPressed and 4 or 0) | (hasFocus(w) and 8 or 0)
    elseif msg == 0x403 then       -- BM_SETSTATE
        w.btnPressed = wp ~= 0
        user.invalidate(w, nil, true)
        return 0
    elseif msg == 0x404 then       -- BM_SETSTYLE
        w.style = (w.style & ~0xFFFF) | (wp & 0xFFFF)
        if lp ~= 0 then user.invalidate(w, nil, true) end
        return 0
    elseif msg == WM.SETFONT then
        w.font = wp
        if lp ~= 0 then user.invalidate(w, nil, true) end
        return 0
    end
    return user.defwnd.proc(hwnd, msg, wp, lp)
end

-- ---- STATIC ----------------------------------------------------------------------------------------------

local SS_ICON, SS_BLACKRECT, SS_GRAYRECT, SS_WHITERECT, SS_BLACKFRAME, SS_GRAYFRAME, SS_WHITEFRAME = 3, 4, 5, 6, 7, 8, 9
local SS_SIMPLE, SS_LEFTNOWORDWRAP, SS_NOPREFIX = 0xB, 0xC, 0x80

local function staticProc(hwnd, msg, wp, lp)
    local w = W(hwnd)
    if not w then return 0 end
    local kind = w.style & 0xF
    if msg == WM.CREATE then
        if kind == SS_ICON and w.text ~= "" then
            local name = w.iconName or w.text
            w.icon = (user.module and require("win16.resources").moduleIcon(user.module, name)) or res.systemIcon(name)
            w.text = ""
            user.setPos(w, w.x, w.y, MT.CXICON, MT.CYICON)
        end
        return 0
    elseif msg == WM.PAINT then
        local hdc, dc = paintDC(w)
        local cw, ch = size(w)
        local bg = ctlColor(w, hdc, 6)
        if kind == SS_ICON then
            user.fillRect(dc, {0, 0, cw, ch}, bg)
            local lin = w.icon and kernel.glin(w.icon)
            if lin then gdi.drawIcon(dc, 0, 0, lin) end
        elseif kind >= SS_BLACKRECT and kind <= SS_WHITEFRAME then
            local col = ({[4] = 0, [5] = C[COLOR.BTNSHADOW], [6] = 0xFFFFFF, [7] = 0, [8] = C[COLOR.BTNSHADOW], [9] = 0xFFFFFF})[kind]
            if kind <= SS_WHITERECT then fillc(dc, 0, 0, cw, ch, col)
            else
                fillc(dc, 0, 0, cw, 1, col); fillc(dc, 0, ch - 1, cw, 1, col)
                fillc(dc, 0, 0, 1, ch, col); fillc(dc, cw - 1, 0, 1, ch, col)
            end
        else
            user.fillRect(dc, {0, 0, cw, ch}, bg)
            local fmt = (kind == 1 and 1) or (kind == 2 and 2) or 0
            if kind == SS_SIMPLE or kind == SS_LEFTNOWORDWRAP then fmt = 0x20 else fmt = fmt | 0x10 end
            if w.style & SS_NOPREFIX ~= 0 then fmt = fmt | 0x800 end
            dc.bkMode = 1
            if w.disabled then dc.text = C[COLOR.GRAYTEXT] end
            user.drawText(dc, w.text, {0, 0, cw, ch}, fmt | 0x40)
        end
        endPaint(w, hdc)
        return 0
    elseif msg == WM.ERASEBKGND then
        return 1
    elseif msg == WM.SETTEXT then
        local r = user.defwnd.proc(hwnd, msg, wp, lp)
        user.invalidate(w, nil, true)
        return r
    elseif msg == WM.NCHITTEST then
        return -1 & 0xFFFF   -- HTTRANSPARENT
    elseif msg == WM.GETDLGCODE then
        return 0x100
    elseif msg == 0x400 then   -- STM_SETICON
        local old = w.icon or 0
        w.icon = wp
        user.invalidate(w, nil, true)
        return old
    elseif msg == 0x401 then   -- STM_GETICON
        return w.icon or 0
    elseif msg == WM.SETFONT then
        w.font = wp
        if lp ~= 0 then user.invalidate(w, nil, true) end
        return 0
    elseif msg == WM.ENABLE then
        user.invalidate(w, nil, true)
        return 0
    end
    return user.defwnd.proc(hwnd, msg, wp, lp)
end

-- ---- EDIT (single line; multiple lines are drawn but edited as one) ---------------------------------------------------

local ES_CENTER, ES_RIGHT, ES_MULTILINE, ES_UPPERCASE, ES_LOWERCASE, ES_PASSWORD, ES_AUTOHSCROLL, ES_READONLY =
    1, 2, 4, 8, 0x10, 0x20, 0x80, 0x800

user.clipboard = ""

local function editState(w)
    if not w.ed then w.ed = {s0 = 0, s1 = 0, scroll = 0, limit = 30000, modified = false} end
    return w.ed
end

local function editShown(w)
    if w.style & ES_PASSWORD ~= 0 then return string.rep("*", #w.text) end
    return w.text
end

local function editCaretX(w, dc, pos)
    return gdi.textWidth(dc, editShown(w):sub(1, pos))
end

local function editFont(w)
    local dc = {font = (w.font and w.font ~= 0) and w.font or gdi.stock(13)}
    return dc
end

local function editEnsureVisible(w)
    local e = editState(w)
    local dc = editFont(w)
    local cw = size(w)
    local x = gdi.textWidth(dc, editShown(w):sub(1, e.s1))
    local margin = 1
    if x - e.scroll > cw - 2 then e.scroll = x - cw + 2 + 8 end
    if x - e.scroll < 0 then e.scroll = math.max(0, x - 8) end
end

local function editChanged(w)
    local e = editState(w)
    e.modified = true
    editEnsureVisible(w)
    user.invalidate(w, nil, true)
    notify(w, 0x400)   -- EN_UPDATE
    notify(w, 0x300)   -- EN_CHANGE
end

local function editReplace(w, s)
    local e = editState(w)
    local a, b = math.min(e.s0, e.s1), math.max(e.s0, e.s1)
    if w.style & ES_UPPERCASE ~= 0 then s = user.upper(s) elseif w.style & ES_LOWERCASE ~= 0 then s = user.lower(s) end
    if w.style & ES_MULTILINE == 0 then s = s:gsub("[\r\n].*", "") end
    local new = w.text:sub(1, a) .. s .. w.text:sub(b + 1)
    if #new > e.limit then
        s = s:sub(1, math.max(0, e.limit - (#w.text - (b - a))))
        new = w.text:sub(1, a) .. s .. w.text:sub(b + 1)
        notify(w, 0x501)   -- EN_MAXTEXT
    end
    w.text = new
    e.s0, e.s1 = a + #s, a + #s
    editChanged(w)
end

local function editPosAt(w, x)
    local e = editState(w)
    local dc = editFont(w)
    local s = editShown(w)
    x = x + e.scroll - 1
    local best, bd = 0, math.huge
    for i = 0, #s do
        local d = math.abs(gdi.textWidth(dc, s:sub(1, i)) - x)
        if d < bd then best, bd = i, d end
    end
    return best
end

local function isWordChar(c) return c:match("[%w_]") ~= nil end

local function editProc(hwnd, msg, wp, lp)
    local w = W(hwnd)
    if not w then return 0 end
    local e = editState(w)
    if msg == WM.CREATE then
        e.s0, e.s1 = 0, 0
        return 0
    elseif msg == WM.PAINT then
        local hdc, dc = paintDC(w)
        local cw, ch = size(w)
        local bg = ctlColor(w, hdc, 1)
        user.fillRect(dc, {0, 0, cw, ch}, bg)
        local s = editShown(w)
        local th = gdi.fontHeight(dc)
        local ty = w.style & ES_MULTILINE ~= 0 and 0 or math.max((ch - th) // 2, 0)
        local x = 1 - e.scroll
        if w.disabled then dc.text = C[COLOR.GRAYTEXT] end
        dc.bkMode = 2
        local a, b = math.min(e.s0, e.s1), math.max(e.s0, e.s1)
        local focused = hasFocus(w)
        if focused and a ~= b then
            local x1 = x + gdi.textWidth(dc, s:sub(1, a))
            local x2 = x + gdi.textWidth(dc, s:sub(1, b))
            gdi.textOut(dc, x, ty, s:sub(1, a))
            local ot, ob = dc.text, dc.bk
            dc.text, dc.bk = C[COLOR.HIGHLIGHTTEXT], C[COLOR.HIGHLIGHT]
            gdi.textOut(dc, x1, ty, s:sub(a + 1, b))
            dc.text, dc.bk = ot, ob
            gdi.textOut(dc, x2, ty, s:sub(b + 1))
        else
            gdi.textOut(dc, x, ty, s)
        end
        if focused and w.style & ES_READONLY == 0 then
            local cx = x + gdi.textWidth(dc, s:sub(1, e.s1))
            if gdi.useClip(dc) then fb.patblt(0, cx + dc.ox, ty + dc.oy, 1, th, 0x55, 0) end
        end
        endPaint(w, hdc)
        return 0
    elseif msg == WM.ERASEBKGND then
        return 1
    elseif msg == WM.GETDLGCODE then
        local code = 0x80 | 0x01   -- DLGC_WANTCHARS | DLGC_WANTARROWS
        code = code | 0x8000        -- DLGC_HASSETSEL
        if w.style & ES_MULTILINE ~= 0 then code = code | 0x04 end
        return code
    elseif msg == WM.SETFOCUS then
        user.invalidate(w, nil, true)
        notify(w, 0x100)  -- EN_SETFOCUS
        return 0
    elseif msg == WM.KILLFOCUS then
        user.invalidate(w, nil, true)
        notify(w, 0x200)  -- EN_KILLFOCUS
        return 0
    elseif msg == WM.LBUTTONDOWN then
        user.setFocus(w)
        local x = api.unpt(lp)
        local p = editPosAt(w, x)
        if user.keys[0x10] then e.s1 = p else e.s0, e.s1 = p, p end
        user.capture = w
        user.invalidate(w, nil, true)
        return 0
    elseif msg == WM.LBUTTONDBLCLK then
        local s = w.text
        local p = e.s1
        local a, b = p, p
        while a > 0 and isWordChar(s:sub(a, a)) do a = a - 1 end
        while b < #s and isWordChar(s:sub(b + 1, b + 1)) do b = b + 1 end
        e.s0, e.s1 = a, b
        user.invalidate(w, nil, true)
        return 0
    elseif msg == WM.MOUSEMOVE then
        if user.capture == w then
            local x = api.unpt(lp)
            local p = editPosAt(w, x)
            if p ~= e.s1 then e.s1 = p; editEnsureVisible(w); user.invalidate(w, nil, true) end
        end
        return 0
    elseif msg == WM.LBUTTONUP then
        if user.capture == w then user.capture = nil end
        return 0
    elseif msg == WM.SETCURSOR then
        user.setCursor("ibeam")
        return 1
    elseif msg == WM.KEYDOWN then
        local shift, ctrl = user.keys[0x10], user.keys[0x11]
        local s = w.text
        local function move(p)
            p = math.max(0, math.min(#s, p))
            if shift then e.s1 = p else e.s0, e.s1 = p, p end
            editEnsureVisible(w)
            user.invalidate(w, nil, true)
        end
        if wp == 0x25 then        -- left
            if not shift and e.s0 ~= e.s1 then move(math.min(e.s0, e.s1))
            elseif ctrl then
                local p = e.s1
                while p > 0 and not isWordChar(s:sub(p, p)) do p = p - 1 end
                while p > 0 and isWordChar(s:sub(p, p)) do p = p - 1 end
                move(p)
            else move(e.s1 - 1) end
        elseif wp == 0x27 then    -- right
            if not shift and e.s0 ~= e.s1 then move(math.max(e.s0, e.s1))
            elseif ctrl then
                local p = e.s1
                while p < #s and isWordChar(s:sub(p + 1, p + 1)) do p = p + 1 end
                while p < #s and not isWordChar(s:sub(p + 1, p + 1)) do p = p + 1 end
                move(p)
            else move(e.s1 + 1) end
        elseif wp == 0x24 then move(0)
        elseif wp == 0x23 then move(#s)
        elseif wp == 0x2E and w.style & ES_READONLY == 0 then   -- Delete
            if shift and e.s0 ~= e.s1 then
                local a, b = math.min(e.s0, e.s1), math.max(e.s0, e.s1)
                user.clipboard = s:sub(a + 1, b)
                editReplace(w, "")
            else
                if e.s0 == e.s1 then e.s1 = math.min(#s, e.s1 + 1) end
                editReplace(w, "")
            end
        elseif wp == 0x2D then    -- Insert: Ctrl copy, Shift paste
            if ctrl then
                local a, b = math.min(e.s0, e.s1), math.max(e.s0, e.s1)
                if a ~= b then user.clipboard = s:sub(a + 1, b) end
            elseif shift and w.style & ES_READONLY == 0 then
                editReplace(w, user.clipboard)
            end
        end
        return 0
    elseif msg == WM.CHAR then
        if w.style & ES_READONLY ~= 0 then return 0 end
        local s = w.text
        if wp == 0x08 then        -- backspace
            if e.s0 == e.s1 and e.s1 > 0 then e.s0 = e.s1 - 1 end
            editReplace(w, "")
        elseif wp == 0x03 then    -- Ctrl+C
            local a, b = math.min(e.s0, e.s1), math.max(e.s0, e.s1)
            if a ~= b then user.clipboard = s:sub(a + 1, b) end
        elseif wp == 0x18 then    -- Ctrl+X
            local a, b = math.min(e.s0, e.s1), math.max(e.s0, e.s1)
            if a ~= b then user.clipboard = s:sub(a + 1, b); editReplace(w, "") end
        elseif wp == 0x16 then    -- Ctrl+V
            editReplace(w, user.clipboard)
        elseif wp == 0x01 then    -- Ctrl+A (not in 3.1, but harmless)
            e.s0, e.s1 = 0, #s
            user.invalidate(w, nil, true)
        elseif wp >= 0x20 then
            editReplace(w, string.char(wp))
        end
        return 0
    elseif msg == WM.SETTEXT then
        local l = cpu.flat(lp)
        w.text = l and mem.cstr(l) or ""
        if #w.text > e.limit then w.text = w.text:sub(1, e.limit) end
        e.s0, e.s1, e.scroll = 0, 0, 0
        e.modified = false
        user.invalidate(w, nil, true)
        notify(w, 0x400)
        notify(w, 0x300)
        return 1
    elseif msg == 0x400 then       -- EM_GETSEL
        return api.mklong(math.min(e.s0, e.s1), math.max(e.s0, e.s1))
    elseif msg == 0x401 then       -- EM_SETSEL: lParam = MAKELONG(start, end)
        local a, b = lp & 0xFFFF, lp >> 16
        if a == 0xFFFF then a = e.s1; b = e.s1 end
        if b == 0xFFFF or b > #w.text then b = #w.text end
        if a > #w.text then a = #w.text end
        e.s0, e.s1 = a, b
        editEnsureVisible(w)
        user.invalidate(w, nil, true)
        return 1
    elseif msg == 0x408 then       -- EM_GETMODIFY
        return e.modified and 1 or 0
    elseif msg == 0x409 then       -- EM_SETMODIFY
        e.modified = wp ~= 0
        return 0
    elseif msg == 0x412 then       -- EM_REPLACESEL
        local l = cpu.flat(lp)
        editReplace(w, l and mem.cstr(l) or "")
        return 0
    elseif msg == 0x415 then       -- EM_LIMITTEXT
        e.limit = wp == 0 and 30000 or wp
        return 0
    elseif msg == 0x40A then       -- EM_GETLINECOUNT
        return 1
    elseif msg == 0x41C or msg == 0x418 then   -- EM_CANUNDO / EM_UNDO
        return 0
    elseif msg == WM.SETFONT then
        w.font = wp
        if lp ~= 0 then user.invalidate(w, nil, true) end
        return 0
    elseif msg == WM.ENABLE then
        user.invalidate(w, nil, true)
        return 0
    end
    return user.defwnd.proc(hwnd, msg, wp, lp)
end

-- ---- LISTBOX -------------------------------------------------------------------------------------------------

local LBS_NOTIFY, LBS_SORT, LBS_NOREDRAW, LBS_MULTIPLESEL, LBS_OWNERDRAWFIXED, LBS_OWNERDRAWVARIABLE, LBS_HASSTRINGS =
    1, 2, 4, 8, 0x10, 0x20, 0x40
local LBS_MULTICOLUMN = 0x200

local function lbState(w)
    if not w.lb then w.lb = {items = {}, sel = -1, top = 0, itemH = 16, colW = 0, caret = 0} end
    return w.lb
end

local function lbOwner(w) return w.style & (LBS_OWNERDRAWFIXED | LBS_OWNERDRAWVARIABLE) ~= 0 end
local function lbStrings(w) return not lbOwner(w) or w.style & LBS_HASSTRINGS ~= 0 end

local function lbRows(w)
    local lb = lbState(w)
    local _, ch = size(w)
    return math.max(ch // lb.itemH, 1)
end

local function lbItemRect(w, i)
    local lb = lbState(w)
    local cw = size(w)
    if w.style & LBS_MULTICOLUMN ~= 0 then
        local rows = lbRows(w)
        local colW = lb.colW > 0 and lb.colW or 120
        local col = i // rows - lb.top // rows
        local row = i % rows
        return {col * colW, row * lb.itemH, col * colW + colW, row * lb.itemH + lb.itemH}
    end
    local y = (i - lb.top) * lb.itemH
    return {0, y, cw, y + lb.itemH}
end

local function lbUpdateScroll(w)
    local lb = lbState(w)
    local n = #lb.items
    if w.style & LBS_MULTICOLUMN ~= 0 then
        if w.hscroll or w.style & WS.HSCROLL ~= 0 then
            local rows = lbRows(w)
            local cw = size(w)
            local colW = lb.colW > 0 and lb.colW or 120
            local cols = (n + rows - 1) // rows
            local visibleCols = math.max(cw // colW, 1)
            local sb = user.scrollBarOf(w, 0)
            local max = math.max(cols - visibleCols, 0)
            local vis = max > 0
            sb.min, sb.max = 0, max
            sb.pos = math.max(0, math.min(max, lb.top // rows))
            if sb.visible ~= vis then sb.visible = vis; user.frameChanged(w) end
        end
    elseif w.style & WS.VSCROLL ~= 0 then
        local rows = lbRows(w)
        local sb = user.scrollBarOf(w, 1)
        local max = math.max(n - rows, 0)
        sb.min, sb.max = 0, max
        sb.pos = math.max(0, math.min(max, lb.top))
        local vis = max > 0
        if sb.visible ~= vis then sb.visible = vis; user.frameChanged(w) end
    end
    w.ncdirty = true
    user.dirty = true
end

local function lbMeasure(w)
    local lb = lbState(w)
    if not lbOwner(w) then
        lb.itemH = gdi.fontHeight({font = (w.font and w.font ~= 0) and w.font or gdi.stock(13)})
        return
    end
    local mark = api.mark()
    local fp, m = api.alloc(14)
    ww(m, 2); ww(m + 2, w.id or 0); ww(m + 4, 0); ww(m + 6, 0); ww(m + 8, 16); wd(m + 10, 0)
    user.send(w.parent, WM.MEASUREITEM, w.id or 0, fp)
    lb.itemH = math.max(rw(m + 8), 1)
    api.release(mark)
end

local function lbDrawItem(w, dc, i, action)
    local lb = lbState(w)
    local it = lb.items[i + 1]
    if not it then return end
    local r = lbItemRect(w, i)
    local selected = lb.sel == i or it.selected
    if lbOwner(w) then
        local mark = api.mark()
        local fp, d = api.alloc(26)
        ww(d, 2); ww(d + 2, w.id or 0); ww(d + 4, i); ww(d + 6, action or 1)
        ww(d + 8, (selected and 1 or 0) | (w.disabled and 4 or 0) | ((hasFocus(w) and lb.caret == i) and 0x10 or 0))
        ww(d + 10, w.handle); ww(d + 12, dc.handle); api.setrect(d + 14, r); wd(d + 22, it.data or 0)
        user.send(w.parent, WM.DRAWITEM, w.id or 0, fp)
        api.release(mark)
        return
    end
    if selected then
        user.fillRect(dc, r, user.sysBrush(COLOR.HIGHLIGHT))
        dc.text, dc.bk = C[COLOR.HIGHLIGHTTEXT], C[COLOR.HIGHLIGHT]
    else
        dc.text, dc.bk = C[COLOR.WINDOWTEXT], C[COLOR.WINDOW]
    end
    dc.bkMode = 1
    gdi.textOut(dc, r[1] + 2, r[2], it.text or "")
    if hasFocus(w) and lb.caret == i then user.focusRect(dc, r) end
end

local function lbSort(w, text)
    local lb = lbState(w)
    if w.style & LBS_SORT == 0 or not lbStrings(w) then return #lb.items + 1 end
    local u = user.upper(text)
    for i, it in ipairs(lb.items) do
        if user.upper(it.text or "") > u then return i end
    end
    return #lb.items + 1
end

local function lbChanged(w)
    lbUpdateScroll(w)
    if not w.noRedraw then user.invalidate(w, nil, true) end
end

local function lbSetSel(w, i, notifyIt)
    local lb = lbState(w)
    if i < -1 or i >= #lb.items then i = -1 end
    if lb.sel == i then return end
    lb.sel = i
    if i >= 0 then lb.caret = i end
    -- keep it in view
    if i >= 0 then
        local rows = lbRows(w)
        if w.style & LBS_MULTICOLUMN ~= 0 then
            local cw = size(w)
            local colW = lb.colW > 0 and lb.colW or 120
            local visCols = math.max(cw // colW, 1)
            local col, topCol = i // rows, lb.top // rows
            if col < topCol then lb.top = col * rows
            elseif col >= topCol + visCols then lb.top = (col - visCols + 1) * rows end
        else
            if i < lb.top then lb.top = i elseif i >= lb.top + rows then lb.top = i - rows + 1 end
        end
    end
    lbChanged(w)
    if notifyIt and w.style & LBS_NOTIFY ~= 0 then notify(w, 1) end  -- LBN_SELCHANGE
end
controls.lbSetSel = lbSetSel

local function lbIndexAt(w, x, y)
    local lb = lbState(w)
    for i = 0, #lb.items - 1 do
        local r = lbItemRect(w, i)
        if x >= r[1] and x < r[3] and y >= r[2] and y < r[4] then return i end
    end
    return -1
end

local function lbProc(hwnd, msg, wp, lp)
    local w = W(hwnd)
    if not w then return 0 end
    local lb = lbState(w)
    if msg == WM.CREATE then
        lbMeasure(w)
        lbUpdateScroll(w)
        return 0
    elseif msg == WM.PAINT then
        local hdc, dc = paintDC(w)
        local cw, ch = size(w)
        local bg = ctlColor(w, hdc, 2)
        user.fillRect(dc, {0, 0, cw, ch}, bg)
        for i = lb.top, #lb.items - 1 do
            local r = lbItemRect(w, i)
            if r[1] >= cw or (w.style & LBS_MULTICOLUMN == 0 and r[2] >= ch) then break end
            lbDrawItem(w, dc, i, 1)
        end
        endPaint(w, hdc)
        return 0
    elseif msg == WM.ERASEBKGND then
        return 1
    elseif msg == WM.GETDLGCODE then
        return 0x01 | 0x80
    elseif msg == WM.SETFOCUS or msg == WM.KILLFOCUS then
        user.invalidate(w, nil, true)
        if w.style & LBS_NOTIFY ~= 0 then notify(w, msg == WM.SETFOCUS and 4 or 5) end
        return 0
    elseif msg == WM.LBUTTONDOWN then
        user.setFocus(w)
        local x, y = api.unpt(lp)
        local i = lbIndexAt(w, x, y)
        if i >= 0 then lbSetSel(w, i, true) end
        user.capture = w
        return 0
    elseif msg == WM.MOUSEMOVE then
        if user.capture == w then
            local x, y = api.unpt(lp)
            local i = lbIndexAt(w, x, y)
            if i >= 0 then lbSetSel(w, i, true) end
        end
        return 0
    elseif msg == WM.LBUTTONUP then
        if user.capture == w then user.capture = nil end
        return 0
    elseif msg == WM.LBUTTONDBLCLK then
        local x, y = api.unpt(lp)
        local i = lbIndexAt(w, x, y)
        if i >= 0 then
            lbSetSel(w, i, true)
            if w.style & LBS_NOTIFY ~= 0 then notify(w, 2) end   -- LBN_DBLCLK
        end
        return 0
    elseif msg == WM.KEYDOWN then
        local n = #lb.items
        if n == 0 then return 0 end
        local i = lb.sel >= 0 and lb.sel or 0
        local rows = lbRows(w)
        local multi = w.style & LBS_MULTICOLUMN ~= 0
        if wp == 0x26 then i = i - 1
        elseif wp == 0x28 then i = i + 1
        elseif wp == 0x25 then i = multi and i - rows or i - 1
        elseif wp == 0x27 then i = multi and i + rows or i + 1
        elseif wp == 0x21 then i = i - rows
        elseif wp == 0x22 then i = i + rows
        elseif wp == 0x24 then i = 0
        elseif wp == 0x23 then i = n - 1
        else return 0 end
        lbSetSel(w, math.max(0, math.min(n - 1, i)), true)
        return 0
    elseif msg == WM.CHAR then
        if lbStrings(w) and wp >= 0x20 then
            local c = string.char(wp):upper()
            local n = #lb.items
            for k = 1, n do
                local i = (lb.sel + k) % n
                local t = lb.items[i + 1].text or ""
                if t:sub(1, 1):upper() == c then lbSetSel(w, i, true); break end
            end
        end
        return 0
    elseif msg == WM.VSCROLL or msg == WM.HSCROLL then
        local rows = lbRows(w)
        local step = msg == WM.HSCROLL and rows or 1
        local n = #lb.items
        local maxTop = msg == WM.HSCROLL and math.max(((n + rows - 1) // rows - 1) * rows, 0) or math.max(n - rows, 0)
        local code = wp
        local top = lb.top
        if code == 0 then top = top - step
        elseif code == 1 then top = top + step
        elseif code == 2 then top = top - step * (msg == WM.HSCROLL and 1 or rows)
        elseif code == 3 then top = top + step * (msg == WM.HSCROLL and 1 or rows)
        elseif code == 4 or code == 5 then top = (lp & 0xFFFF) * step
        elseif code == 6 then top = 0
        elseif code == 7 then top = maxTop end
        if msg == WM.HSCROLL then
            local cw = size(w)
            local colW = lb.colW > 0 and lb.colW or 120
            local visCols = math.max(cw // colW, 1)
            maxTop = math.max(((n + rows - 1) // rows - visCols) * rows, 0)
        end
        lb.top = math.max(0, math.min(maxTop, top))
        lbChanged(w)
        return 0
    elseif msg == WM.SIZE then
        lbUpdateScroll(w)
        return 0
    -- LB_ADDSTRING / LB_INSERTSTRING
    elseif msg == 0x401 or msg == 0x402 then
        local text, data
        if lbStrings(w) then
            local l = cpu.flat(lp)
            text = l and mem.cstr(l) or ""
            data = 0
        else
            data = lp
            text = nil
        end
        local at
        if msg == 0x401 then at = lbSort(w, text or "")
        else
            at = s16(wp) == -1 and #lb.items + 1 or math.min(wp + 1, #lb.items + 1)
        end
        table.insert(lb.items, at, {text = text, data = data})
        if lb.sel >= at - 1 and lb.sel >= 0 then lb.sel = lb.sel + 1 end
        lbChanged(w)
        return at - 1
    elseif msg == 0x403 then       -- LB_DELETESTRING
        if wp >= #lb.items then return 0xFFFF end
        table.remove(lb.items, wp + 1)
        if lb.sel == wp then lb.sel = -1 elseif lb.sel > wp then lb.sel = lb.sel - 1 end
        lbChanged(w)
        return #lb.items
    elseif msg == 0x405 then       -- LB_RESETCONTENT
        lb.items, lb.sel, lb.top, lb.caret = {}, -1, 0, 0
        lbChanged(w)
        return 0
    elseif msg == 0x406 then       -- LB_SETSEL (multiple selection)
        local i = s16(lp & 0xFFFF)
        if i == -1 then for _, it in ipairs(lb.items) do it.selected = wp ~= 0 end
        elseif lb.items[i + 1] then lb.items[i + 1].selected = wp ~= 0 end
        lbChanged(w)
        return 0
    elseif msg == 0x407 then       -- LB_SETCURSEL
        lbSetSel(w, s16(wp), false)
        return s16(wp) == -1 and 0xFFFF or wp
    elseif msg == 0x408 then       -- LB_GETSEL
        local it = lb.items[wp + 1]
        if not it then return 0xFFFF end
        return (lb.sel == wp or it.selected) and 1 or 0
    elseif msg == 0x409 then       -- LB_GETCURSEL
        return lb.sel & 0xFFFF
    elseif msg == 0x40A then       -- LB_GETTEXT
        local it = lb.items[wp + 1]
        if not it then return 0xFFFF end
        local l = cpu.flat(lp)
        if lbStrings(w) then
            if l then mem.write(l, (it.text or "") .. "\0") end
            return #(it.text or "")
        end
        if l then wd(l, it.data or 0) end
        return 4
    elseif msg == 0x40B then       -- LB_GETTEXTLEN
        local it = lb.items[wp + 1]
        if not it then return 0xFFFF end
        return lbStrings(w) and #(it.text or "") or 4
    elseif msg == 0x40C then       -- LB_GETCOUNT
        return #lb.items
    elseif msg == 0x40D or msg == 0x410 then   -- LB_SELECTSTRING / LB_FINDSTRING
        local l = cpu.flat(lp)
        local s = l and user.upper(mem.cstr(l)) or ""
        local start = s16(wp)
        local n = #lb.items
        for k = 1, n do
            local i = (start + k) % n
            if i < 0 then i = i + n end
            local it = lb.items[i + 1]
            local t = lbStrings(w) and user.upper(it.text or "") or nil
            if (t and t:sub(1, #s) == s) or (not t and it.data == lp) then
                if msg == 0x40D then lbSetSel(w, i, false) end
                return i
            end
        end
        return 0xFFFF
    elseif msg == 0x40F then       -- LB_GETTOPINDEX
        return lb.top
    elseif msg == 0x418 then       -- LB_SETTOPINDEX
        lb.top = math.max(0, math.min(#lb.items - 1, wp))
        lbChanged(w)
        return 0
    elseif msg == 0x415 then       -- LB_SETCOLUMNWIDTH
        lb.colW = wp
        lbChanged(w)
        return 0
    elseif msg == 0x419 then       -- LB_GETITEMRECT
        local l = cpu.flat(lp)
        if l then api.setrect(l, lbItemRect(w, wp)) end
        return 1
    elseif msg == 0x41A then       -- LB_GETITEMDATA
        local it = lb.items[wp + 1]
        if not it then return 0xFFFF end
        return it.data or 0
    elseif msg == 0x41B then       -- LB_SETITEMDATA
        local it = lb.items[wp + 1]
        if not it then return 0xFFFF end
        it.data = lp
        return 1
    elseif msg == 0x420 then       -- LB_SETCARETINDEX? (3.1: LB_SETITEMHEIGHT is 0x421 in Win32); accept both
        return 0
    elseif msg == WM.SETFONT then
        w.font = wp
        lbMeasure(w)
        if lp ~= 0 then lbChanged(w) end
        return 0
    elseif msg == WM.DESTROY then
        if lbOwner(w) and not lbStrings(w) then
            for i, it in ipairs(lb.items) do
                local mark = api.mark()
                local fp, d = api.alloc(14)
                ww(d, 2); ww(d + 2, w.id or 0); ww(d + 4, i - 1); ww(d + 6, w.handle); wd(d + 8, it.data or 0)
                user.send(w.parent, WM.DELETEITEM, w.id or 0, fp)
                api.release(mark)
            end
        end
        return 0
    end
    return user.defwnd.proc(hwnd, msg, wp, lp)
end

-- ---- COMBOBOX (drop-down lists) -----------------------------------------------------------------------------------

local function cbState(w)
    if not w.cb then w.cb = {items = {}, sel = -1, dropH = 100} end
    return w.cb
end

local function cbText(w)
    local cb = cbState(w)
    local it = cb.items[cb.sel + 1]
    return it and it.text or ""
end

local function cbDrop(w)
    local cb = cbState(w)
    local font = {font = (w.font and w.font ~= 0) and w.font or gdi.stock(13)}
    local ih = gdi.fontHeight(font)
    local x, y = user.screenPos(w)
    local n = #cb.items
    local rows = math.max(math.min(n, math.max((cb.dropH - w.h) // ih, 1)), 1)
    local lw, lh = w.w, rows * ih + 2
    local ly = y + w.h
    if ly + lh > user.desktop.h then ly = y - lh end
    local top = math.max(0, math.min(cb.sel, n - rows))
    local hot = cb.sel
    local function draw()
        fb.clip(nil)
        fb.patblt(0, x, ly, lw, lh, 0xF0, 0)
        fb.patblt(0, x + 1, ly + 1, lw - 2, lh - 2, 0xF0, C[COLOR.WINDOW])
        local f = gdi.fontObj(font)
        for r = 0, rows - 1 do
            local i = top + r
            local it = cb.items[i + 1]
            if it then
                local iy = ly + 1 + r * ih
                local sel = i == hot
                if sel then fb.patblt(0, x + 1, iy, lw - 2, ih, 0xF0, C[COLOR.HIGHLIGHT]) end
                if f.rf then
                    fb.text(0, f.rf.fid, x + 3, iy, it.text or "", sel and C[COLOR.HIGHLIGHTTEXT] or C[COLOR.WINDOWTEXT], 0, false, f.bold, false)
                end
            end
        end
    end
    local ov = {x = x, y = ly, w = lw, h = lh, draw = draw}
    user.overlays[#user.overlays + 1] = ov
    notify(w, 7)   -- CBN_DROPDOWN
    user.dirty = true
    user.present()
    local chosen
    while true do
        local ev = user.waitInput()
        if ev.kind == "move" or ev.kind == "down" or ev.kind == "up" then
            local mx, my = ev.e[2], ev.e[3]
            local inside = mx >= x and mx < x + lw and my >= ly + 1 and my < ly + lh - 1
            if inside then
                local i = top + (my - ly - 1) // ih
                if i ~= hot and cb.items[i + 1] then hot = i; user.dirty = true end
                if ev.kind == "up" then chosen = hot; break end
            elseif ev.kind == "down" then
                local wr = user.windowRect(w)
                if not (mx >= wr[1] and mx < wr[3] and my >= wr[2] and my < wr[4]) then break end
            end
        elseif ev.kind == "key" and ev.e[3] == 1 then
            local vk = ev.e[2]
            if vk == 0x1B then break
            elseif vk == 0x0D then chosen = hot; break
            elseif vk == 0x26 and hot > 0 then hot = hot - 1
            elseif vk == 0x28 and hot < n - 1 then hot = hot + 1 end
            if hot < top then top = hot elseif hot >= top + rows then top = hot - rows + 1 end
            user.dirty = true
        elseif ev.kind == "close" then
            table.insert(user.input, 1, ev)
            break
        end
        user.present()
    end
    for i, o in ipairs(user.overlays) do if o == ov then table.remove(user.overlays, i); break end end
    user.buttons[1] = false
    user.dirty = true
    if chosen and chosen ~= cb.sel then
        cb.sel = chosen
        user.invalidate(w, nil, true)
        notify(w, 1)   -- CBN_SELCHANGE
    end
    user.present()
end

local function cbProc(hwnd, msg, wp, lp)
    local w = W(hwnd)
    if not w then return 0 end
    local cb = cbState(w)
    if msg == WM.CREATE then
        cb.dropH = w.h
        local font = {font = gdi.stock(13)}
        local h = gdi.fontHeight(font) + 6
        w.h = h
        user.calcClient(w)
        return 0
    elseif msg == WM.PAINT then
        local hdc, dc = paintDC(w)
        local cw, ch = size(w)
        local bg = ctlColor(w, hdc, 2)
        user.fillRect(dc, {0, 0, cw, ch}, bg)
        fillc(dc, 0, 0, cw, 1, 0); fillc(dc, 0, ch - 1, cw, 1, 0)
        fillc(dc, 0, 0, 1, ch, 0); fillc(dc, cw - 1, 0, 1, ch, 0)
        -- the button
        local bw = MT.CXVSCROLL
        local bx = cw - bw
        fillc(dc, bx, 0, 1, ch, 0)
        fillc(dc, bx + 1, 1, bw - 2, ch - 2, C[COLOR.BTNFACE])
        fillc(dc, bx + 1, 1, bw - 3, 1, 0xFFFFFF); fillc(dc, bx + 1, 1, 1, ch - 3, 0xFFFFFF)
        fillc(dc, bx + 1, ch - 2, bw - 2, 1, C[COLOR.BTNSHADOW]); fillc(dc, cw - 2, 1, 1, ch - 2, C[COLOR.BTNSHADOW])
        local arrow = res.obm(32738)
        if arrow and gdi.useClip(dc) then
            fb.bitblt(0, bx + (bw - arrow.w) // 2 + dc.ox, (ch - arrow.h) // 2 + dc.oy, arrow.w, arrow.h, arrow.surface, 0, 0, 0x88, 0, 0, 0xFFFFFF)
        end
        local text = cbText(w)
        local th = gdi.fontHeight(dc)
        local focused = hasFocus(w)
        local tr = {2, 2, bx - 1, ch - 2}
        if focused then
            user.fillRect(dc, tr, user.sysBrush(COLOR.HIGHLIGHT))
            dc.text, dc.bk = C[COLOR.HIGHLIGHTTEXT], C[COLOR.HIGHLIGHT]
        end
        dc.bkMode = 1
        gdi.textOut(dc, 4, (ch - th) // 2, text)
        if focused then user.focusRect(dc, tr) end
        endPaint(w, hdc)
        return 0
    elseif msg == WM.ERASEBKGND then
        return 1
    elseif msg == WM.GETDLGCODE then
        return 0x01 | 0x80
    elseif msg == WM.SETFOCUS or msg == WM.KILLFOCUS then
        user.invalidate(w, nil, true)
        notify(w, msg == WM.SETFOCUS and 3 or 4)
        return 0
    elseif msg == WM.LBUTTONDOWN or msg == WM.LBUTTONDBLCLK then
        user.setFocus(w)
        cbDrop(w)
        return 0
    elseif msg == WM.KEYDOWN then
        local n = #cb.items
        if wp == 0x73 or (wp == 0x28 and user.keys[0x12]) then cbDrop(w); return 0 end
        local i = cb.sel
        if wp == 0x26 or wp == 0x25 then i = i - 1 elseif wp == 0x28 or wp == 0x27 then i = i + 1
        elseif wp == 0x24 then i = 0 elseif wp == 0x23 then i = n - 1 else return 0 end
        i = math.max(0, math.min(n - 1, i))
        if i ~= cb.sel then cb.sel = i; user.invalidate(w, nil, true); notify(w, 1) end
        return 0
    elseif msg == WM.CHAR then
        if wp >= 0x20 then
            local c = string.char(wp):upper()
            local n = #cb.items
            for k = 1, n do
                local i = (cb.sel + k) % n
                if (cb.items[i + 1].text or ""):sub(1, 1):upper() == c then
                    cb.sel = i; user.invalidate(w, nil, true); notify(w, 1); break
                end
            end
        end
        return 0
    elseif msg == 0x403 or msg == 0x40A then      -- CB_ADDSTRING / CB_INSERTSTRING
        local l = cpu.flat(lp)
        local text = l and mem.cstr(l) or ""
        local at
        if msg == 0x403 then
            at = #cb.items + 1
            if w.style & 0x100 ~= 0 then   -- CBS_SORT
                local u = user.upper(text)
                for i, it in ipairs(cb.items) do if user.upper(it.text) > u then at = i; break end end
            end
        else
            at = s16(wp) == -1 and #cb.items + 1 or math.min(wp + 1, #cb.items + 1)
        end
        table.insert(cb.items, at, {text = text, data = 0})
        if cb.sel >= at - 1 and cb.sel >= 0 then cb.sel = cb.sel + 1 end
        user.invalidate(w, nil, true)
        return at - 1
    elseif msg == 0x404 then       -- CB_DELETESTRING
        if wp >= #cb.items then return 0xFFFF end
        table.remove(cb.items, wp + 1)
        if cb.sel == wp then cb.sel = -1 elseif cb.sel > wp then cb.sel = cb.sel - 1 end
        user.invalidate(w, nil, true)
        return #cb.items
    elseif msg == 0x406 then return #cb.items           -- CB_GETCOUNT
    elseif msg == 0x407 then return cb.sel & 0xFFFF     -- CB_GETCURSEL
    elseif msg == 0x408 then       -- CB_GETLBTEXT
        local it = cb.items[wp + 1]
        if not it then return 0xFFFF end
        local l = cpu.flat(lp)
        if l then mem.write(l, it.text .. "\0") end
        return #it.text
    elseif msg == 0x409 then       -- CB_GETLBTEXTLEN
        local it = cb.items[wp + 1]
        return it and #it.text or 0xFFFF
    elseif msg == 0x40B then       -- CB_RESETCONTENT
        cb.items, cb.sel = {}, -1
        user.invalidate(w, nil, true)
        return 0
    elseif msg == 0x40C or msg == 0x40D then  -- CB_FINDSTRING / CB_SELECTSTRING
        local l = cpu.flat(lp)
        local s = l and user.upper(mem.cstr(l)) or ""
        local n = #cb.items
        local start = s16(wp)
        for k = 1, n do
            local i = (start + k) % n
            if i < 0 then i = i + n end
            if user.upper(cb.items[i + 1].text):sub(1, #s) == s then
                if msg == 0x40D then cb.sel = i; user.invalidate(w, nil, true) end
                return i
            end
        end
        return 0xFFFF
    elseif msg == 0x40E then       -- CB_SETCURSEL
        local i = s16(wp)
        if i >= #cb.items then i = -1 end
        cb.sel = i
        user.invalidate(w, nil, true)
        return i & 0xFFFF
    elseif msg == 0x40F then       -- CB_SHOWDROPDOWN
        if wp ~= 0 then cbDrop(w) end
        return 1
    elseif msg == 0x410 then       -- CB_GETITEMDATA
        local it = cb.items[wp + 1]
        return it and it.data or 0xFFFF
    elseif msg == 0x411 then       -- CB_SETITEMDATA
        local it = cb.items[wp + 1]
        if not it then return 0xFFFF end
        it.data = lp
        return 1
    elseif msg == WM.GETTEXT then
        local l = cpu.flat(lp)
        return api.putstr(l, cbText(w), wp)
    elseif msg == WM.GETTEXTLENGTH then
        return #cbText(w)
    elseif msg == WM.SETFONT then
        w.font = wp
        if lp ~= 0 then user.invalidate(w, nil, true) end
        return 0
    end
    return user.defwnd.proc(hwnd, msg, wp, lp)
end

-- ---- registration --------------------------------------------------------------------------------------------

local arrow = res.cursor(32512)
local ibeam = res.cursor(32513)
user.registerClass({name = "BUTTON", style = 0x0008 | 0x0040, proc = user.luaProc("ButtonProc", buttonProc), cursor = arrow})
user.registerClass({name = "STATIC", style = 0, proc = user.luaProc("StaticProc", staticProc), cursor = arrow})
user.registerClass({name = "EDIT", style = 0x0008, proc = user.luaProc("EditProc", editProc), cursor = ibeam})
user.registerClass({name = "LISTBOX", style = 0x0008, proc = user.luaProc("ListBoxProc", lbProc), cursor = arrow})
user.registerClass({name = "COMBOBOX", style = 0x0008, proc = user.luaProc("ComboBoxProc", cbProc), cursor = arrow})

user.controls = controls
return controls

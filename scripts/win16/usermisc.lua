-- USER's API functions: classes and windows, rectangles, text drawing,
-- resources (icons, cursors, strings, accelerators), strings, metrics,
-- hooks, atoms and the rest.

local api = require("win16.api")
local cpu = require("recomp.cpu")
local gdi = require("win16.gdi")
local handles = require("win16.handles")
local kernel = require("win16.kernel")
local region = require("win16.region")
local res = require("win16.resources")
local user = require("win16.user")

local def = api.def
local WM, WS, SC, COLOR = user.WM, user.WS, user.SC, user.COLOR
local C, MT = user.sysColors, user.metrics
local W = user.W
local rw, ww, rb, wb, rd, wd = mem.rw, mem.ww, mem.rb, mem.wb, mem.rd, mem.wd
local s16 = api.s16
local getrect, setrect = api.getrect, api.setrect

local function hw(w) return w and w.handle or 0 end

-- ---- classes ------------------------------------------------------------------------------------

def("USER", 57, "RegisterClass", "p", function(wc)
    if not wc then return 0 end
    local nameFp = rd(wc + 22)
    local name
    if (nameFp >> 16) == 0 then name = "#" .. (nameFp & 0xFFFF) else name = mem.cstr(cpu.flat(nameFp)) end
    local menuFp = rd(wc + 18)
    local menuName
    if menuFp ~= 0 then
        if (menuFp >> 16) == 0 then menuName = menuFp & 0xFFFF else menuName = mem.cstr(cpu.flat(menuFp)) end
    end
    local cls = user.registerClass({
        name = name, style = rw(wc), proc = rd(wc + 2), clsExtra = s16(rw(wc + 6)), wndExtra = s16(rw(wc + 8)),
        inst = rw(wc + 10), icon = rw(wc + 12), cursor = rw(wc + 14), brush = rw(wc + 16), menuName = menuName,
    })
    if not user.atoms then user.atoms = {} end
    return 0xC000 + (#name % 0x3FFF)
end)

-- ---- windows --------------------------------------------------------------------------------------

local function str(fp)
    if not fp or fp == 0 then return nil end
    if (fp >> 16) == 0 then return "#" .. (fp & 0xFFFF) end
    local l = cpu.flat(fp)
    return l and mem.cstr(l)
end

def("USER", 41, "CreateWindow", "f f l i i i i h h h f", function(cls, title, style, x, y, cw, ch, parent, menu, inst, param)
    local w = user.create(str(cls), str(title), style, x, y, cw, ch, parent ~= 0 and parent or nil, menu, inst, param, 0)
    if w and not user.frame and w.style & WS.CHILD == 0 and w.class.name:upper() == "PROGMAN" then
        user.frame = w
        user.fitFrame()
    end
    return hw(w)
end)
def("USER", 452, "CreateWindowEx", "l f f l i i i i h h h f", function(ex, cls, title, style, x, y, cw, ch, parent, menu, inst, param)
    return hw(user.create(str(cls), str(title), style, x, y, cw, ch, parent ~= 0 and parent or nil, menu, inst, param, ex))
end)
def("USER", 53, "DestroyWindow", "h", function(h) return user.destroy(W(h)) end)
def("USER", 42, "ShowWindow", "h i", function(h, cmd)
    local w = W(h)
    if not w then return 0 end
    return user.showWindow(w, cmd)
end)
def("USER", 47, "IsWindow", "h", function(h) local w = W(h); return w ~= nil and not w.destroyed end)
def("USER", 49, "IsWindowVisible", "h", function(h) local w = W(h); return w and user.isVisible(w) or false end)
def("USER", 31, "IsIconic", "h", function(h) local w = W(h); return w and w.iconic or false end)
def("USER", 272, "IsZoomed", "h", function(h)
    local w = W(h)
    if user.appMode and w == user.frame then return true end
    return w and w.zoomed or false
end)
def("USER", 34, "EnableWindow", "h w", function(h, on)
    local w = W(h)
    if not w then return 0 end
    local was = w.disabled
    w.disabled = on == 0
    if was ~= w.disabled then
        if w.disabled and user.focus and user.isDescendant(user.focus, w) then user.focus = nil end
        user.send(w, WM.ENABLE, on, 0)
        w.ncdirty = true
        user.invalidate(w, nil, true)
    end
    return was
end)
def("USER", 35, "IsWindowEnabled", "h", function(h) local w = W(h); return w and not w.disabled or false end)

def("USER", 56, "MoveWindow", "h i i i i w", function(h, x, y, cw, ch, repaint)
    local w = W(h)
    if not w then return 0 end
    if user.appMode and w == user.frame then user.fitFrame(); return 1 end
    if w.zoomed or w.iconic then w.normal = {x, y, cw, ch} end
    if w.iconic then cw, ch = w.w, w.h end
    user.setPos(w, x, y, cw, ch)
    return 1
end)

def("USER", 232, "SetWindowPos", "h h i i i i w:v", function(h, after, x, y, cw, ch, flags)
    local w = W(h)
    if not w then return end
    if flags & 0x80 ~= 0 then user.showWindow(w, 0) end
    if flags & 0x04 == 0 then
        if after == 0 then user.linkZ(w)
        elseif after == 1 then user.linkZ(w, "bottom")
        else local a = W(after); if a and a.parent == w.parent then user.linkZ(w, a) end end
        user.damageWindow(w)
    end
    if not (user.appMode and w == user.frame) then
        local nx, ny, nw, nh = w.x, w.y, w.w, w.h
        if flags & 0x02 == 0 then nx, ny = x, y end
        if flags & 0x01 == 0 then nw, nh = cw, ch end
        user.setPos(w, nx, ny, nw, nh, {frame = flags & 0x20 ~= 0})
    end
    if flags & 0x40 ~= 0 then user.showWindow(w, flags & 0x10 ~= 0 and 8 or 5) end
    if flags & 0x10 == 0 and flags & 0x04 == 0 and w.style & WS.CHILD == 0 and w.visible then user.activate(w) end
end)

def("USER", 45, "BringWindowToTop", "h", function(h)
    local w = W(h)
    if not w then return 0 end
    if w.style & WS.CHILD == 0 then user.activate(w) else user.linkZ(w); user.damageWindow(w) end
    return 1
end)

def("USER", 32, "GetWindowRect", "h p:v", function(h, prc)
    local w = h == 0 and user.desktop or W(h)
    if not w or not prc then return end
    if user.appMode and w == user.frame then setrect(prc, {0, 0, user.desktop.w, user.desktop.h}); return end
    setrect(prc, user.windowRect(w))
end)
def("USER", 33, "GetClientRect", "h p:v", function(h, prc)
    local w = h == 0 and user.desktop or W(h)
    if not w or not prc then return end
    setrect(prc, {0, 0, w.cl[3] - w.cl[1], w.cl[4] - w.cl[2]})
end)
def("USER", 29, "ScreenToClient", "h p:v", function(h, ppt)
    local w = W(h)
    if not w or not ppt then return end
    local ox, oy = user.clientOrigin(w)
    local x, y = api.getpt(ppt)
    api.setpt(ppt, x - ox, y - oy)
end)
def("USER", 28, "ClientToScreen", "h p:v", function(h, ppt)
    local w = W(h)
    if not w or not ppt then return end
    local ox, oy = user.clientOrigin(w)
    local x, y = api.getpt(ppt)
    api.setpt(ppt, x + ox, y + oy)
end)

def("USER", 36, "GetWindowText", "h f i", function(h, fp, n)
    local w = W(h)
    if not w then return 0 end
    return user.send(w, WM.GETTEXT, n, fp)
end)
def("USER", 37, "SetWindowText", "h f:v", function(h, fp)
    local w = W(h)
    if w then user.send(w, WM.SETTEXT, 0, fp) end
end)
def("USER", 38, "GetWindowTextLength", "h", function(h)
    local w = W(h)
    return w and user.send(w, WM.GETTEXTLENGTH, 0, 0) or 0
end)

-- far pointer from a linear address in a known selector: the arguments
-- decoded as linear addresses go back to 16-bit code as far pointers
function cpu.farOf(lin)
    if not lin then return 0 end
    for s = 7, 0xFFFF, 8 do
        local d = cpu.sel(s)
        if d and lin >= d.base and lin <= d.base + d.limit then return (s << 16) | (lin - d.base) end
    end
    return 0
end

-- Window words: GWW_HINSTANCE -6, GWW_HWNDPARENT -8, GWW_ID -12; extra bytes from 0
local function extraWord(w, i) return (w.extra[i] or 0) | ((w.extra[i + 1] or 0) << 8) end
local function setExtraWord(w, i, v) w.extra[i] = v & 0xFF; w.extra[i + 1] = (v >> 8) & 0xFF end
user.extraWord, user.setExtraWord = extraWord, setExtraWord

def("USER", 133, "GetWindowWord", "h i", function(h, i)
    local w = W(h)
    if not w then return 0 end
    if i == -6 then return w.inst or 0 end
    if i == -8 then return hw(w.style & WS.CHILD ~= 0 and w.parent or w.owner) end
    if i == -12 then return w.id or 0 end
    if i >= 0 then return extraWord(w, i) end
    return 0
end)
def("USER", 134, "SetWindowWord", "h i w", function(h, i, v)
    local w = W(h)
    if not w then return 0 end
    local old
    if i == -12 then old = w.id or 0; w.id = v
    elseif i == -6 then old = w.inst or 0; w.inst = v
    elseif i >= 0 then old = extraWord(w, i); setExtraWord(w, i, v) end
    return old or 0
end)
def("USER", 135, "GetWindowLong", "h i:l", function(h, i)
    local w = W(h)
    if not w then return 0 end
    if i == -4 then return w.proc end
    if i == -16 then
        return w.style | (w.visible and WS.VISIBLE or 0) | (w.disabled and WS.DISABLED or 0) |
            (w.iconic and WS.MINIMIZE or 0) | (w.zoomed and WS.MAXIMIZE or 0)
    end
    if i == -20 then return w.exstyle end
    if i >= 0 then return extraWord(w, i) | (extraWord(w, i + 2) << 16) end
    return 0
end)
def("USER", 136, "SetWindowLong", "h i l:l", function(h, i, v)
    local w = W(h)
    if not w then return 0 end
    local old
    if i == -4 then old = w.proc; w.proc = v
    elseif i == -16 then
        old = w.style
        w.style = v & ~(WS.VISIBLE | WS.DISABLED | WS.MINIMIZE | WS.MAXIMIZE)
        if v & WS.VSCROLL == 0 and w.vscroll then w.vscroll.visible = false end
        if v & WS.HSCROLL == 0 and w.hscroll then w.hscroll.visible = false end
        user.frameChanged(w)
    elseif i == -20 then old = w.exstyle; w.exstyle = v
    elseif i >= 0 then
        old = extraWord(w, i) | (extraWord(w, i + 2) << 16)
        setExtraWord(w, i, v & 0xFFFF); setExtraWord(w, i + 2, v >> 16)
    end
    return old or 0
end)

def("USER", 129, "GetClassWord", "h i", function(h, i)
    local w = W(h)
    if not w then return 0 end
    local c = w.class
    if i == -10 then return c.brush or 0 end
    if i == -12 then return c.cursor or 0 end
    if i == -14 then return c.icon or 0 end
    if i == -16 then return c.inst or 0 end
    if i == -18 then return c.wndExtra or 0 end
    if i == -20 then return c.clsExtra or 0 end
    if i == -26 then return c.style or 0 end
    if i >= 0 then return (c.extra[i] or 0) | ((c.extra[i + 1] or 0) << 8) end
    return 0
end)
def("USER", 130, "SetClassWord", "h i w", function(h, i, v)
    local w = W(h)
    if not w then return 0 end
    local c = w.class
    local old
    if i == -10 then old = c.brush; c.brush = v
    elseif i == -12 then old = c.cursor; c.cursor = v
    elseif i == -14 then old = c.icon; c.icon = v
    elseif i == -26 then old = c.style; c.style = v
    elseif i >= 0 then
        old = (c.extra[i] or 0) | ((c.extra[i + 1] or 0) << 8)
        c.extra[i] = v & 0xFF; c.extra[i + 1] = v >> 8
    end
    -- a new class icon shows on every minimized window of the class
    if i == -14 then
        for _, o in pairs(handles.all()) do
            if o.kind == "window" and o.class == c and o.iconic then o.ncdirty = true; user.dirty = true end
        end
    end
    return old or 0
end)

def("USER", 262, "GetWindow", "h w", function(h, rel)
    local w = W(h)
    if not w then return 0 end
    local list = w.parent and w.parent.children or {}
    if rel == 5 then return hw(w.children[1]) end
    if rel == 4 then return hw(w.owner) end
    local idx
    for i, c in ipairs(list) do if c == w then idx = i end end
    if rel == 0 then return hw(list[1]) end
    if rel == 1 then return hw(list[#list]) end
    if rel == 2 then return hw(idx and list[idx + 1]) end
    if rel == 3 then return hw(idx and list[idx - 1]) end
    return 0
end)
def("USER", 46, "GetParent", "h", function(h)
    local w = W(h)
    if not w then return 0 end
    if w.style & WS.CHILD ~= 0 then return hw(w.parent) end
    return hw(w.owner)
end)
def("USER", 60, "GetActiveWindow", "", function() return hw(user.active) end)
def("USER", 59, "SetActiveWindow", "h", function(h)
    local old = user.active
    local w = W(h)
    if w then user.activate(w) end
    return hw(old)
end)
def("USER", 22, "SetFocus", "h", function(h)
    local w = h ~= 0 and W(h) or nil
    return hw(user.setFocus(w))
end)
def("USER", 23, "GetFocus", "", function() return hw(user.focus) end)
def("USER", 287, "GetLastActivePopup", "h", function(h)
    local w = W(h)
    if user.modal and user.modal.owner == w then return hw(user.modal) end
    return h
end)
def("USER", 188, "SetSysModalWindow", "h", function(h) return 0 end)

-- ---- placement ---------------------------------------------------------------------------------------
-- WINDOWPLACEMENT: length, flags, showCmd, ptMinPosition, ptMaxPosition, rcNormalPosition (22 bytes)

def("USER", 370, "GetWindowPlacement", "h p", function(h, wp)
    local w = W(h)
    if not w or not wp then return 0 end
    ww(wp, 22); ww(wp + 2, 0)
    ww(wp + 4, w.iconic and 2 or w.zoomed and 3 or 1)
    api.setpt(wp + 6, w.iconic and w.x or -1, w.iconic and w.y or -1)
    api.setpt(wp + 10, -1, -1)
    local n = (w.iconic or w.zoomed) and w.normal or {w.x, w.y, w.w, w.h}
    if user.appMode and w == user.frame then n = {0, 0, user.desktop.w, user.desktop.h}; ww(wp + 4, 1) end
    setrect(wp + 14, {n[1], n[2], n[1] + n[3], n[2] + n[4]})
    return 1
end)
def("USER", 371, "SetWindowPlacement", "h p", function(h, wp)
    local w = W(h)
    if not w or not wp then return 0 end
    local r = getrect(wp + 14)
    local cmd = s16(rw(wp + 4))
    if user.appMode and w == user.frame then
        user.fitFrame()
        if w.visible == false and cmd ~= 0 then user.showWindow(w, 5) end
        return 1
    end
    if w.iconic or w.zoomed then
        w.normal = {r[1], r[2], r[3] - r[1], r[4] - r[2]}
    else
        user.setPos(w, r[1], r[2], r[3] - r[1], r[4] - r[2])
        w.normal = {r[1], r[2], r[3] - r[1], r[4] - r[2]}
    end
    if cmd == 2 or cmd == 6 or cmd == 7 then
        local mx, my = api.getpt(wp + 6)
        user.showWindow(w, cmd)
        if mx ~= -1 and my ~= -1 and w.iconic and rw(wp + 2) & 1 ~= 0 then user.setPos(w, mx, my, w.w, w.h) end
    elseif cmd ~= 0 then
        user.showWindow(w, cmd)
    end
    return 1
end)

-- ---- rectangles ---------------------------------------------------------------------------------------

def("USER", 72, "SetRect", "p i i i i:v", function(p, a, b, c, d) setrect(p, {a, b, c, d}) end)
def("USER", 73, "SetRectEmpty", "p:v", function(p) setrect(p, {0, 0, 0, 0}) end)
def("USER", 74, "CopyRect", "p p:v", function(d, s) if d and s then mem.write(d, mem.read(s, 8)) end end)
def("USER", 75, "IsRectEmpty", "p", function(p) local r = getrect(p); return not r or r[1] >= r[3] or r[2] >= r[4] end)
def("USER", 76, "PtInRect", "p l", function(p, pt)
    local r = getrect(p)
    local x, y = api.unpt(pt)
    return r and x >= r[1] and x < r[3] and y >= r[2] and y < r[4] or false
end)
def("USER", 77, "OffsetRect", "p i i:v", function(p, dx, dy)
    local r = getrect(p)
    if r then setrect(p, {r[1] + dx, r[2] + dy, r[3] + dx, r[4] + dy}) end
end)
def("USER", 78, "InflateRect", "p i i:v", function(p, dx, dy)
    local r = getrect(p)
    if r then setrect(p, {r[1] - dx, r[2] - dy, r[3] + dx, r[4] + dy}) end
end)
def("USER", 79, "IntersectRect", "p p p", function(d, a, b)
    local i = region.isect(getrect(a), getrect(b))
    setrect(d, i or {0, 0, 0, 0})
    return i ~= nil
end)
def("USER", 80, "UnionRect", "p p p", function(d, a, b)
    local ra, rb2 = getrect(a), getrect(b)
    local ea, eb = region.empty(ra), region.empty(rb2)
    if ea and eb then setrect(d, {0, 0, 0, 0}); return 0 end
    if ea then setrect(d, rb2); return 1 end
    if eb then setrect(d, ra); return 1 end
    setrect(d, {math.min(ra[1], rb2[1]), math.min(ra[2], rb2[2]), math.max(ra[3], rb2[3]), math.max(ra[4], rb2[4])})
    return 1
end)
def("USER", 81, "FillRect", "h p h", function(hdc, prc, hbr)
    local dc = gdi.dc(hdc)
    if not dc or not prc then return 0 end
    user.fillRect(dc, getrect(prc), user.brushFor(hbr) or hbr)
    return 1
end)
def("USER", 466, "DrawFocusRect", "h p:v", function(hdc, prc)
    local dc = gdi.dc(hdc)
    if not dc or not prc then return end
    user.focusRect(dc, getrect(prc))
end)

-- A dotted XOR rectangle.
local DOTS = {}
for i = 1, 64 do
    local x, y = (i - 1) % 8, (i - 1) // 8
    DOTS[i] = ((x + y) % 2 == 0) and 0xFFFFFF or 0
end
function user.focusRect(dc, r)
    if not gdi.useClip(dc) then return end
    local x, y, cw, ch = r[1] + dc.ox, r[2] + dc.oy, r[3] - r[1], r[4] - r[2]
    if cw <= 0 or ch <= 0 then return end
    fb.patblt(dc.surface, x, y, cw, 1, 0x5A, DOTS)
    if ch > 1 then fb.patblt(dc.surface, x, y + ch - 1, cw, 1, 0x5A, DOTS) end
    if ch > 2 then
        fb.patblt(dc.surface, x, y + 1, 1, ch - 2, 0x5A, DOTS)
        if cw > 1 then fb.patblt(dc.surface, x + cw - 1, y + 1, 1, ch - 2, 0x5A, DOTS) end
    end
end

-- ---- text ------------------------------------------------------------------------------------------------

-- Splits "&File" into "File" and the index of the underlined letter.
function user.stripPrefix(s)
    local out, ul = {}, nil
    local i = 1
    while i <= #s do
        local c = s:sub(i, i)
        if c == "&" then
            local n = s:sub(i + 1, i + 1)
            if n == "&" then out[#out + 1] = "&"; i = i + 2
            else
                if n ~= "" and not ul then ul = #table.concat(out) + 1 end
                i = i + 1
            end
        else
            out[#out + 1] = c
            i = i + 1
        end
    end
    return table.concat(out), ul
end

-- Text with an underlined mnemonic at (x, y) (DC logical coordinates).
function user.prefixText(dc, x, y, s, noPrefix)
    local text, ul = s, nil
    if not noPrefix then text, ul = user.stripPrefix(s) end
    gdi.textOut(dc, x, y, text)
    if ul then
        local f = gdi.fontObj(dc)
        if f.rf then
            local ux = x + gdi.textWidth(dc, text:sub(1, ul - 1))
            local uw = gdi.textWidth(dc, text:sub(ul, ul))
            if gdi.useClip(dc) then
                fb.patblt(dc.surface, ux + dc.ox, y + f.rf.m.ascent + 1 + dc.oy, uw, 1, 0xF0, dc.text)
            end
        end
    end
    return text
end

-- Word-wraps a string into lines no wider than width.
local function wrap(dc, s, width)
    local lines = {}
    for para in (s .. "\n"):gmatch("([^\n]*)\n") do
        para = para:gsub("\r", "")
        if width <= 0 then lines[#lines + 1] = para
        else
            local line = ""
            for word, space in para:gmatch("(%S*)(%s*)") do
                if word == "" and space == "" then break end
                local try = line .. word
                if line ~= "" and gdi.textWidth(dc, try) > width then
                    lines[#lines + 1] = line:gsub("%s+$", "")
                    line = word .. space
                else
                    line = try .. space
                end
                -- a single word longer than the line: break it
                while gdi.textWidth(dc, line) > width and #line > 1 do
                    local cut = #line
                    while cut > 1 and gdi.textWidth(dc, line:sub(1, cut)) > width do cut = cut - 1 end
                    lines[#lines + 1] = line:sub(1, cut)
                    line = line:sub(cut + 1)
                end
            end
            lines[#lines + 1] = line:gsub("%s+$", "")
        end
    end
    if #lines > 1 and lines[#lines] == "" and not s:match("\n$") then lines[#lines] = nil end
    return lines
end

-- DrawText. Returns the height drawn, and the rect for DT_CALCRECT.
function user.drawText(dc, s, r, fmt)
    local DT_CENTER, DT_RIGHT, DT_VCENTER, DT_BOTTOM = 1, 2, 4, 8
    local DT_WORDBREAK, DT_SINGLELINE, DT_EXPANDTABS, DT_NOCLIP, DT_CALCRECT, DT_NOPREFIX = 0x10, 0x20, 0x40, 0x100, 0x400, 0x800
    local lh = gdi.fontHeight(dc)
    if fmt & DT_EXPANDTABS ~= 0 then s = s:gsub("\t", "        ") end
    local lines
    if fmt & DT_SINGLELINE ~= 0 then lines = {(s:gsub("[\r\n]", " "))}
    elseif fmt & DT_WORDBREAK ~= 0 then lines = wrap(dc, s, r[3] - r[1])
    else
        lines = {}
        for l in (s .. "\n"):gmatch("([^\n]*)\n") do lines[#lines + 1] = l:gsub("\r", "") end
        if #lines > 1 and lines[#lines] == "" then lines[#lines] = nil end
    end
    local h = #lines * lh
    if fmt & DT_CALCRECT ~= 0 then
        local maxw = 0
        for _, l in ipairs(lines) do
            local t = fmt & DT_NOPREFIX ~= 0 and l or user.stripPrefix(l)
            maxw = math.max(maxw, gdi.textWidth(dc, t))
        end
        if fmt & DT_WORDBREAK == 0 or #lines <= 1 then
            return h, {r[1], r[2], r[1] + maxw, r[2] + h}
        end
        return h, {r[1], r[2], r[1] + math.max(maxw, 0), r[2] + h}
    end
    local y = r[2]
    if fmt & DT_SINGLELINE ~= 0 then
        if fmt & DT_VCENTER ~= 0 then y = r[2] + ((r[4] - r[2]) - lh) // 2
        elseif fmt & DT_BOTTOM ~= 0 then y = r[4] - lh end
    end
    local saveClip = dc.clipRgn
    if fmt & DT_NOCLIP == 0 then
        local cr = {{r[1], r[2], r[3], r[4]}}
        dc.clipRgn = saveClip and region.intersect(saveClip, cr) or cr
    end
    for _, l in ipairs(lines) do
        local t = fmt & DT_NOPREFIX ~= 0 and l or (user.stripPrefix(l))
        local tw = gdi.textWidth(dc, t)
        local x = r[1]
        if fmt & DT_CENTER ~= 0 then x = r[1] + ((r[3] - r[1]) - tw) // 2
        elseif fmt & DT_RIGHT ~= 0 then x = r[3] - tw end
        user.prefixText(dc, x, y, l, fmt & DT_NOPREFIX ~= 0)
        y = y + lh
    end
    dc.clipRgn = saveClip
    return h
end

def("USER", 85, "DrawText", "h f i p w", function(hdc, lp, n, prc, fmt)
    local dc = gdi.dc(hdc)
    local l = cpu.flat(lp)
    if not dc or not l or not prc then return 0 end
    local s = n < 0 and mem.cstr(l) or mem.read(l, n)
    local h, rc = user.drawText(dc, s, getrect(prc), fmt)
    if rc then setrect(prc, rc) end
    return h
end)

def("USER", 185, "GrayString", "h h f l i i i i i", function(hdc, hbr, proc, data, n, x, y, cw, ch)
    local dc = gdi.dc(hdc)
    if not dc then return 0 end
    local s
    if proc == 0 then
        local l = cpu.flat(data)
        s = l and (n == 0 and mem.cstr(l) or mem.read(l, n)) or ""
        local old = dc.text
        dc.text = C[COLOR.GRAYTEXT]
        local oldMode = dc.bkMode
        dc.bkMode = 1
        gdi.textOut(dc, x, y, s)
        dc.text, dc.bkMode = old, oldMode
        return 1
    end
    -- an output procedure: let it draw, in gray
    local old = dc.text
    dc.text = C[COLOR.GRAYTEXT]
    local r = cpu.call16(user.task.R, proc >> 16, proc & 0xFFFF, {hdc, data >> 16, data & 0xFFFF, n},
                         {ds = user.task.dgroup, ax = user.task.dgroup})
    dc.text = old
    return r
end)

def("USER", 84, "DrawIcon", "h i i h", function(hdc, x, y, hicon)
    local dc = gdi.dc(hdc)
    local lin = kernel.glin(hicon)
    if not dc or not lin then return 0 end
    return gdi.drawIcon(dc, x, y, lin)
end)

-- ---- resources -----------------------------------------------------------------------------------------------

local function instModule(inst)
    if not inst or inst == 0 then return nil end
    return kernel.neModule(inst)
end
user.instModule = instModule

def("USER", 174, "LoadIcon", "h r", function(inst, name)
    if inst == 0 or not inst then return res.systemIcon(name) or 0 end
    local m = instModule(inst)
    return (m and res.moduleIcon(m, name)) or 0
end)
def("USER", 173, "LoadCursor", "h r", function(inst, name)
    if inst == 0 then return res.cursor(name) end
    return res.cursor(32512)
end)
def("USER", 176, "LoadString", "h w p i", function(inst, id, buf, n)
    local m = instModule(inst)
    local s = m and m:string(id)
    if not s then if buf and n > 0 then wb(buf, 0) end return 0 end
    return api.putstr(buf, s, n)
end)
def("USER", 368, "CopyIcon", "h h", function(inst, h)
    local g = kernel.global(h)
    if not g then return 0 end
    local n = kernel.galloc(0x42, g.size)
    mem.move(kernel.glin(n), g.base, g.size)
    kernel.global(n).icon = true
    return n
end)
def("USER", 457, "DestroyIcon", "h", function(h)
    local g = kernel.global(h)
    if g and g.icon then kernel.gfree(h) end
    return 1
end)
-- DumpIcon(lpIcon, lpLen, lplpXor, lplpAnd) -> MAKELONG(xor size, xor size)
def("USER", 459, "DumpIcon", "f p p p:l", function(fp, lpLen, lpXor, lpAnd)
    local lin = cpu.flat(fp)
    if not lin then return 0 end
    local w, h, wbA, wbX, planes = gdi.iconBits(lin)
    local andSize, xorSize = wbA * h, wbX * h * planes
    if lpAnd then wd(lpAnd, fp + 12) end
    if lpXor then wd(lpXor, fp + 12 + andSize) end
    if lpLen then ww(lpLen, 12 + andSize + xorSize) end
    return api.mklong(xorSize, xorSize)
end)
-- GetInternalIconHeader(lpIcon, lpDestBuf): the header an icon has on this
-- display (Program Manager builds its icons from group-file bits with it)
def("USER", 372, "GetInternalIconHeader", "f p:v", function(fp, dest)
    if not dest then return end
    mem.write(dest, string.pack("<i2i2I2I2I2BB", 16, 16, 32, 32, 16, 1, 4))
end)

-- Accelerators: entries of flags (1), key (2), id (2); 0x80 ends the table.
local accels = {}
def("USER", 177, "LoadAccelerators", "h r", function(inst, name)
    local m = instModule(inst)
    local data = m and m:resource(9, name)
    if not data then return 0 end
    local list = {}
    for i = 1, #data - 4, 5 do
        local f, key, id = string.unpack("<BI2I2", data, i)
        list[#list + 1] = {flags = f, key = key, id = id}
        if f & 0x80 ~= 0 then break end
    end
    return handles.new({kind = "accel", list = list})
end)
def("USER", 178, "TranslateAccelerator", "h h p", function(hwnd, hacc, lpMsg)
    local a = handles.get(hacc, "accel")
    if not a or not lpMsg then return 0 end
    local m = user.readMsg(lpMsg)
    local isKey = m.msg == WM.KEYDOWN or m.msg == WM.SYSKEYDOWN
    local isChar = m.msg == WM.CHAR or m.msg == WM.SYSCHAR
    if not isKey and not isChar then return 0 end
    local shift, ctrl, alt = user.keys[0x10] and true or false, user.keys[0x11] and true or false, user.keys[0x12] and true or false
    for _, e in ipairs(a.list) do
        local virt = e.flags & 1 ~= 0
        local hit = false
        if virt and isKey and e.key == m.wp then
            hit = ((e.flags & 4 ~= 0) == shift) and ((e.flags & 8 ~= 0) == ctrl) and ((e.flags & 0x10 ~= 0) == alt)
        elseif not virt and isChar and e.key == m.wp then
            hit = ((e.flags & 0x10 ~= 0) == alt)
        end
        if hit then
            local w = W(hwnd)
            if w and not w.iconic and not w.disabled then
                user.send(w, WM.COMMAND, e.id, api.mklong(0, 1))
            end
            return 1
        end
    end
    return 0
end)

-- ---- system information ----------------------------------------------------------------------------------

def("USER", 179, "GetSystemMetrics", "i", function(i)
    local d = user.desktop
    local t = {[0] = d.w, d.h, MT.CXVSCROLL, MT.CYHSCROLL, MT.CYCAPTION, 1, 1, MT.CXDLGFRAME, MT.CYDLGFRAME,
               17, 17, MT.CXICON, MT.CYICON, 32, 32, MT.CYMENU, d.w, d.h - MT.CYCAPTION, 0, 1, 17, 17, 0, 0,
               0, 0, 0, 0, 100, 27, MT.CXSIZE, MT.CYSIZE, MT.CXFRAME, MT.CYFRAME, 100, 27, 4, 4,
               MT.CXICONSPACING, MT.CYICONSPACING, 0, 0, 0, 2}
    return t[i] or 0
end)
def("USER", 180, "GetSysColor", "i:l", function(i) return gdi.colorref(C[i] or 0) end)

-- SystemParametersInfo: the icon-title font and spacing Program Manager uses
def("USER", 483, "SystemParametersInfo", "w w f w", function(action, param, pv, winini)
    local p = cpu.flat(pv)
    if action == 13 then          -- SPI_ICONHORIZONTALSPACING
        if p then ww(p, MT.CXICONSPACING) elseif param > 0 then MT.CXICONSPACING = param end
        return 1
    elseif action == 24 then      -- SPI_ICONVERTICALSPACING
        if p then ww(p, MT.CYICONSPACING) elseif param > 0 then MT.CYICONSPACING = param end
        return 1
    elseif action == 25 then      -- SPI_GETICONTITLEWRAP
        if p then ww(p, 1) end
        return 1
    elseif action == 31 then      -- SPI_GETICONTITLELOGFONT
        if p then
            mem.fill(p, 50, 0)
            ww(p, (-13) & 0xFFFF); ww(p + 8, 400)
            api.putstr(p + 18, "MS Sans Serif", 32)
        end
        return 1
    elseif action == 5 then       -- SPI_GETBORDER
        if p then ww(p, 3) end
        return 1
    elseif action == 1 then       -- SPI_GETBEEP
        if p then ww(p, 1) end
        return 1
    end
    if p then ww(p, 0) end
    return 1
end)

def("USER", 106, "GetKeyState", "i", function(vk)
    local v = 0
    if vk == 1 and user.buttons[1] or vk == 2 and user.buttons[2] or user.keys[vk] then v = 0x8000 end
    if user.toggles[vk] then v = v | 1 end
    return v
end)
def("USER", 104, "MessageBeep", "w:v", function() host.beep() end)
def("USER", 69, "SetCursor", "h", function(h)
    local o = handles.get(h, "cursor")
    local old = user.cursorHandle or 0
    user.cursorHandle = h
    user.setCursor(o and o.name or "arrow")
    return old
end)
def("USER", 71, "ShowCursor", "w", function(show)
    user.cursorCount = (user.cursorCount or 0) + (show ~= 0 and 1 or -1)
    return user.cursorCount
end)

-- ---- messages, hooks, atoms --------------------------------------------------------------------------------

local regMsgs, nextMsg = {}, 0xC000
def("USER", 118, "RegisterWindowMessage", "s", function(s)
    if not s then return 0 end
    local k = s:upper()
    if not regMsgs[k] then regMsgs[k] = nextMsg; nextMsg = nextMsg + 1 end
    return regMsgs[k]
end)

user.hooks = {}
def("USER", 121, "SetWindowsHook", "i f:l", function(id, proc)
    local old = user.hooks[id] or 0
    user.hooks[id] = proc
    return old
end)
def("USER", 234, "UnhookWindowsHook", "i f", function(id, proc)
    if user.hooks[id] == proc then user.hooks[id] = nil end
    return 1
end)
def("USER", 235, "DefHookProc", "i w l f:l", function() return 0 end)

-- Calls the message-filter hook (WH_MSGFILTER) the way dialogs and menus do.
-- Returns true when the hook handled the message.
function user.callMsgFilter(code, lpMsgFar)
    local proc = user.hooks[-1]
    if not proc or proc == 0 then return false end
    local r = cpu.call16(user.task.R, proc >> 16, proc & 0xFFFF, {code, 0, lpMsgFar >> 16, lpMsgFar & 0xFFFF},
                         {ds = user.task.dgroup, ax = user.task.dgroup})
    return r ~= 0
end

-- Global atoms (DDE uses them): strings <-> numbers from 0xC000
user.atomNames, user.atomIds, user.atomRefs = {}, {}, {}
local nextAtom = 0xC000
function user.addAtom(s)
    if type(s) == "number" then return s end
    local k = s:upper()
    local a = user.atomIds[k]
    if not a then
        a = nextAtom
        nextAtom = nextAtom + 1
        user.atomIds[k] = a
        user.atomNames[a] = s
    end
    user.atomRefs[a] = (user.atomRefs[a] or 0) + 1
    return a
end
def("USER", 268, "GlobalAddAtom", "r", function(s) return s and user.addAtom(s) or 0 end)
def("USER", 269, "GlobalDeleteAtom", "w", function(a)
    if user.atomRefs[a] then
        user.atomRefs[a] = user.atomRefs[a] - 1
        if user.atomRefs[a] <= 0 then
            user.atomRefs[a] = nil
            local n = user.atomNames[a]
            if n then user.atomIds[n:upper()] = nil end
            user.atomNames[a] = nil
        end
    end
    return 0
end)
def("USER", 270, "GlobalFindAtom", "r", function(s)
    if type(s) == "number" then return s end
    return s and user.atomIds[s:upper()] or 0
end)
def("USER", 271, "GlobalGetAtomName", "w p i", function(a, buf, n)
    local s = user.atomNames[a]
    if not s then return 0 end
    return api.putstr(buf, s, n)
end)

-- ---- strings ----------------------------------------------------------------------------------------------

local function upper(s) return (s:gsub("[%a\224-\254]", function(c)
    local b = c:byte()
    if b >= 224 and b ~= 247 then return string.char(b - 32) end
    return c:upper()
end)) end
local function lower(s) return (s:gsub("[%a\192-\222]", function(c)
    local b = c:byte()
    if b >= 192 and b <= 222 and b ~= 215 then return string.char(b + 32) end
    return c:lower()
end)) end
user.upper, user.lower = upper, lower

def("USER", 430, "lstrcmp", "s s", function(a, b)
    a, b = a or "", b or ""
    if a == b then return 0 end
    -- Windows compares case-insensitively first (word sort), then by case
    local ua, ub = upper(a), upper(b)
    if ua ~= ub then return ua < ub and -1 or 1 end
    return a > b and -1 or 1
end)
def("USER", 471, "lstrcmpi", "s s", function(a, b)
    a, b = upper(a or ""), upper(b or "")
    if a == b then return 0 end
    return a < b and -1 or 1
end)
def("USER", 431, "AnsiUpper", "f:l", function(fp)
    if (fp >> 16) == 0 then return upper(string.char(fp & 0xFF)):byte() end
    local l = cpu.flat(fp)
    if l then mem.write(l, upper(mem.cstr(l))) end
    return fp
end)
def("USER", 432, "AnsiLower", "f:l", function(fp)
    if (fp >> 16) == 0 then return lower(string.char(fp & 0xFF)):byte() end
    local l = cpu.flat(fp)
    if l then mem.write(l, lower(mem.cstr(l))) end
    return fp
end)
def("USER", 437, "AnsiUpperBuff", "p w", function(p, n)
    if not p then return 0 end
    if n == 0 then n = 65536 end
    mem.write(p, upper(mem.read(p, n)))
    return n
end)
def("USER", 433, "IsCharAlpha", "w", function(c)
    local s = string.char(c & 0xFF)
    return s:match("%a") ~= nil or (c >= 192 and c ~= 215 and c ~= 247 and c <= 255)
end)
def("USER", 434, "IsCharAlphaNumeric", "w", function(c)
    local s = string.char(c & 0xFF)
    return s:match("%w") ~= nil or (c >= 192 and c ~= 215 and c ~= 247 and c <= 255)
end)

-- wsprintf (C calling convention: the caller pops)
local function wsprintf(R)
    -- the thunk has already returned (popped CS:IP), so SP points at lpOut
    local sp = R.ssb + (R.sp & 0xFFFF)
    local out = cpu.flat(rd(sp))
    local fmt = cpu.flat(rd(sp + 4))
    local argp = sp + 8
    if not out or not fmt then R.ax = 0; return end
    local f = mem.cstr(fmt)
    local result = f:gsub("%%([-#0]*)(%d*)%.?(%d*)(l?)([dixXuscp%%])", function(flags, width, prec, long, conv)
        if conv == "%" then return "%" end
        local v
        if conv == "s" then
            local l = cpu.flat(rd(argp)); argp = argp + 4
            v = l and mem.cstr(l) or "(null)"
            if prec ~= "" then v = v:sub(1, tonumber(prec)) end
        elseif conv == "c" then
            v = string.char(rw(argp) & 0xFF); argp = argp + 2
        else
            local n
            if long == "l" then n = rd(argp); argp = argp + 4 else n = rw(argp); argp = argp + 2 end
            if conv == "d" or conv == "i" then
                if long == "l" then if n >= 0x80000000 then n = n - 0x100000000 end else n = s16(n) end
                v = tostring(n)
            elseif conv == "u" then v = tostring(n)
            elseif conv == "x" then v = string.format("%x", n)
            elseif conv == "X" then v = string.format("%X", n)
            else v = string.format("%X", n) end
            if prec ~= "" and #v < tonumber(prec) then v = string.rep("0", tonumber(prec) - #v) .. v end
        end
        local wdt = tonumber(width) or 0
        if #v < wdt then
            if flags:find("-") then v = v .. string.rep(" ", wdt - #v)
            elseif flags:find("0") and conv ~= "s" then
                local neg = v:sub(1, 1) == "-"
                if neg then v = "-" .. string.rep("0", wdt - #v) .. v:sub(2) else v = string.rep("0", wdt - #v) .. v end
            else v = string.rep(" ", wdt - #v) .. v end
        end
        return v
    end)
    mem.write(out, result .. "\0")
    R.ax = #result
end
api.def("USER", 420, "_wsprintf", ":v", function(R) wsprintf(R) end)

-- wvsprintf(lpOut, lpFmt, lpArgs): Pascal, the arguments in a buffer
def("USER", 421, "wvsprintf", "f f f", function(outFp, fmtFp, argsFp, R)
    -- reuse wsprintf by building its stack layout in scratch memory
    local mark = api.mark()
    local fp, lin = api.alloc(256)
    wd(lin, outFp); wd(lin + 4, fmtFp)
    local a = cpu.flat(argsFp)
    if a then mem.write(lin + 8, mem.read(a, 240)) end
    local fake = {sp = 0, ssb = lin}
    wsprintf(setmetatable(fake, {__index = R}))
    api.release(mark)
    return fake.ax
end)

-- ---- the rest --------------------------------------------------------------------------------------------

def("USER", 5, "InitApp", "h", function() return 1 end)
def("USER", 7, "ExitWindows", "l w", function()
    -- Program Manager's "Exit Windows": the app closes
    user.quit = 0
    return 1
end)
def("USER", 171, "WinHelp", "h s w l", function(h, file, cmd, data)
    if cmd == 2 then return 1 end  -- HELP_QUIT
    local launch = require("win16.launch")
    launch.help(file, cmd, data)
    return 1
end)

-- carets: one per queue, drawn by XOR, blinking
user.caret = nil
def("USER", 163, "CreateCaret", "h h i i:v", function(h, bm, cw, ch)
    user.caret = {w = W(h), cw = cw == 0 and 1 or cw, ch = ch == 0 and 16 or ch, x = 0, y = 0, hidden = 1, on = false}
end)
def("USER", 164, "DestroyCaret", ":v", function()
    if user.caret and user.caret.on then user.caretXor() end
    user.caret = nil
end)
def("USER", 165, "SetCaretPos", "i i:v", function(x, y)
    local c = user.caret
    if not c then return end
    if c.on then user.caretXor() end
    c.x, c.y = x, y
end)
def("USER", 166, "HideCaret", "h:v", function()
    local c = user.caret
    if not c then return end
    if c.on then user.caretXor() end
    c.hidden = c.hidden + 1
end)
def("USER", 167, "ShowCaret", "h:v", function()
    local c = user.caret
    if not c then return end
    if c.hidden > 0 then c.hidden = c.hidden - 1 end
end)
function user.caretXor()
    local c = user.caret
    if not c or not c.w or c.w.destroyed then return end
    local vis = user.visRegion(c.w, true)
    if #vis == 0 then c.on = false; return end
    fb.clip(region.flat(vis))
    local ox, oy = user.clientOrigin(c.w)
    fb.patblt(0, ox + c.x, oy + c.y, c.cw, c.ch, 0x55, 0)
    c.on = not c.on
    user.dirty = true
end

return user

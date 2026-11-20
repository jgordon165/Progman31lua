-- DefWindowProc: the non-client area in Windows 3.1's look (frames,
-- captions, the system-menu box and the minimize/maximize buttons from the
-- display driver's bitmaps), hit testing, moving and sizing with the mouse,
-- system commands, icons for minimized windows, and the default handling of
-- every other message.

local api = require("win16.api")
local gdi = require("win16.gdi")
local handles = require("win16.handles")
local region = require("win16.region")
local res = require("win16.resources")
local user = require("win16.user")

local WM, WS, SC, HT, COLOR = user.WM, user.WS, user.SC, user.HT, user.COLOR
local C, MT = user.sysColors, user.metrics
local W = user.W
local rw, ww, rd = mem.rw, mem.ww, mem.rd
local s16 = api.s16

local defwnd = {}

local OBM = {CLOSE = 32754, REDUCE = 32749, ZOOM = 32748, RESTORE = 32747, REDUCED = 32746, ZOOMD = 32745,
             RESTORED = 32744}
defwnd.OBM = OBM

local function hasCaption(w) return (w.style & WS.CAPTION) == WS.CAPTION end

-- Draws on the screen surface, clipped to a window's visible region.
local function screenClip(w)
    local vis = user.visRegion(w, false)
    if #vis == 0 then return false end
    fb.clip(region.flat(vis))
    return true
end
defwnd.screenClip = screenClip

local function fill(x, y, cw, ch, c) fb.patblt(0, x, y, cw, ch, 0xF0, c) end
local function frameRect(x, y, cw, ch, c, t)
    t = t or 1
    fill(x, y, cw, t, c); fill(x, y + ch - t, cw, t, c)
    fill(x, y, t, ch, c); fill(x + cw - t, y, t, ch, c)
end
defwnd.fill, defwnd.frameRect = fill, frameRect

-- Draws a display-driver bitmap at a screen position; mono ones in black on the given colour.
local function obm(id, x, y, sx, sw, sh)
    local b = res.obm(id)
    if not b then return false end
    fb.bitblt(0, x, y, sw or b.w, sh or b.h, b.surface, sx or 0, 0, 0xCC, 0, 0, 0xFFFFFF)
    return true
end
defwnd.obm = obm

-- Caption button geometry (window coordinates): sysmenu, minimize, maximize.
function defwnd.buttons(w)
    local b = user.borderOf(w)
    local top = b
    local h = MT.CYCAPTION - 2
    local out = {}
    local right = w.w - b
    if w.style & WS.SYSMENU ~= 0 then out.sys = {b, top, b + MT.CXSIZE + 1, top + h} end
    if w.style & WS.MAXIMIZEBOX ~= 0 and w.style & WS.CHILD == 0 or (w.style & WS.CHILD ~= 0 and w.style & WS.MAXIMIZEBOX ~= 0) then
        out.max = {right - (MT.CXSIZE + 1), top, right, top + h}
        right = right - (MT.CXSIZE + 1)
    end
    if w.style & WS.MINIMIZEBOX ~= 0 then
        out.min = {right - (MT.CXSIZE + 1), top, right, top + h}
    end
    return out
end

-- The caption text, centred in the space between the buttons.
local function drawCaption(w, x0, y0, active)
    local b = user.borderOf(w)
    local cy = MT.CYCAPTION - 1
    local cx0, cx1 = x0 + b, x0 + w.w - b
    local capColor = active and C[COLOR.ACTIVECAPTION] or C[COLOR.INACTIVECAPTION]
    local textColor = active and C[COLOR.CAPTIONTEXT] or C[COLOR.INACTIVECAPTIONTEXT]
    fill(cx0, y0 + b, cx1 - cx0, cy - 1, capColor)
    fill(cx0, y0 + b + cy - 1, cx1 - cx0, 1, C[COLOR.WINDOWFRAME])
    local btn = defwnd.buttons(w)
    local tl, tr = cx0, cx1
    if btn.sys then
        local sb = btn.sys
        -- the system-menu box: the left half of OBM_CLOSE for windows, the right half for MDI children
        local child = w.style & WS.CHILD ~= 0
        local img = res.obm(OBM.CLOSE)
        if img then
            local half = img.w // 2
            fb.bitblt(0, x0 + sb[1], y0 + sb[2], half, math.min(img.h, cy - 1), img.surface, child and half or 0, 0, 0xCC, 0, 0, 0xFFFFFF)
        end
        fill(x0 + sb[3] - 1, y0 + sb[2], 1, cy - 1, C[COLOR.WINDOWFRAME])
        tl = x0 + sb[3]
    end
    local pressed = defwnd.pressed and defwnd.pressed.w == w and defwnd.pressed.which
    if btn.max then
        local mb = btn.max
        local id = w.zoomed and (pressed == "max" and OBM.RESTORED or OBM.RESTORE) or (pressed == "max" and OBM.ZOOMD or OBM.ZOOM)
        fill(x0 + mb[1] - 1, y0 + mb[2], 1, cy - 1, C[COLOR.WINDOWFRAME])
        obm(id, x0 + mb[1], y0 + mb[2])
        tr = x0 + mb[1] - 1
    end
    if btn.min then
        local nb = btn.min
        fill(x0 + nb[1] - 1, y0 + nb[2], 1, cy - 1, C[COLOR.WINDOWFRAME])
        obm(pressed == "min" and OBM.REDUCED or OBM.REDUCE, x0 + nb[1], y0 + nb[2])
        tr = x0 + nb[1] - 1
    end
    local font = gdi.fontObj({font = gdi.stock(13)})
    if font.rf and w.text ~= "" then
        local text = w.text
        local tw = fb.text_width(font.rf.fid, text, false)
        local avail = tr - tl - 4
        while tw > avail and #text > 1 do
            text = text:sub(1, -2)
            tw = fb.text_width(font.rf.fid, text .. "...", false)
            if tw <= avail then text = text .. "..."; break end
        end
        local tx = tl + math.max((tr - tl - tw) // 2, 2)
        local ty = y0 + b + (cy - 1 - font.rf.m.height) // 2
        local vis = user.visRegion(w, false)
        fb.clip(region.flat(region.intersect(vis, {{tl, y0 + b, tr, y0 + b + cy - 1}})))
        fb.text(0, font.rf.fid, tx, ty, text, textColor, capColor, false, false, false)
        screenClip(w)
    end
end

-- Paints a window's non-client area on the screen.
function defwnd.paintNC(w)
    if w.destroyed or not user.isVisible(w) then return end
    user.dirty = true
    if not screenClip(w) then return end
    local x0, y0 = user.screenPos(w)
    if w.iconic then return defwnd.paintIcon(w, x0, y0) end
    local b = user.borderOf(w)
    local active = user.isActiveCaption(w)
    local frameColor = C[COLOR.WINDOWFRAME]
    if w.style & WS.THICKFRAME ~= 0 then
        local bc = active and C[COLOR.ACTIVEBORDER] or C[COLOR.INACTIVEBORDER]
        frameRect(x0, y0, w.w, w.h, frameColor, 1)
        frameRect(x0 + 1, y0 + 1, w.w - 2, w.h - 2, bc, b - 2)
        frameRect(x0 + b - 1, y0 + b - 1, w.w - 2 * (b - 1), w.h - 2 * (b - 1), frameColor, 1)
        -- the sizing marks, one caption height from each corner
        local m = MT.CYCAPTION + b - 1
        if w.w > 2 * m and w.h > 2 * m then
            for _, xx in ipairs({x0 + m, x0 + w.w - m - 1}) do
                fill(xx, y0, 1, b, frameColor); fill(xx, y0 + w.h - b, 1, b, frameColor)
            end
            for _, yy in ipairs({y0 + m, y0 + w.h - m - 1}) do
                fill(x0, yy, b, 1, frameColor); fill(x0 + w.w - b, yy, b, 1, frameColor)
            end
        end
    elseif b == MT.CXDLGFRAME then
        -- a dialog frame: black, then the caption colour (blue when active)
        frameRect(x0, y0, w.w, w.h, frameColor, 1)
        frameRect(x0 + 1, y0 + 1, w.w - 2, w.h - 2, active and C[COLOR.ACTIVECAPTION] or C[COLOR.INACTIVEBORDER], b - 2)
        frameRect(x0 + b - 1, y0 + b - 1, w.w - 2 * (b - 1), w.h - 2 * (b - 1), frameColor, 1)
    elseif b == 1 then
        frameRect(x0, y0, w.w, w.h, frameColor, 1)
    end
    if hasCaption(w) then drawCaption(w, x0, y0, active) end
    if w.menuH and w.menuH > 0 and user.paintMenuBar then user.paintMenuBar(w, x0, y0) end
    if user.paintScrollBars then user.paintScrollBars(w, x0, y0) end
end

-- A caption is drawn active when its window is the active one, or for an
-- MDI child, the MDI client's active child.
function user.isActiveCaption(w)
    if w.style & WS.CHILD ~= 0 then
        local p = w.parent
        return p and p.mdiActive == w and user.active == user.topLevel(w)
    end
    return user.active == w or (user.active and user.active.owner == w and user.active.disabledOwner)
end

-- A minimized window: its class icon (or WM_PAINTICON), and the title below.
function defwnd.paintIcon(w, x0, y0)
    local p = w.parent
    local bg = p.class and user.brushFor(p.class.brush)
    if p.class and p.class.mdiClient then bg = user.sysBrush(COLOR.APPWORKSPACE) end
    local bgc = C[COLOR.BACKGROUND]
    if bg then local o = handles.get(bg); if o and o.color then bgc = o.color end end
    fill(x0, y0, w.w, w.h, bgc)
    local icon = w.class.icon
    local ix = x0 + (w.w - MT.CXICON) // 2
    if icon and icon ~= 0 then
        local lin = require("win16.kernel").glin(icon)
        if lin then
            local dc = gdi.dc(gdi.newDC({surface = 0, ox = 0, oy = 0, clipFn = function() return user.visRegion(w, false) end}))
            gdi.drawIcon(dc, ix, y0 + 2, lin)
            handles.free(dc.handle)
        end
    end
    -- the title, wrapped like Windows' icon titles (one line here), highlighted when active
    local font = gdi.fontObj({font = user.iconFont or gdi.stock(12)})
    if font.rf then
        local text = w.text
        local tw = fb.text_width(font.rf.fid, text, font.bold)
        local maxw = w.w - 2
        if tw > maxw then
            while #text > 1 and fb.text_width(font.rf.fid, text, font.bold) > maxw do text = text:sub(1, -2) end
            tw = fb.text_width(font.rf.fid, text, font.bold)
        end
        local ty = y0 + MT.CYICON + 4
        local tx = x0 + (w.w - tw) // 2
        local active = user.isActiveCaption(w) or user.active == w
        screenClip(w)
        if active then
            fill(tx - 1, ty, tw + 2, font.rf.m.height, C[COLOR.ACTIVECAPTION])
        end
        fb.text(0, font.rf.fid, tx, ty, text, active and C[COLOR.CAPTIONTEXT] or 0, 0, false, font.bold, false)
    end
end

-- Hit testing (screen point).
function defwnd.hitTest(w, x, y)
    local x0, y0 = user.screenPos(w)
    local lx, ly = x - x0, y - y0
    if lx < 0 or ly < 0 or lx >= w.w or ly >= w.h then return HT.NOWHERE end
    if w.iconic then return HT.CAPTION end
    local cl = w.cl
    if lx >= cl[1] and lx < cl[3] and ly >= cl[2] and ly < cl[4] then return HT.CLIENT end
    local b = user.borderOf(w)
    if w.style & WS.THICKFRAME ~= 0 and not w.zoomed then
        local corner = MT.CYCAPTION + b
        local left, right, top, bottom = lx < b, lx >= w.w - b, ly < b, ly >= w.h - b
        if top or bottom or left or right then
            if top then
                if lx < corner then return HT.TOPLEFT end
                if lx >= w.w - corner then return HT.TOPRIGHT end
                return HT.TOP
            elseif bottom then
                if lx < corner then return HT.BOTTOMLEFT end
                if lx >= w.w - corner then return HT.BOTTOMRIGHT end
                return HT.BOTTOM
            elseif left then
                if ly < corner then return HT.TOPLEFT end
                if ly >= w.h - corner then return HT.BOTTOMLEFT end
                return HT.LEFT
            else
                if ly < corner then return HT.TOPRIGHT end
                if ly >= w.h - corner then return HT.BOTTOMRIGHT end
                return HT.RIGHT
            end
        end
    end
    if hasCaption(w) and ly >= b and ly < b + MT.CYCAPTION - 1 then
        local btn = defwnd.buttons(w)
        local function inb(r) return r and lx >= r[1] and lx < r[3] end
        if inb(btn.sys) then return HT.SYSMENU end
        if inb(btn.max) then return HT.ZOOM end
        if inb(btn.min) then return HT.REDUCE end
        return HT.CAPTION
    end
    if w.menuH and w.menuH > 0 and ly >= w.menuTop and ly < w.menuTop + w.menuH then return HT.MENU end
    if w.vscroll and w.vscroll.visible and lx >= cl[3] and ly >= cl[2] and ly < cl[4] then return HT.VSCROLL end
    if w.hscroll and w.hscroll.visible and ly >= cl[4] and lx >= cl[1] and lx < cl[3] then return HT.HSCROLL end
    if w.vscroll and w.vscroll.visible and w.hscroll and w.hscroll.visible and lx >= cl[3] and ly >= cl[4] then
        return HT.GROWBOX
    end
    return HT.BORDER
end

-- ---- moving and sizing ---------------------------------------------------------------------------------
-- As Windows 3.1 did it: a gray XOR outline follows the mouse; the window
-- moves once, at the end.

local GRAY = {}
for i = 1, 64 do
    local x, y = (i - 1) % 8, (i - 1) // 8
    GRAY[i] = ((x + y) % 2 == 0) and 0xFFFFFF or 0
end

-- The outline is an overlay: drawn over the screen for each present (XOR
-- with the gray pattern, as Windows 3.1 drew it) and never left behind.
local function outline(r, t)
    return {x = r[1], y = r[2], w = r[3] - r[1], h = r[4] - r[2], draw = function(o)
        fb.clip(nil)
        local x, y, cw, ch = o.x, o.y, o.w, o.h
        fb.patblt(0, x, y, cw, t, 0x5A, GRAY)
        fb.patblt(0, x, y + ch - t, cw, t, 0x5A, GRAY)
        fb.patblt(0, x, y + t, t, ch - 2 * t, 0x5A, GRAY)
        fb.patblt(0, x + cw - t, y + t, t, ch - 2 * t, 0x5A, GRAY)
    end}
end
defwnd.outline = outline

local function showOutline(o, r)
    o.x, o.y, o.w, o.h = r[1], r[2], r[3] - r[1], r[4] - r[2]
    user.dirty = true
end

function defwnd.track(w, hit, sx, sy)
    if user.appMode and w == user.frame then return end
    local r0 = user.windowRect(w)
    local r = {r0[1], r0[2], r0[3], r0[4]}
    local t = w.iconic and 1 or math.max(user.borderOf(w), 3)
    local p = w.parent
    local pc = user.clientRect(p)
    local minW, minH = w.iconic and 0 or 100, w.iconic and 0 or (MT.CYCAPTION + 8)
    local o = outline(r, t)
    local drawFn = o.draw
    o.draw = function() drawFn(o) end
    local shown = false
    local moved = false
    local function done(ok)
        for i, x in ipairs(user.overlays) do if x == o then table.remove(user.overlays, i); break end end
        user.dirty = true
        return ok
    end
    while true do
        local ev = user.waitInput()
        if ev.kind == "move" or ev.kind == "up" then
            local x, y = ev.e[2], ev.e[3]
            -- keep the pointer inside the parent's client area
            x = math.max(pc[1], math.min(pc[3] - 1, x))
            y = math.max(pc[2], math.min(pc[4] - 1, y))
            local dx, dy = x - sx, y - sy
            -- a few pixels of slack before a press becomes a drag
            if not moved and math.abs(dx) <= 2 and math.abs(dy) <= 2 and ev.kind == "move" then goto next end
            if dx ~= 0 or dy ~= 0 then moved = true end
            local n = {r0[1], r0[2], r0[3], r0[4]}
            if hit == HT.CAPTION then
                n = {r0[1] + dx, r0[2] + dy, r0[3] + dx, r0[4] + dy}
            else
                if hit == HT.LEFT or hit == HT.TOPLEFT or hit == HT.BOTTOMLEFT then n[1] = math.min(r0[1] + dx, r0[3] - minW) end
                if hit == HT.RIGHT or hit == HT.TOPRIGHT or hit == HT.BOTTOMRIGHT then n[3] = math.max(r0[3] + dx, r0[1] + minW) end
                if hit == HT.TOP or hit == HT.TOPLEFT or hit == HT.TOPRIGHT then n[2] = math.min(r0[2] + dy, r0[4] - minH) end
                if hit == HT.BOTTOM or hit == HT.BOTTOMLEFT or hit == HT.BOTTOMRIGHT then n[4] = math.max(r0[4] + dy, r0[2] + minH) end
            end
            r = n
            if ev.kind == "up" then break end
            if not shown then user.overlays[#user.overlays + 1] = o; shown = true end
            showOutline(o, r)
            user.present()
        elseif ev.kind == "key" and ev.e[2] == 0x1B and ev.e[3] == 1 then
            user.buttons[1] = false
            return done(false)
        end
        ::next::
    end
    done(true)
    user.buttons[1] = false
    if not moved then return false end
    local ox, oy = user.clientOrigin(p)
    user.setPos(w, r[1] - ox, r[2] - oy, r[3] - r[1], r[4] - r[2])
    if w.iconic then w.iconMoved = true end
    return true
end

-- Tracks a press on a caption button: drawn pushed while the mouse is over it.
local function trackButton(w, which, rect)
    local x0, y0 = user.screenPos(w)
    local inside = true
    defwnd.pressed = {w = w, which = which}
    defwnd.paintNC(w)
    user.present()
    while true do
        local ev = user.waitInput()
        if ev.kind == "move" or ev.kind == "up" then
            local x, y = ev.e[2] - x0, ev.e[3] - y0
            local now = x >= rect[1] and x < rect[3] and y >= rect[2] and y < rect[4]
            if now ~= inside then
                inside = now
                defwnd.pressed = now and {w = w, which = which} or nil
                defwnd.paintNC(w)
                user.present()
            end
            if ev.kind == "up" then break end
        end
    end
    user.buttons[1] = false
    defwnd.pressed = nil
    defwnd.paintNC(w)
    return inside
end

-- ---- system commands ---------------------------------------------------------------------------------

function defwnd.sysCommand(w, cmd, lp)
    local c = cmd & 0xFFF0
    if c == SC.CLOSE then
        user.send(w, WM.CLOSE, 0, 0)
    elseif c == SC.MINIMIZE then
        user.showWindow(w, 6)
    elseif c == SC.MAXIMIZE then
        user.showWindow(w, 3)
    elseif c == SC.RESTORE then
        user.showWindow(w, 9)
    elseif c == SC.MOVE or c == SC.SIZE then
        if c == SC.MOVE and w.zoomed then return 0 end
        local hit = c == SC.MOVE and HT.CAPTION or ((cmd & 0xF) ~= 0 and (cmd & 0xF) + 9 or HT.BOTTOMRIGHT)
        local sx, sy
        if lp ~= 0 then sx, sy = api.unpt(lp) else sx, sy = user.mouseX, user.mouseY end
        defwnd.track(w, hit, sx, sy)
    elseif c == SC.MOUSEMENU then
        if user.trackMenuBar then user.trackMenuBar(w, lp) end
    elseif c == SC.KEYMENU then
        if user.keyMenu then user.keyMenu(w, lp & 0xFFFF) end
    elseif c == SC.NEXTWINDOW or c == SC.PREVWINDOW then
        local list = {}
        for _, s in ipairs(user.desktop.children) do if s.visible then list[#list + 1] = s end end
        if #list > 1 then user.activate(c == SC.NEXTWINDOW and list[#list] or list[2]) end
    elseif c == SC.TASKLIST then
        -- no Task List here
    end
    return 0
end

-- ---- DefWindowProc ----------------------------------------------------------------------------------------

function defwnd.proc(hwnd, msg, wp, lp)
    local w = W(hwnd)
    if not w then return 0 end
    if msg == WM.NCCREATE then
        local cs = require("recomp.cpu").flat(lp)
        if cs then
            local name = rd(cs + 22)
            local l = require("recomp.cpu").flat(name)
            if l then w.text = mem.cstr(l) end
        end
        return 1
    elseif msg == WM.NCPAINT then
        defwnd.paintNC(w)
        return 0
    elseif msg == WM.NCACTIVATE then
        w.ncdirty = true
        user.dirty = true
        return 1
    elseif msg == WM.NCHITTEST then
        local x, y = api.unpt(lp)
        return defwnd.hitTest(w, x, y)
    elseif msg == WM.RBUTTONUP then
        -- not in Windows 3.1: a hook for host context menus
        if user.contextMenu then
            local x, y = api.unpt(lp)
            local ox, oy = user.clientOrigin(w)
            user.contextMenu(w, x + ox, y + oy)
        end
        return 0
    elseif msg == WM.NCLBUTTONDOWN then
        local x, y = api.unpt(lp)
        if wp == HT.CAPTION then
            if w.style & WS.CHILD ~= 0 and user.mdiActivate then user.mdiActivate(w) end
            if w.iconic then
                -- a click on an icon opens its system menu; a drag moves it
                local moved = defwnd.track(w, HT.CAPTION, x, y)
                if moved or (user.appMode and w == user.frame) then return 0 end
                -- a second click within the double-click time restores it instead
                local deadline = host.ticks() + 450
                while host.ticks() < deadline do
                    local ev = user.waitInput(math.max(deadline - host.ticks(), 1))
                    if ev and ev.kind == "down" and ev.e[4] == 1 then
                        local ev2 = user.waitInput(300)
                        user.buttons[1] = false
                        user.send(w, WM.SYSCOMMAND, SC.RESTORE, lp)
                        return 0
                    elseif ev and ev.kind ~= "move" and ev.kind ~= "up" then
                        table.insert(user.input, 1, ev)
                        break
                    end
                end
                if user.trackSysMenu then user.trackSysMenu(w) end
                return 0
            end
            user.send(w, WM.SYSCOMMAND, SC.MOVE + HT.CAPTION, lp)
        elseif wp >= HT.LEFT and wp <= HT.BOTTOMRIGHT then
            user.send(w, WM.SYSCOMMAND, SC.SIZE + (wp - 9), lp)
        elseif wp == HT.SYSMENU then
            if user.trackSysMenu then user.trackSysMenu(w) end
        elseif wp == HT.MENU then
            user.send(w, WM.SYSCOMMAND, SC.MOUSEMENU, lp)
        elseif wp == HT.REDUCE or wp == HT.ZOOM then
            local btn = defwnd.buttons(w)
            local which = wp == HT.REDUCE and "min" or "max"
            if trackButton(w, which, btn[which]) then
                local cmd = wp == HT.REDUCE and SC.MINIMIZE or (w.zoomed and SC.RESTORE or SC.MAXIMIZE)
                user.send(w, WM.SYSCOMMAND, cmd, lp)
            end
        elseif wp == HT.VSCROLL or wp == HT.HSCROLL then
            if user.trackScrollBar then user.trackScrollBar(w, wp == HT.VSCROLL, x, y) end
        end
        return 0
    elseif msg == WM.NCLBUTTONDBLCLK then
        if wp == HT.CAPTION and not (user.appMode and w == user.frame) then
            if w.iconic then user.send(w, WM.SYSCOMMAND, SC.RESTORE, lp)
            elseif w.style & WS.MAXIMIZEBOX ~= 0 then
                user.send(w, WM.SYSCOMMAND, w.zoomed and SC.RESTORE or SC.MAXIMIZE, lp)
            end
        elseif wp == HT.SYSMENU then
            user.send(w, WM.SYSCOMMAND, SC.CLOSE, lp)
        elseif wp == HT.VSCROLL or wp == HT.HSCROLL then
            local x, y = api.unpt(lp)
            if user.trackScrollBar then user.trackScrollBar(w, wp == HT.VSCROLL, x, y) end
        end
        return 0
    elseif msg == WM.SETCURSOR then
        local ht = s16(lp & 0xFFFF)
        -- a child asks its parent first
        if w.style & WS.CHILD ~= 0 and w.parent and w.parent ~= user.desktop then
            if user.send(w.parent, WM.SETCURSOR, wp, lp) ~= 0 then return 1 end
        end
        local name = "arrow"
        if ht == HT.LEFT or ht == HT.RIGHT then name = "sizewe"
        elseif ht == HT.TOP or ht == HT.BOTTOM then name = "sizens"
        elseif ht == HT.TOPLEFT or ht == HT.BOTTOMRIGHT then name = "sizenwse"
        elseif ht == HT.TOPRIGHT or ht == HT.BOTTOMLEFT then name = "sizenesw"
        elseif ht == HT.CLIENT and w.class.cursor and w.class.cursor ~= 0 then
            local o = handles.get(w.class.cursor)
            name = o and o.name or "arrow"
        end
        if ht ~= HT.CLIENT or (w.class.cursor and w.class.cursor ~= 0) then
            user.setCursor(name)
            return ht == HT.CLIENT and 0 or 1
        end
        return 0
    elseif msg == WM.MOUSEACTIVATE then
        if w.style & WS.CHILD ~= 0 and w.parent and w.parent ~= user.desktop then
            local r = user.send(w.parent, WM.MOUSEACTIVATE, wp, lp)
            if r ~= 0 then return r end
        end
        return 1
    elseif msg == WM.ACTIVATE then
        if (wp & 0xFFFF) ~= 0 and (lp >> 16) == 0 then
            if not user.focus or user.topLevel(user.focus) ~= w then user.setFocus(w) end
        end
        return 0
    elseif msg == WM.SETTEXT then
        local l = require("recomp.cpu").flat(lp)
        w.text = l and mem.cstr(l) or ""
        if (w.style & WS.CAPTION) == WS.CAPTION or w.iconic then w.ncdirty = true; user.dirty = true end
        if user.appMode and w == user.frame then host.title(w.text) end
        if user.onTextChanged then user.onTextChanged(w) end
        return 1
    elseif msg == WM.GETTEXT then
        local l = require("recomp.cpu").flat(lp)
        return api.putstr(l, w.text, wp)
    elseif msg == WM.GETTEXTLENGTH then
        return #w.text
    elseif msg == WM.ERASEBKGND then
        local brush = user.brushFor(w.class.brush)
        if not brush then return 0 end
        local dc = gdi.dc(wp)
        if dc then user.fillRect(dc, {0, 0, w.cl[3] - w.cl[1], w.cl[4] - w.cl[2]}, brush) end
        return 1
    elseif msg == WM.ICONERASEBKGND then
        return 1
    elseif msg == WM.PAINT then
        local mark = api.mark()
        local fp, lin = api.alloc(32)
        local hdc = user.beginPaint(w, lin)
        user.endPaint(w, hdc)
        api.release(mark)
        return 0
    elseif msg == WM.CLOSE then
        user.destroy(w)
        return 0
    elseif msg == WM.SYSCOMMAND then
        return defwnd.sysCommand(w, wp, lp)
    elseif msg == WM.SYSKEYDOWN then
        if wp == 0x73 and user.keys[0x12] then        -- Alt+F4
            user.post(user.topLevel(w), WM.SYSCOMMAND, SC.CLOSE, 0)
        elseif wp == 0x79 then                         -- F10
            user.send(user.topLevel(w), WM.SYSCOMMAND, SC.KEYMENU, 0)
        end
        return 0
    elseif msg == WM.SYSKEYUP then
        if wp == 0x12 and user.altReleased then
            user.altReleased = false
            user.send(user.topLevel(w), WM.SYSCOMMAND, SC.KEYMENU, 0)
        end
        return 0
    elseif msg == WM.SYSCHAR then
        local top = user.topLevel(w)
        if wp == 0x20 then user.send(w.style & WS.CHILD ~= 0 and top or w, WM.SYSCOMMAND, SC.KEYMENU, 0x20)
        elseif wp == 0x2D and w.style & WS.CHILD ~= 0 then user.send(w, WM.SYSCOMMAND, SC.KEYMENU, 0x2D)
        else user.send(top, WM.SYSCOMMAND, SC.KEYMENU, wp) end
        return 0
    elseif msg == WM.CTLCOLOR then
        local dc = gdi.dc(wp)
        local kind = lp >> 16
        if kind == 6 or kind == 2 or kind == 3 then   -- scroll bars use their own colour
            if dc then dc.text = C[COLOR.WINDOWTEXT]; dc.bk = C[COLOR.WINDOW] end
            if kind == 6 then return user.sysBrush(COLOR.SCROLLBAR) end
            return user.sysBrush(COLOR.WINDOW)
        end
        if dc then dc.text = C[COLOR.WINDOWTEXT]; dc.bk = C[COLOR.WINDOW] end
        return user.sysBrush(COLOR.WINDOW)
    elseif msg == WM.QUERYOPEN or msg == WM.QUERYENDSESSION then
        return 1
    elseif msg == WM.GETMINMAXINFO or msg == WM.SHOWWINDOW or msg == WM.WINDOWPOSCHANGING or msg == WM.WINDOWPOSCHANGED then
        return 0
    elseif msg == WM.PAINTICON then
        return 0
    elseif msg == WM.QUERYDRAGICON then
        return w.class.icon or 0
    elseif msg == WM.SETREDRAW then
        w.noRedraw = wp == 0
        return 0
    elseif msg == WM.GETFONT then
        return w.font or 0
    elseif msg == WM.SETFONT then
        w.font = wp
        return 0
    end
    return 0
end

local defProcFar = user.luaProc("DefWindowProc", defwnd.proc)
user.defProcFar = defProcFar
user.defwnd = defwnd

api.def("USER", 107, "DefWindowProc", "h w w l:l", function(h, m, wp, lp) return defwnd.proc(h, m, wp, lp) end)

-- ---- painting APIs --------------------------------------------------------------------------------------------

local currentCursor = "arrow"
function user.setCursor(name)
    if name ~= currentCursor then
        currentCursor = name
        host.cursor(name)
    end
end

-- BeginPaint: erases if asked, fills the PAINTSTRUCT (hdc, fErase, rcPaint, ...)
function user.beginPaint(w, ps)
    if w.ncdirty then w.ncdirty = false; user.send(w, WM.NCPAINT, 1, 0) end
    local upd = w.upd or {}
    w.upd = nil
    -- without WS_CLIPCHILDREN the window paints over its children, so they
    -- are painted again after it
    if #upd > 0 and w.style & WS.CLIPCHILDREN == 0 then
        for _, c in ipairs(w.children) do
            if c.visible and not c.destroyed then
                local cr = {c.x, c.y, c.x + c.w, c.y + c.h}
                for _, r in ipairs(upd) do
                    local i = region.isect(r, cr)
                    if i then
                        user.invalidate(c, {i[1] - c.x - c.cl[1], i[2] - c.y - c.cl[2], i[3] - c.x - c.cl[1], i[4] - c.y - c.cl[2]}, true)
                        if c.cl[1] > 0 or c.cl[2] > 0 or c.cl[3] < c.w or c.cl[4] < c.h then c.ncdirty = true end
                    end
                end
            end
        end
    end
    local hdc = user.getDC(w, false, upd)
    local dc = gdi.dc(hdc)
    local erase = w.erase
    w.erase = false
    local b = region.bounds(upd)
    if erase and #upd > 0 then
        if w.iconic then user.send(w, WM.ICONERASEBKGND, hdc, 0)
        elseif user.send(w, WM.ERASEBKGND, hdc, 0) ~= 0 then erase = false end
    end
    if ps then
        ww(ps, hdc); ww(ps + 2, erase and 1 or 0)
        api.setrect(ps + 4, b)
        ww(ps + 12, 0); ww(ps + 14, 0)
    end
    user.dirty = true
    return hdc
end

function user.endPaint(w, hdc)
    local dc = gdi.dc(hdc)
    if dc then handles.free(hdc) end
end

api.def("USER", 39, "BeginPaint", "h p", function(hwnd, ps)
    local w = W(hwnd)
    if not w then return 0 end
    return user.beginPaint(w, ps)
end)
api.def("USER", 40, "EndPaint", "h p:v", function(hwnd, ps)
    local w = W(hwnd)
    if w and ps then user.endPaint(w, rw(ps)) end
end)
api.def("USER", 66, "GetDC", "h", function(hwnd)
    local w = hwnd == 0 and user.desktop or W(hwnd)
    if not w then return 0 end
    user.dirty = true
    return user.getDC(w, false)
end)
api.def("USER", 67, "GetWindowDC", "h", function(hwnd)
    local w = hwnd == 0 and user.desktop or W(hwnd)
    if not w then return 0 end
    user.dirty = true
    return user.getDC(w, true)
end)
api.def("USER", 68, "ReleaseDC", "h h", function(hwnd, hdc)
    local dc = gdi.dc(hdc)
    if dc and not dc.memory then handles.free(hdc); return 1 end
    return 0
end)

api.def("USER", 125, "InvalidateRect", "h p w:v", function(hwnd, prc, erase)
    if hwnd == 0 then user.damage({{0, 0, user.desktop.w, user.desktop.h}}); return end
    local w = W(hwnd)
    if not w then return end
    local r = prc and api.getrect(prc)
    user.invalidate(w, r, erase ~= 0)
end)
api.def("USER", 126, "InvalidateRgn", "h h w:v", function(hwnd, hrgn, erase)
    local w = W(hwnd)
    if not w then return end
    local rg = handles.get(hrgn, "rgn")
    if not rg then user.invalidate(w, nil, erase ~= 0); return end
    for _, r in ipairs(rg.rects) do user.invalidate(w, r, erase ~= 0) end
end)
api.def("USER", 127, "ValidateRect", "h p:v", function(hwnd, prc)
    local w = W(hwnd)
    if not w then return end
    if not prc then w.upd = nil; return end
    if w.upd then w.upd = region.subtract(w.upd, {api.getrect(prc)}) end
end)
api.def("USER", 124, "UpdateWindow", "h:v", function(hwnd)
    local w = W(hwnd)
    if not w or not user.isVisible(w) then return end
    if w.ncdirty then w.ncdirty = false; user.send(w, WM.NCPAINT, 1, 0) end
    if w.upd and #w.upd > 0 then
        user.send(w, WM.PAINT, 0, 0)
        if w.upd and #w.upd > 0 then w.upd = nil end
    end
end)
api.def("USER", 61, "ScrollWindow", "h i i p p:v", function(hwnd, dx, dy, prcScroll, prcClip)
    local w = W(hwnd)
    if not w then return end
    -- repaint rather than move pixels: simple, and the visible result is the same
    user.invalidate(w, nil, true)
    for _, c in ipairs(w.children) do
        c.x, c.y = c.x + dx, c.y + dy
    end
    user.damageWindow(w)
end)

return defwnd

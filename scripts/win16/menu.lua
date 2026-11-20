-- Menus: MENU resources, the menu bar in a window's frame, drop-down and
-- system menus, and the tracking loop (mouse and keyboard) in Windows 3.1's
-- look. Popups are overlays: drawn on top of the screen at each present
-- and taken away again, so the windows under them never need repainting.

local api = require("win16.api")
local cpu = require("recomp.cpu")
local gdi = require("win16.gdi")
local handles = require("win16.handles")
local region = require("win16.region")
local res = require("win16.resources")
local user = require("win16.user")

local def = api.def
local WM, WS, SC, COLOR = user.WM, user.WS, user.SC, user.COLOR
local C, MT = user.sysColors, user.metrics
local W = user.W

local MF_GRAYED, MF_DISABLED, MF_BITMAP, MF_CHECKED, MF_POPUP = 0x1, 0x2, 0x4, 0x8, 0x10
local MF_MENUBARBREAK, MF_MENUBREAK, MF_OWNERDRAW, MF_SEPARATOR, MF_BYPOSITION = 0x20, 0x40, 0x100, 0x800, 0x400
local MF_HELP, MF_SYSMENU, MF_MOUSESELECT = 0x4000, 0x2000, 0x8000
local MF_HILITE = 0x80

local menu = {}

local function M(h) return handles.get(h, "menu") end
menu.M = M

function menu.new(items) return handles.new({kind = "menu", items = items or {}}) end

-- ---- MENU resources --------------------------------------------------------------------------------

local function parse(data, at)
    local items = {}
    while at <= #data do
        local flags = string.unpack("<I2", data, at)
        at = at + 2
        local item = {flags = flags & ~0x80}
        if flags & MF_POPUP == 0 then
            item.id = string.unpack("<I2", data, at)
            at = at + 2
        end
        local z = data:find("\0", at, true) or (#data + 1)
        item.text = data:sub(at, z - 1)
        at = z + 1
        if flags & MF_POPUP ~= 0 then
            local sub
            sub, at = parse(data, at)
            item.popup = menu.new(sub)
        end
        if item.text == "" and flags & MF_POPUP == 0 and item.id == 0 then item.flags = item.flags | MF_SEPARATOR end
        items[#items + 1] = item
        if flags & 0x80 ~= 0 then break end
    end
    return items, at
end

function menu.fromResource(data)
    local offset = string.unpack("<I2", data, 3)
    local items = parse(data, 5 + offset)
    return menu.new(items)
end

function user.loadMenu(inst, name)
    local m = user.module
    local data = m and m:resource(4, name)
    if not data then return 0 end
    return menu.fromResource(data)
end

def("USER", 150, "LoadMenu", "h r", function(inst, name) return user.loadMenu(inst, name) end)

-- ---- system menus ------------------------------------------------------------------------------------

function menu.defaultSysMenu(mdiChild)
    local items = {
        {id = SC.RESTORE, text = "&Restore", flags = 0},
        {id = SC.MOVE, text = "&Move", flags = 0},
        {id = SC.SIZE, text = "&Size", flags = 0},
        {id = SC.MINIMIZE, text = "Mi&nimize", flags = 0},
        {id = SC.MAXIMIZE, text = "Ma&ximize", flags = 0},
        {id = 0, text = "", flags = MF_SEPARATOR},
    }
    if mdiChild then
        items[#items + 1] = {id = SC.CLOSE, text = "&Close\tCtrl+F4", flags = 0}
        items[#items + 1] = {id = 0, text = "", flags = MF_SEPARATOR}
        items[#items + 1] = {id = SC.NEXTWINDOW, text = "Nex&t\tCtrl+F6", flags = 0}
    else
        items[#items + 1] = {id = SC.CLOSE, text = "&Close\tAlt+F4", flags = 0}
        items[#items + 1] = {id = 0, text = "", flags = MF_SEPARATOR}
        items[#items + 1] = {id = SC.TASKLIST, text = "S&witch To...\tCtrl+Esc", flags = MF_GRAYED}
    end
    local h = menu.new(items)
    M(h).sys = true
    return h
end

function menu.sysMenuOf(w)
    if not w.sysMenu then w.sysMenu = menu.defaultSysMenu(w.style & WS.CHILD ~= 0) end
    return w.sysMenu
end

-- Greys the system menu's items to fit the window's state.
local function updateSysMenu(w, h)
    local m = M(h)
    for _, it in ipairs(m.items) do
        if not it.custom then
            local g = false
            if it.id == SC.RESTORE then g = not (w.iconic or w.zoomed)
            elseif it.id == SC.MOVE then g = w.zoomed
            elseif it.id == SC.SIZE then g = w.iconic or w.zoomed or w.style & WS.THICKFRAME == 0
            elseif it.id == SC.MINIMIZE then g = w.iconic or w.style & WS.MINIMIZEBOX == 0
            elseif it.id == SC.MAXIMIZE then g = w.zoomed or w.style & WS.MAXIMIZEBOX == 0 end
            if it.id ~= SC.TASKLIST and it.id ~= 0 then
                it.flags = g and (it.flags | MF_GRAYED) or (it.flags & ~MF_GRAYED)
            end
        end
    end
end

-- ---- API ----------------------------------------------------------------------------------------------------

local function findItem(h, pos, flags)
    local m = M(h)
    if not m then return nil end
    if flags & MF_BYPOSITION ~= 0 then return m, pos + 1, m.items[pos + 1] end
    for i, it in ipairs(m.items) do
        if it.id == pos and not it.popup then return m, i, it end
    end
    -- search submenus too, as Windows does for commands
    for _, it in ipairs(m.items) do
        if it.popup then
            local mm, i, found = findItem(it.popup, pos, flags)
            if found then return mm, i, found end
        end
    end
    return nil
end

local function changed(h)
    -- redraw any menu bar showing this menu
    for _, o in pairs(handles.all()) do
        if o.kind == "window" and (o.menu == h) then o.ncdirty = true; user.dirty = true end
    end
end

def("USER", 157, "GetMenu", "h", function(h) local w = W(h); return w and w.menu or 0 end)
def("USER", 158, "SetMenu", "h h", function(h, hm)
    local w = W(h)
    if not w then return 0 end
    w.menu = hm
    user.frameChanged(w)
    return 1
end)
def("USER", 160, "DrawMenuBar", "h:v", function(h)
    local w = W(h)
    if w then user.frameChanged(w); w.ncdirty = true; user.dirty = true end
end)
def("USER", 159, "GetSubMenu", "h i", function(h, i)
    local m = M(h)
    local it = m and m.items[i + 1]
    return it and it.popup or 0
end)
def("USER", 263, "GetMenuItemCount", "h", function(h) local m = M(h); return m and #m.items or 0xFFFF end)
def("USER", 264, "GetMenuItemID", "h i", function(h, i)
    local m = M(h)
    local it = m and m.items[i + 1]
    if not it then return 0xFFFF end
    if it.popup then return 0xFFFF end
    return it.id
end)
def("USER", 250, "GetMenuState", "h w w", function(h, pos, flags)
    local _, _, it = findItem(h, pos, flags)
    if not it then return 0xFFFF end
    if it.popup then return ((#M(it.popup).items) << 8) | (it.flags & 0xFF) | MF_POPUP end
    return it.flags
end)
def("USER", 161, "GetMenuString", "h w p i w", function(h, pos, buf, n, flags)
    local _, _, it = findItem(h, pos, flags)
    if not it then return 0 end
    return api.putstr(buf, it.text or "", n)
end)
def("USER", 154, "CheckMenuItem", "h w w", function(h, pos, flags)
    local _, _, it = findItem(h, pos, flags)
    if not it then return 0xFFFF end
    local old = it.flags & MF_CHECKED
    it.flags = (it.flags & ~MF_CHECKED) | (flags & MF_CHECKED)
    return old
end)
def("USER", 155, "EnableMenuItem", "h w w", function(h, pos, flags)
    local _, _, it = findItem(h, pos, flags)
    if not it then return 0xFFFF end
    local old = it.flags & 3
    it.flags = (it.flags & ~3) | (flags & 3)
    if it.id and M(h) and M(h).sys == nil then changed(h) end
    changed(h)
    return old
end)
def("USER", 156, "GetSystemMenu", "h w", function(h, revert)
    local w = W(h)
    if not w then return 0 end
    if revert ~= 0 then w.sysMenu = nil; return 0 end
    local s = menu.sysMenuOf(w)
    return s
end)
def("USER", 151, "CreateMenu", "", function() return menu.new() end)
def("USER", 415, "CreatePopupMenu", "", function() return menu.new() end)
def("USER", 152, "DestroyMenu", "h", function(h) if M(h) then handles.free(h) end return 1 end)

local function newItem(flags, id, fp)
    local it = {flags = flags & ~(MF_BYPOSITION | MF_POPUP), id = id}
    if flags & MF_POPUP ~= 0 then it.popup = id; it.flags = it.flags | MF_POPUP; it.id = nil end
    if flags & MF_SEPARATOR ~= 0 then it.text = ""
    elseif flags & (MF_BITMAP | MF_OWNERDRAW) ~= 0 then it.text = ""; it.data = fp
    else local l = cpu.flat(fp); it.text = l and mem.cstr(l) or "" end
    return it
end
menu.newItem = newItem

def("USER", 411, "AppendMenu", "h w w f", function(h, flags, id, fp)
    local m = M(h)
    if not m then return 0 end
    local it = newItem(flags, id, fp)
    it.custom = true
    m.items[#m.items + 1] = it
    changed(h)
    return 1
end)
def("USER", 410, "InsertMenu", "h w w w f", function(h, pos, flags, id, fp)
    local m = M(h)
    if not m then return 0 end
    local it = newItem(flags, id, fp)
    it.custom = true
    local at
    if flags & MF_BYPOSITION ~= 0 then at = pos + 1
    else local _, i = findItem(h, pos, 0); at = i end
    if not at or at > #m.items + 1 or pos == 0xFFFF then at = #m.items + 1 end
    table.insert(m.items, at, it)
    changed(h)
    return 1
end)
def("USER", 414, "ModifyMenu", "h w w w f", function(h, pos, flags, id, fp)
    local m, i = findItem(h, pos, flags)
    if not m then return 0 end
    m.items[i] = newItem(flags, id, fp)
    m.items[i].custom = true
    changed(h)
    return 1
end)
def("USER", 412, "RemoveMenu", "h w w", function(h, pos, flags)
    local m, i = findItem(h, pos, flags)
    if not m then return 0 end
    table.remove(m.items, i)
    changed(h)
    return 1
end)
def("USER", 413, "DeleteMenu", "h w w", function(h, pos, flags)
    local m, i, it = findItem(h, pos, flags)
    if not m then return 0 end
    table.remove(m.items, i)
    changed(h)
    return 1
end)

-- ---- drawing ------------------------------------------------------------------------------------------------

local function sysFont() return gdi.fontObj({font = gdi.stock(13)}) end

local function textParts(s)
    local left, right = s:match("^(.-)\t(.*)$")
    if not left then left, right = s:match("^(.-)\\a(.*)$") end
    return left or s, right or ""
end

local PAD = 8

-- Menu bar layout: {rows, items = {{x, y, w, h, index}}}, the bar's height
function menu.layoutBar(w, width)
    local m = M(w.menu)
    if not m then return {items = {}}, 0 end
    local f = sysFont()
    local x, y = 0, 0
    local row = MT.CYMENU
    local items = {}
    local list = {}
    -- an MDI child maximized in this frame lends its system-menu box and restore button
    local child = user.mdiMaxChild and user.mdiMaxChild(w)
    if child then list[#list + 1] = {sysbox = true} end
    for i, it in ipairs(m.items) do list[#list + 1] = {index = i, it = it} end
    for _, e in ipairs(list) do
        local iw
        if e.sysbox then iw = MT.CXSIZE + 2
        else
            local text = user.stripPrefix(e.it.text or "")
            iw = (f.rf and fb.text_width(f.rf.fid, text, false) or #text * 8) + 2 * PAD
        end
        if x + iw > width and x > 0 then x = 0; y = y + row end
        items[#items + 1] = {x = x, y = y, w = iw, h = row, index = e.index, sysbox = e.sysbox}
        x = x + iw
    end
    if child then
        items[#items + 1] = {x = width - (MT.CXSIZE + 1), y = 0, w = MT.CXSIZE + 1, h = row, restore = true}
    end
    return {items = items}, y + row + 1
end

function user.menuBarHeight(w, width)
    local _, h = menu.layoutBar(w, width)
    return h
end

local function drawItemText(f, x, y, text, color, ul)
    fb.text(0, f.rf.fid, x, y, text, color, 0, false, false, false)
    if ul then
        local ux = x + fb.text_width(f.rf.fid, text:sub(1, ul - 1), false)
        local uw = fb.text_width(f.rf.fid, text:sub(ul, ul), false)
        fb.patblt(0, ux, y + f.rf.m.ascent + 1, uw, 1, 0xF0, color)
    end
end

function user.paintMenuBar(w, x0, y0)
    local b = user.borderOf(w)
    local bx, by = x0 + b, y0 + w.menuTop
    local width = w.w - 2 * b
    local lay = menu.layoutBar(w, width)
    local m = M(w.menu)
    local f = sysFont()
    fb.patblt(0, bx, by, width, w.menuH - 1, 0xF0, C[COLOR.MENU])
    fb.patblt(0, bx, by + w.menuH - 1, width, 1, 0xF0, C[COLOR.WINDOWFRAME])
    local sel = menu.tracking and menu.tracking.owner == w and menu.tracking.barSel
    for li, e in ipairs(lay.items) do
        local x, y = bx + e.x, by + e.y
        if e.sysbox then
            local img = res.obm(32754)
            if img then
                local half = img.w // 2
                fb.bitblt(0, x + 1, y, half, math.min(img.h, e.h), img.surface, half, 0, 0xCC, 0, 0, 0xFFFFFF)
            end
            if sel == li then fb.patblt(0, x + 1, y, e.w - 2, e.h, 0x55, 0) end
        elseif e.restore then
            local img = res.obm(32747)
            if img then fb.bitblt(0, x, y, img.w, math.min(img.h, e.h), img.surface, 0, 0, 0xCC, 0, 0, 0xFFFFFF) end
        else
            local it = m.items[e.index]
            local text, ul = user.stripPrefix(it.text or "")
            local hot = sel == li
            if hot then fb.patblt(0, x, y, e.w, e.h, 0xF0, C[COLOR.HIGHLIGHT]) end
            local color = (it.flags & MF_GRAYED ~= 0) and C[COLOR.GRAYTEXT] or (hot and C[COLOR.HIGHLIGHTTEXT] or C[COLOR.MENUTEXT])
            if f.rf then drawItemText(f, x + PAD, y + (e.h - f.rf.m.height) // 2, text, color, ul) end
        end
    end
end

-- Popup layout: width, height, and each item's y and height.
local ITEM_LEFT, ITEM_RIGHT = 15, 15
local function layoutPopup(h)
    local m = M(h)
    local f = sysFont()
    local fh = f.rf and f.rf.m.height or 16
    local lw, rw2 = 0, 0
    local rows = {}
    local y = 1
    for i, it in ipairs(m.items) do
        local ih
        if it.flags & MF_SEPARATOR ~= 0 then ih = 8
        else
            ih = fh + 1
            local l, r = textParts(it.text or "")
            l = user.stripPrefix(l)
            if f.rf then
                lw = math.max(lw, fb.text_width(f.rf.fid, l, false))
                if r ~= "" then rw2 = math.max(rw2, fb.text_width(f.rf.fid, r, false)) end
            end
        end
        rows[i] = {y = y, h = ih}
        y = y + ih
    end
    local width = ITEM_LEFT + lw + (rw2 > 0 and (rw2 + 16) or 0) + ITEM_RIGHT + 2
    return {w = math.max(width, 40), h = y + 1, rows = rows, rightW = rw2, fh = fh}
end

local function drawPopup(level)
    local m = M(level.menu)
    local lay = level.layout
    local f = sysFont()
    local x, y = level.x, level.y
    fb.clip(nil)
    fb.patblt(0, x, y, lay.w, lay.h, 0xF0, C[COLOR.MENU])
    -- black frame with the 3.1 drop shadow on the right and bottom
    fb.patblt(0, x, y, lay.w, 1, 0xF0, 0); fb.patblt(0, x, y + lay.h - 1, lay.w, 1, 0xF0, 0)
    fb.patblt(0, x, y, 1, lay.h, 0xF0, 0); fb.patblt(0, x + lay.w - 1, y, 1, lay.h, 0xF0, 0)
    fb.patblt(0, x + lay.w, y + 2, 2, lay.h, 0xF0, 0x808080)
    fb.patblt(0, x + 2, y + lay.h, lay.w, 2, 0xF0, 0x808080)
    for i, it in ipairs(m.items) do
        local r = lay.rows[i]
        local iy = y + r.y
        if it.flags & MF_SEPARATOR ~= 0 then
            fb.patblt(0, x + 1, iy + 3, lay.w - 2, 1, 0xF0, 0)
        else
            local hot = level.sel == i
            if hot then fb.patblt(0, x + 1, iy, lay.w - 2, r.h, 0xF0, C[COLOR.HIGHLIGHT]) end
            local grayed = it.flags & MF_GRAYED ~= 0
            local color = grayed and C[COLOR.GRAYTEXT] or (hot and C[COLOR.HIGHLIGHTTEXT] or C[COLOR.MENUTEXT])
            if it.flags & MF_CHECKED ~= 0 then
                local chk = res.obm(32760)
                if chk then
                    fb.bitblt(0, x + 2, iy + (r.h - chk.h) // 2, chk.w, chk.h, chk.surface, 0, 0, hot and 0x33 or 0x88, 0, 0, 0xFFFFFF)
                end
            end
            local l, rt = textParts(it.text or "")
            local text, ul = user.stripPrefix(l)
            if f.rf then
                local ty = iy + (r.h - f.rf.m.height) // 2
                drawItemText(f, x + ITEM_LEFT, ty, text, color, ul)
                if rt ~= "" then
                    fb.text(0, f.rf.fid, x + lay.w - ITEM_RIGHT - lay.rightW, ty, rt, color, 0, false, false, false)
                end
            end
            if it.popup then
                local arrow = res.obm(32739)
                if arrow then
                    fb.bitblt(0, x + lay.w - arrow.w - 4, iy + (r.h - arrow.h) // 2, arrow.w, arrow.h, arrow.surface, 0, 0,
                        hot and 0x33 or 0x88, 0, 0, 0xFFFFFF)
                end
            end
        end
    end
end

-- Overlays: drawn over the screen for each present, then taken away.
user.overlays = {}
local basePresent = user.present
function user.present()
    if #user.overlays == 0 then return basePresent() end
    local saved = {}
    fb.clip(nil)
    local sw, sh = fb.size(0)
    for _, o in ipairs(user.overlays) do
        local x, y, ow, oh = o.x, o.y, o.w + 2, o.h + 2
        local s = fb.new(ow, oh)
        fb.bitblt(s, 0, 0, ow, oh, 0, x, y, 0xCC, 0, 0, 0)
        saved[#saved + 1] = {s = s, x = x, y = y, w = ow, h = oh}
        o.draw()
    end
    fb.clip(nil)
    host.present()
    user.dirty = false
    for i = #saved, 1, -1 do
        local s = saved[i]
        fb.clip(nil)
        fb.bitblt(0, s.x, s.y, s.w, s.h, s.s, 0, 0, 0xCC, 0, 0, 0)
        fb.free(s.s)
    end
end

-- ---- tracking -----------------------------------------------------------------------------------------------
-- t = {owner (the window that gets the commands), bar (hmenu) or nil,
--      barLayout, barSel (index into the layout), levels = {{menu, x, y, layout, sel}}}

local function sendSelect(t, level)
    local owner = t.owner
    if not level then
        user.send(owner, WM.MENUSELECT, 0, api.mklong(0xFFFF, 0))
        return
    end
    local m = M(level.menu)
    local it = level.sel and m.items[level.sel]
    if not it then return end
    local flags = it.flags | MF_HILITE | (t.mouse and MF_MOUSESELECT or 0) | (m.sys and MF_SYSMENU or 0)
    if it.popup then user.send(owner, WM.MENUSELECT, it.popup, api.mklong(flags | MF_POPUP, level.menu))
    else user.send(owner, WM.MENUSELECT, it.id, api.mklong(flags, level.menu)) end
end

local function closeLevels(t, from)
    for i = #t.levels, from, -1 do
        local l = t.levels[i]
        for k, o in ipairs(user.overlays) do if o == l.overlay then table.remove(user.overlays, k); break end end
        t.levels[i] = nil
    end
    user.dirty = true
end

local function openPopup(t, h, x, y, index, isSys)
    local m = M(h)
    if not m then return end
    user.send(t.owner, WM.INITMENUPOPUP, h, api.mklong(index or 0, isSys and 1 or 0))
    local lay = layoutPopup(h)
    local sw, sh = user.desktop.w, user.desktop.h
    if x + lay.w > sw then x = math.max(0, sw - lay.w - 2) end
    if y + lay.h > sh then y = math.max(0, sh - lay.h - 2) end
    local level = {menu = h, x = x, y = y, layout = lay, sel = nil}
    level.overlay = {x = x, y = y, w = lay.w + 2, h = lay.h + 2, draw = function() drawPopup(level) end}
    user.overlays[#user.overlays + 1] = level.overlay
    t.levels[#t.levels + 1] = level
    user.dirty = true
    return level
end

-- Screen rect of a menu-bar layout entry
local function barItemRect(t, li)
    local w = t.owner
    local x0, y0 = user.screenPos(w)
    local e = t.barLayout.items[li]
    local b = user.borderOf(w)
    return {x0 + b + e.x, y0 + w.menuTop + e.y, x0 + b + e.x + e.w, y0 + w.menuTop + e.y + e.h}, e
end

local function redrawBar(t)
    if t.bar then
        t.owner.ncdirty = true
        user.dirty = true
        require("win16.defwnd").paintNC(t.owner)
        t.owner.ncdirty = false
    end
end

-- Selects a menu-bar entry and opens its popup (open = false: just highlight).
local function selectBar(t, li, open)
    if t.barSel == li and (not open or #t.levels > 0) then return end
    closeLevels(t, 1)
    t.barSel = li
    redrawBar(t)
    if not li then return end
    local r, e = barItemRect(t, li)
    if e.sysbox then
        local child = user.mdiMaxChild(t.owner)
        if child then
            local sys = menu.sysMenuOf(child)
            updateSysMenu(child, sys)
            t.sysTarget = child
            local fake = {menu = nil}
            user.send(t.owner, WM.MENUSELECT, sys, api.mklong(MF_POPUP | MF_SYSMENU | MF_HILITE, sys))
            if open then openPopup(t, sys, r[1], r[4], 0, true) end
        end
        return
    end
    t.sysTarget = nil
    if e.restore then return end
    local m = M(t.bar)
    local it = m.items[e.index]
    if it.popup then
        user.send(t.owner, WM.MENUSELECT, it.popup, api.mklong(it.flags | MF_POPUP | MF_HILITE, t.bar))
        if open and it.flags & MF_GRAYED == 0 then openPopup(t, it.popup, r[1], r[4], e.index - 1, false) end
    else
        user.send(t.owner, WM.MENUSELECT, it.id, api.mklong(it.flags | MF_HILITE, t.bar))
    end
end

local function barIndexAt(t, x, y)
    if not t.bar then return nil end
    for li = 1, #t.barLayout.items do
        local r = barItemRect(t, li)
        if x >= r[1] and x < r[3] and y >= r[2] and y < r[4] then return li end
    end
end

local function levelAt(t, x, y)
    for i = #t.levels, 1, -1 do
        local l = t.levels[i]
        if x >= l.x and x < l.x + l.layout.w and y >= l.y and y < l.y + l.layout.h then
            for k, r in ipairs(l.layout.rows) do
                if y >= l.y + r.y and y < l.y + r.y + r.h then return i, k end
            end
            return i, nil
        end
    end
end

local function selectItem(t, li, k)
    local level = t.levels[li]
    if level.sel == k then return end
    closeLevels(t, li + 1)
    level.sel = k
    user.dirty = true
    sendSelect(t, level)
end

-- Opens the submenu of the selected item of a level, if it has one.
local function openSub(t, li)
    local level = t.levels[li]
    local m = M(level.menu)
    local it = level.sel and m.items[level.sel]
    if it and it.popup and it.flags & MF_GRAYED == 0 and #t.levels == li then
        local r = level.layout.rows[level.sel]
        openPopup(t, it.popup, level.x + level.layout.w - 4, level.y + r.y, level.sel - 1, false)
        return true
    end
end

-- Chooses the selected item of a level: returns the command, or nil.
local function choose(t, li)
    local level = t.levels[li]
    local m = M(level.menu)
    local it = level.sel and m.items[level.sel]
    if not it or it.flags & (MF_GRAYED | MF_DISABLED | MF_SEPARATOR) ~= 0 then return nil end
    if it.popup then openSub(t, li); return nil end
    return {id = it.id, sys = m.sys}
end

local function moveSel(level, dir)
    local m = M(level.menu)
    local n = #m.items
    if n == 0 then return nil end
    local i = level.sel or (dir > 0 and 0 or n + 1)
    for _ = 1, n do
        i = ((i - 1 + dir) % n) + 1
        if m.items[i].flags & MF_SEPARATOR == 0 then return i end
    end
end

-- The main loop. start: {mouse = true} or {key = true, char = n}
local function track(t, start)
    menu.tracking = t
    t.levels = {}
    if t.bar then t.barLayout = menu.layoutBar(t.owner, t.owner.w - 2 * user.borderOf(t.owner)) end
    user.send(t.owner, WM.INITMENU, t.bar or t.popupRoot or 0, 0)
    local result
    local mouseDown = start.mouse and user.buttons[1]
    local downAt = host.ticks()
    if start.popup then
        local l = openPopup(t, t.popupRoot, start.x, start.y, 0, t.popupSys)
        if start.key and l then l.sel = moveSel(l, 1); sendSelect(t, l) end
    elseif start.mouse then
        local li = barIndexAt(t, user.mouseX, user.mouseY)
        selectBar(t, li or 1, true)
    elseif start.key then
        local li = 1
        if start.char and start.char ~= 0 then
            li = nil
            for k, e in ipairs(t.barLayout.items) do
                if e.index then
                    local it = M(t.bar).items[e.index]
                    local _, ul = user.stripPrefix(it.text or "")
                    local text = user.stripPrefix(it.text or "")
                    if ul and text:sub(ul, ul):upper() == string.char(start.char):upper() then li = k; break end
                end
            end
            if not li then menu.tracking = nil; user.send(t.owner, WM.MENUSELECT, 0, api.mklong(0xFFFF, 0)); return nil end
        end
        selectBar(t, li, start.char and start.char ~= 0)
        if t.levels[1] then
            t.levels[1].sel = moveSel(t.levels[1], 1)
            sendSelect(t, t.levels[1])
        end
    end
    user.present()
    while true do
        local ev = user.waitInput()
        t.mouse = ev.kind == "move" or ev.kind == "down" or ev.kind == "up"
        if ev.kind == "close" then
            table.insert(user.input, 1, ev)
            break
        elseif ev.kind == "move" or ev.kind == "down" or ev.kind == "up" then
            local x, y = ev.e[2], ev.e[3]
            user.mouseX, user.mouseY = x, y
            if ev.kind == "down" then user.buttons[ev.e[4]] = true end
            if ev.kind == "up" then user.buttons[ev.e[4]] = false end
            local li, k = levelAt(t, x, y)
            local bi = barIndexAt(t, x, y)
            if li then
                if k then
                    selectItem(t, li, k)
                    if ev.kind == "up" then
                        result = choose(t, li)
                        if result then break end
                    end
                end
            elseif bi then
                if ev.kind == "down" and bi == t.barSel and #t.levels > 0 and not mouseDown then
                    break   -- a second click on the open entry closes the menu
                end
                if user.buttons[1] or #t.levels > 0 or ev.kind == "down" then selectBar(t, bi, true) end
                if ev.kind == "up" then
                    local _, e = barItemRect(t, bi)
                    if e.restore then
                        result = {id = SC.RESTORE, sys = true, target = user.mdiMaxChild(t.owner)}
                        break
                    end
                    local it = e.index and M(t.bar).items[e.index]
                    if it and not it.popup and it.flags & MF_GRAYED == 0 then result = {id = it.id}; break end
                end
            else
                if ev.kind == "down" then break end
                if ev.kind == "up" and host.ticks() - downAt > 300 and mouseDown then break end
                -- off every menu: the deepest popup keeps its selection off
                if #t.levels > 0 then
                    local top = t.levels[#t.levels]
                    if top.sel and not M(top.menu).items[top.sel].popup then
                        top.sel = nil
                        user.dirty = true
                    end
                end
            end
            if ev.kind == "up" then mouseDown = false end
        elseif ev.kind == "key" and ev.e[3] == 1 then
            local vk = ev.e[2]
            user.keys[vk] = true
            local top = t.levels[#t.levels]
            if vk == 0x1B then        -- Esc: one level back
                if #t.levels > 1 or (#t.levels == 1 and not t.bar) then
                    closeLevels(t, #t.levels)
                    if #t.levels == 0 then break end
                elseif #t.levels == 1 then
                    closeLevels(t, 1)
                else
                    break
                end
            elseif vk == 0x12 or vk == 0x79 then  -- Alt / F10 again: out
                break
            elseif vk == 0x26 or vk == 0x28 then  -- up/down
                if top then
                    top.sel = moveSel(top, vk == 0x28 and 1 or -1)
                    closeLevels(t, #t.levels + 1)
                    sendSelect(t, top)
                    user.dirty = true
                elseif t.barSel then
                    selectBar(t, t.barSel, true)
                    if t.levels[1] then t.levels[1].sel = moveSel(t.levels[1], 1); sendSelect(t, t.levels[1]) end
                end
            elseif vk == 0x25 or vk == 0x27 then  -- left/right
                if vk == 0x27 and top and openSub(t, #t.levels) then
                    local sub = t.levels[#t.levels]
                    sub.sel = moveSel(sub, 1)
                    sendSelect(t, sub)
                elseif vk == 0x25 and #t.levels > 1 then
                    closeLevels(t, #t.levels)
                elseif t.bar then
                    local n = #t.barLayout.items
                    local li = t.barSel or 1
                    repeat
                        li = ((li - 1 + (vk == 0x27 and 1 or -1)) % n) + 1
                    until not t.barLayout.items[li].restore
                    local wasOpen = #t.levels > 0
                    selectBar(t, li, wasOpen)
                    if t.levels[1] then t.levels[1].sel = moveSel(t.levels[1], 1); sendSelect(t, t.levels[1]) end
                end
            elseif vk == 0x0D then
                if top then
                    result = choose(t, #t.levels)
                    if result then break end
                    local sub = t.levels[#t.levels]
                    if sub ~= top and sub then sub.sel = moveSel(sub, 1); sendSelect(t, sub) end
                elseif t.barSel then
                    local _, e = barItemRect(t, t.barSel)
                    local it = e.index and M(t.bar).items[e.index]
                    if it and not it.popup then result = {id = it.id}; break end
                    selectBar(t, t.barSel, true)
                    if t.levels[1] then t.levels[1].sel = moveSel(t.levels[1], 1); sendSelect(t, t.levels[1]) end
                end
            end
        elseif ev.kind == "key" and ev.e[3] == 0 then
            user.keys[ev.e[2]] = nil
        elseif ev.kind == "char" then
            local c = string.char(ev.e[2]):upper()
            local top = t.levels[#t.levels]
            local m = top and M(top.menu)
            local hit
            if m then
                for i, it in ipairs(m.items) do
                    local text, ul = user.stripPrefix(it.text or "")
                    if ul and text:sub(ul, ul):upper() == c and it.flags & MF_SEPARATOR == 0 then hit = i; break end
                end
                if hit then
                    top.sel = hit
                    sendSelect(t, top)
                    result = choose(t, #t.levels)
                    if result then break end
                    local sub = t.levels[#t.levels]
                    if sub ~= top then sub.sel = moveSel(sub, 1); sendSelect(t, sub) end
                end
            elseif t.bar then
                for k, e in ipairs(t.barLayout.items) do
                    if e.index then
                        local it = M(t.bar).items[e.index]
                        local text, ul = user.stripPrefix(it.text or "")
                        if ul and text:sub(ul, ul):upper() == c then
                            selectBar(t, k, true)
                            if t.levels[1] then t.levels[1].sel = moveSel(t.levels[1], 1); sendSelect(t, t.levels[1]) end
                            break
                        end
                    end
                end
            end
        end
        user.present()
    end
    closeLevels(t, 1)
    local sysTarget = t.sysTarget
    t.barSel = nil
    menu.tracking = nil
    redrawBar(t)
    user.send(t.owner, WM.MENUSELECT, 0, api.mklong(0xFFFF, 0))
    user.buttons[1] = false
    user.present()
    if result and result.sys and not result.target then result.target = sysTarget or t.sysWindow end
    return result
end

local function deliver(t, result)
    if not result then return end
    if result.sys then
        local target = result.target or t.owner
        user.post(target, WM.SYSCOMMAND, result.id, api.mkpt(user.mouseX, user.mouseY))
    else
        user.post(t.owner, WM.COMMAND, result.id, 0)
    end
end

-- Mouse press on a window's menu bar.
function user.trackMenuBar(w, lp)
    if not w.menu or w.menu == 0 then return end
    local t = {owner = w, bar = w.menu}
    deliver(t, track(t, {mouse = true}))
end

-- Alt, F10 or Alt+letter: the keyboard menu (char 0x20 = system menu).
function user.keyMenu(w, char)
    if w.style & WS.CHILD ~= 0 then
        -- an MDI child's system menu (Alt+-)
        if char == 0x2D then user.trackSysMenu(w, true) end
        return
    end
    if char == 0x20 then
        if user.appMode and w == user.frame then return end
        user.trackSysMenu(w, true)
        return
    end
    if char == 0x2D then
        local c = user.mdiMaxChild and user.mdiMaxChild(w) or (user.mdiActiveChild and user.mdiActiveChild(w))
        if c then user.trackSysMenu(c, true) end
        return
    end
    if not w.menu or w.menu == 0 then return end
    local t = {owner = w, bar = w.menu}
    deliver(t, track(t, {key = true, char = char}))
end

-- A window's system menu, below its system-menu box (or above its icon).
function user.trackSysMenu(w, byKey)
    local sys = menu.sysMenuOf(w)
    updateSysMenu(w, sys)
    local x, y = user.screenPos(w)
    local px, py
    if w.iconic then
        local lay = layoutPopup(sys)
        px, py = x, y - lay.h
        if py < 0 then py = y + w.h end
    else
        local b = user.borderOf(w)
        px, py = x + b, y + b + MT.CYCAPTION - 1
    end
    local owner = w
    local t = {owner = owner, popupRoot = sys, popupSys = true, sysWindow = w}
    local r = track(t, {popup = true, x = px, y = py, key = byKey})
    if r then r.sys = true; r.target = w end
    deliver(t, r)
end

-- TrackPopupMenu(hmenu, flags, x, y, reserved, hwnd, lprc)
def("USER", 416, "TrackPopupMenu", "h w i i i h p", function(h, flags, x, y, _, hwnd)
    local w = W(hwnd)
    if not w or not M(h) then return 0 end
    local t = {owner = w, popupRoot = h}
    local lay = layoutPopup(h)
    if flags & 4 ~= 0 then x = x - lay.w // 2 elseif flags & 8 ~= 0 then x = x - lay.w end
    deliver(t, track(t, {popup = true, x = x, y = y, mouse = true}))
    return 1
end)

user.menu = menu
return menu

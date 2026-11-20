-- Right-click menus for Program Manager (Windows 3.1 had none; these are
-- in the manner of Windows 95). A right click on an item selects it and
-- offers Open, Move, Copy, Delete and Properties; on a group's empty space,
-- New and Arrange Icons. Every entry is one of Program Manager's own menu
-- commands, so the program does the work.

local user = require("win16.user")
local gdi = require("win16.gdi")
local menu = require("win16.menu")
local api = require("win16.api")

local WM = user.WM
local MF_GRAYED, MF_DISABLED, MF_SEPARATOR = 0x1, 0x2, 0x800

local pm = {}

-- Where icons were drawn, per window (screen coordinates), so a click can
-- be told to be on an item without knowing Program Manager's data.
local spots = {}
-- (Program Manager blits its icons from an offscreen cache.)
function gdi.onImage(dc, x, y, w, h)
    local list = dc.hwnd and dc.surface == 0 and spots[dc.hwnd]
    if list and w == 32 and h == 32 then list[#list + 1] = {x = x + dc.ox, y = y + dc.oy} end
end

local function plain(text) return ((text or ""):gsub("&", ""):gsub("\t.*", "")) end

-- The frame's menu item whose text starts with one of the names.
local function find(items, ...)
    for _, it in ipairs(items or {}) do
        local t = plain(it.text):lower()
        for _, name in ipairs({...}) do
            if t:sub(1, #name) == name then return it end
        end
    end
end

local function submenu(frame, name)
    local bar = menu.M(frame.menu)
    local it = bar and find(bar.items, name)
    return it and it.popup, it and menu.M(it.popup)
end

local function groupOf(w)
    while w do
        local p = w.parent
        if p and p.class and p.class.mdiClient then return w end
        w = p
    end
end

-- Repaint the group now so its icon positions are current.
local function itemAt(g, sx, sy)
    spots[g.handle] = {}
    user.invalidate(g, nil, true)
    user.send(g, WM.PAINT, 0, 0)
    local list = spots[g.handle]
    spots[g.handle] = nil
    for _, s in ipairs(list) do
        -- the icon, or its title below it
        if (sx >= s.x and sx < s.x + 32 and sy >= s.y and sy < s.y + 32) or
            (sx >= s.x - 24 and sx < s.x + 56 and sy >= s.y + 32 and sy < s.y + 32 + 36) then
            return s
        end
    end
end

function pm.contextMenu(w, sx, sy)
    local g = groupOf(w)
    local frame = user.frame
    if not g or g.iconic or not frame or not frame.menu or frame.menu == 0 then return end
    local hit = itemAt(g, sx, sy)
    local ox, oy = user.clientOrigin(g)
    if hit then
        -- select the item the way a left click does
        local lp = api.mkpt(hit.x + 16 - ox, hit.y + 16 - oy)
        user.send(g, WM.LBUTTONDOWN, 1, lp)
        user.send(g, WM.LBUTTONUP, 0, lp)
    end
    local fileH, file = submenu(frame, "file")
    local winH, win = submenu(frame, "window")
    if not file then return end
    -- let Program Manager enable or gray its commands for the selection
    user.send(frame, WM.INITMENU, frame.menu, 0)
    user.send(frame, WM.INITMENUPOPUP, fileH, 0)
    if winH then user.send(frame, WM.INITMENUPOPUP, winH, 2) end
    local items = {}
    local function add(it, text)
        if not it then return end
        items[#items + 1] = {id = it.id, text = text or it.text, flags = it.flags & (MF_GRAYED | MF_DISABLED)}
    end
    local function sep() items[#items + 1] = {id = 0, text = "", flags = MF_SEPARATOR} end
    if hit then
        add(find(file.items, "open"))
        sep()
        add(find(file.items, "move"))
        add(find(file.items, "copy"))
        add(find(file.items, "delete"))
        sep()
        add(find(file.items, "properties"))
    else
        add(find(file.items, "new"))
        if win then add(find(win.items, "arrange")) end
    end
    if #items == 0 then return end
    local h = menu.new(items)
    menu.popup(h, frame, sx, sy)
end

function pm.init()
    user.contextMenu = pm.contextMenu
end

return pm

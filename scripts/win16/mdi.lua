-- MDI: the MDICLIENT class, DefFrameProc, DefMDIChildProc and
-- TranslateMDISysAccel. Program Manager's groups are MDI children.
-- A maximized child fills the client with its frame outside it, and lends
-- its system-menu box and restore button to the frame's menu bar; the frame's
-- caption gets " - [child]" (shown in the host window's title).

local api = require("win16.api")
local cpu = require("recomp.cpu")
local handles = require("win16.handles")
local region = require("win16.region")
local user = require("win16.user")

local def = api.def
local WM, WS, SC, HT, COLOR = user.WM, user.WS, user.SC, user.HT, user.COLOR
local C, MT = user.sysColors, user.metrics
local W = user.W
local rw, rd = mem.rw, mem.rd
local s16 = api.s16
local menu = user.menu

local WS_EX_MDICHILD = 0x40

local function isMdiChild(w)
    return w and w.style & WS.CHILD ~= 0 and w.parent and w.parent.class and w.parent.class.mdiClient
end
user.isMdiChild = isMdiChild

local function clientOf(w) return isMdiChild(w) and w.parent end

local function frameOf(client)
    local f = client.parent
    return f ~= user.desktop and f or nil
end

-- the children in creation order (their ids)
local function kids(client)
    local out = {}
    for _, c in ipairs(client.mdi.order) do
        if not c.destroyed then out[#out + 1] = c end
    end
    client.mdi.order = out
    return out
end

-- ---- the Window menu --------------------------------------------------------------------------------------

local function windowMenuItems(client)
    local m = client.mdi.windowMenu and menu.M(client.mdi.windowMenu)
    if not m then return end
    -- remove what we added before
    for i = #m.items, 1, -1 do
        if m.items[i].mdi then table.remove(m.items, i) end
    end
    local list = kids(client)
    local visible = {}
    for _, c in ipairs(list) do if c.visible then visible[#visible + 1] = c end end
    if #visible == 0 then return end
    m.items[#m.items + 1] = {flags = 0x800, text = "", id = 0, mdi = true}
    for i, c in ipairs(visible) do
        if i > 9 then
            m.items[#m.items + 1] = {flags = 0, text = "&More Windows...", id = client.mdi.firstId + 9, mdi = true}
            break
        end
        c.id = client.mdi.firstId + i - 1
        m.items[#m.items + 1] = {flags = c == client.mdiActive and 0x8 or 0, text = "&" .. i .. " " .. c.text,
                                 id = c.id, mdi = true}
    end
end

local function refreshFrameMenu(client)
    local f = frameOf(client)
    if f then user.frameChanged(f); f.ncdirty = true; user.dirty = true end
end

-- The frame's caption with the maximized child's title.
local function updateFrameTitle(client)
    local f = frameOf(client)
    if not f then return end
    f.baseText = f.baseText or f.text
    local mx = client.mdi.maximized
    local text = f.baseText
    if mx and not mx.destroyed and mx.text ~= "" then text = f.baseText .. " - [" .. mx.text .. "]" end
    if f.text ~= text then
        f.text = text
        f.ncdirty = true
        user.dirty = true
        if user.appMode and f == user.frame then host.title(text) end
    end
end

-- ---- activation --------------------------------------------------------------------------------------------

function user.mdiActivate(w)
    local client = clientOf(w)
    if not client then return end
    local old = client.mdiActive
    if old == w then
        if not user.focus or not user.isDescendant(user.focus, w) then user.setFocus(w) end
        return
    end
    -- with one child maximized, the next one is too
    if client.mdi.maximized and client.mdi.maximized ~= w and old then
        local mx = client.mdi.maximized
        client.mdi.maximized = nil
        user.mdiRestoreNow(mx, true)
        client.mdiActive = w
        user.mdiMaximizeNow(w)
    end
    client.mdiActive = w
    user.linkZ(w)
    if old and not old.destroyed then
        old.ncdirty = true
        user.send(old, WM.NCACTIVATE, 0, 0)
        user.send(old, WM.MDIACTIVATE, 0, api.mklong(w.handle, old.handle))
    end
    w.ncdirty = true
    user.damageWindow(w)
    user.send(w, WM.NCACTIVATE, 1, 0)
    user.send(w, WM.MDIACTIVATE, 1, api.mklong(w.handle, old and old.handle or 0))
    if user.active == user.topLevel(w) then user.setFocus(w) end
    windowMenuItems(client)
    user.dirty = true
end

function user.mdiActiveChild(frame)
    for _, c in ipairs(frame.children) do
        if c.class.mdiClient then return c.mdiActive end
    end
end

function user.mdiMaxChild(frame)
    for _, c in ipairs(frame.children) do
        if c.class and c.class.mdiClient and c.mdi.maximized and not c.mdi.maximized.destroyed then
            return c.mdi.maximized
        end
    end
end

-- ---- maximize / restore / minimize ------------------------------------------------------------------------------

function user.mdiMaximizeNow(w)
    local client = clientOf(w)
    if not w.iconic then w.normal = {w.x, w.y, w.w, w.h} end
    w.iconic, w.zoomed = false, true
    w.visible = true
    w.style = (w.style | WS.MAXIMIZE) & ~WS.MINIMIZE
    client.mdi.maximized = w
    local x, y, cw, ch = user.maxRect(w)
    user.setPos(w, x, y, cw, ch, {frame = true})
    user.linkZ(w)
    refreshFrameMenu(client)
    updateFrameTitle(client)
    user.damageWindow(client)
end

function user.mdiRestoreNow(w, keepOthers)
    local client = clientOf(w)
    local n = w.normal or {w.x, w.y, w.w, w.h}
    w.iconic, w.zoomed = false, false
    w.style = w.style & ~(WS.MINIMIZE | WS.MAXIMIZE)
    if client.mdi.maximized == w then client.mdi.maximized = nil end
    user.setPos(w, n[1], n[2], n[3], n[4], {frame = true})
    w.ncdirty = true
    refreshFrameMenu(client)
    updateFrameTitle(client)
    user.damageWindow(client)
end

function user.mdiMaximize(w)
    if not isMdiChild(w) then return false end
    local client = clientOf(w)
    local mx = client.mdi.maximized
    if mx and mx ~= w then mx.zoomed = false; client.mdi.maximized = nil; user.mdiRestoreNow(mx, true) end
    user.mdiMaximizeNow(w)
    user.mdiActivate(w)
    return true
end

function user.mdiRestore(w)
    if not isMdiChild(w) then return false end
    local client = clientOf(w)
    if w.iconic and client.mdi.maximized and client.mdi.maximized ~= w then
        -- restoring an icon while another child is maximized: this one maximizes
        local mx = client.mdi.maximized
        client.mdi.maximized = nil
        user.mdiRestoreNow(mx, true)
        w.iconic = false
        user.mdiMaximizeNow(w)
        user.mdiActivate(w)
        return true
    end
    user.mdiRestoreNow(w)
    user.mdiActivate(w)
    return true
end

function user.mdiMinimize(w)
    if not isMdiChild(w) then return false end
    local client = clientOf(w)
    if client.mdi.maximized == w then
        client.mdi.maximized = nil
        refreshFrameMenu(client)
    else
        w.normal = {w.x, w.y, w.w, w.h}
    end
    w.iconic, w.zoomed = true, false
    w.style = (w.style | WS.MINIMIZE) & ~WS.MAXIMIZE
    local ix, iy = user.iconSlot(w)
    user.setPos(w, ix, iy, MT.CXICONSPACING, user.iconHeight(), {frame = true})
    w.ncdirty = true
    updateFrameTitle(client)
    user.damageWindow(client)
    -- the next non-minimized child becomes active; an icon stays active otherwise
    user.mdiActivate(w)
    return true
end

-- ---- arranging ----------------------------------------------------------------------------------------------

local function clientSize(client) return client.cl[3] - client.cl[1], client.cl[4] - client.cl[2] end

local function arrangeIcons(client)
    local cw, ch = clientSize(client)
    local sx, sy = MT.CXICONSPACING, MT.CYICONSPACING
    local cols = math.max(cw // sx, 1)
    local i = 0
    for _, c in ipairs(kids(client)) do
        if c.iconic and c.visible then
            local col, row = i % cols, i // cols
            user.setPos(c, col * sx, ch - (row + 1) * sy + (sy - user.iconHeight()), c.w, c.h)
            i = i + 1
        end
    end
    user.damageWindow(client)
end

local function iconRows(client)
    local cw = clientSize(client)
    local n = 0
    for _, c in ipairs(kids(client)) do if c.iconic and c.visible then n = n + 1 end end
    if n == 0 then return 0 end
    local cols = math.max(cw // MT.CXICONSPACING, 1)
    return (n + cols - 1) // cols
end

local function cascade(client)
    if client.mdi.maximized then user.mdiRestoreNow(client.mdi.maximized) end
    local cw, ch = clientSize(client)
    ch = ch - iconRows(client) * MT.CYICONSPACING
    local step = MT.CYCAPTION + MT.CYFRAME - 1
    local list = {}
    -- the active window ends on top, so it goes last
    for _, c in ipairs(kids(client)) do
        if c.visible and not c.iconic and c ~= client.mdiActive then list[#list + 1] = c end
    end
    if client.mdiActive and not client.mdiActive.iconic then list[#list + 1] = client.mdiActive end
    local n = 0
    local w, h = math.max(cw - step * 4, 100), math.max(ch - step * 4, 60)
    for _, c in ipairs(list) do
        local x, y = n * step, n * step
        if x + w > cw or y + h > ch then n = 0; x, y = 0, 0 end
        user.setPos(c, x, y, w, h)
        user.linkZ(c)
        n = n + 1
    end
    user.damageWindow(client)
end

local function tile(client, horizontal)
    if client.mdi.maximized then user.mdiRestoreNow(client.mdi.maximized) end
    local cw, ch = clientSize(client)
    ch = ch - iconRows(client) * MT.CYICONSPACING
    local list = {}
    for _, c in ipairs(kids(client)) do if c.visible and not c.iconic then list[#list + 1] = c end end
    local n = #list
    if n == 0 then return end
    -- Windows 3.1 tiles in columns: as square a grid as the count allows
    local cols = math.floor(math.sqrt(n))
    if horizontal then cols = 1 end
    local rowsIn = {}
    for c = 1, cols do rowsIn[c] = n // cols end
    for c = cols - (n % cols) + 1, cols do rowsIn[c] = rowsIn[c] + 1 end
    local i = 1
    local colW = cw // cols
    for c = 1, cols do
        local rows = rowsIn[c]
        local rowH = ch // rows
        for r = 1, rows do
            local win = list[i]
            i = i + 1
            if win then
                local x = (c - 1) * colW
                local y = (r - 1) * rowH
                user.setPos(win, x, y, c == cols and (cw - x) or colW, r == rows and (ch - y) or rowH)
            end
        end
    end
    user.damageWindow(client)
end

-- ---- MDICLIENT ---------------------------------------------------------------------------------------------

local function createChild(client, mcs)
    -- MDICREATESTRUCT: szClass, szTitle, hOwner, x, y, cx, cy, style, lParam
    local clsFp, titleFp = rd(mcs), rd(mcs + 4)
    local inst = rw(mcs + 8)
    local x, y, cx, cy = s16(rw(mcs + 10)), s16(rw(mcs + 12)), s16(rw(mcs + 14)), s16(rw(mcs + 16))
    local style = rd(mcs + 18)
    local cls = (clsFp >> 16) == 0 and ("#" .. (clsFp & 0xFFFF)) or mem.cstr(cpu.flat(clsFp))
    local title = titleFp ~= 0 and mem.cstr(cpu.flat(titleFp)) or ""
    style = style | WS.CHILD | WS.CLIPSIBLINGS | WS.CAPTION | WS.SYSMENU | WS.THICKFRAME |
            WS.MINIMIZEBOX | WS.MAXIMIZEBOX
    local visible = true
    local maximizeNew = client.mdi.maximized ~= nil and style & WS.MINIMIZE == 0
    local id = client.mdi.firstId + #kids(client)
    local mcsFp = cpu.farOf(mcs)
    local w = user.create(cls, title, style & ~WS.VISIBLE, x, y, cx, cy, client.handle, id, inst, mcsFp, WS_EX_MDICHILD)
    if not w then return 0 end
    client.mdi.order[#client.mdi.order + 1] = w
    if style & WS.MINIMIZE ~= 0 then
        user.mdiMinimize(w)
        w.visible = true
    elseif style & WS.MAXIMIZE ~= 0 or maximizeNew then
        w.visible = true
        user.mdiMaximize(w)
    else
        user.setVisible(w, true)
    end
    user.mdiActivate(w)
    windowMenuItems(client)
    return w.handle
end

local function destroyChild(client, w)
    if not w or w.destroyed then return end
    local wasMax = client.mdi.maximized == w
    if wasMax then client.mdi.maximized = nil end
    local wasActive = client.mdiActive == w
    if wasActive then client.mdiActive = nil end
    user.destroy(w)
    if wasMax then refreshFrameMenu(client); updateFrameTitle(client) end
    if wasActive then
        local nxt
        for _, c in ipairs(client.children) do
            if c.visible and not c.destroyed then nxt = c; break end
        end
        if nxt then
            if wasMax and not nxt.iconic then user.mdiMaximizeNow(nxt) end
            user.mdiActivate(nxt)
        else
            local f = frameOf(client)
            if f then user.setFocus(client) end
        end
    end
    windowMenuItems(client)
end

local function clientProc(hwnd, msg, wp, lp)
    local client = W(hwnd)
    if not client then return 0 end
    if msg == WM.CREATE then
        -- CLIENTCREATESTRUCT: hWindowMenu, idFirstChild
        local cs = cpu.flat(lp)
        local ccs = cs and cpu.flat(rd(cs))
        client.mdi = {order = {}, windowMenu = ccs and rw(ccs) or 0, firstId = ccs and rw(ccs + 2) or 100}
        -- the scroll bars appear only when children reach outside (CalcChildScroll)
        if client.vscroll then client.vscroll.visible = false end
        if client.hscroll then client.hscroll.visible = false end
        user.calcClient(client)
        return 0
    elseif msg == WM.MDICREATE then
        local mcs = cpu.flat(lp)
        return mcs and createChild(client, mcs) or 0
    elseif msg == WM.MDIDESTROY then
        destroyChild(client, W(wp))
        return 0
    elseif msg == WM.MDIACTIVATE then
        local c = W(wp)
        if c and c.parent == client then user.mdiActivate(c) end
        return 0
    elseif msg == WM.MDIGETACTIVE then
        local a = client.mdiActive
        if a and a.destroyed then a = nil end
        return api.mklong(a and a.handle or 0, (a and client.mdi.maximized == a) and 1 or 0)
    elseif msg == WM.MDIMAXIMIZE then
        local c = W(wp)
        if c then user.mdiMaximize(c) end
        return 0
    elseif msg == WM.MDIRESTORE then
        local c = W(wp)
        if c then user.mdiRestore(c) end
        return 0
    elseif msg == WM.MDINEXT then
        local list = {}
        for _, c in ipairs(client.children) do if c.visible then list[#list + 1] = c end end
        if #list > 1 then
            local cur = W(wp) or client.mdiActive
            if lp == 0 then
                -- next: the current one goes to the bottom
                user.linkZ(cur, "bottom")
                local first
                for _, c in ipairs(client.children) do if c.visible then first = c; break end end
                if first then user.mdiActivate(first) end
            else
                user.mdiActivate(list[#list])
            end
            user.damageWindow(client)
        end
        return 0
    elseif msg == WM.MDICASCADE then
        cascade(client)
        return 1
    elseif msg == WM.MDITILE then
        tile(client, (wp & 1) ~= 0)
        return 1
    elseif msg == WM.MDIICONARRANGE then
        arrangeIcons(client)
        return 0
    elseif msg == WM.MDISETMENU then
        local f = frameOf(client)
        local old = f and f.menu or 0
        local frameMenu, winMenu = lp & 0xFFFF, lp >> 16
        if f and frameMenu ~= 0 then f.menu = frameMenu end
        if winMenu ~= 0 then client.mdi.windowMenu = winMenu end
        windowMenuItems(client)
        if f then refreshFrameMenu(client) end
        return old
    elseif msg == WM.SIZE then
        if client.mdi.maximized and not client.mdi.maximized.destroyed then
            local x, y, cw, ch = user.maxRect(client.mdi.maximized)
            user.setPos(client.mdi.maximized, x, y, cw, ch)
        end
        -- icons stay at the bottom
        for _, c in ipairs(kids(client)) do
            if c.iconic and not c.iconMoved then arrangeIcons(client); break end
        end
        return 0
    elseif msg == WM.SETFOCUS then
        if client.mdiActive and not client.mdiActive.destroyed and not client.mdiActive.iconic then
            user.setFocus(client.mdiActive)
        end
        return 0
    elseif msg == WM.ERASEBKGND then
        local dc = require("win16.gdi").dc(wp)
        if dc then user.fillRect(dc, {0, 0, client.cl[3], client.cl[4]}, user.sysBrush(COLOR.APPWORKSPACE)) end
        return 1
    elseif msg == WM.NCHITTEST then
        return HT.CLIENT
    elseif msg == WM.PARENTNOTIFY then
        return 0
    end
    return user.defwnd.proc(hwnd, msg, wp, lp)
end

user.registerClass({name = "MDICLIENT", style = 0, proc = user.luaProc("MDIClientProc", clientProc),
                    brush = COLOR.APPWORKSPACE + 1, mdiClient = true})
user.classes.MDICLIENT.mdiClient = true

-- ---- DefFrameProc ----------------------------------------------------------------------------------------------

local function defFrame(hwnd, hclient, msg, wp, lp)
    local f = W(hwnd)
    local client = W(hclient)
    if not f then return 0 end
    if client and client.mdi then
        if msg == WM.COMMAND then
            local id = wp
            local first = client.mdi.firstId
            if id >= first and id < first + 9 then
                local list = {}
                for _, c in ipairs(kids(client)) do if c.visible then list[#list + 1] = c end end
                local c = list[id - first + 1]
                if c then
                    if c.iconic then user.mdiRestore(c) else user.mdiActivate(c) end
                end
                return 0
            end
            -- system commands of a maximized child chosen in the frame's menu bar
            if id >= 0xF000 and client.mdiActive then
                return user.send(client.mdiActive, WM.SYSCOMMAND, id, lp)
            end
            return 0
        elseif msg == WM.SIZE then
            user.setPos(client, f.cl[1] - f.cl[1], 0, f.cl[3] - f.cl[1], f.cl[4] - f.cl[2])
            return 0
        elseif msg == WM.SETFOCUS then
            user.setFocus(client)
            return 0
        elseif msg == WM.SETTEXT then
            local l = cpu.flat(lp)
            f.baseText = l and mem.cstr(l) or ""
            f.text = f.baseText
            updateFrameTitle(client)
            f.ncdirty = true
            user.dirty = true
            if user.appMode and f == user.frame then host.title(f.text) end
            return 1
        elseif msg == WM.SYSCOMMAND and (wp & 0xFFF0) == SC.KEYMENU and wp & 0xFFFF == 0x2D then
            if client.mdiActive then user.trackSysMenu(client.mdiActive, true) end
            return 0
        end
    end
    return user.defwnd.proc(hwnd, msg, wp, lp)
end

def("USER", 445, "DefFrameProc", "h h w w l:l", function(h, hc, msg, wp, lp) return defFrame(h, hc, msg, wp, lp) end)

-- ---- DefMDIChildProc ---------------------------------------------------------------------------------------------

local function defChild(hwnd, msg, wp, lp)
    local w = W(hwnd)
    if not w then return 0 end
    local client = clientOf(w)
    if not client then return user.defwnd.proc(hwnd, msg, wp, lp) end
    if msg == WM.SYSCOMMAND then
        local c = wp & 0xFFF0
        if c == SC.MAXIMIZE then user.mdiMaximize(w); return 0 end
        if c == SC.RESTORE then user.mdiRestore(w); return 0 end
        if c == SC.MINIMIZE then user.mdiMinimize(w); return 0 end
        if c == SC.NEXTWINDOW then user.send(client, WM.MDINEXT, w.handle, 0); return 0 end
        if c == SC.PREVWINDOW then user.send(client, WM.MDINEXT, w.handle, 1); return 0 end
        if c == SC.KEYMENU then
            -- Alt+letter in a group goes to the frame's menu bar; Alt+- to this window's system menu
            if (lp & 0xFFFF) == 0x2D or ((lp & 0xFFFF) == 0x20 and false) then user.trackSysMenu(w, true); return 0 end
            local f = frameOf(client)
            if f then return user.send(f, WM.SYSCOMMAND, wp, lp) end
            return 0
        end
        if c == SC.MOVE and w.zoomed then return 0 end
        return user.defwnd.proc(hwnd, msg, wp, lp)
    elseif msg == WM.CLOSE then
        user.send(client, WM.MDIDESTROY, w.handle, 0)
        return 0
    elseif msg == WM.CHILDACTIVATE or msg == WM.MOUSEACTIVATE then
        user.mdiActivate(w)
        return msg == WM.MOUSEACTIVATE and 1 or 0
    elseif msg == WM.SETFOCUS then
        if client.mdiActive ~= w then user.mdiActivate(w) end
        return 0
    elseif msg == WM.SETTEXT then
        local r = user.defwnd.proc(hwnd, msg, wp, lp)
        windowMenuItems(client)
        if client.mdi.maximized == w then updateFrameTitle(client) end
        return r
    elseif msg == WM.SIZE then
        return user.defwnd.proc(hwnd, msg, wp, lp)
    elseif msg == WM.NEXTMENU or msg == WM.MENUCHAR then
        return 0
    end
    return user.defwnd.proc(hwnd, msg, wp, lp)
end

def("USER", 447, "DefMDIChildProc", "h w w l:l", function(h, msg, wp, lp) return defChild(h, msg, wp, lp) end)

def("USER", 451, "TranslateMDISysAccel", "h p", function(hclient, lpMsg)
    local client = W(hclient)
    if not client or not client.mdi or not lpMsg then return 0 end
    local m = user.readMsg(lpMsg)
    if m.msg ~= WM.KEYDOWN and m.msg ~= WM.SYSKEYDOWN then return 0 end
    if not user.keys[0x11] then return 0 end
    local a = client.mdiActive
    if not a or a.destroyed then return 0 end
    if m.wp == 0x73 then user.post(a, WM.SYSCOMMAND, SC.CLOSE, 0); return 1 end           -- Ctrl+F4
    if m.wp == 0x75 or m.wp == 0x09 then                                                   -- Ctrl+F6 / Ctrl+Tab
        user.post(a, WM.SYSCOMMAND, user.keys[0x10] and SC.PREVWINDOW or SC.NEXTWINDOW, 0)
        return 1
    end
    return 0
end)

def("USER", 462, "CalcChildScroll", "h w:v", function() end)

-- Text changes of a child show in the Window menu.
local prevChanged = user.onTextChanged
function user.onTextChanged(w)
    if prevChanged then prevChanged(w) end
    local client = clientOf(w)
    if client then windowMenuItems(client); if client.mdi.maximized == w then updateFrameTitle(client) end end
end

return {}

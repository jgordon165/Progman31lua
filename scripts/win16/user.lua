-- USER: windows, classes, messages, painting, input and DefWindowProc, in
-- Windows 3.1's look. Menus, MDI, dialogs, controls and the window scroll
-- bars live in their own files and hook into the tables here.
--
-- A window is a Lua table. Its position (x, y, w, h) is relative to its
-- parent's client area (the desktop's for top-level windows); cl is its
-- client area relative to its own top-left. Update regions are rectangle
-- lists in client coordinates. Every DC is clipped to the window's visible
-- region: what isn't covered by windows above it, minus its own children.

local api = require("win16.api")
local cpu = require("recomp.cpu")
local gdi = require("win16.gdi")
local handles = require("win16.handles")
local region = require("win16.region")
local res = require("win16.resources")
local kernel = require("win16.kernel")

local user = {}
local def = api.def
local rw, ww, rb, wb, rd, wd = mem.rw, mem.ww, mem.rb, mem.wb, mem.rd, mem.wd
local s16 = api.s16

-- ---- constants ------------------------------------------------------------------------------

local WM = {
    NULL = 0, CREATE = 1, DESTROY = 2, MOVE = 3, SIZE = 5, ACTIVATE = 6, SETFOCUS = 7, KILLFOCUS = 8,
    ENABLE = 0x0A, SETREDRAW = 0x0B, SETTEXT = 0x0C, GETTEXT = 0x0D, GETTEXTLENGTH = 0x0E, PAINT = 0x0F,
    CLOSE = 0x10, QUERYENDSESSION = 0x11, QUIT = 0x12, QUERYOPEN = 0x13, ERASEBKGND = 0x14,
    SYSCOLORCHANGE = 0x15, ENDSESSION = 0x16, SHOWWINDOW = 0x18, CTLCOLOR = 0x19, WININICHANGE = 0x1A,
    ACTIVATEAPP = 0x1C, CANCELMODE = 0x1F, SETCURSOR = 0x20, MOUSEACTIVATE = 0x21, CHILDACTIVATE = 0x22,
    GETMINMAXINFO = 0x24, PAINTICON = 0x26, ICONERASEBKGND = 0x27, NEXTDLGCTL = 0x28, DRAWITEM = 0x2B,
    MEASUREITEM = 0x2C, DELETEITEM = 0x2D, VKEYTOITEM = 0x2E, CHARTOITEM = 0x2F, SETFONT = 0x30,
    GETFONT = 0x31, QUERYDRAGICON = 0x37, COMPAREITEM = 0x39, WINDOWPOSCHANGING = 0x46,
    WINDOWPOSCHANGED = 0x47, NCCREATE = 0x81, NCDESTROY = 0x82, NCCALCSIZE = 0x83, NCHITTEST = 0x84,
    NCPAINT = 0x85, NCACTIVATE = 0x86, GETDLGCODE = 0x87, NCMOUSEMOVE = 0xA0, NCLBUTTONDOWN = 0xA1,
    NCLBUTTONUP = 0xA2, NCLBUTTONDBLCLK = 0xA3, NCRBUTTONDOWN = 0xA4, NCRBUTTONUP = 0xA5,
    KEYDOWN = 0x100, KEYUP = 0x101, CHAR = 0x102, DEADCHAR = 0x103, SYSKEYDOWN = 0x104, SYSKEYUP = 0x105,
    SYSCHAR = 0x106, INITDIALOG = 0x110, COMMAND = 0x111, SYSCOMMAND = 0x112, TIMER = 0x113,
    HSCROLL = 0x114, VSCROLL = 0x115, INITMENU = 0x116, INITMENUPOPUP = 0x117, MENUSELECT = 0x11F,
    MENUCHAR = 0x120, ENTERIDLE = 0x121, MOUSEMOVE = 0x200, LBUTTONDOWN = 0x201, LBUTTONUP = 0x202,
    LBUTTONDBLCLK = 0x203, RBUTTONDOWN = 0x204, RBUTTONUP = 0x205, RBUTTONDBLCLK = 0x206,
    MBUTTONDOWN = 0x207, MBUTTONUP = 0x208, MBUTTONDBLCLK = 0x209, PARENTNOTIFY = 0x210,
    MDICREATE = 0x220, MDIDESTROY = 0x221, MDIACTIVATE = 0x222, MDIRESTORE = 0x223, MDINEXT = 0x224,
    MDIMAXIMIZE = 0x225, MDITILE = 0x226, MDICASCADE = 0x227, MDIICONARRANGE = 0x228,
    MDIGETACTIVE = 0x229, MDISETMENU = 0x230, DROPOBJECT = 0x22A, QUERYDROPOBJECT = 0x22B,
    BEGINDRAG = 0x22C, DRAGLOOP = 0x22D, DRAGSELECT = 0x22E, DRAGMOVE = 0x22F, DROPFILES = 0x233,
    USER = 0x400,
    DDE_INITIATE = 0x3E0, DDE_TERMINATE = 0x3E1, DDE_ADVISE = 0x3E2, DDE_UNADVISE = 0x3E3, DDE_ACK = 0x3E4,
    DDE_DATA = 0x3E5, DDE_REQUEST = 0x3E6, DDE_POKE = 0x3E7, DDE_EXECUTE = 0x3E8,
}
user.WM = WM

local WS = {
    OVERLAPPED = 0, POPUP = 0x80000000, CHILD = 0x40000000, MINIMIZE = 0x20000000, VISIBLE = 0x10000000,
    DISABLED = 0x08000000, CLIPSIBLINGS = 0x04000000, CLIPCHILDREN = 0x02000000, MAXIMIZE = 0x01000000,
    CAPTION = 0x00C00000, BORDER = 0x00800000, DLGFRAME = 0x00400000, VSCROLL = 0x00200000,
    HSCROLL = 0x00100000, SYSMENU = 0x00080000, THICKFRAME = 0x00040000, GROUP = 0x00020000,
    TABSTOP = 0x00010000, MINIMIZEBOX = 0x00020000, MAXIMIZEBOX = 0x00010000,
}
user.WS = WS
local WS_EX_DLGMODALFRAME, WS_EX_NOPARENTNOTIFY, WS_EX_TOPMOST = 1, 4, 8

local SC = {SIZE = 0xF000, MOVE = 0xF010, MINIMIZE = 0xF020, MAXIMIZE = 0xF030, NEXTWINDOW = 0xF040,
            PREVWINDOW = 0xF050, CLOSE = 0xF060, VSCROLL = 0xF070, HSCROLL = 0xF080, MOUSEMENU = 0xF090,
            KEYMENU = 0xF100, ARRANGE = 0xF110, RESTORE = 0xF120, TASKLIST = 0xF130}
user.SC = SC

local HT = {NOWHERE = 0, CLIENT = 1, CAPTION = 2, SYSMENU = 3, GROWBOX = 4, MENU = 5, HSCROLL = 6,
            VSCROLL = 7, REDUCE = 8, ZOOM = 9, LEFT = 10, RIGHT = 11, TOP = 12, TOPLEFT = 13, TOPRIGHT = 14,
            BOTTOM = 15, BOTTOMLEFT = 16, BOTTOMRIGHT = 17, BORDER = 18}
user.HT = HT

-- Windows 3.1's default colours ("Windows Default" scheme)
user.sysColors = {[0] = 0xC0C0C0, 0xC0C0C0, 0x000080, 0xFFFFFF, 0xFFFFFF, 0xFFFFFF, 0x000000, 0x000000,
                  0x000000, 0xFFFFFF, 0xC0C0C0, 0xC0C0C0, 0xFFFFFF, 0x000080, 0xFFFFFF, 0xC0C0C0, 0x808080,
                  0x808080, 0x000000, 0x000000, 0xFFFFFF}
local C = user.sysColors
local COLOR = {SCROLLBAR = 0, BACKGROUND = 1, ACTIVECAPTION = 2, INACTIVECAPTION = 3, MENU = 4, WINDOW = 5,
               WINDOWFRAME = 6, MENUTEXT = 7, WINDOWTEXT = 8, CAPTIONTEXT = 9, ACTIVEBORDER = 10,
               INACTIVEBORDER = 11, APPWORKSPACE = 12, HIGHLIGHT = 13, HIGHLIGHTTEXT = 14, BTNFACE = 15,
               BTNSHADOW = 16, GRAYTEXT = 17, BTNTEXT = 18, INACTIVECAPTIONTEXT = 19, BTNHIGHLIGHT = 20}
user.COLOR = COLOR

user.metrics = {
    CXVSCROLL = 17, CYHSCROLL = 17, CYCAPTION = 20, CXBORDER = 1, CYBORDER = 1, CXDLGFRAME = 4,
    CYDLGFRAME = 4, CXFRAME = 4, CYFRAME = 4, CYMENU = 18, CXICON = 32, CYICON = 32, CXSIZE = 18,
    CYSIZE = 18, CXICONSPACING = 75, CYICONSPACING = 72,
}
local MT = user.metrics

-- ---- state --------------------------------------------------------------------------------------

user.classes = {}        -- upper-case name -> class
user.focus = nil         -- window with the keyboard focus
user.active = nil        -- active top-level window
user.capture = nil       -- internal mouse capture
user.posted = {}         -- posted messages
user.input = {}          -- raw input waiting to become messages
user.quit = nil          -- exit code once PostQuitMessage was called
user.keys = {}           -- vk -> down
user.toggles = {}
user.mouseX, user.mouseY = 0, 0
user.dirty = true        -- the screen changed since the last present
user.appMode = true      -- the frame window is the host window

local function W(h) return handles.get(h, "window") end
user.W = W
function user.hwnd(w) return w and w.handle or 0 end

-- ---- classes ----------------------------------------------------------------------------------------

-- cls: {name, style, proc (far pointer), clsExtra, wndExtra, inst, icon, cursor, brush, menu, extra = {}}
function user.registerClass(cls)
    cls.extra = cls.extra or {}
    user.classes[cls.name:upper()] = cls
    return cls
end

-- Lua window procedures as far pointers.
function user.luaProc(name, fn)
    return (api.farproc(name, "h w w l:l", function(h, m, wp, lp) return fn(h, m, wp, lp) end))
end

-- ---- geometry ------------------------------------------------------------------------------------------

local function hasCaption(w) return (w.style & WS.CAPTION) == WS.CAPTION end

-- The border thickness of a window's frame.
function user.borderOf(w)
    if w.iconic then return 0 end
    if w.style & WS.THICKFRAME ~= 0 then return MT.CXFRAME end
    if w.exstyle & WS_EX_DLGMODALFRAME ~= 0 then return MT.CXDLGFRAME end
    if (w.style & WS.CAPTION) == WS.DLGFRAME then return MT.CXDLGFRAME end
    if w.style & WS.BORDER ~= 0 then return 1 end
    return 0
end

-- Recomputes the client area: the window minus the frame, the caption, the
-- menu bar and the scroll bars.
function user.calcClient(w)
    if w.iconic then w.cl = {0, 0, 0, 0}; return end
    local b = user.borderOf(w)
    local l, t, r, bo = b, b, w.w - b, w.h - b
    w.capTop = t
    if hasCaption(w) then
        -- with a thick frame, the caption sits inside the frame; with a
        -- plain border it shares the border's line
        t = t + MT.CYCAPTION - 1
    end
    w.menuTop = t
    w.menuH = 0
    if w.style & WS.CHILD == 0 and w.menu and w.menu ~= 0 and user.menuBarHeight then
        w.menuH = user.menuBarHeight(w, r - l)
        t = t + w.menuH
    end
    if w.vscroll and w.vscroll.visible then r = r - (MT.CXVSCROLL - (b > 0 and 1 or 0)) end
    if w.hscroll and w.hscroll.visible then bo = bo - (MT.CYHSCROLL - (b > 0 and 1 or 0)) end
    if r < l then r = l end
    if bo < t then bo = t end
    w.cl = {l, t, r, bo}
end

-- Screen position of a window's top-left corner.
function user.screenPos(w)
    local x, y = 0, 0
    while w and w ~= user.desktop do
        x, y = x + w.x, y + w.y
        local p = w.parent
        if p and p ~= user.desktop then x, y = x + p.cl[1], y + p.cl[2] end
        w = p
    end
    return x, y
end

-- Screen rectangles of a window and of its client area.
function user.windowRect(w)
    local x, y = user.screenPos(w)
    return {x, y, x + w.w, y + w.h}
end
function user.clientRect(w)
    if w == user.desktop then return {0, 0, user.desktop.w, user.desktop.h} end
    local x, y = user.screenPos(w)
    return {x + w.cl[1], y + w.cl[2], x + w.cl[3], y + w.cl[4]}
end
function user.clientOrigin(w)
    if w == user.desktop then return 0, 0 end
    local x, y = user.screenPos(w)
    return x + w.cl[1], y + w.cl[2]
end

function user.isVisible(w)
    while w and w ~= user.desktop do
        if not w.visible then return false end
        w = w.parent
    end
    return true
end

-- The visible region of a window (screen coordinates): its rectangle (or
-- its client area) inside every ancestor's client area, minus every window
-- above it at each level, minus its own children.
function user.visRegion(w, clientOnly)
    if not user.isVisible(w) then return {} end
    local r = clientOnly and user.clientRect(w) or user.windowRect(w)
    local vis = {r}
    local cur = w
    while cur ~= user.desktop do
        local p = cur.parent
        local pc = user.clientRect(p)
        vis = region.intersect(vis, {pc})
        if #vis == 0 then return vis end
        -- siblings above (earlier in the list)
        local cut = {}
        for _, s in ipairs(p.children) do
            if s == cur then break end
            if s.visible then cut[#cut + 1] = user.windowRect(s) end
        end
        if #cut > 0 then vis = region.subtract(vis, cut) end
        cur = p
    end
    if w.children then
        local cut = {}
        for _, c in ipairs(w.children) do
            if c.visible then cut[#cut + 1] = user.windowRect(c) end
        end
        if #cut > 0 then vis = region.subtract(vis, cut) end
    end
    return vis
end

-- ---- painting ----------------------------------------------------------------------------------------------

-- Marks a window's area as needing paint: rect (client coordinates) or the
-- whole client area.
function user.invalidate(w, rect, erase)
    if not w or w.iconic then
        if w then w.ncdirty = true; user.dirty = true end
        return
    end
    local cw, ch = w.cl[3] - w.cl[1], w.cl[4] - w.cl[2]
    local r = rect and region.isect(rect, {0, 0, cw, ch}) or ((cw > 0 and ch > 0) and {0, 0, cw, ch} or nil)
    if not r then return end
    w.upd = region.union(w.upd or {}, {r})
    if erase then w.erase = true end
end

-- Repaints everything under a screen-coordinate area: frames and clients of
-- every window there, and the desktop.
function user.damage(rects)
    if #rects == 0 then return end
    user.dirty = true
    local function walk(w)
        for _, c in ipairs(w.children) do
            if c.visible then
                local wr = user.windowRect(c)
                local hit = region.intersect(rects, {wr})
                if #hit > 0 then
                    local cr = user.clientRect(c)
                    local inner = region.intersect(hit, {cr})
                    if #region.subtract(hit, {cr}) > 0 or c.iconic then c.ncdirty = true end
                    local ox, oy = cr[1], cr[2]
                    for _, r in ipairs(inner) do
                        user.invalidate(c, {r[1] - ox, r[2] - oy, r[3] - ox, r[4] - oy}, true)
                    end
                    walk(c)
                end
            end
        end
    end
    walk(user.desktop)
    user.paintDesktop(rects)
end

function user.damageWindow(w)
    if user.isVisible(w) then user.damage({user.windowRect(w)}) end
end

function user.paintDesktop(rects)
    local vis = {{0, 0, user.desktop.w, user.desktop.h}}
    local cut = {}
    for _, c in ipairs(user.desktop.children) do
        if c.visible then cut[#cut + 1] = user.windowRect(c) end
    end
    vis = region.intersect(region.subtract(vis, cut), rects)
    if #vis == 0 then return end
    fb.clip(region.flat(vis))
    fb.patblt(0, 0, 0, user.desktop.w, user.desktop.h, 0xF0, C[COLOR.BACKGROUND])
end

-- A DC on a window: client area (default) or whole window.
function user.getDC(w, whole, upd)
    local x, y
    if whole then x, y = user.screenPos(w) else x, y = user.clientOrigin(w) end
    local vis = user.visRegion(w, not whole)
    if upd then
        local ox, oy = user.clientOrigin(w)
        vis = region.intersect(vis, region.offset(upd, ox, oy))
    end
    local brush = w.class and w.class.brush
    return gdi.newDC({surface = 0, ox = x, oy = y, hwnd = w.handle, vis = vis,
                      clipFn = function(dc) return dc.vis end,
                      font = (w.font and w.font ~= 0) and w.font or nil})
end

-- A brush handle for a class background (a brush, or a COLOR_* + 1)
function user.brushFor(b)
    if not b or b == 0 then return nil end
    local o = handles.get(b)
    if o and o.kind == "brush" then return b end
    local idx = b - 1
    if C[idx] then return user.sysBrush(idx) end
end

local sysBrushes = {}
function user.sysBrush(idx)
    if not sysBrushes[idx] then
        sysBrushes[idx] = gdi.newBrush(C[idx])
        handles.get(sysBrushes[idx]).stock = true
    end
    return sysBrushes[idx]
end

-- Fills a rectangle (DC logical coordinates) with a brush handle.
function user.fillRect(dc, r, hbr)
    local b = handles.get(hbr)
    if not b or b.kind ~= "brush" or b.null then return end
    if not gdi.useClip(dc) then return end
    fb.patblt(dc.surface, r[1] + dc.ox, r[2] + dc.oy, r[3] - r[1], r[4] - r[2], 0xF0, gdi.fbBrush(b))
end

-- ---- windows ------------------------------------------------------------------------------------------------

local function newWindow(t)
    t.kind = "window"
    t.children = {}
    t.extra = {}
    t.props = {}
    t.style = t.style or 0
    t.exstyle = t.exstyle or 0
    t.text = t.text or ""
    t.x, t.y, t.w, t.h = t.x or 0, t.y or 0, t.w or 0, t.h or 0
    t.cl = {0, 0, t.w, t.h}
    handles.new(t)
    return t
end

function user.init(cfg, sys)
    user.cfg = cfg
    if type(cfg.opts.script) == "string" then user.script = assert(loadfile(cfg.opts.script))()
    elseif type(cfg.opts.script) == "table" then user.script = cfg.opts.script end
    user.appMode = not cfg.opts.desktop
    user.exitAfter = tonumber(cfg.opts["exit-after"])
    user.started = host.ticks()
    if sys.display then res.system[#res.system + 1] = sys.display end
    if sys.user then res.system[#res.system + 1] = sys.user end
    user.desktop = newWindow({w = cfg.screenW, h = cfg.screenH, visible = true, text = ""})
    user.desktop.cl = {0, 0, cfg.screenW, cfg.screenH}
    user.desktop.class = {name = "#32769", extra = {}}
    require("win16.defwnd")
    require("win16.scroll")
    require("win16.menu")
    require("win16.controls")
    require("win16.dialog")
    require("win16.mdi")
    require("win16.usermisc")
    require("win16.dragdrop")
    host.cursor("arrow")
end

function user.setTask(task, mod)
    user.task = task
    user.module = mod
end

function user.shutdown() end

-- Inserts w into its parent's z-order: top (default) or after another sibling.
local function linkZ(w, after)
    local list = w.parent.children
    for i, c in ipairs(list) do if c == w then table.remove(list, i); break end end
    if after == "bottom" then list[#list + 1] = w; return end
    if type(after) == "table" then
        for i, c in ipairs(list) do
            if c == after then table.insert(list, i + 1, w); return end
        end
    end
    -- topmost windows stay above the rest
    local at = 1
    if w.exstyle & WS_EX_TOPMOST == 0 then
        while list[at] and list[at].exstyle & WS_EX_TOPMOST ~= 0 do at = at + 1 end
    end
    table.insert(list, at, w)
end
user.linkZ = linkZ

-- Calls a window procedure (16-bit or Lua) and returns the LRESULT.
function user.callProc(proc, hwnd, msg, wp, lp)
    wp, lp = wp & 0xFFFF, lp & 0xFFFFFFFF
    local fn = api.luaproc(proc)
    if fn then
        local r = fn(hwnd, msg, wp, lp)
        if r == true then r = 1 elseif not r then r = 0 end
        return r
    end
    local R = user.task.R
    local dg = user.task.dgroup
    local ax, dx = cpu.call16(R, proc >> 16, proc & 0xFFFF, {hwnd, msg, wp, lp >> 16, lp & 0xFFFF}, {ds = dg, ax = dg})
    return (dx << 16) | ax
end

-- SendMessage
function user.send(w, msg, wp, lp)
    if type(w) == "number" then w = W(w) end
    if not w or w.destroyed and msg ~= WM.NCDESTROY then return 0 end
    if user.sendHook then user.sendHook(w, msg, wp or 0, lp or 0) end
    return user.callProc(w.proc, w.handle, msg, wp or 0, lp or 0)
end

function user.post(w, msg, wp, lp)
    local h = type(w) == "table" and w.handle or w or 0
    user.posted[#user.posted + 1] = {hwnd = h, msg = msg, wp = (wp or 0) & 0xFFFF, lp = (lp or 0) & 0xFFFFFFFF,
                                     time = host.ticks(), x = user.mouseX, y = user.mouseY}
    return true
end

-- CreateWindow
local CW_USEDEFAULT = -32768
function user.create(className, title, style, x, y, cw, ch, parent, menu, inst, param, exstyle)
    local cls = user.classes[(className or ""):upper()]
    if not cls then
        host.log("CreateWindow: no class " .. tostring(className))
        return nil
    end
    exstyle = exstyle or 0
    local child = style & WS.CHILD ~= 0
    local p = parent and W(parent)
    if child and not p then return nil end
    local owner
    if not child then
        owner = p
        if owner then while owner.style & WS.CHILD ~= 0 do owner = owner.parent end end
        p = user.desktop
    end
    p = p or user.desktop
    -- default positions, cascading
    if x == CW_USEDEFAULT then
        user.cascadeN = ((user.cascadeN or 0) + 1) % 8
        local pc = p == user.desktop and {0, 0, p.w, p.h} or {0, 0, p.cl[3] - p.cl[1], p.cl[4] - p.cl[2]}
        x, y = user.cascadeN * 24, user.cascadeN * 24
        if cw == CW_USEDEFAULT then cw, ch = (pc[3] * 3) // 4, (pc[4] * 3) // 4 end
    elseif cw == CW_USEDEFAULT then
        cw, ch = (p.w * 3) // 4, (p.h * 3) // 4
    end
    local w = newWindow({class = cls, style = style & ~(WS.VISIBLE | WS.MINIMIZE | WS.MAXIMIZE), exstyle = exstyle,
                         parent = p, owner = owner, x = x, y = y, w = cw, h = ch, inst = inst, proc = cls.proc,
                         id = child and menu or 0, menu = (not child) and menu or nil, visible = false,
                         disabled = style & WS.DISABLED ~= 0})
    if not child and (not menu or menu == 0) and cls.menuName and user.loadMenu then
        w.menu = user.loadMenu(inst, cls.menuName)
    end
    if exstyle & WS_EX_DLGMODALFRAME ~= 0 then w.style = w.style end
    if w.style & WS.VSCROLL ~= 0 then w.vscroll = {min = 0, max = 100, pos = 0, visible = true} end
    if w.style & WS.HSCROLL ~= 0 then w.hscroll = {min = 0, max = 100, pos = 0, visible = true} end
    linkZ(w)
    user.calcClient(w)

    -- CREATESTRUCT
    local mark = api.mark()
    local csfp, cs = api.alloc(34)
    local namefp = title and api.str(title) or 0
    local clsfp = api.str(className)
    wd(cs, param or 0); ww(cs + 4, inst or 0); ww(cs + 6, child and (menu or 0) or (w.menu or 0))
    ww(cs + 8, (child and parent or (owner and owner.handle) or 0)); ww(cs + 10, ch & 0xFFFF); ww(cs + 12, cw & 0xFFFF)
    ww(cs + 14, y & 0xFFFF); ww(cs + 16, x & 0xFFFF); wd(cs + 18, style); wd(cs + 22, namefp); wd(cs + 26, clsfp)
    wd(cs + 30, exstyle)
    if user.send(w, WM.NCCREATE, 0, csfp) == 0 then
        api.release(mark)
        user.destroy(w)
        return nil
    end
    user.calcClient(w)
    local r = user.send(w, WM.CREATE, 0, csfp)
    api.release(mark)
    if r == 0xFFFFFFFF or w.destroyed then
        user.destroy(w)
        return nil
    end
    if child and exstyle & WS_EX_NOPARENTNOTIFY == 0 then
        user.send(p, WM.PARENTNOTIFY, WM.CREATE, api.mklong(w.handle, w.id or 0))
    end
    if not w.destroyed then
        user.send(w, WM.SIZE, 0, api.mklong(w.cl[3] - w.cl[1], w.cl[4] - w.cl[2]))
        user.send(w, WM.MOVE, 0, api.mklong(w.x + w.cl[1], w.y + w.cl[2]))
    end
    if w.destroyed then return nil end
    if style & WS.MINIMIZE ~= 0 then user.showWindow(w, 6)
    elseif style & WS.MAXIMIZE ~= 0 then user.showWindow(w, 3) end
    if style & WS.VISIBLE ~= 0 and not w.visible then user.showWindow(w, 5) end
    return w
end

function user.destroy(w)
    if not w or w.destroyed or w.dying then return false end
    w.dying = true
    local wasVisible = w.visible and user.isVisible(w)
    local rect = wasVisible and user.windowRect(w)
    if w.style & WS.CHILD ~= 0 and w.exstyle & WS_EX_NOPARENTNOTIFY == 0 and w.parent and not w.parent.destroyed then
        user.send(w.parent, WM.PARENTNOTIFY, WM.DESTROY, api.mklong(w.handle, w.id or 0))
    end
    -- owned popups go first
    for _, o in pairs(handles.all()) do
        if o.kind == "window" and o.owner == w and not o.destroyed then user.destroy(o) end
    end
    user.callProc(w.proc, w.handle, WM.DESTROY, 0, 0)
    for i = #w.children, 1, -1 do user.destroy(w.children[i]) end
    user.callProc(w.proc, w.handle, WM.NCDESTROY, 0, 0)
    w.destroyed = true
    w.visible = false
    if user.focus == w or (user.focus and user.isDescendant(user.focus, w)) then
        user.focus = nil
    end
    if user.capture == w then user.capture = nil end
    local list = w.parent.children
    for i, c in ipairs(list) do if c == w then table.remove(list, i); break end end
    if user.active == w then
        user.active = nil
        -- activate the owner, or the next top-level window
        local nxt = w.owner
        if not nxt or nxt.destroyed or not nxt.visible then
            for _, c in ipairs(user.desktop.children) do
                if c.visible and not c.destroyed then nxt = c; break end
            end
        end
        if nxt and not nxt.destroyed then user.activate(nxt) end
    end
    handles.free(w.handle)
    if rect then user.damage({rect}) end
    return true
end

function user.isDescendant(c, p)
    while c do
        if c == p then return true end
        c = c.parent
    end
    return false
end

function user.topLevel(w)
    while w and w.parent and w.parent ~= user.desktop do w = w.parent end
    return w
end

-- Moves/sizes a window (parent client coordinates), sending WM_MOVE/WM_SIZE.
function user.setPos(w, x, y, cw, ch, opts)
    opts = opts or {}
    local before = user.isVisible(w) and user.windowRect(w)
    local moved = x ~= w.x or y ~= w.y
    local sized = cw ~= w.w or ch ~= w.h
    if not moved and not sized and not opts.frame then return end
    w.x, w.y, w.w, w.h = x, y, math.max(cw, 0), math.max(ch, 0)
    local oldcl = w.cl
    user.calcClient(w)
    if user.isVisible(w) then
        local after = user.windowRect(w)
        user.damage(before and region.union({before}, {after}) or {after})
    end
    if sized or opts.frame or oldcl[3] - oldcl[1] ~= w.cl[3] - w.cl[1] or oldcl[4] - oldcl[2] ~= w.cl[4] - w.cl[2] then
        local kind = w.iconic and 1 or w.zoomed and 2 or 0
        user.send(w, WM.SIZE, kind, api.mklong(w.cl[3] - w.cl[1], w.cl[4] - w.cl[2]))
    end
    if moved then user.send(w, WM.MOVE, 0, api.mklong(w.x + w.cl[1], w.y + w.cl[2])) end
end

-- Recomputes the client area after a frame change (menu, scroll bars).
function user.frameChanged(w)
    local old = w.cl
    user.calcClient(w)
    w.ncdirty = true
    user.dirty = true
    if old[1] ~= w.cl[1] or old[2] ~= w.cl[2] or old[3] ~= w.cl[3] or old[4] ~= w.cl[4] then
        user.damageWindow(w)
        user.send(w, WM.SIZE, w.zoomed and 2 or 0, api.mklong(w.cl[3] - w.cl[1], w.cl[4] - w.cl[2]))
    end
end

-- Show states
function user.setVisible(w, on)
    if w.visible == on then return end
    if on then
        w.visible = true
        user.calcClient(w)
        w.ncdirty = true
        user.invalidate(w, nil, true)
        if user.isVisible(w) then user.damage({user.windowRect(w)}) end
    else
        local r = user.isVisible(w) and user.windowRect(w)
        w.visible = false
        if r then user.damage({r}) end
        if user.focus and user.isDescendant(user.focus, w) then
            user.focus = nil
            if w.parent and w.parent ~= user.desktop then user.setFocus(user.topLevel(w)) end
        end
    end
end

-- The rectangle a maximized window fills (in parent client coordinates):
-- the parent's client area with the window's frame outside it.
function user.maxRect(w)
    local p = w.parent
    local pw, ph
    if p == user.desktop then pw, ph = p.w, p.h else pw, ph = p.cl[3] - p.cl[1], p.cl[4] - p.cl[2] end
    local b = (w.style & WS.THICKFRAME ~= 0) and MT.CXFRAME or user.borderOf(w)
    return -b, -b, pw + 2 * b, ph + 2 * b
end

-- Where a minimized window goes: the next free icon slot along the bottom.
function user.iconSlot(w)
    local p = w.parent
    local pw, ph
    if p == user.desktop then pw, ph = p.w, p.h else pw, ph = p.cl[3] - p.cl[1], p.cl[4] - p.cl[2] end
    local sx, sy = MT.CXICONSPACING, MT.CYICONSPACING
    local used = {}
    for _, c in ipairs(p.children) do
        if c ~= w and c.iconic and c.visible then used[c.x // sx .. "," .. (ph - c.y - c.h) // sy] = true end
    end
    local cols = math.max(pw // sx, 1)
    for row = 0, 50 do
        for col = 0, cols - 1 do
            if not used[col .. "," .. row] then
                return col * sx, ph - (row + 1) * sy + (sy - user.iconHeight())
            end
        end
    end
    return 0, ph - sy
end

function user.iconHeight() return MT.CYICON + 4 + 15 end

-- ShowWindow
function user.showWindow(w, cmd)
    local was = w.visible
    if cmd == 0 then
        if w.visible then user.send(w, WM.SHOWWINDOW, 0, 0) end
        user.setVisible(w, false)
        if user.active == w then
            user.active = nil
            for _, c in ipairs(user.desktop.children) do
                if c.visible and c ~= w then user.activate(c); break end
            end
        end
        return was
    end
    if user.appMode and w == user.frame and (cmd == 2 or cmd == 6 or cmd == 7) then
        -- the frame is the host window: minimizing it would leave nothing to see
        cmd = 5
    end
    if (cmd == 2 or cmd == 6 or cmd == 7) and not w.iconic then
        if user.mdiMinimize and user.mdiMinimize(w) then return was end
        if not w.zoomed then w.normal = {w.x, w.y, w.w, w.h} end
        w.iconic, w.zoomed = true, false
        w.style = (w.style | WS.MINIMIZE) & ~WS.MAXIMIZE
        local ix, iy = user.iconSlot(w)
        if not w.visible then w.visible = true end
        user.setPos(w, ix, iy, MT.CXICONSPACING, user.iconHeight(), {frame = true})
        w.ncdirty = true
        if cmd ~= 7 and w.style & WS.CHILD == 0 then user.activate(w) end
        user.damageWindow(w)
    elseif cmd == 3 and not w.zoomed then
        if user.mdiMaximize and user.mdiMaximize(w) then return was end
        if not w.iconic then w.normal = {w.x, w.y, w.w, w.h} end
        w.iconic, w.zoomed = false, true
        w.style = (w.style | WS.MAXIMIZE) & ~WS.MINIMIZE
        w.visible = true
        local x, y, cw, ch = user.maxRect(w)
        user.setPos(w, x, y, cw, ch, {frame = true})
        user.damageWindow(w)
        if w.style & WS.CHILD == 0 then user.activate(w) end
    elseif (cmd == 1 or cmd == 9) and (w.iconic or w.zoomed) then
        if user.mdiRestore and user.mdiRestore(w) then return was end
        local n = w.normal or {w.x, w.y, w.w, w.h}
        w.iconic, w.zoomed = false, false
        w.style = w.style & ~(WS.MINIMIZE | WS.MAXIMIZE)
        w.visible = true
        user.setPos(w, n[1], n[2], n[3], n[4], {frame = true})
        w.ncdirty = true
        user.damageWindow(w)
        if w.style & WS.CHILD == 0 then user.activate(w) end
    else
        if not w.visible then user.send(w, WM.SHOWWINDOW, 1, 0) end
        user.setVisible(w, true)
        if cmd == 1 or cmd == 5 or cmd == 9 or cmd == 3 then
            if w.style & WS.CHILD == 0 then user.activate(w)
            elseif user.isMdiChild and user.isMdiChild(w) then user.mdiActivate(w) end
        end
    end
    if user.appMode and w == user.frame then user.fitFrame() end
    return was
end

-- App mode: Program Manager's frame fills the host window, its caption and
-- border just outside it, so the host's own title bar stands in for them.
function user.fitFrame()
    local f = user.frame
    if not f or not user.appMode then return end
    local b = user.borderOf(f)
    local cap = hasCaption(f) and (MT.CYCAPTION - 1) or 0
    local x, y = -b, -b - cap
    local cw, ch = user.desktop.w + 2 * b, user.desktop.h + 2 * b + cap
    f.zoomed = false
    if f.x ~= x or f.y ~= y or f.w ~= cw or f.h ~= ch then user.setPos(f, x, y, cw, ch) end
    host.title(f.text ~= "" and f.text or "Program Manager")
end

-- ---- focus and activation -------------------------------------------------------------------------------

function user.setFocus(w)
    local old = user.focus
    if w == old then return old end
    if w and (w.destroyed or (w.disabled and false)) then return old end
    if w then
        -- focusing a window inside an inactive top-level window activates it
        local top = user.topLevel(w)
        if top ~= user.active and top.visible then user.activate(top, true) end
    end
    user.focus = w
    if old and not old.destroyed then user.send(old, WM.KILLFOCUS, w and w.handle or 0, 0) end
    if w and user.focus == w and not w.destroyed then user.send(w, WM.SETFOCUS, old and old.handle or 0, 0) end
    return old
end

function user.activate(w, noFocus)
    if not w or w.destroyed then return end
    w = user.topLevel(w)
    local old = user.active
    if old == w then
        if not noFocus and not user.focus then user.setFocus(w) end
        return
    end
    user.active = w
    if old and not old.destroyed then
        user.send(old, WM.NCACTIVATE, 0, 0)
        user.send(old, WM.ACTIVATE, 0, api.mklong(w.handle, 0))
    end
    linkZ(w)
    -- owned windows stay above their owner
    for i = #user.desktop.children, 1, -1 do
        local c = user.desktop.children[i]
        if c.owner == w and c.visible then linkZ(c) end
    end
    user.damageWindow(w)
    user.send(w, WM.NCACTIVATE, 1, 0)
    user.send(w, WM.ACTIVATE, w.iconic and 0x10001 or 1, api.mklong(old and old.handle or 0, w.iconic and 1 or 0))
    if not noFocus and user.active == w and (not user.focus or user.topLevel(user.focus) ~= w) then
        user.setFocus(w)
    end
end

-- ---- the message loop ----------------------------------------------------------------------------------

local MSG_SIZE = 18
local function writeMsg(lin, m)
    if not lin then return end
    ww(lin, m.hwnd); ww(lin + 2, m.msg); ww(lin + 4, m.wp); wd(lin + 6, m.lp); wd(lin + 10, m.time & 0xFFFFFFFF)
    ww(lin + 14, m.x & 0xFFFF); ww(lin + 16, m.y & 0xFFFF)
end
local function readMsg(lin)
    return {hwnd = rw(lin), msg = rw(lin + 2), wp = rw(lin + 4), lp = rd(lin + 6), time = rd(lin + 10),
            x = s16(rw(lin + 14)), y = s16(rw(lin + 16))}
end
user.writeMsg, user.readMsg = writeMsg, readMsg

local function matches(m, hwnd, lo, hi)
    if hwnd ~= 0 then
        local w = W(m.hwnd)
        local target = W(hwnd)
        if not w or not target or not user.isDescendant(w, target) then return false end
    end
    if lo == 0 and hi == 0 then return true end
    return m.msg >= lo and m.msg <= hi
end

-- Repaints what needs it: frames first, then WM_PAINT for one window
-- (returned as a message), so the program paints in its own loop.
local function findPaint(w, hwnd)
    for _, c in ipairs(w.children) do
        if c.visible and not c.destroyed then
            if c.ncdirty then
                c.ncdirty = false
                user.send(c, WM.NCPAINT, 1, 0)
            end
            if c.upd and #c.upd > 0 and (hwnd == 0 or user.isDescendant(c, W(hwnd) or c)) then
                return c
            end
            local r = findPaint(c, hwnd)
            if r then return r end
        end
    end
end

function user.present()
    if user.dirty then
        fb.clip(nil)
        host.present()
        user.dirty = false
    end
end

-- Turns host events into raw input entries.
-- Scripted input for headless runs (--script file.lua returning steps:
-- {at = ms, ev = {host event}} | {at = ms, shot = "file.bmp"} | {at = ms, fn = function(user) end})
local function runScript()
    local now = host.ticks() - user.started
    while user.script and user.script[1] and now >= user.script[1].at do
        local st = table.remove(user.script, 1)
        if st.ev then user.input[#user.input + 1] = {kind = st.ev[1], e = st.ev, t = host.ticks()} end
        if st.shot then
            user.dirty = true
            user.present()
            local saved = user.overlays
            -- the overlays (open menus) belong in the picture: draw them once more
            if #saved > 0 then
                local base = {}
                for _, o in ipairs(saved) do o.draw() end
                fb.clip(nil)
                fb.save_bmp(0, st.shot)
                user.damage({{0, 0, user.desktop.w, user.desktop.h}})
            else
                fb.clip(nil)
                fb.save_bmp(0, st.shot)
            end
        end
        if st.fn then st.fn(user) end
    end
end

function user.pumpHost(timeout)
    if user.script then runScript() end
    local evs = host.pump(timeout or 0)
    for _, e in ipairs(evs) do
        local k = e[1]
        if k == "quit" then
            user.input[#user.input + 1] = {kind = "close"}
        elseif k == "resize" then
            user.hostResized()
        elseif k == "expose" then
            user.dirty = true
        else
            user.input[#user.input + 1] = {kind = k, e = e, t = host.ticks()}
        end
    end
    if user.exitAfter and host.ticks() - user.started > user.exitAfter then
        local shot = user.cfg.opts.screenshot
        if type(shot) == "string" then
            user.dirty = true
            user.present()
            fb.clip(nil)
            fb.save_bmp(0, shot)
        end
        error({quit = true, code = 0}, 0)
    end
    return #evs
end

function user.hostResized()
    local w, h = host.window_size()
    if not user.appMode or w < 100 or h < 80 then
        user.dirty = true
        return
    end
    -- the screen follows the window, at the scale it was opened with
    local k = user.cfg.opts.scale and tonumber(user.cfg.opts.scale) or 1
    local sw, sh = math.floor(w / k), math.floor(h / k)
    if sw == user.desktop.w and sh == user.desktop.h then user.dirty = true; return end
    fb.resize(0, sw, sh)
    user.desktop.w, user.desktop.h = sw, sh
    user.desktop.cl = {0, 0, sw, sh}
    gdi.screenW, gdi.screenH = sw, sh
    user.fitFrame()
    user.damage({{0, 0, sw, sh}})
end

-- The next message for GetMessage/PeekMessage; wait = block until there is one.
-- Returns the message table, or nil (no message, only when not waiting).
function user.nextMessage(hwnd, lo, hi, remove, wait)
    while true do
        for i, m in ipairs(user.posted) do
            if matches(m, hwnd, lo, hi) then
                if remove then table.remove(user.posted, i) end
                return m
            end
        end
        -- input
        local m = user.inputMessage(hwnd, lo, hi, remove)
        if m then return m end
        if user.quit and (lo == 0 and hi == 0) then
            return {hwnd = 0, msg = WM.QUIT, wp = user.quit, lp = 0, time = host.ticks(), x = 0, y = 0}
        end
        -- paint
        if lo == 0 and hi == 0 or (WM.PAINT >= lo and WM.PAINT <= hi) then
            local p = findPaint(user.desktop, hwnd)
            if p then
                return {hwnd = p.handle, msg = WM.PAINT, wp = 0, lp = 0, time = host.ticks(), x = 0, y = 0}
            end
        end
        -- one-time work for when the program first sits idle (the first-run Setup)
        if wait and user.idle and user.frame and user.frame.visible then
            local f = user.idle
            user.idle = nil
            f()
            goto continue
        end
        user.present()
        if not wait then
            if user.pumpHost(0) == 0 then return nil end
        else
            user.pumpHost(20)
        end
        ::continue::
    end
end

def("USER", 108, "GetMessage", "p h w w", function(lpMsg, hwnd, lo, hi)
    local m = user.nextMessage(hwnd, lo, hi, true, true)
    writeMsg(lpMsg, m)
    if m.msg == WM.QUIT then return 0 end
    return 1
end)

def("USER", 109, "PeekMessage", "p h w w w", function(lpMsg, hwnd, lo, hi, flags)
    local m = user.nextMessage(hwnd, lo, hi, flags & 1 ~= 0, false)
    if not m then return 0 end
    writeMsg(lpMsg, m)
    return 1
end)

def("USER", 110, "PostMessage", "h w w l", function(hwnd, msg, wp, lp)
    if hwnd == 0xFFFF then   -- HWND_BROADCAST
        for _, c in ipairs(user.desktop.children) do user.post(c, msg, wp, lp) end
        return 1
    end
    if hwnd ~= 0 and not W(hwnd) then return 0 end
    return user.post(hwnd, msg, wp, lp)
end)

def("USER", 111, "SendMessage", "h w w l:l", function(hwnd, msg, wp, lp)
    if hwnd == 0xFFFF then
        local list = {}
        for _, c in ipairs(user.desktop.children) do list[#list + 1] = c end
        for _, c in ipairs(list) do user.send(c, msg, wp, lp) end
        return 0
    end
    return user.send(W(hwnd), msg, wp, lp)
end)

def("USER", 6, "PostQuitMessage", "i:v", function(code) user.quit = code & 0xFFFF end)

def("USER", 114, "DispatchMessage", "p:l", function(lpMsg)
    if not lpMsg then return 0 end
    local m = readMsg(lpMsg)
    local w = W(m.hwnd)
    if not w then return 0 end
    if m.msg == WM.TIMER and m.lp ~= 0 then
        return user.callProc(m.lp, m.hwnd, m.msg, m.wp, rd(lpMsg + 10))
    end
    local r = user.send(w, m.msg, m.wp, m.lp)
    if m.msg == WM.PAINT and w.upd and #w.upd > 0 and not w.destroyed then
        -- the program didn't validate: don't repaint forever
        w.upd = nil
    end
    return r
end)

def("USER", 113, "TranslateMessage", "p", function(lpMsg)
    if not lpMsg then return 0 end
    local m = readMsg(lpMsg)
    if m.msg ~= WM.KEYDOWN and m.msg ~= WM.SYSKEYDOWN then return 0 end
    local ch = user.vkToChar(m.wp)
    if ch then
        user.post(m.hwnd, m.msg == WM.KEYDOWN and WM.CHAR or WM.SYSCHAR, ch, m.lp)
        return 1
    end
    return 0
end)

-- The character a key makes, for keys SDL gives no text for: control keys,
-- Ctrl+letters, Alt+letters (WM_SYSCHAR).
function user.vkToChar(vk)
    local ctrl, alt, shift = user.keys[0x11], user.keys[0x12], user.keys[0x10]
    if vk == 0x08 or vk == 0x09 or vk == 0x0D or vk == 0x1B then return vk end
    if alt and not ctrl then
        if vk >= 0x41 and vk <= 0x5A then return shift and vk or (vk + 32) end
        if vk >= 0x30 and vk <= 0x39 then return vk end
        if vk == 0x20 then return 0x20 end
        if vk == 0xBD then return 0x2D end
    end
    if ctrl and not alt and vk >= 0x41 and vk <= 0x5A then return vk - 0x40 end
    return nil
end

-- ---- input --------------------------------------------------------------------------------------------------

-- The deepest visible, enabled window under a screen point, and its hit code.
function user.windowFromPoint(x, y, parent)
    parent = parent or user.desktop
    for _, c in ipairs(parent.children) do
        if c.visible and not c.destroyed then
            local r = user.windowRect(c)
            if x >= r[1] and x < r[3] and y >= r[2] and y < r[4] then
                if c.disabled and c.style & WS.CHILD ~= 0 then return parent, HT.CLIENT end
                local cr = user.clientRect(c)
                if x >= cr[1] and x < cr[3] and y >= cr[2] and y < cr[4] and not c.iconic then
                    local inner, ht = user.windowFromPoint(x, y, c)
                    if inner ~= c then return inner, ht end
                end
                return c
            end
        end
    end
    return parent
end

local lastClick = {time = 0, x = 0, y = 0, w = nil, button = 0}
local DBLCLK_MS = 500

-- The next input event as a Windows message (or nil). Raw input is
-- translated in order; a message PeekMessage looked at without removing it
-- (or that didn't match a filter) waits, already translated, for the next call.
user.translated = {}
function user.inputMessage(hwnd, lo, hi, remove)
    for i, m in ipairs(user.translated) do
        if matches(m, hwnd, lo, hi) then
            if remove then table.remove(user.translated, i) end
            return m
        end
    end
    while #user.input > 0 do
        local ev = table.remove(user.input, 1)
        local m = user.translateInput(ev)
        if m then
            if matches(m, hwnd, lo, hi) then
                if not remove then user.translated[#user.translated + 1] = m end
                return m
            end
            user.translated[#user.translated + 1] = m
        end
    end
end

local function keyFlags()
    local f = 0
    if user.buttons and user.buttons[1] then f = f | 1 end
    if user.buttons and user.buttons[2] then f = f | 2 end
    if user.keys[0x10] then f = f | 4 end
    if user.keys[0x11] then f = f | 8 end
    if user.buttons and user.buttons[3] then f = f | 0x10 end
    return f
end
user.keyFlags = keyFlags
user.buttons = {}

-- Raw mouse/key -> a message for the right window (also sends WM_SETCURSOR
-- and WM_MOUSEACTIVATE as Windows does on the way).
function user.translateInput(ev)
    local now = host.ticks()
    if ev.kind == "close" then
        local f = user.frame
        if f and not f.destroyed then
            if user.modal then return nil end
            return {hwnd = f.handle, msg = WM.SYSCOMMAND, wp = SC.CLOSE, lp = 0, time = now, x = 0, y = 0}
        end
        user.quit = user.quit or 0
        return nil
    end
    if ev.kind == "focus" then
        if ev.e[2] == 0 then user.keys = {} end
        return nil
    end
    if ev.kind == "move" or ev.kind == "down" or ev.kind == "up" or ev.kind == "wheel" then
        local x, y = user.mouseX, user.mouseY
        if ev.kind ~= "wheel" then x, y = ev.e[2], ev.e[3]; user.mouseX, user.mouseY = x, y end
        local button = ev.e[4]
        if ev.kind == "down" then user.buttons[button] = true elseif ev.kind == "up" then user.buttons[button] = false end
        if ev.kind == "wheel" then
            -- the wheel scrolls whatever's under the pointer that has a scroll bar
            local w = user.windowFromPoint(x, y)
            while w and w ~= user.desktop and not (w.vscroll and w.vscroll.visible) do w = w.parent end
            if w and w ~= user.desktop then
                local code = ev.e[2] > 0 and 0 or 1
                for _ = 1, 3 do user.send(w, WM.VSCROLL, code, 0) end
                user.send(w, WM.VSCROLL, 8, 0)
            end
            return nil
        end
        local w, ht
        if user.capture then
            w, ht = user.capture, HT.CLIENT
        else
            w = user.windowFromPoint(x, y)
            if w == user.desktop then return nil end
            ht = s16(user.send(w, WM.NCHITTEST, 0, api.mkpt(x, y)) & 0xFFFF)
            -- a disabled window (behind a dialog) only beeps
            local top = user.topLevel(w)
            if top.disabled then
                if ev.kind == "down" and user.modal then user.activate(user.modal) end
                return nil
            end
            local mm = ev.kind == "move" and WM.MOUSEMOVE or ev.kind == "down" and (button == 1 and WM.LBUTTONDOWN or button == 2 and WM.RBUTTONDOWN or WM.MBUTTONDOWN)
                or (button == 1 and WM.LBUTTONUP or button == 2 and WM.RBUTTONUP or WM.MBUTTONUP)
            user.send(w, WM.SETCURSOR, w.handle, api.mklong(ht & 0xFFFF, mm))
            if ev.kind == "down" then
                local top2 = user.topLevel(w)
                if top2 ~= user.active or (w.style & WS.CHILD ~= 0 and w.parent and w.parent.class and w.parent.class.mdiClient) then
                    local r = user.send(w, WM.MOUSEACTIVATE, top2.handle, api.mklong(ht & 0xFFFF, mm))
                    if r == 1 or r == 2 or r == 0 then
                        if top2 ~= user.active then user.activate(top2) end
                    end
                    if r == 4 or r == 2 then return nil end   -- MA_NOACTIVATEANDEAT / MA_ACTIVATEANDEAT
                end
            end
        end
        local client = ht == HT.CLIENT
        local msg
        if ev.kind == "move" then
            msg = client and WM.MOUSEMOVE or WM.NCMOUSEMOVE
        else
            local base = client and (button == 1 and WM.LBUTTONDOWN or button == 2 and WM.RBUTTONDOWN or WM.MBUTTONDOWN)
                or (button == 1 and WM.NCLBUTTONDOWN or button == 2 and WM.NCRBUTTONDOWN or 0xA7)
            if ev.kind == "up" then msg = base + 1
            else
                msg = base
                -- double clicks: the class must ask for them (non-client ones always come)
                -- timed by when the clicks happened, not when they're handled
                local at = ev.t or now
                local quick = at - lastClick.time < DBLCLK_MS or ((ev.e[5] or 1) >= 2 and lastClick.time > 0)
                if lastClick.w == w and lastClick.button == button and quick and
                    math.abs(x - lastClick.x) <= 4 and math.abs(y - lastClick.y) <= 4 and
                    (not client or (w.class.style or 0) & 0x0008 ~= 0) then
                    msg = base + 2
                    lastClick.time = 0
                else
                    lastClick = {time = ev.t or now, x = x, y = y, w = w, button = button}
                end
            end
        end
        local lp
        if client then
            local ox, oy = user.clientOrigin(w)
            lp = api.mkpt(x - ox, y - oy)
            return {hwnd = w.handle, msg = msg, wp = keyFlags(), lp = lp, time = now, x = x, y = y}
        end
        return {hwnd = w.handle, msg = msg, wp = ht & 0xFFFF, lp = api.mkpt(x, y), time = now, x = x, y = y}
    end
    if ev.kind == "key" then
        local vk, down, rep = ev.e[2], ev.e[3] == 1, ev.e[4] ~= 0
        local wasDown = user.keys[vk]
        user.keys[vk] = down or nil
        if down and not wasDown then user.toggles[vk] = not user.toggles[vk] end
        local alt = user.keys[0x12]
        local sys = (alt and vk ~= 0x12 and not user.keys[0x11]) or vk == 0x79 or (vk == 0x12)
        local msg = down and (sys and WM.SYSKEYDOWN or WM.KEYDOWN) or (sys and WM.SYSKEYUP or WM.KEYUP)
        if vk == 0x12 and not down then msg = WM.SYSKEYUP end
        local target = user.focus or user.active
        if not target then return nil end
        if not user.focus then msg = down and WM.SYSKEYDOWN or WM.SYSKEYUP end
        local lp = 1 | ((ev.e[5] or 0) & 0xFF) << 16
        if alt then lp = lp | 0x20000000 end
        if wasDown then lp = lp | 0x40000000 end
        if not down then lp = lp | 0xC0000000 end
        -- Alt pressed and released alone opens the menu bar
        if vk == 0x12 then
            if down then user.altAlone = true
            elseif user.altAlone then user.altAlone = false; user.altReleased = true end
        elseif down then
            user.altAlone = false
        end
        return {hwnd = target.handle, msg = msg, wp = vk, lp = lp, time = now, x = user.mouseX, y = user.mouseY}
    end
    if ev.kind == "char" then
        if user.keys[0x11] or user.keys[0x12] then return nil end   -- those come from TranslateMessage
        local target = user.focus
        if not target then return nil end
        return {hwnd = target.handle, msg = WM.CHAR, wp = ev.e[2], lp = 1, time = now, x = user.mouseX, y = user.mouseY}
    end
end

-- For modal loops inside USER (menus, moving windows, scroll bars): the next
-- raw input event, painting while waiting.
function user.waitInput(timeout)
    local deadline = timeout and (host.ticks() + timeout)
    while true do
        if #user.input > 0 then return table.remove(user.input, 1) end
        user.pumpHost(0)
        if #user.input > 0 then return table.remove(user.input, 1) end
        -- keep the screen up to date meanwhile
        local p = findPaint(user.desktop, 0)
        if p then
            user.send(p, WM.PAINT, 0, 0)
            if p.upd and #p.upd > 0 then p.upd = nil end
        else
            user.present()
            user.pumpHost(10)
        end
        if deadline and host.ticks() >= deadline then return nil end
    end
end

-- Runs posted messages and paints from inside a Lua modal loop (dialogs).
function user.dispatchOne(m)
    local w = W(m.hwnd)
    if not w then return end
    user.send(w, m.msg, m.wp, m.lp)
    if m.msg == WM.PAINT and w.upd and #w.upd > 0 and not w.destroyed then w.upd = nil end
end

return user

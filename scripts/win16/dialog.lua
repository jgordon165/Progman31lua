-- Dialog boxes: DIALOG templates, DialogBox's modal loop, the dialog
-- manager (Tab, arrows, Enter, Esc, mnemonics), DefDlgProc and MessageBox.
-- Windows 3.1 dialogs are white with gray buttons.

local api = require("win16.api")
local cpu = require("recomp.cpu")
local gdi = require("win16.gdi")
local handles = require("win16.handles")
local res = require("win16.resources")
local user = require("win16.user")

local def = api.def
local WM, WS, COLOR = user.WM, user.WS, user.COLOR
local C, MT = user.sysColors, user.metrics
local W = user.W
local rw, ww, rd, wd = mem.rw, mem.ww, mem.rd, mem.wd
local s16 = api.s16

local DS_SETFONT, DS_MODALFRAME = 0x40, 0x80
local DWL_MSGRESULT, DWL_DLGPROC = 0, 4
local DLGC_WANTARROWS, DLGC_WANTTAB, DLGC_WANTALLKEYS, DLGC_WANTMESSAGE = 1, 2, 4, 4
local DLGC_HASSETSEL, DLGC_DEFPUSHBUTTON, DLGC_UNDEFPUSHBUTTON, DLGC_RADIOBUTTON = 8, 0x10, 0x20, 0x40
local DLGC_WANTCHARS, DLGC_STATIC, DLGC_BUTTON = 0x80, 0x100, 0x2000
local IDOK, IDCANCEL = 1, 2

local dialog = {}

-- ---- templates ------------------------------------------------------------------------------------------

local function cstr(data, at)
    local z = data:find("\0", at, true) or (#data + 1)
    return data:sub(at, z - 1), z + 1
end

local function nameOrOrd(data, at)
    if data:byte(at) == 0xFF then return string.unpack("<I2", data, at + 1), at + 3 end
    return cstr(data, at)
end

local CLASSES = {[0x80] = "BUTTON", [0x81] = "EDIT", [0x82] = "STATIC", [0x83] = "LISTBOX", [0x84] = "SCROLLBAR", [0x85] = "COMBOBOX"}

function dialog.parse(data)
    local t = {}
    t.style, t.count, t.x, t.y, t.cx, t.cy = string.unpack("<I4Bi2i2i2i2", data, 1)
    local at = 14
    t.menu, at = nameOrOrd(data, at)
    t.class, at = nameOrOrd(data, at)
    t.caption, at = cstr(data, at)
    if t.style & DS_SETFONT ~= 0 then
        t.points = string.unpack("<I2", data, at)
        t.face, at = cstr(data, at + 2)
    end
    t.items = {}
    for i = 1, t.count do
        local it = {}
        it.x, it.y, it.cx, it.cy, it.id, it.style = string.unpack("<i2i2i2i2I2I4", data, at)
        at = at + 14
        local c = data:byte(at)
        if c and c >= 0x80 then it.class = CLASSES[c] or "STATIC"; at = at + 1
        else it.class, at = cstr(data, at) end
        if data:byte(at) == 0xFF then
            it.textOrd = string.unpack("<I2", data, at + 1)
            it.text = ""
            at = at + 3
        else
            it.text, at = cstr(data, at)
        end
        local extra = data:byte(at) or 0
        at = at + 1 + extra
        t.items[i] = it
    end
    return t
end

-- Dialog base units for a font: (average width, height), as Windows 3.1 computes them.
local function baseUnits(hfont)
    local dc = {font = hfont}
    local f = gdi.fontObj(dc)
    if not f.rf then return 8, 16 end
    local alpha = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"
    local avg = (fb.text_width(f.rf.fid, alpha, f.bold) // 26 + 1) // 2
    return avg, f.rf.m.height
end
dialog.baseUnits = baseUnits

-- ---- creation ------------------------------------------------------------------------------------------------

local dlgProcFar

local function dlgClass()
    return user.classes["#32770"]
end

-- Creates a dialog from a parsed template. owner: window or nil; proc: far pointer.
function dialog.create(t, owner, proc, param, inst)
    local font
    if t.face then
        local mark = api.mark()
        local _, lf = api.alloc(50)
        ww(lf, (-(t.points * 96 // 72)) & 0xFFFF); ww(lf + 8, 700)
        api.putstr(lf + 18, t.face, 32)
        local cfi = api.byName["GDI.CREATEFONTINDIRECT"]
        font = cfi.fn(lf)
        -- MS Sans Serif 8 in dialogs is bold in Windows 3.1
        api.release(mark)
    end
    local bx, by = baseUnits(font or gdi.stock(13))
    local function px(v) return (v * bx) // 4 end
    local function py(v) return (v * by) // 8 end

    local style = t.style & ~WS.VISIBLE
    local ex = (t.style & DS_MODALFRAME ~= 0) and 1 or 0
    local clsName = (type(t.class) == "string" and t.class ~= "") and t.class or "#32770"
    -- the window's size from the client size
    local cw, ch = px(t.cx), py(t.cy)
    local probe = {style = style, exstyle = ex, w = 0, h = 0, menu = nil}
    local b = (style & WS.THICKFRAME ~= 0) and MT.CXFRAME or ((ex == 1 or (style & WS.CAPTION) == WS.DLGFRAME) and MT.CXDLGFRAME or
        ((style & WS.BORDER ~= 0) and 1 or 0))
    local capH = ((style & WS.CAPTION) == WS.CAPTION) and (MT.CYCAPTION - 1) or 0
    local ww2, wh = cw + 2 * b, ch + 2 * b + capH
    -- position: relative to the owner's client area
    local x, y = px(t.x), py(t.y)
    if owner and style & WS.CHILD == 0 then
        local ox, oy = user.clientOrigin(owner)
        x, y = x + ox, y + oy
    end
    -- keep it on the screen
    x = math.max(0, math.min(x, user.desktop.w - ww2))
    y = math.max(0, math.min(y, user.desktop.h - wh))
    if style & WS.CHILD ~= 0 then x, y = px(t.x), py(t.y) end
    local parentH = owner and owner.handle or nil
    -- the dialog proc comes in through the window's extra bytes, set before WM_CREATE
    user.pendingDlgProc = proc
    local d = user.create(clsName, t.caption, style, x, y, ww2, wh, parentH, 0, inst, param, ex)
    user.pendingDlgProc = nil
    if not d then return nil end
    d.isDialog = true
    d.dlgProc = proc
    d.dlgFont = font
    user.setExtraWord(d, DWL_DLGPROC, proc & 0xFFFF)
    user.setExtraWord(d, DWL_DLGPROC + 2, proc >> 16)
    -- controls
    for _, it in ipairs(t.items) do
        local cstyle = it.style | WS.CHILD
        local text = it.text
        local c = user.create(it.class, text, cstyle & ~WS.VISIBLE, px(it.x), py(it.y), px(it.cx), py(it.cy), d.handle,
                              it.id, inst, 0, 0)
        if c then
            if it.textOrd then
                -- an icon by number
                local m = require("win16.kernel").neModule(inst)
                c.icon = (m and res.moduleIcon(m, it.textOrd)) or res.systemIcon(it.textOrd)
                if c.icon then user.setPos(c, c.x, c.y, MT.CXICON, MT.CYICON) end
            end
            if font then user.send(c, WM.SETFONT, font, 0) end
            if cstyle & WS.VISIBLE ~= 0 then user.setVisible(c, true) end
        end
    end
    if font then d.font = font end
    -- WM_INITDIALOG: TRUE means "set the focus to the first tab stop"
    local first = dialog.nextTab(d, nil, false)
    local r = user.callProc(proc, d.handle, WM.INITDIALOG, first and first.handle or 0, param or 0)
    if d.destroyed then return nil end
    if r ~= 0 and first then
        user.setFocus(first)
        if (user.send(first, WM.GETDLGCODE, 0, 0) & DLGC_HASSETSEL) ~= 0 or first.class.name == "EDIT" then
            user.send(first, 0x401, 0, 0xFFFF0000)  -- EM_SETSEL 0..end
        end
    end
    d.focusSave = user.focus
    if t.style & WS.VISIBLE ~= 0 then user.showWindow(d, 5) end
    return d
end

-- ---- navigation ------------------------------------------------------------------------------------------------

local function controlsOf(d)
    local out = {}
    -- children in creation order: our list is z-order (topmost first), and
    -- controls are created top to bottom, so the creation order is reversed
    for i = #d.children, 1, -1 do out[#out + 1] = d.children[i] end
    return out
end
dialog.controlsOf = controlsOf

local function usable(c) return c.visible and not c.disabled and not c.destroyed end

function dialog.nextTab(d, from, back)
    local list = controlsOf(d)
    local n = #list
    if n == 0 then return nil end
    local idx = 0
    for i, c in ipairs(list) do if c == from then idx = i end end
    for k = 1, n do
        local i
        if back then i = ((idx - 1 - k) % n) + 1 else i = ((idx - 1 + k) % n) + 1 end
        local c = list[i]
        if usable(c) and c.style & WS.TABSTOP ~= 0 then return c end
    end
    -- no tab stops: the first usable control
    for _, c in ipairs(list) do if usable(c) and (c.class.name ~= "STATIC") then return c end end
end

-- the next control of the same group (radio buttons, arrows)
local function nextInGroup(d, from, back)
    local list = controlsOf(d)
    local idx
    for i, c in ipairs(list) do if c == from then idx = i end end
    if not idx then return nil end
    -- the group: from the WS_GROUP control before, to the one before the next WS_GROUP
    local s = idx
    while s > 1 and list[s].style & WS.GROUP == 0 do s = s - 1 end
    local e = idx
    while e < #list and list[e + 1].style & WS.GROUP == 0 do e = e + 1 end
    local n = e - s + 1
    for k = 1, n do
        local i = back and (((idx - s - k) % n) + s) or (((idx - s + k) % n) + s)
        if usable(list[i]) then return list[i] end
    end
end

local function defButton(d)
    for _, c in ipairs(controlsOf(d)) do
        if c.class.name == "BUTTON" and (c.style & 0xF) == 1 and usable(c) then return c end
    end
end

local function clickButton(d, id, c)
    if c and c.class.name == "BUTTON" then
        user.controls.buttonClick(c)
    else
        user.send(d, WM.COMMAND, id, api.mklong(c and c.handle or 0, 0))
    end
end

-- Moves the focus to a control, making the default push button follow it.
local function focusCtl(d, c)
    if not c then return end
    user.setFocus(c)
    local code = user.send(c, WM.GETDLGCODE, 0, 0)
    if code & DLGC_HASSETSEL ~= 0 then user.send(c, 0x401, 0, 0xFFFF0000) end
    -- a focused push button is the default; otherwise the template's default
    for _, b in ipairs(controlsOf(d)) do
        if b.class.name == "BUTTON" and ((b.style & 0xF) == 0 or (b.style & 0xF) == 1) then
            local want = (b == c) and 1 or ((code & (DLGC_DEFPUSHBUTTON | DLGC_UNDEFPUSHBUTTON) ~= 0) and 0 or (b.origDefault and 1 or 0))
            if not b.origDefaultSet then b.origDefault = (b.style & 0xF) == 1; b.origDefaultSet = true end
            if (b.style & 0xF) ~= want then
                b.style = (b.style & ~0xF) | want
                user.invalidate(b, nil, true)
            end
        end
    end
end
dialog.focusCtl = focusCtl

-- IsDialogMessage: returns true when the dialog manager used the message.
function dialog.isDialogMessage(d, m)
    local target = W(m.hwnd)
    if not target or not user.isDescendant(target, d) then return false end
    local msg = m.msg
    if msg ~= WM.KEYDOWN and msg ~= WM.CHAR and msg ~= WM.SYSCHAR and msg ~= WM.SYSKEYDOWN then return false end
    local code = 0
    if target ~= d then code = user.send(target, WM.GETDLGCODE, m.wp, 0) end
    if msg == WM.KEYDOWN then
        local vk = m.wp
        if vk == 0x09 and code & (DLGC_WANTTAB | DLGC_WANTALLKEYS) == 0 then
            focusCtl(d, dialog.nextTab(d, user.focus, user.keys[0x10]))
            return true
        elseif (vk >= 0x25 and vk <= 0x28) and code & (DLGC_WANTARROWS | DLGC_WANTALLKEYS) == 0 then
            local back = vk == 0x25 or vk == 0x26
            local c = nextInGroup(d, user.focus, back)
            if c and c ~= user.focus then
                focusCtl(d, c)
                if c.class.name == "BUTTON" and ((c.style & 0xF) == 9) then user.controls.buttonClick(c) end
            end
            return true
        elseif vk == 0x0D and code & DLGC_WANTALLKEYS == 0 then
            local f = user.focus
            if f and f.class.name == "BUTTON" and ((f.style & 0xF) <= 1) and usable(f) then clickButton(d, f.id, f); return true end
            local defid = user.send(d, 0x400, 0, 0)   -- DM_GETDEFID
            local id = (defid >> 16) == 0x534B and (defid & 0xFFFF) or nil
            local b = defButton(d)
            if id then
                local c
                for _, x in ipairs(controlsOf(d)) do if x.id == id then c = x end end
                if c and usable(c) then clickButton(d, id, c) elseif not c then user.send(d, WM.COMMAND, id, 0) end
            elseif b then clickButton(d, b.id, b)
            else user.send(d, WM.COMMAND, IDOK, 0) end
            return true
        elseif vk == 0x1B and code & DLGC_WANTALLKEYS == 0 then
            local cancel
            for _, x in ipairs(controlsOf(d)) do if x.id == IDCANCEL then cancel = x end end
            if cancel and cancel.disabled then return true end
            user.send(d, WM.COMMAND, IDCANCEL, api.mklong(cancel and cancel.handle or 0, 0))
            return true
        end
        user.translateAndDispatch(m)
        return true
    elseif msg == WM.CHAR or msg == WM.SYSCHAR then
        if msg == WM.CHAR and code & (DLGC_WANTCHARS | DLGC_WANTALLKEYS) ~= 0 then return false end
        if m.wp < 0x20 then return msg == WM.CHAR and (m.wp == 0x09 or m.wp == 0x0D or m.wp == 0x1B) end
        local ch = string.char(m.wp):upper()
        local list = controlsOf(d)
        local start = 0
        for i, c in ipairs(list) do if c == user.focus then start = i end end
        for k = 1, #list do
            local i = ((start - 1 + k) % #list) + 1
            local c = list[i]
            if c.visible and c.text ~= "" then
                local text, ul = user.stripPrefix(c.text)
                if ul and text:sub(ul, ul):upper() == ch then
                    if c.class.name == "STATIC" then
                        -- a label: the control after it
                        local nxt = list[i + 1]
                        while nxt and not usable(nxt) do i = i + 1; nxt = list[i + 1] end
                        if nxt then focusCtl(d, nxt) end
                    elseif usable(c) then
                        focusCtl(d, c)
                        if c.class.name == "BUTTON" then
                            local t = c.style & 0xF
                            if t ~= 7 then user.controls.buttonClick(c) end
                        end
                    end
                    return true
                end
            end
        end
        return msg == WM.SYSCHAR
    end
    return false
end

-- ---- DefDlgProc (the #32770 class) ----------------------------------------------------------------------------------

local function callDlg(d, msg, wp, lp)
    local proc = d.dlgProc or user.pendingDlgProc
    if not proc or proc == 0 then return 0 end
    user.setExtraWord(d, DWL_MSGRESULT, 0)
    user.setExtraWord(d, DWL_MSGRESULT + 2, 0)
    return user.callProc(proc, d.handle, msg, wp, lp) & 0xFFFF
end

local RETURNS_VALUE = {[WM.CTLCOLOR] = true, [0x39] = true, [WM.VKEYTOITEM] = true, [WM.CHARTOITEM] = true,
                       [WM.QUERYDRAGICON] = true, [WM.INITDIALOG] = true}

local function defDlg(hwnd, msg, wp, lp)
    local d = W(hwnd)
    if not d then return 0 end
    if not d.dlgProc and user.pendingDlgProc then d.dlgProc = user.pendingDlgProc end
    local r = 0
    if msg ~= WM.NCCREATE and msg ~= WM.NCDESTROY then r = callDlg(d, msg, wp, lp) end
    if d.destroyed and msg ~= WM.DESTROY then return r end
    if RETURNS_VALUE[msg] then
        if r ~= 0 or msg == WM.INITDIALOG then return r end
    elseif r ~= 0 then
        return user.extraWord(d, DWL_MSGRESULT) | (user.extraWord(d, DWL_MSGRESULT + 2) << 16)
    end
    -- the defaults
    if msg == WM.ERASEBKGND then
        local dc = gdi.dc(wp)
        if dc then
            local b = user.send(d, WM.CTLCOLOR, wp, api.mklong(d.handle, 4)) & 0xFFFF
            if b == 0 or not handles.get(b, "brush") then b = user.sysBrush(COLOR.WINDOW) end
            user.fillRect(dc, {0, 0, d.cl[3] - d.cl[1], d.cl[4] - d.cl[2]}, b)
        end
        return 1
    elseif msg == WM.CLOSE then
        local cancel
        for _, c in ipairs(controlsOf(d)) do if c.id == IDCANCEL then cancel = c end end
        if not cancel or not cancel.disabled then
            user.post(d, WM.COMMAND, IDCANCEL, api.mklong(cancel and cancel.handle or 0, 0))
        end
        return 0
    elseif msg == WM.SETFOCUS then
        local f = d.focusSave
        if f and not f.destroyed and user.isDescendant(f, d) then user.setFocus(f)
        else
            local c = dialog.nextTab(d, nil, false)
            if c then user.setFocus(c) end
        end
        return 0
    elseif msg == WM.ACTIVATE then
        if (wp & 0xFFFF) == 0 then
            if user.focus and user.isDescendant(user.focus, d) then d.focusSave = user.focus end
        else
            local f = d.focusSave
            if f and not f.destroyed and user.isDescendant(f, d) then user.setFocus(f) end
        end
        return 0
    elseif msg == WM.CTLCOLOR then
        local dc = gdi.dc(wp)
        if dc then dc.text = C[COLOR.WINDOWTEXT]; dc.bk = C[COLOR.WINDOW] end
        return user.sysBrush(COLOR.WINDOW)
    elseif msg == 0x400 then   -- DM_GETDEFID
        local b = defButton(d)
        if d.defId then return api.mklong(d.defId, 0x534B) end
        return b and api.mklong(b.id, 0x534B) or 0
    elseif msg == 0x401 then   -- DM_SETDEFID
        d.defId = wp
        return 1
    elseif msg == WM.NEXTDLGCTL then
        local c
        if lp & 0xFFFF ~= 0 then c = W(wp) else c = dialog.nextTab(d, user.focus, wp ~= 0) end
        focusCtl(d, c)
        return 0
    elseif msg == WM.GETDLGCODE then
        return 0
    end
    return user.defwnd.proc(hwnd, msg, wp, lp)
end

user.registerClass({name = "#32770", style = 0x0008, proc = user.luaProc("DefDlgProc", defDlg), wndExtra = 30,
                    cursor = res.cursor(32512)})
def("USER", 308, "DefDlgProc", "h w w l:l", function(h, m, wp, lp) return defDlg(h, m, wp, lp) end)

-- ---- the modal loop ------------------------------------------------------------------------------------------

function user.translateAndDispatch(m)
    local w = W(m.hwnd)
    if not w then return end
    if m.msg == WM.KEYDOWN or m.msg == WM.SYSKEYDOWN then
        local ch = user.vkToChar(m.wp)
        if ch then user.post(m.hwnd, m.msg == WM.KEYDOWN and WM.CHAR or WM.SYSCHAR, ch, m.lp) end
    end
    user.dispatchOne(m)
end

function dialog.runModal(d, owner)
    local prevModal = user.modal
    user.modal = d
    d.owner = d.owner or owner
    if owner then
        owner.disabled = true
        d.disabledOwner = owner
    end
    if not d.visible then user.showWindow(d, 5) end
    user.activate(d)
    local result = 0
    while not d.ended and not d.destroyed do
        local m = user.nextMessage(0, 0, 0, true, true)
        if m.msg == WM.QUIT then
            user.quit = m.wp
            break
        end
        local handled = false
        if user.hooks[-1] then
            local mark = api.mark()
            local fp, lin = api.alloc(18)
            user.writeMsg(lin, m)
            handled = user.callMsgFilter(0, fp)   -- MSGF_DIALOGBOX
            api.release(mark)
        end
        if not handled and not dialog.isDialogMessage(d, m) then
            user.translateAndDispatch(m)
        end
    end
    result = d.result or 0
    if owner then owner.disabled = false end
    user.modal = prevModal
    if not d.destroyed then user.destroy(d) end
    if owner and not owner.destroyed then user.activate(owner) end
    return result
end

def("USER", 87, "DialogBox", "h r h f", function(inst, name, hparent, proc)
    local m = require("win16.kernel").neModule(inst)
    local data = m and m:resource(5, name)
    if not data then return 0xFFFF end
    local owner = W(hparent)
    if owner then owner = user.topLevel(owner) end
    local t = dialog.parse(data)
    local d = dialog.create(t, owner, proc, 0, inst)
    if not d then return 0xFFFF end
    return dialog.runModal(d, owner)
end)
def("USER", 239, "DialogBoxParam", "h r h f l", function(inst, name, hparent, proc, param)
    local m = require("win16.kernel").neModule(inst)
    local data = m and m:resource(5, name)
    if not data then return 0xFFFF end
    local owner = W(hparent)
    if owner then owner = user.topLevel(owner) end
    local d = dialog.create(dialog.parse(data), owner, proc, param, inst)
    if not d then return 0xFFFF end
    return dialog.runModal(d, owner)
end)
def("USER", 89, "CreateDialog", "h r h f", function(inst, name, hparent, proc)
    local m = require("win16.kernel").neModule(inst)
    local data = m and m:resource(5, name)
    if not data then return 0 end
    local d = dialog.create(dialog.parse(data), W(hparent), proc, 0, inst)
    return d and d.handle or 0
end)
def("USER", 88, "EndDialog", "h i:v", function(h, result)
    local d = W(h)
    if d then d.ended = true; d.result = result & 0xFFFF end
end)
def("USER", 90, "IsDialogMessage", "h p", function(h, lpMsg)
    local d = W(h)
    if not d or not lpMsg then return 0 end
    return dialog.isDialogMessage(d, user.readMsg(lpMsg))
end)

-- ---- dialog items ------------------------------------------------------------------------------------------------

local function item(h, id)
    local d = W(h)
    if not d then return nil end
    for _, c in ipairs(d.children) do if c.id == id then return c end end
end
dialog.item = item

def("USER", 91, "GetDlgItem", "h i", function(h, id) local c = item(h, id & 0xFFFF); return c and c.handle or 0 end)
-- (GetDlgCtrlID is USER 277; 95 is GetDlgItemInt)
def("USER", 95, "GetDlgItemInt", "h i f w", function(h, id, fpOk, signed)
    local c = item(h, id & 0xFFFF)
    local okp = cpu.flat(fpOk)
    local text = c and c.text or ""
    local n = tonumber(text:match("^%s*([%+%-]?%d+)%s*$") or "")
    local ok = n ~= nil and (signed ~= 0 and n >= -32768 and n <= 32767 or signed == 0 and n >= 0 and n <= 65535)
    if okp then mem.ww(okp, ok and 1 or 0) end
    if not ok then return 0 end
    return n & 0xFFFF
end)
def("USER", 92, "SetDlgItemText", "h i f:v", function(h, id, fp)
    local c = item(h, id & 0xFFFF)
    if c then user.send(c, WM.SETTEXT, 0, fp) end
end)
def("USER", 93, "GetDlgItemText", "h i f i", function(h, id, fp, n)
    local c = item(h, id & 0xFFFF)
    if not c then local l = cpu.flat(fp); if l and n > 0 then mem.wb(l, 0) end return 0 end
    return user.send(c, WM.GETTEXT, n, fp)
end)
def("USER", 94, "SetDlgItemInt", "h i w w:v", function(h, id, v, signed)
    local c = item(h, id & 0xFFFF)
    if not c then return end
    local s = tostring(signed ~= 0 and s16(v) or v)
    local mark = api.mark()
    user.send(c, WM.SETTEXT, 0, (api.str(s)))
    api.release(mark)
end)
def("USER", 96, "CheckRadioButton", "h i i i:v", function(h, first, last, check)
    for id = first, last do
        local c = item(h, id)
        if c then user.send(c, 0x401, id == check and 1 or 0, 0) end
    end
end)
def("USER", 97, "CheckDlgButton", "h i w:v", function(h, id, v)
    local c = item(h, id & 0xFFFF)
    if c then user.send(c, 0x401, v, 0) end
end)
def("USER", 98, "IsDlgButtonChecked", "h i", function(h, id)
    local c = item(h, id & 0xFFFF)
    return c and user.send(c, 0x400, 0, 0) or 0
end)
def("USER", 101, "SendDlgItemMessage", "h i w w l:l", function(h, id, msg, wp, lp)
    local c = item(h, id & 0xFFFF)
    return c and user.send(c, msg, wp, lp) or 0
end)
def("USER", 227, "GetNextDlgGroupItem", "h h w", function(h, hc, prev)
    local d, c = W(h), W(hc)
    local n = d and c and nextInGroup(d, c, prev ~= 0)
    return n and n.handle or hc
end)
def("USER", 228, "GetNextDlgTabItem", "h h w", function(h, hc, prev)
    local d = W(h)
    local n = d and dialog.nextTab(d, W(hc), prev ~= 0)
    return n and n.handle or 0
end)
def("USER", 103, "MapDialogRect", "h p:v", function(h, prc)
    local d = W(h)
    if not d or not prc then return end
    local bx, by = baseUnits(d.dlgFont or gdi.stock(13))
    local r = api.getrect(prc)
    api.setrect(prc, {r[1] * bx // 4, r[2] * by // 8, r[3] * bx // 4, r[4] * by // 8})
end)

-- ---- MessageBox --------------------------------------------------------------------------------------------------

local BUTTONSETS = {
    [0] = {{1, "OK"}}, {{1, "OK"}, {2, "Cancel"}}, {{3, "&Abort"}, {4, "&Retry"}, {5, "&Ignore"}},
    {{6, "&Yes"}, {7, "&No"}, {2, "Cancel"}}, {{6, "&Yes"}, {7, "&No"}}, {{4, "&Retry"}, {2, "Cancel"}},
}
local ICONS = {[0x10] = 32513, [0x20] = 32514, [0x30] = 32515, [0x40] = 32516}

local msgboxProc = user.luaProc("MessageBoxProc", function(h, msg, wp, lp)
    if msg == WM.COMMAND then
        local d = W(h)
        if d and (lp >> 16) == 0 then
            local id = wp
            if id == 2 and not d.hasCancel then
                if d.single then id = d.single else return 1 end
            end
            d.ended = true
            d.result = id
        end
        return 1
    end
    return 0
end)

function user.messageBox(owner, text, caption, kind)
    local set = BUTTONSETS[kind & 0xF] or BUTTONSETS[0]
    local font = gdi.stock(13)
    local dcf = {font = font}
    local bx, by = baseUnits(font)
    local icon = ICONS[kind & 0xF0]
    local iconW = icon and (MT.CXICON + 16) or 0
    local maxText = math.floor(user.desktop.w * 0.6)
    local _, rc = user.drawText(dcf, text, {0, 0, maxText, 0}, 0x10 | 0x400)
    local tw, th = rc[3] - rc[1], rc[4] - rc[2]
    local btnW, btnH, gap = math.max(bx * 10, 56), by + 10, bx * 2
    local rowW = #set * btnW + (#set - 1) * gap
    local cw = math.max(tw + iconW + 2 * bx * 2, rowW + 2 * bx * 2)
    local bodyH = math.max(th, icon and MT.CYICON or 0)
    local ch = by + bodyH + by + btnH + by
    local capH = MT.CYCAPTION - 1
    local b = MT.CXDLGFRAME
    local ww2, wh = cw + 2 * b, ch + 2 * b + capH
    local x, y = (user.desktop.w - ww2) // 2, (user.desktop.h - wh) // 2
    local style = WS.POPUP | WS.CAPTION | WS.SYSMENU | 0x80
    local mark = api.mark()
    user.pendingDlgProc = msgboxProc
    -- system-modal (and ownerless) boxes stay above everything
    local ex = 1
    if kind & 0x1000 ~= 0 or not owner then ex = ex | 8 end
    local d = user.create("#32770", caption or "Error", style, x, y, ww2, wh, owner and owner.handle or nil, 0, 0, 0, ex)
    user.pendingDlgProc = nil
    if not d then api.release(mark); return 1 end
    d.dlgProc = msgboxProc
    d.isDialog = true
    for _, s in ipairs(set) do if s[1] == 2 then d.hasCancel = true end end
    if #set == 1 then d.single = set[1][1]; d.hasCancel = true end
    if icon then
        local ic = user.create("STATIC", "", WS.CHILD | WS.VISIBLE | 3, bx * 2, by, MT.CXICON, MT.CYICON, d.handle, 0xFFFF, 0, 0, 0)
        if ic then ic.icon = res.systemIcon(icon) end
    end
    local tx = bx * 2 + iconW
    user.create("STATIC", text, WS.CHILD | WS.VISIBLE | 0x80, tx, by + math.max((bodyH - th) // 2, 0), tw + 2, th, d.handle, 0xFFFF, 0, 0, 0)
    local defIdx = ((kind >> 8) & 0xF) + 1
    local bx0 = (cw - rowW) // 2
    local firstBtn
    for i, s in ipairs(set) do
        local bstyle = WS.CHILD | WS.VISIBLE | WS.TABSTOP | (i == 1 and WS.GROUP or 0) | (i == defIdx and 1 or 0)
        local btn = user.create("BUTTON", s[2], bstyle, bx0 + (i - 1) * (btnW + gap), by + bodyH + by, btnW, btnH, d.handle, s[1], 0, 0, 0)
        if i == defIdx then firstBtn = btn end
    end
    api.release(mark)
    user.showWindow(d, 5)
    if firstBtn then user.setFocus(firstBtn) end
    host.beep()
    return dialog.runModal(d, owner)
end

def("USER", 1, "MessageBox", "h s s w", function(h, text, caption, kind)
    local owner = W(h)
    if owner then owner = user.topLevel(owner) end
    return user.messageBox(owner, text or "", caption, kind)
end)

user.dialog = dialog
return dialog

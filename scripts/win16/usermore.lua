-- More of USER, for Control Panel and its applets: capture, properties,
-- dialogs from memory, system colours and mouse settings, bitmaps from
-- resources, directory lists, and the network, comm and driver calls
-- (answered as a machine without them).

local api = require("win16.api")
local cpu = require("recomp.cpu")
local gdi = require("win16.gdi")
local handles = require("win16.handles")
local kernel = require("win16.kernel")
local dosfs = require("win16.dosfs")
local profile = require("win16.profile")
local user = require("win16.user")
local dialog = require("win16.dialog")

local def = api.def
local WM = user.WM
local W = user.W
local C = user.sysColors
local rw, ww, rd, wd, rb, wb = mem.rw, mem.ww, mem.rd, mem.wd, mem.rb, mem.wb
local s16 = api.s16
local getrect = api.getrect

local function hw(w) return w and w.handle or 0 end

-- ---- capture ------------------------------------------------------------------------------------

def("USER", 18, "SetCapture", "h", function(h)
    local old = user.capture
    user.capture = W(h)
    return hw(old)
end)
def("USER", 19, "ReleaseCapture", ":v", function() user.capture = nil end)
def("USER", 236, "GetCapture", "", function() return hw(user.capture) end)
def("USER", 16, "ClipCursor", "p:v", function() end)
def("USER", 119, "GetMessagePos", ":l", function()
    return (((user.mouseY or 0) & 0xFFFF) << 16) | ((user.mouseX or 0) & 0xFFFF)
end)
def("USER", 249, "GetAsyncKeyState", "i", function(vk)
    if vk == 1 then return user.buttons[user.swapped and 2 or 1] and 0x8000 or 0 end
    if vk == 2 then return user.buttons[user.swapped and 1 or 2] and 0x8000 or 0 end
    if vk == 4 then return user.buttons[3] and 0x8000 or 0 end
    return user.keys[vk] and 0x8000 or 0
end)

-- ---- windows -------------------------------------------------------------------------------------

def("USER", 58, "GetClassName", "h p i", function(h, buf, n)
    local w = W(h)
    if not w or not w.class then return 0 end
    return api.putstr(buf, w.class.name, n)
end)
def("USER", 131, "GetClassLong", "h i:l", function(h, i)
    local w = W(h)
    if not w or not w.class then return 0 end
    if i == -24 then return w.class.proc or 0 end   -- GCL_WNDPROC
    if i == -8 then return w.class.menuNameFp or 0 end
    return 0
end)
def("USER", 277, "GetDlgCtrlID", "h", function(h)
    local w = W(h)
    return w and w.id or 0
end)
def("USER", 191, "ChildWindowFromPoint", "h l", function(h, pt)
    local w = W(h)
    if not w then return 0 end
    local x, y = s16(pt & 0xFFFF), s16(pt >> 16)
    for i = #w.children, 1, -1 do
        local c = w.children[i]
        if c.visible and not c.destroyed and x >= c.x and y >= c.y and x < c.x + c.w and y < c.y + c.h then return c.handle end
    end
    if x >= 0 and y >= 0 and x < (w.cl[3] - w.cl[1]) and y < (w.cl[4] - w.cl[2]) then return h end
    return 0
end)
def("USER", 190, "GetUpdateRect", "h p w", function(h, prc)
    local w = W(h)
    if not w then return 0 end
    local upd = w.upd
    if not upd or #upd == 0 then
        if prc then api.setrect(prc, {0, 0, 0, 0}) end
        return 0
    end
    local b = require("win16.region").bounds(upd)
    if prc then api.setrect(prc, b) end
    return 1
end)
def("USER", 122, "CallWindowProc", "f h w w l:l", function(proc, h, msg, wp, lp)
    return user.callProc(proc, h, msg, wp, lp)
end)
def("USER", 189, "GetSysModalWindow", "", function() return 0 end)

-- ---- properties ------------------------------------------------------------------------------------

local function propKey(name)
    if type(name) == "number" then return "#" .. name end
    return name and name:upper() or ""
end
def("USER", 26, "SetProp", "h r h", function(h, name, v)
    local w = W(h)
    if not w then return 0 end
    w.props[propKey(name)] = v
    return 1
end)
def("USER", 25, "GetProp", "h r", function(h, name)
    local w = W(h)
    return w and w.props[propKey(name)] or 0
end)
def("USER", 24, "RemoveProp", "h r", function(h, name)
    local w = W(h)
    if not w then return 0 end
    local k = propKey(name)
    local v = w.props[k]
    w.props[k] = nil
    return v or 0
end)

-- ---- rectangles ---------------------------------------------------------------------------------------

def("USER", 244, "EqualRect", "p p", function(a, b)
    local r, s = getrect(a), getrect(b)
    if not r or not s then return 0 end
    return r[1] == s[1] and r[2] == s[2] and r[3] == s[3] and r[4] == s[4]
end)
def("USER", 83, "FrameRect", "h p h", function(hdc, prc, hbr)
    local dc = gdi.dc(hdc)
    local r = getrect(prc)
    local b = handles.get(user.brushFor(hbr) or hbr)
    if not dc or not r or not b or b.kind ~= "brush" or b.null then return 0 end
    if not gdi.useClip(dc) then return 1 end
    local c = gdi.fbBrush(b)
    local x0, y0, x1, y1 = r[1] + dc.ox, r[2] + dc.oy, r[3] + dc.ox, r[4] + dc.oy
    fb.patblt(dc.surface, x0, y0, x1 - x0, 1, 0xF0, c)
    fb.patblt(dc.surface, x0, y1 - 1, x1 - x0, 1, 0xF0, c)
    fb.patblt(dc.surface, x0, y0, 1, y1 - y0, 0xF0, c)
    fb.patblt(dc.surface, x1 - 1, y0, 1, y1 - y0, 0xF0, c)
    user.dirty = true
    return 1
end)
def("USER", 82, "InvertRect", "h p:v", function(hdc, prc)
    local dc = gdi.dc(hdc)
    local r = getrect(prc)
    if not dc or not r or not gdi.useClip(dc) then return end
    fb.patblt(dc.surface, r[1] + dc.ox, r[2] + dc.oy, r[3] - r[1], r[4] - r[2], 0x55, 0)
    user.dirty = true
end)

-- ---- bitmaps --------------------------------------------------------------------------------------------

-- LoadBitmap: a BITMAP resource of the module (or one of the system's OBM_
-- bitmaps from the display driver when inst is 0)
def("USER", 175, "LoadBitmap", "h r", function(inst, name)
    local m
    if inst == 0 then m = require("win16").state.sys.display
    else m = kernel.neModule(inst) end
    local data = m and m:resource(2, name)
    if not data then return 0 end
    return gdi.bitmapFromDib(data)
end)

-- ---- system colours and settings -----------------------------------------------------------------------------

-- [colors] in WIN.INI, by COLOR_ index
user.colorNames = {[0] = "Scrollbar", "Background", "ActiveTitle", "InactiveTitle", "Menu", "Window", "WindowFrame",
    "MenuText", "WindowText", "TitleText", "ActiveBorder", "InactiveBorder", "AppWorkspace", "Hilight",
    "HilightText", "ButtonFace", "ButtonShadow", "GrayText", "ButtonText", "InactiveTitleText", "ButtonHilight"}

-- Everything is drawn again in the new colours.
function user.colorsChanged()
    if user.resetSysBrushes then user.resetSysBrushes() end
    local function all(w)
        for _, c in ipairs(w.children) do
            c.ncdirty = true
            all(c)
        end
    end
    all(user.desktop)
    user.damage({{0, 0, user.desktop.w, user.desktop.h}})
    for _, c in ipairs({table.unpack(user.desktop.children)}) do
        if not c.destroyed then user.send(c, 0x15, 0, 0) end   -- WM_SYSCOLORCHANGE
    end
end

function user.loadColors()
    local ini = profile.resolve(nil)
    for i, name in pairs(user.colorNames) do
        local v = profile.get(ini, "colors", name)
        local r, g, b = (v or ""):match("^%s*(%d+)%s+(%d+)%s+(%d+)")
        -- (older Progman31lua wrote GrayText as 192 192 192, which isn't Windows' own default)
        if name == "GrayText" and v:match("^192 192 192%s*$") then r = nil end
        if r then C[i] = (tonumber(r) << 16) | (tonumber(g) << 8) | tonumber(b) end
    end
end

def("USER", 181, "SetSysColors", "i p p:v", function(n, pIdx, pVal)
    if not pIdx or not pVal then return end
    for i = 0, n - 1 do
        local idx = rw(pIdx + i * 2)
        if C[idx] then C[idx] = gdi.color(rd(pVal + i * 4)) end
    end
    user.colorsChanged()
end)

user.swapped = false
def("USER", 186, "SwapMouseButton", "w", function(swap)
    local old = user.swapped
    user.swapped = swap ~= 0
    return old
end)
def("USER", 20, "SetDoubleClickTime", "w:v", function(ms) user.doubleClickTime = ms end)
def("USER", 21, "GetDoubleClickTime", "", function() return user.doubleClickTime or 500 end)
def("USER", 168, "SetCaretBlinkTime", "w:v", function(ms) user.caretBlink = ms end)
def("USER", 169, "GetCaretBlinkTime", "", function() return user.caretBlink or 530 end)

-- ---- dialogs from memory ---------------------------------------------------------------------------------------

-- The bytes of a dialog template in memory: enough of them for the parser
-- (templates are small; a global block's size bounds it when known).
local function templateBytes(lin, hmem)
    local n = 4096
    local g = hmem and kernel.global(hmem)
    if g then n = math.min(n, g.size) end
    return mem.read(lin, n)
end

def("USER", 240, "DialogBoxIndirectParam", "h h h f l", function(inst, hTemplate, hparent, proc, param)
    local lin = kernel.glin(hTemplate)
    if not lin then return 0xFFFF end
    local owner = W(hparent)
    if owner then owner = user.topLevel(owner) end
    local d = dialog.create(dialog.parse(templateBytes(lin, hTemplate)), owner, proc, param, inst)
    if not d then return 0xFFFF end
    return dialog.runModal(d, owner)
end)
def("USER", 219, "DialogBoxIndirect", "h h h f", function(inst, hTemplate, hparent, proc)
    return api.byOrd.USER[240].fn(inst, hTemplate, hparent, proc, 0)
end)
def("USER", 242, "CreateDialogIndirectParam", "h f h f l", function(inst, tmpl, hparent, proc, param)
    local lin = cpu.flat(tmpl)
    if not lin then return 0 end
    local d = dialog.create(dialog.parse(templateBytes(lin)), W(hparent), proc, param, inst)
    return d and d.handle or 0
end)
def("USER", 243, "GetDialogBaseUnits", ":l", function()
    local f = gdi.fontObj({font = gdi.stock(13)})
    local h = f and f.rf and f.rf.m.height or 16
    return (h << 16) | 8
end)

-- ---- directory lists ---------------------------------------------------------------------------------------------

-- The entries a directory list shows for a spec: files (lower case), then
-- [directories], then [-c-] drives, as attributes ask (0x10 directories,
-- 0x4000 drives, 0x8000 exclusive: no files).
function user.dirEntries(spec, attr)
    local full = dosfs.full(spec or "*.*")
    local dir = full:match("^(.*)\\[^\\]*$") or dosfs.windows
    local out = {}
    if attr & 0x8000 == 0 then
        local names = {}
        for _, e in ipairs(dosfs.find(full) or {}) do
            if not e.dir then names[#names + 1] = e.name:lower() end
        end
        table.sort(names)
        for _, n in ipairs(names) do out[#out + 1] = n end
    end
    if attr & 0x10 ~= 0 then
        local dirs = {}
        for _, e in ipairs(dosfs.find(dir .. "\\*.*") or {}) do
            if e.dir and e.name ~= "." then dirs[#dirs + 1] = "[" .. e.name:lower() .. "]" end
        end
        table.sort(dirs)
        for _, n in ipairs(dirs) do out[#out + 1] = n end
    end
    if attr & 0x4000 ~= 0 then out[#out + 1] = "[-c-]" end
    return out
end

-- Fills a list box (or combo box) with the files matching a spec;
-- attributes: 0x10 directories, 0x4000 drives, 0x8000 exclusive.
local function dirList(h, spec, id, staticId, attr, combo)
    local d = W(h)
    if not d then return 0 end
    local function child(cid)
        for _, c in ipairs(d.children) do if c.id == cid then return c end end
    end
    local list = id ~= 0 and child(id)
    -- Windows 3.1's list and combo box messages (WM_USER based)
    local reset, add = combo and 0x40B or 0x405, combo and 0x403 or 0x401
    local full = dosfs.full(spec or "*.*")
    local dir = full:match("^(.*)\\[^\\]*$") or dosfs.windows
    if list then
        user.send(list, reset, 0, 0)
        local mark = api.mark()
        for _, n in ipairs(user.dirEntries(spec, attr)) do user.send(list, add, 0, (api.str(n))) end
        api.release(mark)
    end
    local st = staticId ~= 0 and child(staticId)
    if st then
        local mark = api.mark()
        user.send(st, WM.SETTEXT, 0, (api.str(dir:lower())))
        api.release(mark)
    end
    return 1
end
def("USER", 100, "DlgDirList", "h p i i w", function(h, lpSpec, id, staticId, attr)
    return dirList(h, lpSpec and mem.cstr(lpSpec), id, staticId, attr, false)
end)
def("USER", 195, "DlgDirListComboBox", "h p i i w", function(h, lpSpec, id, staticId, attr)
    return dirList(h, lpSpec and mem.cstr(lpSpec), id, staticId, attr, true)
end)
local function dirSelect(h, buf, id, combo)
    local d = W(h)
    if not d then return 0 end
    local list
    for _, c in ipairs(d.children) do if c.id == id then list = c end end
    if not list or not buf then return 0 end
    local sel = user.send(list, combo and 0x407 or 0x409, 0, 0)
    if sel == 0xFFFF or sel == 0xFFFFFFFF then return 0 end
    local mark = api.mark()
    local fp, lin = api.alloc(260)
    user.send(list, combo and 0x408 or 0x40A, sel, fp)
    local s = mem.cstr(lin)
    api.release(mark)
    local isDir = s:match("^%[(.*)%]$")
    if isDir then
        local drive = isDir:match("^%-(%a)%-$")
        mem.write(buf, (drive and (drive .. ":") or (isDir .. "\\")) .. "\0")
        return 1
    end
    mem.write(buf, s .. "\0")
    return 0
end
def("USER", 99, "DlgDirSelect", "h p i", function(h, buf, id) return dirSelect(h, buf, id, false) end)
def("USER", 194, "DlgDirSelectComboBox", "h p i", function(h, buf, id) return dirSelect(h, buf, id, true) end)

-- ---- strings -----------------------------------------------------------------------------------------------------

def("USER", 435, "IsCharUpper", "w", function(c) return c >= 0x41 and c <= 0x5A or (c >= 0xC0 and c <= 0xDE and c ~= 0xD7) end)
def("USER", 436, "IsCharLower", "w", function(c) return c >= 0x61 and c <= 0x7A or (c >= 0xDF and c ~= 0xF7) end)
def("USER", 472, "AnsiNext", "f:l", function(fp)
    local l = cpu.flat(fp)
    if not l or rb(l) == 0 then return fp end
    return fp + 1
end)
def("USER", 473, "AnsiPrev", "f f:l", function(start, cur)
    if cur <= start then return start end
    return cur - 1
end)

-- ---- what this machine doesn't have: a network, serial ports, installable drivers ------------------------------------

-- WN_NOT_SUPPORTED
for _, e in ipairs({{512, "WNetGetConnection", "s p p"}, {514, "WNetDeviceMode", "h"}, {515, "WNetBrowseDialog", "h w p"},
                    {517, "WNetAddConnection", "s s s"}, {518, "WNetCancelConnection", "s w"}, {519, "WNetGetError", "p"},
                    {520, "WNetGetErrorText", "w p p"}, {525, "WNetConnectDialog", "h w"},
                    {527, "WNetConnectionDialog", "h w"}}) do
    def("USER", e[1], e[2], e[3], function() return 1 end)
end
def("USER", 513, "WNetGetCaps", "w", function() return 0 end)

def("USER", 200, "OpenComm", "s w w", function() return 0xFFFE end)   -- IE_BADID
def("USER", 207, "CloseComm", "i", function() return 0 end)
def("USER", 214, "EscapeCommFunction", "i i:l", function() return 0 end)

def("USER", 252, "OpenDriver", "s s l", function() return 0 end)
def("USER", 253, "CloseDriver", "h l l:l", function() return 0 end)
def("USER", 251, "SendDriverMessage", "h w l l:l", function() return 0 end)
def("USER", 254, "GetDriverModuleHandle", "h", function() return 0 end)
def("USER", 257, "GetNextDriver", "h l", function() return 0 end)

return {}

-- DragObject: USER's drag-and-drop between windows, which Program Manager
-- uses to move and copy items between groups. While dragging, the window
-- under the pointer is asked (WM_QUERYDROPOBJECT) whether it takes the
-- object; the pointer shows the item's icon over one that does. On release
-- the target gets WM_DROPOBJECT.
--
-- DRAGINFO: hWnd, hScope, wFlags, hList, hOfStruct, pt (client coordinates
-- of the target), l.

local api = require("win16.api")
local cpu = require("recomp.cpu")
local gdi = require("win16.gdi")
local kernel = require("win16.kernel")
local region = require("win16.region")
local user = require("win16.user")

local def = api.def
local WM = user.WM
local W = user.W
local rw, ww, rd, wd = mem.rw, mem.ww, mem.rd, mem.wd

-- The window that takes the drop at a screen point (asking up the parents,
-- within the scope), or nil.
local function query(scope, x, y, infoLin, infoFp)
    local w, ht = user.windowFromPoint(x, y)
    while w and w ~= user.desktop do
        if scope and not user.isDescendant(w, scope) then return nil end
        local ox, oy = user.clientOrigin(w)
        api.setpt(infoLin + 10, x - ox, y - oy)
        ww(infoLin + 2, w.handle)
        local cr = user.clientRect(w)
        local nc = not (x >= cr[1] and x < cr[3] and y >= cr[2] and y < cr[4])
        if not w.disabled then
            local r = user.send(w, WM.QUERYDROPOBJECT, nc and 1 or 0, infoFp)
            if r ~= 0 then return w end
        end
        if w == scope then return nil end
        w = w.parent
    end
end

def("USER", 464, "DragObject", "h h w w w h:l", function(hScope, hwnd, flags, hOfStruct, hList, hCursor)
    local src = W(hwnd)
    if not src then return 0 end
    local scope = hScope ~= 0 and W(hScope) or nil
    local mark = api.mark()
    local infoFp, info = api.alloc(18)
    ww(info, hwnd); ww(info + 2, 0); ww(info + 4, flags); ww(info + 6, hList); ww(info + 8, hOfStruct); wd(info + 14, 0)
    user.send(src, WM.BEGINDRAG, 0, infoFp)
    local iconLin = kernel.glin(hCursor)
    local over = nil
    local accepted = false
    local mx, my = user.mouseX, user.mouseY
    local ov = {x = mx - 16, y = my - 16, w = 34, h = 34}
    ov.draw = function()
        fb.clip(nil)
        if accepted and iconLin then
            local dc = gdi.dc(gdi.newDC({surface = 0, ox = 0, oy = 0}))
            gdi.drawIcon(dc, ov.x, ov.y, iconLin)
            require("win16.handles").free(dc.handle)
        else
            -- the "no" sign: a circle with a slash, roughly
            local cx, cy = ov.x + 16, ov.y + 16
            for a = 0, 359, 6 do
                local r = math.rad(a)
                fb.patblt(0, cx + math.floor(10 * math.cos(r)), cy + math.floor(10 * math.sin(r)), 2, 2, 0xF0, 0)
            end
            for t = -7, 7 do fb.patblt(0, cx + t, cy + t, 2, 2, 0xF0, 0) end
        end
    end
    user.overlays[#user.overlays + 1] = ov
    user.setCursor("hide")
    local function update(x, y)
        local target = query(scope, x, y, info, infoFp)
        if target ~= over then
            if over and not over.destroyed then user.send(over, WM.DRAGSELECT, 0, infoFp) end
            over = target
            if over then user.send(over, WM.DRAGSELECT, 1, infoFp) end
        end
        accepted = target ~= nil
        if over then user.send(over, WM.DRAGMOVE, 0, infoFp) end
        user.send(src, WM.DRAGLOOP, accepted and 1 or 0, infoFp)
        ov.x, ov.y = x - 16, y - 16
        user.dirty = true
    end
    update(mx, my)
    user.present()
    local dropped = false
    while true do
        local ev = user.waitInput()
        if ev.kind == "move" then
            user.mouseX, user.mouseY = ev.e[2], ev.e[3]
            update(ev.e[2], ev.e[3])
        elseif ev.kind == "up" then
            user.mouseX, user.mouseY = ev.e[2], ev.e[3]
            update(ev.e[2], ev.e[3])
            dropped = true
            break
        elseif ev.kind == "key" and ev.e[2] == 0x1B and ev.e[3] == 1 then
            break
        elseif ev.kind == "key" then
            user.keys[ev.e[2]] = ev.e[3] == 1 or nil
        elseif ev.kind == "close" then
            table.insert(user.input, 1, ev)
            break
        end
        user.present()
    end
    for i, o in ipairs(user.overlays) do if o == ov then table.remove(user.overlays, i); break end end
    user.setCursor("arrow")
    user.buttons[1] = false
    user.dirty = true
    local result = 0
    if over and not over.destroyed then
        user.send(over, WM.DRAGSELECT, 0, infoFp)
        if dropped and accepted then
            -- the target's coordinates for the drop
            local ox, oy = user.clientOrigin(over)
            api.setpt(info + 10, user.mouseX - ox, user.mouseY - oy)
            ww(info + 2, over.handle)
            result = user.send(over, WM.DROPOBJECT, hwnd, infoFp)
        end
    end
    api.release(mark)
    user.present()
    return result
end)

return {}

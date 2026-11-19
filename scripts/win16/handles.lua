-- USER and GDI handles (HWND, HDC, HBRUSH, HMENU, ...): 16-bit values that
-- are multiples of 4, so they never collide with selectors (which end in
-- binary 111) or the global memory handles that are selectors.

local handles = {}

local objects = {}
local nextH = 0x0100

function handles.new(obj)
    local tries = 0
    while objects[nextH] do
        nextH = nextH + 4
        if nextH > 0xFFF0 then nextH = 0x0100 end
        tries = tries + 1
        if tries > 0x4000 then error("out of USER/GDI handles") end
    end
    local h = nextH
    objects[h] = obj
    obj.handle = h
    nextH = nextH + 4
    if nextH > 0xFFF0 then nextH = 0x0100 end
    return h
end

function handles.get(h, kind)
    local o = objects[h]
    if o and (not kind or o.kind == kind) then return o end
end

function handles.free(h) objects[h] = nil end

function handles.all() return objects end

return handles

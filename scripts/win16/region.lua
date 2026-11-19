-- Regions as lists of non-overlapping rectangles {x0, y0, x1, y1} (x1, y1
-- exclusive): window visible regions, update regions, and GDI region objects.

local region = {}

local function rect(x0, y0, x1, y1) return {x0, y0, x1, y1} end
region.rect = rect

function region.empty(r) return r[1] >= r[3] or r[2] >= r[4] end

function region.isect(a, b)
    local x0, y0 = math.max(a[1], b[1]), math.max(a[2], b[2])
    local x1, y1 = math.min(a[3], b[3]), math.min(a[4], b[4])
    if x0 >= x1 or y0 >= y1 then return nil end
    return {x0, y0, x1, y1}
end

-- a minus b: up to four pieces
local function sub1(a, b, out)
    local i = region.isect(a, b)
    if not i then out[#out + 1] = a; return end
    if a[2] < i[2] then out[#out + 1] = {a[1], a[2], a[3], i[2]} end
    if i[4] < a[4] then out[#out + 1] = {a[1], i[4], a[3], a[4]} end
    if a[1] < i[1] then out[#out + 1] = {a[1], i[2], i[1], i[4]} end
    if i[3] < a[3] then out[#out + 1] = {i[3], i[2], a[3], i[4]} end
end

-- list minus list
function region.subtract(A, B)
    local cur = A
    for _, b in ipairs(B) do
        local nxt = {}
        for _, a in ipairs(cur) do sub1(a, b, nxt) end
        cur = nxt
        if #cur == 0 then break end
    end
    return cur
end

function region.intersect(A, B)
    local out = {}
    for _, a in ipairs(A) do
        for _, b in ipairs(B) do
            local i = region.isect(a, b)
            if i then out[#out + 1] = i end
        end
    end
    return out
end

function region.union(A, B)
    local out = {}
    for _, a in ipairs(A) do out[#out + 1] = a end
    for _, b in ipairs(region.subtract(B, A)) do out[#out + 1] = b end
    return region.compact(out)
end

function region.xor(A, B)
    local out = region.subtract(A, B)
    for _, b in ipairs(region.subtract(B, A)) do out[#out + 1] = b end
    return out
end

function region.offset(A, dx, dy)
    local out = {}
    for i, a in ipairs(A) do out[i] = {a[1] + dx, a[2] + dy, a[3] + dx, a[4] + dy} end
    return out
end

function region.bounds(A)
    if #A == 0 then return {0, 0, 0, 0} end
    local b = {A[1][1], A[1][2], A[1][3], A[1][4]}
    for _, a in ipairs(A) do
        b[1] = math.min(b[1], a[1]); b[2] = math.min(b[2], a[2])
        b[3] = math.max(b[3], a[3]); b[4] = math.max(b[4], a[4])
    end
    return b
end

-- Merges vertically adjacent pieces with the same span, keeping lists short.
function region.compact(A)
    if #A < 2 then return A end
    local changed = true
    while changed do
        changed = false
        for i = 1, #A do
            local a = A[i]
            for j = i + 1, #A do
                local b = A[j]
                if a[1] == b[1] and a[3] == b[3] and (a[4] == b[2] or b[4] == a[2]) then
                    A[i] = {a[1], math.min(a[2], b[2]), a[3], math.max(a[4], b[4])}
                    table.remove(A, j)
                    changed = true
                    break
                elseif a[2] == b[2] and a[4] == b[4] and (a[3] == b[1] or b[3] == a[1]) then
                    A[i] = {math.min(a[1], b[1]), a[2], math.max(a[3], b[3]), a[4]}
                    table.remove(A, j)
                    changed = true
                    break
                end
            end
            if changed then break end
        end
    end
    return A
end

-- flat list for fb.clip
function region.flat(A)
    local out = {}
    for _, a in ipairs(A) do
        out[#out + 1] = a[1]; out[#out + 1] = a[2]; out[#out + 1] = a[3]; out[#out + 1] = a[4]
    end
    return out
end

return region

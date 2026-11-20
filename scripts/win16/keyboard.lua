-- KEYBOARD.DRV: character-set conversion and key names.

local api = require("win16.api")
local cpu = require("recomp.cpu")

local def = api.def

-- ANSI (Windows-1252) and OEM (code page 437) agree below 0x80; above,
-- characters without an equivalent become '_' as Windows did.
local ansiToOem, oemToAnsi = {}, {}
do
    local pairsList = {
        {0xC7, 0x80}, {0xFC, 0x81}, {0xE9, 0x82}, {0xE2, 0x83}, {0xE4, 0x84}, {0xE0, 0x85}, {0xE5, 0x86},
        {0xE7, 0x87}, {0xEA, 0x88}, {0xEB, 0x89}, {0xE8, 0x8A}, {0xEF, 0x8B}, {0xEE, 0x8C}, {0xEC, 0x8D},
        {0xC4, 0x8E}, {0xC5, 0x8F}, {0xC9, 0x90}, {0xE6, 0x91}, {0xC6, 0x92}, {0xF4, 0x93}, {0xF6, 0x94},
        {0xF2, 0x95}, {0xFB, 0x96}, {0xF9, 0x97}, {0xFF, 0x98}, {0xD6, 0x99}, {0xDC, 0x9A}, {0xA2, 0x9B},
        {0xA3, 0x9C}, {0xA5, 0x9D}, {0xE1, 0xA0}, {0xED, 0xA1}, {0xF3, 0xA2}, {0xFA, 0xA3}, {0xF1, 0xA4},
        {0xD1, 0xA5}, {0xAA, 0xA6}, {0xBA, 0xA7}, {0xBF, 0xA8}, {0xAC, 0xAA}, {0xBD, 0xAB}, {0xBC, 0xAC},
        {0xA1, 0xAD}, {0xAB, 0xAE}, {0xBB, 0xAF}, {0xDF, 0xE1}, {0xB5, 0xE6}, {0xB1, 0xF1}, {0xF7, 0xF6},
        {0xB0, 0xF8}, {0xB7, 0xFA}, {0xB2, 0xFD},
    }
    for _, p in ipairs(pairsList) do ansiToOem[p[1]] = p[2]; oemToAnsi[p[2]] = p[1] end
end

local function convert(srcFp, dstFp, map)
    local s, d = cpu.flat(srcFp), cpu.flat(dstFp)
    if not s or not d then return 0 end
    local str = mem.cstr(s)
    local out = str:gsub("[\128-\255]", function(c) return string.char(map[c:byte()] or 0x5F) end)
    mem.write(d, out .. "\0")
    return 1
end

def("KEYBOARD", 5, "AnsiToOem", "f f", function(s, d) return convert(s, d, ansiToOem) end)
def("KEYBOARD", 6, "OemToAnsi", "f f", function(s, d) return convert(s, d, oemToAnsi) end)

-- MapVirtualKey(code, type): 0 VK->scan, 1 scan->VK, 2 VK->char
local SCAN = {[0x08] = 0x0E, [0x09] = 0x0F, [0x0D] = 0x1C, [0x10] = 0x2A, [0x11] = 0x1D, [0x12] = 0x38, [0x1B] = 0x01,
              [0x20] = 0x39, [0x21] = 0x49, [0x22] = 0x51, [0x23] = 0x4F, [0x24] = 0x47, [0x25] = 0x4B, [0x26] = 0x48,
              [0x27] = 0x4D, [0x28] = 0x50, [0x2D] = 0x52, [0x2E] = 0x53}
local ROWS = {"1234567890", "QWERTYUIOP", "ASDFGHJKL", "ZXCVBNM"}
local ROW_START = {0x02, 0x10, 0x1E, 0x2C}
for r, keys in ipairs(ROWS) do
    for i = 1, #keys do SCAN[keys:byte(i)] = ROW_START[r] + i - 1 end
end
for i = 0, 9 do SCAN[0x70 + i] = 0x3B + i end
SCAN[0x7A], SCAN[0x7B] = 0x57, 0x58
local VK = {}
for vk, sc in pairs(SCAN) do VK[sc] = vk end

def("KEYBOARD", 131, "MapVirtualKey", "w w", function(code, kind)
    if kind == 0 then return SCAN[code] or 0 end
    if kind == 1 then return VK[code] or 0 end
    if kind == 2 then
        if (code >= 0x30 and code <= 0x39) or (code >= 0x41 and code <= 0x5A) or code == 0x20 then return code end
        return 0
    end
    return 0
end)

local NAMES = {[0x0E] = "Backspace", [0x0F] = "Tab", [0x1C] = "Enter", [0x2A] = "Shift", [0x1D] = "Ctrl",
               [0x38] = "Alt", [0x01] = "Esc", [0x39] = "Space", [0x49] = "Num 9", [0x51] = "Num 3",
               [0x4F] = "Num 1", [0x47] = "Num 7", [0x4B] = "Num 4", [0x48] = "Num 8", [0x4D] = "Num 6",
               [0x50] = "Num 2", [0x52] = "Num 0", [0x53] = "Num Del"}
def("KEYBOARD", 133, "GetKeyNameText", "l p i", function(lp, buf, n)
    local sc = (lp >> 16) & 0xFF
    local ext = (lp >> 24) & 1 ~= 0
    local name = NAMES[sc]
    if ext then
        local extNames = {[0x49] = "Page Up", [0x51] = "Page Down", [0x4F] = "End", [0x47] = "Home",
                          [0x4B] = "Left", [0x48] = "Up", [0x4D] = "Right", [0x50] = "Down", [0x52] = "Insert",
                          [0x53] = "Delete", [0x1D] = "Right Ctrl", [0x38] = "Right Alt"}
        name = extNames[sc] or name
    end
    if not name then
        local vk = VK[sc]
        if vk and vk >= 0x70 and vk <= 0x7B then name = "F" .. (vk - 0x6F)
        elseif vk then name = string.char(vk) end
    end
    return api.putstr(buf, name or "", n)
end)

return {}

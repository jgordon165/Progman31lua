-- Builds a games folder for the tests: shortcuts (.lnk, .url) in folders
-- with long names, and an icon for some of them.

local fixture = {}

local sep = host.platform() == "Windows" and "\\" or "/"
fixture.sep = sep

local function u16(s)
    local out = {}
    for _, c in utf8.codes(s) do out[#out + 1] = string.pack("<I2", c) end
    return table.concat(out)
end

-- A 32x32, 32-bit .ICO: a filled circle of `rgb` on transparent.
function fixture.ico(rgb)
    local px = {}
    for y = 31, 0, -1 do
        for x = 0, 31 do
            local dx, dy = x - 15.5, y - 15.5
            if dx * dx + dy * dy < 14 * 14 then
                px[#px + 1] = string.pack("BBBB", rgb & 255, (rgb >> 8) & 255, rgb >> 16, 255)
            else
                px[#px + 1] = "\0\0\0\0"
            end
        end
    end
    local bmp = string.pack("<I4i4i4I2I2I4I4i4i4I4I4", 40, 32, 64, 1, 32, 0, 0, 0, 0, 0, 0)
        .. table.concat(px) .. string.rep("\0", 32 * 4)
    return string.pack("<I2I2I2", 0, 1, 1) .. string.pack("<BBBBI2I2I4I4", 32, 32, 0, 0, 1, 32, #bmp, 22) .. bmp
end

-- A Windows shortcut to `target`, with an icon location if given.
function fixture.lnk(target, icon, relative)
    local flags = 0x2 | 0x80
    if relative then flags = flags | 0x8 end
    if icon then flags = flags | 0x40 end
    local clsid = "\1\20\2\0\0\0\0\0\192\0\0\0\0\0\0\70"
    local header = string.pack("<I4", 0x4C) .. clsid .. string.pack("<I4I4", flags, 0x20)
        .. string.rep("\0", 24) .. string.pack("<I4i4I4I2I2I4I4", 0, 0, 1, 0, 0, 0, 0)
    assert(#header == 0x4C)
    local volume = string.pack("<I4I4I4I4", 0x11, 3, 0x1234, 0x10) .. "\0"
    local base = target .. "\0"
    local volOff = 0x1C
    local baseOff = volOff + #volume
    local suffixOff = baseOff + #base
    local body = volume .. base .. "\0"
    local info = string.pack("<I4I4I4I4I4I4I4", 0x1C + #body, 0x1C, 1, volOff, baseOff, 0, suffixOff) .. body
    local strings = ""
    if relative then strings = strings .. string.pack("<I2", utf8.len(relative)) .. u16(relative) end
    if icon then strings = strings .. string.pack("<I2", utf8.len(icon)) .. u16(icon) end
    return header .. info .. strings .. string.pack("<I4", 0)
end

function fixture.url(url, iconFile)
    local t = "[InternetShortcut]\r\nURL=" .. url .. "\r\n"
    if iconFile then t = t .. "IconFile=" .. iconFile .. "\r\nIconIndex=0\r\n" end
    return t
end

local function rmtree(p)
    local st = host.stat(p)
    if not st then return end
    if st.dir then
        for _, e in ipairs(host.list(p) or {}) do rmtree(p .. sep .. e.name) end
    end
    host.remove(p)
end
fixture.rmtree = rmtree

-- The folder: One Must Fall 2097 (a .lnk with its own icon), Raptor (a .lnk
-- with no icon), Steam Games/MegaRace (a .url with an icon).
function fixture.build(dir)
    rmtree(dir)
    host.mkdir(dir)
    local omf = dir .. sep .. "One Must Fall 2097"
    host.mkdir(omf)
    host.write(omf .. sep .. "omf.ico", fixture.ico(0xE00000))
    host.write(omf .. sep .. "One Must Fall 2097.lnk", fixture.lnk("C:\\Games\\OMF\\OneMuastFall.exe", "omf.ico"))
    local raptor = dir .. sep .. "Raptor"
    host.mkdir(raptor)
    host.write(raptor .. sep .. "Raptor.lnk", fixture.lnk("C:\\Games\\Raptor\\Raptua.exe", nil, ".\\Raptua.exe"))
    host.write(raptor .. sep .. "readme.txt", "not a shortcut")
    local steam = dir .. sep .. "Steam Games" .. sep .. "MegaRace"
    host.mkdir(dir .. sep .. "Steam Games")
    host.mkdir(steam)
    host.write(steam .. sep .. "mega.ico", fixture.ico(0x00C000))
    host.write(steam .. sep .. "MegaRace, the Movie.url", fixture.url("steam://rungameid/1", steam .. sep .. "mega.ico"))
end

return fixture

-- A small PNG decoder (for the icons modern programs carry, which are PNG
-- images inside .ico resources): non-interlaced, 8 bits per channel or
-- palette, decompressed with a plain inflate. Returns width, height and
-- the pixels as rows of {r, g, b, a} packed 0xAARRGGBB, top row first.

local png = {}

-- ---- inflate (RFC 1951) ----------------------------------------------------------------

local function inflate(data, pos)
    local out = {}
    local outn = 0
    local bitbuf, bitcnt = 0, 0
    local function bits(n)
        while bitcnt < n do
            local b = data:byte(pos)
            if not b then error("png: truncated data") end
            pos = pos + 1
            bitbuf = bitbuf | (b << bitcnt)
            bitcnt = bitcnt + 8
        end
        local v = bitbuf & ((1 << n) - 1)
        bitbuf = bitbuf >> n
        bitcnt = bitcnt - n
        return v
    end
    -- canonical Huffman table: lengths[0..n-1] -> {count=, symbol=}
    local function build(lengths, n)
        local count, offs, sym = {}, {}, {}
        for i = 0, 15 do count[i] = 0 end
        for i = 0, n - 1 do count[lengths[i] or 0] = count[lengths[i] or 0] + 1 end
        count[0] = 0
        offs[1] = 0
        for i = 1, 14 do offs[i + 1] = offs[i] + count[i] end
        for i = 0, n - 1 do
            local l = lengths[i] or 0
            if l ~= 0 then sym[offs[l]] = i; offs[l] = offs[l] + 1 end
        end
        return {count = count, sym = sym}
    end
    local function decode(h)
        local code, first, index = 0, 0, 0
        for len = 1, 15 do
            code = code | bits(1)
            local c = h.count[len]
            if code - c < first then return h.sym[index + (code - first)] end
            index = index + c
            first = (first + c) << 1
            code = code << 1
        end
        error("png: bad Huffman code")
    end
    local LBASE = {3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258}
    local LEXT = {0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0}
    local DBASE = {1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073,
                   4097, 6145, 8193, 12289, 16385, 24577}
    local DEXT = {0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13}
    local fixedL, fixedD
    local function codes(lh, dh)
        while true do
            local s = decode(lh)
            if s < 256 then
                outn = outn + 1; out[outn] = s
            elseif s == 256 then
                return
            else
                s = s - 257
                local len = LBASE[s + 1] + bits(LEXT[s + 1])
                local d = decode(dh)
                local dist = DBASE[d + 1] + bits(DEXT[d + 1])
                for _ = 1, len do
                    outn = outn + 1
                    out[outn] = out[outn - dist]
                end
            end
        end
    end
    local ORDER = {16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15}
    repeat
        local last = bits(1)
        local kind = bits(2)
        if kind == 0 then
            bitbuf, bitcnt = 0, 0
            local len = data:byte(pos) | (data:byte(pos + 1) << 8)
            pos = pos + 4
            for i = 0, len - 1 do outn = outn + 1; out[outn] = data:byte(pos + i) end
            pos = pos + len
        elseif kind == 1 then
            if not fixedL then
                local l = {}
                for i = 0, 143 do l[i] = 8 end
                for i = 144, 255 do l[i] = 9 end
                for i = 256, 279 do l[i] = 7 end
                for i = 280, 287 do l[i] = 8 end
                fixedL = build(l, 288)
                local d = {}
                for i = 0, 29 do d[i] = 5 end
                fixedD = build(d, 30)
            end
            codes(fixedL, fixedD)
        elseif kind == 2 then
            local hlit, hdist, hclen = bits(5) + 257, bits(5) + 1, bits(4) + 4
            local cl = {}
            for i = 1, hclen do cl[ORDER[i]] = bits(3) end
            local ch = build(cl, 19)
            local lens = {}
            local i = 0
            while i < hlit + hdist do
                local s = decode(ch)
                if s < 16 then lens[i] = s; i = i + 1
                else
                    local rep, v = 0, 0
                    if s == 16 then rep, v = 3 + bits(2), lens[i - 1]
                    elseif s == 17 then rep = 3 + bits(3)
                    else rep = 11 + bits(7) end
                    for _ = 1, rep do lens[i] = v; i = i + 1 end
                end
            end
            local ll, dl = {}, {}
            for k = 0, hlit - 1 do ll[k] = lens[k] end
            for k = 0, hdist - 1 do dl[k] = lens[hlit + k] end
            codes(build(ll, hlit), build(dl, hdist))
        else
            error("png: bad block type")
        end
    until last == 1
    return out, outn
end

-- ---- PNG ---------------------------------------------------------------------------------

function png.decode(data)
    if data:sub(1, 8) ~= "\137PNG\r\n\26\n" then return nil end
    local pos = 9
    local w, h, depth, ctype, interlace
    local palette, trns = {}, nil
    local idat = {}
    while pos + 8 <= #data do
        local len, kind = string.unpack(">I4c4", data, pos)
        local body = data:sub(pos + 8, pos + 7 + len)
        if kind == "IHDR" then
            w, h, depth, ctype, _, _, interlace = string.unpack(">I4I4BBBBB", body)
        elseif kind == "PLTE" then
            for i = 0, #body // 3 - 1 do
                palette[i] = (body:byte(i * 3 + 1) << 16) | (body:byte(i * 3 + 2) << 8) | body:byte(i * 3 + 3)
            end
        elseif kind == "tRNS" then
            trns = body
        elseif kind == "IDAT" then
            idat[#idat + 1] = body
        elseif kind == "IEND" then
            break
        end
        pos = pos + 12 + len
    end
    if not w or depth ~= 8 or interlace ~= 0 then return nil end
    local channels = ({[0] = 1, [2] = 3, [3] = 1, [4] = 2, [6] = 4})[ctype]
    if not channels then return nil end
    local z = table.concat(idat)
    local ok, raw = pcall(inflate, z, 3)    -- skip the zlib header
    if not ok then return nil end
    local bpp = channels
    local stride = w * bpp
    local rows = {}
    local prev = {}
    for i = 1, stride do prev[i] = 0 end
    local at = 1
    for y = 0, h - 1 do
        local filter = raw[at]
        at = at + 1
        local cur = {}
        for i = 1, stride do
            local x = raw[at + i - 1] or 0
            local a = i > bpp and cur[i - bpp] or 0
            local b = prev[i]
            local c = i > bpp and prev[i - bpp] or 0
            if filter == 1 then x = x + a
            elseif filter == 2 then x = x + b
            elseif filter == 3 then x = x + (a + b) // 2
            elseif filter == 4 then
                local p = a + b - c
                local pa, pb, pc = math.abs(p - a), math.abs(p - b), math.abs(p - c)
                if pa <= pb and pa <= pc then x = x + a elseif pb <= pc then x = x + b else x = x + c end
            end
            cur[i] = x & 0xFF
        end
        at = at + stride
        local row = {}
        for px = 0, w - 1 do
            local o = px * bpp
            local r, g, b, al
            if ctype == 6 then r, g, b, al = cur[o + 1], cur[o + 2], cur[o + 3], cur[o + 4]
            elseif ctype == 2 then r, g, b, al = cur[o + 1], cur[o + 2], cur[o + 3], 255
            elseif ctype == 0 then r, g, b, al = cur[o + 1], cur[o + 1], cur[o + 1], 255
            elseif ctype == 4 then r, g, b, al = cur[o + 1], cur[o + 1], cur[o + 1], cur[o + 2]
            else
                local idx = cur[o + 1]
                local v = palette[idx] or 0
                r, g, b = v >> 16, (v >> 8) & 0xFF, v & 0xFF
                al = trns and trns:byte(idx + 1) or 255
            end
            row[px + 1] = (al << 24) | (r << 16) | (g << 8) | b
        end
        rows[y + 1] = row
        prev = cur
    end
    return w, h, rows
end

-- The PNG as a 32-bit DIB (BITMAPINFOHEADER, bottom-up BGRA, then an AND
-- mask), the shape an icon resource has.
function png.toIconDib(data)
    local w, h, rows = png.decode(data)
    if not w then return nil end
    local px = {}
    for y = h, 1, -1 do
        local row = rows[y]
        for x = 1, w do
            local v = row[x]
            px[#px + 1] = string.pack("BBBB", v & 0xFF, (v >> 8) & 0xFF, (v >> 16) & 0xFF, v >> 24)
        end
    end
    local maskStride = ((w + 31) // 32) * 4
    local mask = {}
    for y = h, 1, -1 do
        local row = rows[y]
        local bytes = {}
        for bx = 0, maskStride - 1 do
            local b = 0
            for k = 0, 7 do
                local x = bx * 8 + k + 1
                if x <= w and (row[x] >> 24) < 128 then b = b | (0x80 >> k) end
            end
            bytes[#bytes + 1] = string.char(b)
        end
        mask[#mask + 1] = table.concat(bytes)
    end
    return string.pack("<I4i4i4I2I2I4I4i4i4I4I4", 40, w, h * 2, 1, 32, 0, 0, 0, 0, 0, 0)
        .. table.concat(px) .. table.concat(mask)
end

return png

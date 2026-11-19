-- The dynamic recompiler: 16-bit x86 (8086 through 80286, as Microsoft C 6
-- emitted it for Windows 3.x programs) to Lua, one basic block at a time.
--
-- compile(fetch, csSel, csBase, ip) decodes from CS:IP up to the first
-- control transfer, writes Lua source for that block and load()s it. The
-- block keeps the eight general registers and the six arithmetic flags in
-- Lua locals and stores them back into the register table R on every exit.
-- Flags are computed only where something can read them: a backward
-- liveness pass drops flag updates that a later instruction in the same
-- block overwrites unread (at every exit all flags count as live).
--
-- Memory is the host's flat linear space (mem.rb/rw/wb/ww); a segment
-- register's selector is kept with its base (R.ds and R.dsb, ...), so an
-- access is base + 16-bit offset.

local M = {}

local CF, PF, AF, ZF, SF, OF = 0x1, 0x4, 0x10, 0x40, 0x80, 0x800
local ALL = CF | PF | AF | ZF | SF | OF
local SZP = SF | ZF | PF
M.ALL = ALL

local R16 = {[0] = "ax", "cx", "dx", "bx", "sp", "bp", "si", "di"}
local SREG = {[0] = "es", "cs", "ss", "ds"}

local function hex(v) return string.format("0x%X", v) end

-- Thrown (as a table) when an instruction can't be compiled, so the caller
-- can report where.
local function unsupported(ip, what)
    error({recomp = true, ip = ip, msg = what}, 0)
end

-- ---- operands -----------------------------------------------------------------
-- {k="r", n=0..7, w=1|2}      register (w=1: al,cl,dl,bl,ah,ch,dh,bh)
-- {k="m", seg="ds", ea=expr, w=1|2} memory
-- {k="i", v=n, w}             immediate
-- {k="s", n=0..3}             segment register

local function get(o, ctx)
    if o.k == "r" then
        if o.w == 2 then return R16[o.n] end
        if o.n < 4 then return "(" .. R16[o.n] .. "&0xFF)" end
        return "(" .. R16[o.n - 4] .. ">>8)"
    elseif o.k == "m" then
        return (o.w == 1 and "rb(" or "rw(") .. ctx.lin(o) .. ")"
    elseif o.k == "a" then          -- memory with its address already in A
        return o.w == 1 and "rb(A)" or "rw(A)"
    elseif o.k == "i" then
        return hex(o.v)
    elseif o.k == "s" then
        return "R." .. SREG[o.n]
    end
    error("bad operand")
end

local function set(o, expr, ctx)
    if o.k == "r" then
        if o.w == 2 then return R16[o.n] .. " = " .. expr end
        if o.n < 4 then
            local r = R16[o.n]
            return r .. " = (" .. r .. " & 0xFF00) | (" .. expr .. ")"
        end
        local r = R16[o.n - 4]
        return r .. " = (" .. r .. " & 0xFF) | ((" .. expr .. ") << 8)"
    elseif o.k == "m" then
        return (o.w == 1 and "wb(" or "ww(") .. ctx.lin(o) .. ", " .. expr .. ")"
    elseif o.k == "a" then
        return (o.w == 1 and "wb(A, " or "ww(A, ") .. expr .. ")"
    elseif o.k == "s" then
        local s = SREG[o.n]
        return "t = " .. expr .. "; R." .. s .. " = t; " .. s .. "b = SEL(t); R." .. s .. "b = " .. s .. "b"
    end
    error("bad destination")
end

-- For read-modify-write: a memory operand's address goes into A once.
local function rmw(o, ctx, out)
    if o.k ~= "m" then return o end
    out[#out + 1] = "A = " .. ctx.lin(o)
    return {k = "a", w = o.w}
end

-- ---- flags ----------------------------------------------------------------------

local function szp(lines, need, r, w)
    if need & ZF ~= 0 then lines[#lines + 1] = "zf = " .. r .. " == 0" end
    if need & SF ~= 0 then lines[#lines + 1] = "sf = " .. r .. " >= " .. (w == 1 and "0x80" or "0x8000") end
    if need & PF ~= 0 then lines[#lines + 1] = "pf = PAR[" .. r .. " & 0xFF]" end
end

local function mask(w) return w == 1 and "0xFF" or "0xFFFF" end
local function sign(w) return w == 1 and "0x80" or "0x8000" end

-- Binary ALU ops on (a, b) already in locals a and b; result to r.
-- op: 0 add, 1 or, 2 adc, 3 sbb, 4 and, 5 sub, 6 xor, 7 cmp
local function alu(lines, op, w, need)
    local m, s = mask(w), sign(w)
    if op == 1 or op == 4 or op == 6 then
        lines[#lines + 1] = "r = a " .. ({[1] = "|", [4] = "&", [6] = "~"})[op] .. " b"
        if need & CF ~= 0 then lines[#lines + 1] = "cf = false" end
        if need & OF ~= 0 then lines[#lines + 1] = "of = false" end
        if need & AF ~= 0 then lines[#lines + 1] = "af = false" end
        szp(lines, need, "r", w)
        return
    end
    local add = op == 0 or op == 2
    local carry = (op == 2 or op == 3) and " + (cf and 1 or 0)" or ""
    if add then
        lines[#lines + 1] = "t = a + b" .. carry
        if need & CF ~= 0 then lines[#lines + 1] = "cf = t > " .. m end
        lines[#lines + 1] = "r = t & " .. m
        if need & OF ~= 0 then lines[#lines + 1] = "of = ((a ~ r) & (b ~ r) & " .. s .. ") ~= 0" end
    else
        lines[#lines + 1] = "t = a - b" .. (carry ~= "" and " - (cf and 1 or 0)" or "")
        if need & CF ~= 0 then lines[#lines + 1] = "cf = t < 0" end
        lines[#lines + 1] = "r = t & " .. m
        if need & OF ~= 0 then lines[#lines + 1] = "of = ((a ~ b) & (a ~ r) & " .. s .. ") ~= 0" end
    end
    if need & AF ~= 0 then lines[#lines + 1] = "af = ((a ~ b ~ r) & 0x10) ~= 0" end
    szp(lines, need, "r", w)
end

-- Jcc conditions: Lua expression and the flags they read.
local COND = {
    [0] = {"of", OF}, {"not of", OF}, {"cf", CF}, {"not cf", CF},
    {"zf", ZF}, {"not zf", ZF}, {"(cf or zf)", CF | ZF}, {"not (cf or zf)", CF | ZF},
    {"sf", SF}, {"not sf", SF}, {"pf", PF}, {"not pf", PF},
    {"(sf ~= of)", SF | OF}, {"(sf == of)", SF | OF}, {"(zf or sf ~= of)", ZF | SF | OF}, {"(not zf and sf == of)", ZF | SF | OF},
}

-- ---- the decoder ----------------------------------------------------------------

-- Decodes one instruction at offset ip. Returns a record:
--   len, rf (flags read), wf (flags always written), term (ends the block),
--   gen(need, ctx) -> list of Lua statements
local function decode(fetch, ip0, csSel)
    local ip = ip0
    local function b()
        local v = fetch(ip)
        ip = (ip + 1) & 0xFFFF
        return v
    end
    local function w16()
        local lo = b()
        return lo | (b() << 8)
    end
    local function sb()   -- signed byte
        local v = b()
        return v >= 0x80 and v - 0x100 or v
    end

    local seg, rep = nil, nil
    local op
    while true do
        op = b()
        if op == 0x26 then seg = "es"
        elseif op == 0x2E then seg = "cs"
        elseif op == 0x36 then seg = "ss"
        elseif op == 0x3E then seg = "ds"
        elseif op == 0xF2 then rep = "ne"
        elseif op == 0xF3 then rep = "e"
        elseif op == 0xF0 then -- lock: nothing to do
        elseif op == 0x66 or op == 0x67 then unsupported(ip0, "32-bit operand/address prefix")
        else break end
    end

    -- ModR/M: returns mod, reg, and the r/m operand of width w
    local function modrm(w)
        local m = b()
        local mod, reg, rm = m >> 6, (m >> 3) & 7, m & 7
        if mod == 3 then return mod, reg, {k = "r", n = rm, w = w} end
        local base = ({[0] = {"bx", "si"}, {"bx", "di"}, {"bp", "si"}, {"bp", "di"}, {"si"}, {"di"}, {"bp"}, {"bx"}})[rm]
        local defseg = (rm == 2 or rm == 3 or rm == 6) and "ss" or "ds"
        local disp = 0
        if mod == 0 and rm == 6 then
            base, defseg, disp = {}, "ds", w16()
        elseif mod == 1 then
            disp = sb()
        elseif mod == 2 then
            disp = w16()
            if disp >= 0x8000 then disp = disp - 0x10000 end
        end
        local parts = {}
        for _, p in ipairs(base) do parts[#parts + 1] = p end
        local ea
        if #parts == 0 then
            ea = hex(disp & 0xFFFF)
        else
            local e = table.concat(parts, " + ")
            if disp > 0 then e = e .. " + " .. hex(disp) elseif disp < 0 then e = e .. " - " .. hex(-disp) end
            if #parts == 1 and disp == 0 then ea = e else ea = "((" .. e .. ") & 0xFFFF)" end
        end
        return mod, reg, {k = "m", seg = seg or defseg, ea = ea, w = w}
    end

    local I = {rf = 0, wf = 0, term = false}
    local function done(gen, rf, wf, term)
        I.len = (ip - ip0) & 0xFFFF
        I.gen, I.rf, I.wf, I.term = gen, rf or 0, wf or 0, term or false
        I.next = ip
        return I
    end
    local nextIp = function() return ip end

    -- ALU group 0x00..0x3F
    if op < 0x40 and (op & 7) < 6 then
        local aop, form = op >> 3, op & 7
        local w = (form & 1) == 1 and 2 or 1
        local dst, src
        if form < 4 then
            local _, reg, rmo = modrm(w)
            local r = {k = "r", n = reg, w = w}
            if form < 2 then dst, src = rmo, r else dst, src = r, rmo end
        else
            dst = {k = "r", n = 0, w = w}
            src = {k = "i", v = w == 1 and b() or w16(), w = w}
        end
        local rf = (aop == 2 or aop == 3) and CF or 0
        return done(function(need, ctx)
            local L = {}
            local d = rmw(dst, ctx, L)
            -- xor/sub of a register with itself: a constant 0.
            if (aop == 6 or aop == 5) and dst.k == "r" and src.k == "r" and dst.n == src.n then
                L[#L + 1] = "a, b = 0, 0"
            else
                L[#L + 1] = "a = " .. get(d, ctx)
                L[#L + 1] = "b = " .. get(src, ctx)
            end
            alu(L, aop, w, aop == 7 and need or need)
            if aop ~= 7 then L[#L + 1] = set(d, "r", ctx) end
            return L
        end, rf, ALL)
    end

    if op == 0x06 or op == 0x0E or op == 0x16 or op == 0x1E then
        local s = SREG[op >> 3]
        return done(function()
            if s == "cs" then return {"sp = (sp - 2) & 0xFFFF", "ww(ssb + sp, " .. hex(csSel) .. ")"} end
            return {"sp = (sp - 2) & 0xFFFF", "ww(ssb + sp, R." .. s .. ")"}
        end)
    end
    if op == 0x07 or op == 0x17 or op == 0x1F then
        local n = op >> 3
        return done(function(_, ctx)
            return {"v = rw(ssb + sp); sp = (sp + 2) & 0xFFFF", set({k = "s", n = n}, "v", ctx)}
        end)
    end
    if op == 0x27 or op == 0x2F or op == 0x37 or op == 0x3F then
        local name = ({[0x27] = "DAA", [0x2F] = "DAS", [0x37] = "AAA", [0x3F] = "AAS"})[op]
        return done(function()
            return {"ax, cf, af, zf, sf, pf, of = H." .. name .. "(ax, cf, af)"}
        end, CF | AF, ALL)
    end
    if op >= 0x40 and op <= 0x4F then
        local r = R16[op & 7]
        local inc = op < 0x48
        return done(function(need)
            local L = {"a = " .. r}
            if inc then
                L[#L + 1] = "r = (a + 1) & 0xFFFF"
                if need & OF ~= 0 then L[#L + 1] = "of = r == 0x8000" end
                if need & AF ~= 0 then L[#L + 1] = "af = (r & 0xF) == 0" end
            else
                L[#L + 1] = "r = (a - 1) & 0xFFFF"
                if need & OF ~= 0 then L[#L + 1] = "of = r == 0x7FFF" end
                if need & AF ~= 0 then L[#L + 1] = "af = (r & 0xF) == 0xF" end
            end
            szp(L, need, "r", 2)
            L[#L + 1] = r .. " = r"
            return L
        end, 0, OF | AF | SZP)
    end
    if op >= 0x50 and op <= 0x57 then
        local r = R16[op & 7]
        return done(function()
            if r == "sp" then return {"t = sp; sp = (sp - 2) & 0xFFFF; ww(ssb + sp, t)"} end
            return {"sp = (sp - 2) & 0xFFFF; ww(ssb + sp, " .. r .. ")"}
        end)
    end
    if op >= 0x58 and op <= 0x5F then
        local r = R16[op & 7]
        return done(function()
            if r == "sp" then return {"sp = rw(ssb + sp)"} end
            return {r .. " = rw(ssb + sp); sp = (sp + 2) & 0xFFFF"}
        end)
    end
    if op == 0x60 then
        return done(function()
            return {"t = sp", "for _, v in ipairs({ax, cx, dx, bx, t, bp, si, di}) do sp = (sp - 2) & 0xFFFF; ww(ssb + sp, v) end"}
        end)
    end
    if op == 0x61 then
        return done(function()
            return {"di = rw(ssb + sp); si = rw(ssb + ((sp + 2) & 0xFFFF)); bp = rw(ssb + ((sp + 4) & 0xFFFF))",
                    "bx = rw(ssb + ((sp + 8) & 0xFFFF)); dx = rw(ssb + ((sp + 10) & 0xFFFF))",
                    "cx = rw(ssb + ((sp + 12) & 0xFFFF)); ax = rw(ssb + ((sp + 14) & 0xFFFF)); sp = (sp + 16) & 0xFFFF"}
        end)
    end
    if op == 0x62 then   -- bound: assume in range
        modrm(2)
        return done(function() return {} end)
    end
    if op == 0x68 or op == 0x6A then
        local v = op == 0x68 and w16() or (sb() & 0xFFFF)
        return done(function() return {"sp = (sp - 2) & 0xFFFF; ww(ssb + sp, " .. hex(v) .. ")"} end)
    end
    if op == 0x69 or op == 0x6B then
        local _, reg, rmo = modrm(2)
        local imm = op == 0x69 and w16() or (sb() & 0xFFFF)
        return done(function(_, ctx)
            return {"r, cf = H.IMUL3(" .. get(rmo, ctx) .. ", " .. hex(imm) .. ")", "of = cf",
                    R16[reg] .. " = r"}
        end, 0, CF | OF)
    end
    if op >= 0x70 and op <= 0x7F then
        local d = sb()
        local target = (ip + d) & 0xFFFF
        local c = COND[op & 15]
        return done(function(_, ctx)
            return {"if " .. c[1] .. " then " .. ctx.exit(hex(target)) .. " end", ctx.exit(hex(ip))}
        end, c[2], 0, true)
    end
    if op >= 0x80 and op <= 0x83 then
        local w = op == 0x80 and 1 or op == 0x82 and 1 or 2
        local _, aop, rmo = modrm(w)
        local imm
        if op == 0x81 then imm = w16() elseif op == 0x83 then imm = sb() & 0xFFFF else imm = b() end
        local rf = (aop == 2 or aop == 3) and CF or 0
        return done(function(need, ctx)
            local L = {}
            local d = rmw(rmo, ctx, L)
            L[#L + 1] = "a = " .. get(d, ctx)
            L[#L + 1] = "b = " .. hex(imm)
            alu(L, aop, w, need)
            if aop ~= 7 then L[#L + 1] = set(d, "r", ctx) end
            return L
        end, rf, ALL)
    end
    if op == 0x84 or op == 0x85 or op == 0xA8 or op == 0xA9 then
        local w = (op & 1) == 1 and 2 or 1
        local x, y
        if op < 0xA8 then
            local _, reg, rmo = modrm(w)
            x, y = rmo, {k = "r", n = reg, w = w}
        else
            x, y = {k = "r", n = 0, w = w}, {k = "i", v = w == 1 and b() or w16()}
        end
        return done(function(need, ctx)
            local L = {"a = " .. get(x, ctx), "b = " .. get(y, ctx)}
            alu(L, 4, w, need)
            return L
        end, 0, ALL)
    end
    if op == 0x86 or op == 0x87 then
        local w = op == 0x86 and 1 or 2
        local _, reg, rmo = modrm(w)
        local r = {k = "r", n = reg, w = w}
        return done(function(_, ctx)
            local L = {}
            local d = rmw(rmo, ctx, L)
            L[#L + 1] = "a = " .. get(d, ctx)
            L[#L + 1] = "b = " .. get(r, ctx)
            L[#L + 1] = set(d, "b", ctx)
            L[#L + 1] = set(r, "a", ctx)
            return L
        end)
    end
    if op >= 0x88 and op <= 0x8B then
        local w = (op & 1) == 1 and 2 or 1
        local _, reg, rmo = modrm(w)
        local r = {k = "r", n = reg, w = w}
        return done(function(_, ctx)
            if op < 0x8A then return {set(rmo, get(r, ctx), ctx)} end
            return {set(r, get(rmo, ctx), ctx)}
        end)
    end
    if op == 0x8C then
        local _, reg, rmo = modrm(2)
        return done(function(_, ctx)
            if reg == 1 then return {set(rmo, hex(csSel), ctx)} end
            return {set(rmo, "R." .. SREG[reg & 3], ctx)}
        end)
    end
    if op == 0x8D then
        local _, reg, rmo = modrm(2)
        if rmo.k ~= "m" then unsupported(ip0, "lea with a register") end
        return done(function() return {R16[reg] .. " = " .. rmo.ea} end)
    end
    if op == 0x8E then
        local _, reg, rmo = modrm(2)
        if reg == 1 then unsupported(ip0, "mov cs") end
        return done(function(_, ctx) return {set({k = "s", n = reg & 3}, get(rmo, ctx), ctx)} end)
    end
    if op == 0x8F then
        local _, _, rmo = modrm(2)
        return done(function(_, ctx)
            return {"v = rw(ssb + sp); sp = (sp + 2) & 0xFFFF", set(rmo, "v", ctx)}
        end)
    end
    if op == 0x90 then return done(function() return {} end) end
    if op >= 0x91 and op <= 0x97 then
        local r = R16[op & 7]
        return done(function() return {"ax, " .. r .. " = " .. r .. ", ax"} end)
    end
    if op == 0x98 then
        return done(function() return {"t = ax & 0xFF; ax = t >= 0x80 and (t | 0xFF00) or t"} end)
    end
    if op == 0x99 then
        return done(function() return {"dx = ax >= 0x8000 and 0xFFFF or 0"} end)
    end
    if op == 0x9A then
        local off = w16()
        local sel = w16()
        return done(function(_, ctx)
            return {"sp = (sp - 2) & 0xFFFF; ww(ssb + sp, " .. hex(csSel) .. ")",
                    "sp = (sp - 2) & 0xFFFF; ww(ssb + sp, " .. hex(ip) .. ")",
                    "R.cs = " .. hex(sel), ctx.exit(hex(off))}
        end, 0, 0, true)
    end
    if op == 0x9B then return done(function() return {} end) end
    if op == 0x9C then
        return done(function()
            return {"sp = (sp - 2) & 0xFFFF; ww(ssb + sp, H.FLAGS(cf, pf, af, zf, sf, of, R))"}
        end, ALL, 0)
    end
    if op == 0x9D then
        return done(function()
            return {"cf, pf, af, zf, sf, of = H.SETFLAGS(rw(ssb + sp), R); sp = (sp + 2) & 0xFFFF"}
        end, 0, ALL)
    end
    if op == 0x9E then
        return done(function()
            return {"t = ax >> 8; cf = t & 1 ~= 0; pf = t & 4 ~= 0; af = t & 0x10 ~= 0; zf = t & 0x40 ~= 0; sf = t & 0x80 ~= 0"}
        end, 0, CF | PF | AF | ZF | SF)
    end
    if op == 0x9F then
        return done(function()
            return {"ax = (ax & 0xFF) | ((H.FLAGS(cf, pf, af, zf, sf, of, R) & 0xFF) << 8)"}
        end, CF | PF | AF | ZF | SF, 0)
    end
    if op >= 0xA0 and op <= 0xA3 then
        local w = (op & 1) == 1 and 2 or 1
        local m = {k = "m", seg = seg or "ds", ea = hex(w16()), w = w}
        local r = {k = "r", n = 0, w = w}
        return done(function(_, ctx)
            if op < 0xA2 then return {set(r, get(m, ctx), ctx)} end
            return {set(m, get(r, ctx), ctx)}
        end)
    end
    if op >= 0xA4 and op <= 0xAF and op ~= 0xA8 and op ~= 0xA9 then
        local w = (op & 1) == 1 and 2 or 1
        local kind = ({[0xA4] = "movs", [0xA6] = "cmps", [0xAA] = "stos", [0xAC] = "lods", [0xAE] = "scas"})[op & 0xFE]
        local srcb = (seg or "ds") .. "b"
        if seg == "cs" then srcb = "CSB" end
        local rd, wr = w == 1 and "rb" or "rw", w == 1 and "wb" or "ww"
        local acc = w == 1 and "(ax & 0xFF)" or "ax"
        local setacc = w == 1 and "ax = (ax & 0xFF00) | " or "ax = "
        local cmp = kind == "cmps" or kind == "scas"
        local rf, wf = 0, 0
        if cmp then wf = ALL end
        if cmp and rep then rf = ALL end   -- with rep and cx = 0 nothing changes
        return done(function(need, ctx)
            local L = {"d = R.df and -" .. w .. " or " .. w}
            local body
            if kind == "movs" then
                body = wr .. "(esb + di, " .. rd .. "(" .. srcb .. " + si)); si = (si + d) & 0xFFFF; di = (di + d) & 0xFFFF"
            elseif kind == "stos" then
                body = wr .. "(esb + di, " .. acc .. "); di = (di + d) & 0xFFFF"
            elseif kind == "lods" then
                body = setacc .. rd .. "(" .. srcb .. " + si); si = (si + d) & 0xFFFF"
            elseif kind == "cmps" then
                body = "a = " .. rd .. "(" .. srcb .. " + si); b = " .. rd .. "(esb + di); si = (si + d) & 0xFFFF; di = (di + d) & 0xFFFF"
            else
                body = "a = " .. acc .. "; b = " .. rd .. "(esb + di); di = (di + d) & 0xFFFF"
            end
            local fl = {}
            if cmp then alu(fl, 7, w, rep and ALL or need) end
            local flags = table.concat(fl, "; ")
            if not rep then
                L[#L + 1] = body
                if cmp then L[#L + 1] = flags end
            elseif not cmp then
                if kind == "movs" and w == 2 then
                    -- forward word copies are most of it: whole runs at once when they don't wrap
                    L[#L + 1] = "if d > 0 and cx > 0 and si + cx * 2 <= 0x10000 and di + cx * 2 <= 0x10000 then H.MOVE(esb + di, " ..
                        srcb .. " + si, cx * 2); si = (si + cx * 2) & 0xFFFF; di = (di + cx * 2) & 0xFFFF; cx = 0 end"
                elseif kind == "stos" then
                    L[#L + 1] = "if d > 0 and cx > 0 and di + cx * " .. w .. " <= 0x10000 then H.FILL(esb + di, cx, " .. acc .. ", " ..
                        w .. "); di = (di + cx * " .. w .. ") & 0xFFFF; cx = 0 end"
                end
                L[#L + 1] = "while cx ~= 0 do " .. body .. "; cx = cx - 1 end"
            else
                local stop = rep == "e" and "not zf" or "zf"
                L[#L + 1] = "while cx ~= 0 do " .. body .. "; cx = cx - 1; " .. flags .. "; if " .. stop .. " then break end end"
            end
            return L
        end, rf, wf)
    end
    if op >= 0xB0 and op <= 0xBF then
        local w = op >= 0xB8 and 2 or 1
        local v = w == 2 and w16() or b()
        return done(function(_, ctx) return {set({k = "r", n = op & 7, w = w}, hex(v), ctx)} end)
    end
    if op == 0xC0 or op == 0xC1 or (op >= 0xD0 and op <= 0xD3) then
        local w = (op & 1) == 1 and 2 or 1
        local _, sop, rmo = modrm(w)
        local count
        if op <= 0xC1 then count = hex(b() & 31) elseif op <= 0xD1 then count = "1" else count = "(cx & 31)" end
        local name = ({[0] = "ROL", "ROR", "RCL", "RCR", "SHL", "SHR", "SHL", "SAR"})[sop] .. (w == 1 and "8" or "16")
        local isShift = sop >= 4
        return done(function(_, ctx)
            local L = {"c = " .. count}
            local d = rmw(rmo, ctx, L)
            local body = {"r, cf, of = H." .. name .. "(" .. get(d, ctx) .. ", c, cf)", set(d, "r", ctx)}
            if isShift then
                body[#body + 1] = "zf = r == 0; sf = r >= " .. sign(w) .. "; pf = PAR[r & 0xFF]; af = false"
            end
            L[#L + 1] = "if c ~= 0 then " .. table.concat(body, "; ") .. " end"
            return L
        end, ALL, 0)  -- a zero count leaves the flags as they were
    end
    if op == 0xC2 or op == 0xC3 then
        local n = op == 0xC2 and w16() or 0
        return done(function(_, ctx)
            return {"t = rw(ssb + sp); sp = (sp + " .. (2 + n) .. ") & 0xFFFF", ctx.exit("t")}
        end, 0, 0, true)
    end
    if op == 0xC4 or op == 0xC5 then
        local _, reg, rmo = modrm(2)
        if rmo.k ~= "m" then unsupported(ip0, "les/lds with a register") end
        local s = op == 0xC4 and 0 or 3
        return done(function(_, ctx)
            local L = {}
            rmw(rmo, ctx, L)
            L[#L + 1] = "v = rw(A)"
            L[#L + 1] = set({k = "s", n = s}, "rw(A + 2)", ctx)
            L[#L + 1] = R16[reg] .. " = v"
            return L
        end)
    end
    if op == 0xC6 or op == 0xC7 then
        local w = op == 0xC6 and 1 or 2
        local _, _, rmo = modrm(w)
        local v = w == 1 and b() or w16()
        return done(function(_, ctx) return {set(rmo, hex(v), ctx)} end)
    end
    if op == 0xC8 then
        local size = w16()
        local level = b() & 31
        return done(function()
            return {"sp = (sp - 2) & 0xFFFF; ww(ssb + sp, bp); t = sp",
                    level > 0 and ("for i = 1, " .. (level - 1) .. " do bp = (bp - 2) & 0xFFFF; sp = (sp - 2) & 0xFFFF; ww(ssb + sp, rw(ssb + bp)) end; " ..
                        "sp = (sp - 2) & 0xFFFF; ww(ssb + sp, t)") or "",
                    "bp = t; sp = (sp - " .. size .. ") & 0xFFFF"}
        end)
    end
    if op == 0xC9 then
        return done(function() return {"sp = bp; bp = rw(ssb + sp); sp = (sp + 2) & 0xFFFF"} end)
    end
    if op == 0xCA or op == 0xCB then
        local n = op == 0xCA and w16() or 0
        return done(function(_, ctx)
            return {"t = rw(ssb + sp); R.cs = rw(ssb + ((sp + 2) & 0xFFFF)); sp = (sp + " .. (4 + n) .. ") & 0xFFFF", ctx.exit("t")}
        end, 0, 0, true)
    end
    if op == 0xCC or op == 0xCD or op == 0xCE then
        local n = op == 0xCC and 3 or op == 0xCD and b() or 4
        return done(function(_, ctx)
            if op == 0xCE then
                return {"if of then " .. ctx.store() .. "; R.ip = " .. hex(ip) .. "; return H.INT(R, 4) end", ctx.exit(hex(ip))}
            end
            return {ctx.store(), "R.ip = " .. hex(ip), "return H.INT(R, " .. n .. ")"}
        end, ALL, 0, true)
    end
    if op == 0xCF then
        return done(function()
            return {"t = rw(ssb + sp); R.cs = rw(ssb + ((sp + 2) & 0xFFFF))",
                    "cf, pf, af, zf, sf, of = H.SETFLAGS(rw(ssb + ((sp + 4) & 0xFFFF)), R); sp = (sp + 6) & 0xFFFF",
                    "R.ax, R.cx, R.dx, R.bx, R.sp, R.bp, R.si, R.di = ax, cx, dx, bx, sp, bp, si, di",
                    "R.cf, R.pf, R.af, R.zf, R.sf, R.of = cf, pf, af, zf, sf, of", "R.ip = t", "do return end"}
        end, 0, ALL, true)
    end
    if op == 0xD4 or op == 0xD5 then
        local base = b()
        return done(function()
            if op == 0xD4 then
                if base == 0 then return {"error('aam 0')"} end
                return {"t = ax & 0xFF; ax = ((t // " .. base .. ") << 8) | (t % " .. base .. "); r = ax & 0xFF; zf = r == 0; sf = r >= 0x80; pf = PAR[r]"}
            end
            return {"ax = ((ax & 0xFF) + (ax >> 8) * " .. base .. ") & 0xFF; r = ax; zf = r == 0; sf = r >= 0x80; pf = PAR[r]"}
        end, 0, SZP)
    end
    if op == 0xD6 then
        return done(function() return {"ax = (ax & 0xFF00) | (cf and 0xFF or 0)"} end, CF, 0)
    end
    if op == 0xD7 then
        local sbase = (seg or "ds") .. "b"
        if seg == "cs" then sbase = "CSB" end
        return done(function()
            return {"ax = (ax & 0xFF00) | rb(" .. sbase .. " + ((bx + (ax & 0xFF)) & 0xFFFF))"}
        end)
    end
    if op >= 0xD8 and op <= 0xDF then
        unsupported(ip0, "x87 floating point")
    end
    if op >= 0xE0 and op <= 0xE3 then
        local d = sb()
        local target = (ip + d) & 0xFFFF
        return done(function(_, ctx)
            if op == 0xE3 then
                return {"if cx == 0 then " .. ctx.exit(hex(target)) .. " end", ctx.exit(hex(ip))}
            end
            local extra = op == 0xE0 and " and not zf" or op == 0xE1 and " and zf" or ""
            return {"cx = (cx - 1) & 0xFFFF", "if cx ~= 0" .. extra .. " then " .. ctx.exit(hex(target)) .. " end",
                    ctx.exit(hex(ip))}
        end, (op == 0xE0 or op == 0xE1) and ZF or 0, 0, true)
    end
    if op == 0xE4 or op == 0xE5 or op == 0xEC or op == 0xED then
        if op < 0xE8 then b() end
        local w = (op & 1) == 1 and 2 or 1
        return done(function() return {w == 1 and "ax = ax | 0xFF" or "ax = 0xFFFF"} end)
    end
    if op == 0xE6 or op == 0xE7 or op == 0xEE or op == 0xEF then
        if op < 0xE8 then b() end
        return done(function() return {} end)
    end
    if op == 0xE8 then
        local d = w16()
        local target = (ip + d) & 0xFFFF
        return done(function(_, ctx)
            return {"sp = (sp - 2) & 0xFFFF; ww(ssb + sp, " .. hex(ip) .. ")", ctx.exit(hex(target))}
        end, 0, 0, true)
    end
    if op == 0xE9 or op == 0xEB then
        local d = op == 0xE9 and w16() or (sb() & 0xFFFF)
        local target = (ip + d) & 0xFFFF
        return done(function(_, ctx) return {ctx.exit(hex(target))} end, 0, 0, true)
    end
    if op == 0xEA then
        local off = w16()
        local sel = w16()
        return done(function(_, ctx) return {"R.cs = " .. hex(sel), ctx.exit(hex(off))} end, 0, 0, true)
    end
    if op == 0xF4 then
        return done(function(_, ctx) return {ctx.store(), "R.ip = " .. hex(ip), "return H.INT(R, -1)"} end, 0, 0, true)
    end
    if op == 0xF5 then return done(function() return {"cf = not cf"} end, CF, CF) end
    if op == 0xF6 or op == 0xF7 then
        local w = op == 0xF6 and 1 or 2
        local _, sop, rmo = modrm(w)
        if sop == 0 or sop == 1 then
            local imm = w == 1 and b() or w16()
            return done(function(need, ctx)
                local L = {"a = " .. get(rmo, ctx), "b = " .. hex(imm)}
                alu(L, 4, w, need)
                return L
            end, 0, ALL)
        end
        if sop == 2 then
            return done(function(_, ctx)
                local L = {}
                local d = rmw(rmo, ctx, L)
                L[#L + 1] = set(d, "(~" .. get(d, ctx) .. ") & " .. mask(w), ctx)
                return L
            end)
        end
        if sop == 3 then
            return done(function(need, ctx)
                local L = {}
                local d = rmw(rmo, ctx, L)
                L[#L + 1] = "a = 0; b = " .. get(d, ctx)
                alu(L, 5, w, need)
                L[#L + 1] = set(d, "r", ctx)
                return L
            end, 0, ALL)
        end
        local name = ({[4] = "MUL", [5] = "IMUL", [6] = "DIV", [7] = "IDIV"})[sop] .. (w == 1 and "8" or "16")
        return done(function(_, ctx)
            if sop <= 5 then
                if w == 1 then return {"ax, cf = H." .. name .. "(ax, " .. get(rmo, ctx) .. "); of = cf"} end
                return {"ax, dx, cf = H." .. name .. "(ax, dx, " .. get(rmo, ctx) .. "); of = cf"}
            end
            -- a divide error raises INT 0
            local L = {ctx.store(), "R.ip = " .. hex(ip0)}
            if w == 1 then
                L[#L + 1] = "t, v = H." .. name .. "(ax, " .. get(rmo, ctx) .. ")"
                L[#L + 1] = "if not t then return H.INT(R, 0) end"
                L[#L + 1] = "ax = t"
            else
                L[#L + 1] = "t, v = H." .. name .. "(ax, dx, " .. get(rmo, ctx) .. ")"
                L[#L + 1] = "if not t then return H.INT(R, 0) end"
                L[#L + 1] = "ax, dx = t, v"
            end
            return L
        end, 0, sop <= 5 and (CF | OF) or 0)
    end
    if op == 0xF8 then return done(function() return {"cf = false"} end, 0, CF) end
    if op == 0xF9 then return done(function() return {"cf = true"} end, 0, CF) end
    if op == 0xFA or op == 0xFB then return done(function() return {} end) end
    if op == 0xFC then return done(function() return {"R.df = false"} end) end
    if op == 0xFD then return done(function() return {"R.df = true"} end) end
    if op == 0xFE or op == 0xFF then
        local w = op == 0xFE and 1 or 2
        local _, sop, rmo = modrm(w)
        if sop == 0 or sop == 1 then
            local inc = sop == 0
            return done(function(need, ctx)
                local L = {}
                local d = rmw(rmo, ctx, L)
                L[#L + 1] = "a = " .. get(d, ctx)
                local m = mask(w)
                L[#L + 1] = "r = (a " .. (inc and "+" or "-") .. " 1) & " .. m
                if need & OF ~= 0 then
                    L[#L + 1] = "of = r == " .. (inc and sign(w) or (w == 1 and "0x7F" or "0x7FFF"))
                end
                if need & AF ~= 0 then L[#L + 1] = "af = (r & 0xF) == " .. (inc and "0" or "0xF") end
                szp(L, need, "r", w)
                L[#L + 1] = set(d, "r", ctx)
                return L
            end, 0, OF | AF | SZP)
        end
        if w == 1 then unsupported(ip0, "FE /" .. sop) end
        if sop == 2 then
            return done(function(_, ctx)
                return {"t = " .. get(rmo, ctx), "sp = (sp - 2) & 0xFFFF; ww(ssb + sp, " .. hex(ip) .. ")", ctx.exit("t")}
            end, 0, 0, true)
        end
        if sop == 3 or sop == 5 then
            if rmo.k ~= "m" then unsupported(ip0, "far call/jmp through a register") end
            return done(function(_, ctx)
                local L = {}
                rmw(rmo, ctx, L)
                L[#L + 1] = "t = rw(A); v = rw(A + 2)"
                if sop == 3 then
                    L[#L + 1] = "sp = (sp - 2) & 0xFFFF; ww(ssb + sp, " .. hex(csSel) .. ")"
                    L[#L + 1] = "sp = (sp - 2) & 0xFFFF; ww(ssb + sp, " .. hex(ip) .. ")"
                end
                L[#L + 1] = "R.cs = v"
                L[#L + 1] = ctx.exit("t")
                return L
            end, 0, 0, true)
        end
        if sop == 4 then
            return done(function(_, ctx) return {ctx.exit(get(rmo, ctx))} end, 0, 0, true)
        end
        if sop == 6 then
            return done(function(_, ctx)
                return {"v = " .. get(rmo, ctx), "sp = (sp - 2) & 0xFFFF; ww(ssb + sp, v)"}
            end)
        end
        unsupported(ip0, "FF /7")
    end
    if op == 0x0F then
        local op2 = b()
        if op2 == 0x00 or op2 == 0x01 then
            local _, sop, rmo = modrm(2)
            if op2 == 0x01 and sop == 4 then   -- smsw: protected mode
                return done(function(_, ctx) return {set(rmo, "0xFFF1", ctx)} end)
            end
            if op2 == 0x00 and (sop == 4 or sop == 5) then   -- verr/verw
                return done(function(_, ctx) return {"zf = H.VALIDSEL(" .. get(rmo, ctx) .. ")"} end, 0, ZF)
            end
            unsupported(ip0, string.format("0F %02X /%d", op2, sop))
        end
        if op2 == 0x02 or op2 == 0x03 then   -- lar / lsl
            local _, reg, rmo = modrm(2)
            local fn = op2 == 0x02 and "LAR" or "LSL"
            return done(function(_, ctx)
                return {"t = H." .. fn .. "(" .. get(rmo, ctx) .. ")",
                        "if t then " .. R16[reg] .. " = t; zf = true else zf = false end"}
            end, 0, ZF)
        end
        unsupported(ip0, string.format("0F %02X", op2))
    end
    unsupported(ip0, string.format("opcode %02X", op))
end

M.decode = decode

-- ---- blocks -----------------------------------------------------------------------

local MAX_INSNS = 128

local HEADER = [[
local rb, rw, wb, ww, SEL, PAR, H = ...
return function(R)
local ax, cx, dx, bx, sp, bp, si, di = R.ax, R.cx, R.dx, R.bx, R.sp, R.bp, R.si, R.di
local cf, pf, af, zf, sf, of = R.cf, R.pf, R.af, R.zf, R.sf, R.of
local dsb, esb, ssb = R.dsb, R.esb, R.ssb
local A, a, b, c, d, r, t, v
]]

local STORE = "R.ax, R.cx, R.dx, R.bx, R.sp, R.bp, R.si, R.di = ax, cx, dx, bx, sp, bp, si, di; " ..
              "R.cf, R.pf, R.af, R.zf, R.sf, R.of = cf, pf, af, zf, sf, of"

-- Decodes and generates the Lua for one block. Returns the source and the
-- decoded instruction count.
function M.source(fetch, csSel, csBase, ip)
    local insns = {}
    local at = ip
    while true do
        local I = decode(fetch, at, csSel)
        I.ip = at
        insns[#insns + 1] = I
        at = I.next
        if I.term or #insns >= MAX_INSNS then break end
    end

    -- Flag liveness, backward: at every exit all flags are live.
    local live = ALL
    for i = #insns, 1, -1 do
        local I = insns[i]
        if I.term then live = ALL end
        I.need = I.wf & live
        live = (live & ~I.wf) | I.rf
        -- an instruction that reads flags and writes some of them
        -- conditionally (shifts by a zero count) keeps them live: rf covers it
    end

    local ctx = {}
    function ctx.lin(o)
        local base = o.seg == "cs" and hex(csBase) or (o.seg .. "b")
        return base .. " + " .. o.ea
    end
    function ctx.store() return STORE end
    function ctx.exit(ipExpr) return STORE .. "; R.ip = " .. ipExpr .. "; do return end" end

    local out = {HEADER, "local CSB = " .. hex(csBase) .. "\n"}
    for _, I in ipairs(insns) do
        out[#out + 1] = string.format("-- %04X\n", I.ip)
        for _, line in ipairs(I.gen(I.need, ctx)) do
            if line ~= "" then out[#out + 1] = line .. "\n" end
        end
    end
    local last = insns[#insns]
    if not last.term then out[#out + 1] = ctx.exit(hex(last.next)) .. "\n" end
    out[#out + 1] = "end\n"
    return table.concat(out), #insns
end

return M

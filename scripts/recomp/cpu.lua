-- The machine the recompiled code runs on: protected-mode selectors over the
-- host's linear memory, the block cache, the dispatcher, and the helpers the
-- generated blocks call (multiply, divide, shifts, BCD, flags).
--
-- Control leaves the 16-bit world through far calls into the thunk
-- selector: each import of the program (USER.41 CreateWindow, ...) is
-- relocated to THUNK:n, and the dispatcher hands n to the Win16 layer
-- instead of running code there. The Win16 layer calls back into 16-bit
-- code (window procedures, ...) with cpu.call16, which runs a nested
-- dispatcher until the callee returns to a sentinel address.

local x86 = require("recomp.x86")

local cpu = {}

local rb, rw, wb, ww = mem.rb, mem.rw, mem.wb, mem.ww

-- ---- linear memory ------------------------------------------------------------------
-- First fit over the host's 16 MB; the bottom 64 KB stays unused so a null
-- far pointer never lands on anything.

local heap = {free = {{at = 0x10000, size = mem.size - 0x10000}}, used = {}}

function cpu.lalloc(size)
    size = (math.max(size, 1) + 15) & ~15
    for i, f in ipairs(heap.free) do
        if f.size >= size then
            local at = f.at
            f.at, f.size = f.at + size, f.size - size
            if f.size == 0 then table.remove(heap.free, i) end
            heap.used[at] = size
            mem.fill(at, size, 0)
            return at
        end
    end
    error("out of linear memory (" .. size .. " bytes)")
end

function cpu.lfree(at)
    local size = heap.used[at]
    if not size then return end
    heap.used[at] = nil
    local free = heap.free
    local i = 1
    while i <= #free and free[i].at < at do i = i + 1 end
    table.insert(free, i, {at = at, size = size})
    -- merge with the neighbours
    if i < #free and free[i].at + free[i].size == free[i + 1].at then
        free[i].size = free[i].size + free[i + 1].size
        table.remove(free, i + 1)
    end
    if i > 1 and free[i - 1].at + free[i - 1].size == free[i].at then
        free[i - 1].size = free[i - 1].size + free[i].size
        table.remove(free, i)
    end
end

function cpu.lsize(at) return heap.used[at] end

-- ---- selectors --------------------------------------------------------------------
-- Selector = index << 3 | 7 (LDT, ring 3), as Windows 3.1 hands them out.

local sels = {}          -- selector -> {base=, limit=, code=bool, owner=...}
local nextIndex = 1
local freeIdx = {}

function cpu.newsel(base, limit, code)
    local idx = table.remove(freeIdx) or nextIndex
    if idx == nextIndex then nextIndex = nextIndex + 1 end
    if idx >= 0x2000 then error("out of selectors") end
    local s = (idx << 3) | 7
    sels[s] = {base = base, limit = limit, code = code or false}
    return s
end

function cpu.freesel(s)
    if sels[s] then
        sels[s] = nil
        freeIdx[#freeIdx + 1] = s >> 3
        cpu.invalidate(s)
    end
end

function cpu.sel(s) return sels[s] end

function cpu.setsel(s, base, limit)
    local d = sels[s]
    d.base, d.limit = base, limit
    cpu.invalidate(s)
end

local function SEL(s)
    if s == 0 then return 0 end
    local d = sels[s]
    if not d then error(string.format("load of an invalid selector %04X", s), 0) end
    return d.base
end
cpu.SEL = SEL

-- far pointer (sel:off) -> linear address
function cpu.lin(sel, off)
    if sel == 0 then return nil end
    local d = sels[sel]
    if not d then return nil end
    return d.base + (off & 0xFFFF)
end

-- a 32-bit far pointer value -> linear (nil for NULL)
function cpu.flat(fp)
    if not fp or fp == 0 then return nil end
    return cpu.lin(fp >> 16, fp & 0xFFFF)
end

-- ---- helpers for the generated code --------------------------------------------------

local PAR = {}
for i = 0, 255 do
    local n, v = 0, i
    while v ~= 0 do n = n + (v & 1); v = v >> 1 end
    PAR[i] = n % 2 == 0
end

local H = {}

local function sx8(v) return v >= 0x80 and v - 0x100 or v end
local function sx16(v) return v >= 0x8000 and v - 0x10000 or v end

function H.FLAGS(cf, pf, af, zf, sf, of, R)
    return (cf and 1 or 0) | 2 | (pf and 4 or 0) | (af and 0x10 or 0) | (zf and 0x40 or 0) |
           (sf and 0x80 or 0) | 0x200 | (R.df and 0x400 or 0) | (of and 0x800 or 0)
end

function H.SETFLAGS(w, R)
    R.df = w & 0x400 ~= 0
    return w & 1 ~= 0, w & 4 ~= 0, w & 0x10 ~= 0, w & 0x40 ~= 0, w & 0x80 ~= 0, w & 0x800 ~= 0
end

local function shifts(W)
    local m, s = (1 << W) - 1, 1 << (W - 1)
    local t = {}
    t.SHL = function(a, c)
        local r = (a << c) & m
        local cf = c <= W and ((a >> (W - c)) & 1) ~= 0
        return r, cf, ((r & s) ~= 0) ~= cf
    end
    t.SHR = function(a, c)
        local r = a >> c
        return r, ((a >> (c - 1)) & 1) ~= 0, (a & s) ~= 0
    end
    t.SAR = function(a, c)
        local v = a >= s and a - (1 << W) or a
        if c > W then c = W end
        return (v >> c | (v < 0 and ~(m >> c) or 0)) & m, ((v >> (c - 1)) & 1) ~= 0, false
    end
    t.ROL = function(a, c)
        local k = c % W
        local r = ((a << k) | (a >> (W - k))) & m
        local cf = (r & 1) ~= 0
        return r, cf, ((r & s) ~= 0) ~= cf
    end
    t.ROR = function(a, c)
        local k = c % W
        local r = ((a >> k) | (a << (W - k))) & m
        local cf = (r & s) ~= 0
        return r, cf, ((r & s) ~= 0) ~= ((r & (s >> 1)) ~= 0)
    end
    t.RCL = function(a, c, cf)
        for _ = 1, c % (W + 1) do
            local out = (a & s) ~= 0
            a = ((a << 1) | (cf and 1 or 0)) & m
            cf = out
        end
        return a, cf, ((a & s) ~= 0) ~= cf
    end
    t.RCR = function(a, c, cf)
        local of = ((a & s) ~= 0) ~= cf
        for _ = 1, c % (W + 1) do
            local out = (a & 1) ~= 0
            a = (a >> 1) | (cf and s or 0)
            cf = out
        end
        return a, cf, of
    end
    return t
end
for W, suffix in pairs({[8] = "8", [16] = "16"}) do
    for k, f in pairs(shifts(W)) do H[k .. suffix] = f end
end
-- SAR via arithmetic: Lua's >> is logical, so do it by hand.
H.SAR8 = function(a, c)
    local v = sx8(a)
    if c > 8 then c = 8 end
    local r = v // (1 << c)
    return r & 0xFF, ((v // (1 << (c - 1))) & 1) ~= 0, false
end
H.SAR16 = function(a, c)
    local v = sx16(a)
    if c > 16 then c = 16 end
    local r = v // (1 << c)
    return r & 0xFFFF, ((v // (1 << (c - 1))) & 1) ~= 0, false
end

function H.MUL8(ax, b)
    local r = (ax & 0xFF) * b
    return r, r > 0xFF
end
function H.IMUL8(ax, b)
    local r = sx8(ax & 0xFF) * sx8(b)
    return r & 0xFFFF, r < -128 or r > 127
end
function H.MUL16(ax, dx, b)
    local r = ax * b
    return r & 0xFFFF, r >> 16, r > 0xFFFF
end
function H.IMUL16(ax, dx, b)
    local r = sx16(ax) * sx16(b)
    return r & 0xFFFF, (r >> 16) & 0xFFFF, r < -32768 or r > 32767
end
function H.IMUL3(a, b)
    local r = sx16(a) * sx16(b)
    return r & 0xFFFF, r < -32768 or r > 32767
end
-- Truncating division (toward zero), as x86 IDIV.
local function tdiv(n, d)
    local q = n // d
    if (n % d ~= 0) and ((n < 0) ~= (d < 0)) then q = q + 1 end
    return q, n - q * d
end
function H.DIV8(ax, b)
    if b == 0 then return nil end
    local q, r = ax // b, ax % b
    if q > 0xFF then return nil end
    return (r << 8) | q
end
function H.IDIV8(ax, b)
    b = sx8(b)
    if b == 0 then return nil end
    local q, r = tdiv(sx16(ax), b)
    if q < -128 or q > 127 then return nil end
    return ((r & 0xFF) << 8) | (q & 0xFF)
end
function H.DIV16(ax, dx, b)
    if b == 0 then return nil end
    local n = (dx << 16) | ax
    local q = n // b
    if q > 0xFFFF then return nil end
    return q, n % b
end
function H.IDIV16(ax, dx, b)
    b = sx16(b)
    if b == 0 then return nil end
    local n = (dx << 16) | ax
    if n >= 0x80000000 then n = n - 0x100000000 end
    local q, r = tdiv(n, b)
    if q < -32768 or q > 32767 then return nil end
    return q & 0xFFFF, r & 0xFFFF
end

function H.DAA(ax, cf, af)
    local al = ax & 0xFF
    local oldal, oldcf = al, cf
    cf = false
    if (al & 0xF) > 9 or af then al = al + 6; cf = oldcf or al > 0xFF; af = true else af = false end
    if oldal > 0x99 or oldcf then al = al + 0x60; cf = true end
    al = al & 0xFF
    return (ax & 0xFF00) | al, cf, af, al == 0, al >= 0x80, PAR[al], false
end
function H.DAS(ax, cf, af)
    local al = ax & 0xFF
    local oldal, oldcf = al, cf
    cf = false
    if (al & 0xF) > 9 or af then al = al - 6; cf = oldcf or al < 0; af = true else af = false end
    if oldal > 0x99 or oldcf then al = al - 0x60; cf = true end
    al = al & 0xFF
    return (ax & 0xFF00) | al, cf, af, al == 0, al >= 0x80, PAR[al], false
end
function H.AAA(ax, cf, af)
    if (ax & 0xF) > 9 or af then
        ax = (ax + 0x106) & 0xFFFF
        af, cf = true, true
    else
        af, cf = false, false
    end
    ax = ax & 0xFF0F
    local al = ax & 0xFF
    return ax, cf, af, al == 0, false, PAR[al], false
end
function H.AAS(ax, cf, af)
    if (ax & 0xF) > 9 or af then
        local al = ((ax & 0xFF) - 6) & 0xFF
        local ah = ((ax >> 8) - 1) & 0xFF
        ax = (ah << 8) | al
        af, cf = true, true
    else
        af, cf = false, false
    end
    ax = ax & 0xFF0F
    local al = ax & 0xFF
    return ax, cf, af, al == 0, false, PAR[al], false
end

H.MOVE = mem.move
function H.FILL(at, count, v, w)
    if w == 1 then mem.fill(at, count, v)
    elseif (v & 0xFF) == (v >> 8) then mem.fill(at, count * 2, v & 0xFF)
    else for i = 0, count - 1 do ww(at + i * 2, v) end end
end

function H.VALIDSEL(s) return sels[s] ~= nil end
function H.LSL(s)
    local d = sels[s]
    return d and d.limit or nil
end
function H.LAR(s)
    local d = sels[s]
    if not d then return nil end
    return d.code and 0xFA00 or 0xF200
end

-- Interrupt handlers: cpu.ints[n] = function(R). -1 is HLT.
cpu.ints = {}
function H.INT(R, n)
    local h = cpu.ints[n]
    if not h then
        error(string.format("unhandled INT %02Xh at %04X:%04X", n & 0xFF, R.cs, R.ip), 0)
    end
    h(R)
end

cpu.H = H
cpu.PAR = PAR

-- ---- registers ----------------------------------------------------------------------

function cpu.newregs()
    return {ax = 0, cx = 0, dx = 0, bx = 0, sp = 0, bp = 0, si = 0, di = 0,
            cs = 0, ip = 0, ds = 0, es = 0, ss = 0, dsb = 0, esb = 0, ssb = 0,
            cf = false, pf = false, af = false, zf = false, sf = false, of = false, df = false}
end

function cpu.setseg(R, name, s)
    R[name] = s
    R[name .. "b"] = SEL(s)
end

-- ---- the block cache and the dispatcher ---------------------------------------------

local cache = {}           -- cs << 16 | ip -> compiled block
cpu.stats = {blocks = 0, insns = 0, runs = 0}
cpu.dump = nil             -- set to a folder to write each block's Lua source there

-- Blocks of a segment are dropped when its selector changes (freed, moved).
function cpu.invalidate(s)
    local lo, hi = s << 16, (s << 16) | 0xFFFF
    for k in pairs(cache) do
        if k >= lo and k <= hi then cache[k] = nil end
    end
end

function cpu.flush() cache = {} end

local function compile(cs, ip)
    local d = sels[cs]
    if not d then error(string.format("jump to an invalid selector %04X:%04X", cs, ip), 0) end
    local base = d.base
    local limit = d.limit
    local function fetch(off)
        if off > limit then error(string.format("code past the segment limit at %04X:%04X", cs, off), 0) end
        return rb(base + off)
    end
    local ok, src, n = pcall(x86.source, fetch, cs, base, ip)
    if not ok then
        if type(src) == "table" and src.recomp then
            error(string.format("cannot recompile %04X:%04X: %s", cs, src.ip, src.msg), 0)
        end
        error(src, 0)
    end
    local name = string.format("=%04X:%04X", cs, ip)
    local chunk, err = load(src, name, "t", {ipairs = ipairs, error = error})
    if not chunk then error("recompiler produced bad Lua for " .. name .. ": " .. err .. "\n" .. src, 0) end
    if cpu.dump then
        local f = io.open(string.format("%s/%04X_%04X.lua", cpu.dump, cs, ip), "w")
        if f then f:write(src); f:close() end
    end
    local fn = chunk(rb, rw, wb, ww, SEL, PAR, H)
    cpu.stats.blocks = cpu.stats.blocks + 1
    cpu.stats.insns = cpu.stats.insns + n
    cache[(cs << 16) | ip] = fn
    return fn
end

-- far calls to THUNK_SEL:n go to cpu.thunks[n](R)
cpu.THUNK_SEL = nil
cpu.thunks = {}
cpu.SENTINEL = 0xFFFF       -- THUNK_SEL:FFFF ends a call16

-- Runs until control reaches THUNK_SEL:SENTINEL at the given depth.
local depth = 0
function cpu.run(R)
    local thunk = cpu.THUNK_SEL
    local thunks = cpu.thunks
    local sentinel = cpu.SENTINEL
    while true do
        local cs, ip = R.cs, R.ip
        if cs == thunk then
            if ip == sentinel then return end
            local f = thunks[ip]
            if not f then error(string.format("call to an unknown thunk %04X", ip), 0) end
            f(R)
        else
            local fn = cache[(cs << 16) | ip] or compile(cs, ip)
            fn(R)
        end
    end
end

local SAVE = {"ax", "cx", "dx", "bx", "sp", "bp", "si", "di", "cs", "ip", "ds", "es", "ss", "dsb", "esb", "ssb",
              "cf", "pf", "af", "zf", "sf", "of", "df"}

-- Calls a 16-bit far procedure (Pascal: arguments pushed in order, the callee
-- pops them) and returns AX, DX. regs: optional register values to set
-- first (ds = ..., ax = ...). Every register is restored afterwards.
function cpu.call16(R, sel, off, args, regs)
    local saved = {}
    for _, k in ipairs(SAVE) do saved[k] = R[k] end
    local sp = R.sp
    local ssb = R.ssb
    for _, v in ipairs(args or {}) do
        sp = (sp - 2) & 0xFFFF
        ww(ssb + sp, v & 0xFFFF)
    end
    sp = (sp - 2) & 0xFFFF; ww(ssb + sp, cpu.THUNK_SEL)
    sp = (sp - 2) & 0xFFFF; ww(ssb + sp, cpu.SENTINEL)
    R.sp = sp
    if regs then
        for k, v in pairs(regs) do
            if k == "ds" or k == "es" then cpu.setseg(R, k, v) else R[k] = v end
        end
    end
    R.cs, R.ip = sel, off
    depth = depth + 1
    if depth > 200 then depth = 0; error("callbacks nested too deeply", 0) end
    local ok, err = pcall(cpu.run, R)
    depth = depth - 1
    local ax, dx = R.ax, R.dx
    for _, k in ipairs(SAVE) do R[k] = saved[k] end
    if not ok then error(err, 0) end
    return ax, dx
end

function cpu.depth() return depth end

return cpu

-- The Win16 API registry: every function the program imports is defined here
-- by module, ordinal, name and Pascal signature, and reached through a thunk
-- (a far address in the thunk selector the loader writes into the program).
--
-- Signatures list the arguments left to right (the order the caller pushes
-- them; Pascal callees pop them):
--   w  WORD          i  INT (signed)      h  a handle (WORD)
--   l  DWORD         n  LONG (signed)     f  far pointer, raw (sel << 16 | off)
--   p  far pointer as a linear address (nil when NULL)
--   s  far pointer to a string, read as a Lua string (nil when NULL)
--   r  a resource name: a number when the selector is 0 (MAKEINTRESOURCE), else a string
-- and after a colon the return type: w (AX), l (DX:AX), v (nothing).

local cpu = require("recomp.cpu")

local api = {}

api.byName = {}          -- "USER.CREATEWINDOW" -> def
api.byOrd = {}           -- "USER" -> {ord -> def}
api.thunkOf = {}         -- def -> thunk index
api.defOfThunk = {}      -- thunk index -> def
api.trace = false        -- log every call
api.counts = {}

local thunks = cpu.thunks
local nextThunk = 1

local rw, rd = mem.rw, mem.rd

local function argSize(c)
    if c == "l" or c == "n" or c == "f" or c == "p" or c == "s" or c == "r" then return 4 end
    return 2
end

-- Reads the arguments of a Pascal call from the stack at SS:SP+4.
local function readArgs(R, sig)
    local n = #sig
    local at = R.ssb + ((R.sp + 4) & 0xFFFF)
    local args = {}
    -- the last argument is at the lowest address
    for i = n, 1, -1 do
        local c = sig:sub(i, i)
        if argSize(c) == 4 then
            local v = rd(at)
            at = at + 4
            if c == "n" then
                if v >= 0x80000000 then v = v - 0x100000000 end
            elseif c == "p" then
                v = cpu.flat(v)
            elseif c == "s" then
                local l = cpu.flat(v)
                v = l and mem.cstr(l) or nil
            elseif c == "r" then
                if (v >> 16) == 0 then v = v & 0xFFFF
                else
                    local l = cpu.flat(v)
                    v = l and mem.cstr(l) or nil
                    if v and v:sub(1, 1) == "#" and tonumber(v:sub(2)) then v = tonumber(v:sub(2)) end
                end
            end
            args[i] = v
        else
            local v = rw(at)
            at = at + 2
            if c == "i" and v >= 0x8000 then v = v - 0x10000 end
            args[i] = v
        end
    end
    return args, n
end
api.readArgs = readArgs

local function sigBytes(sig)
    local n = 0
    for i = 1, #sig do n = n + argSize(sig:sub(i, i)) end
    return n
end

local function retf(R, n)
    local ssb, sp = R.ssb, R.sp
    R.ip = rw(ssb + sp)
    R.cs = rw(ssb + ((sp + 2) & 0xFFFF))
    R.sp = (sp + 4 + n) & 0xFFFF
end
api.retf = retf

local function toWord(v)
    if v == true then return 1 elseif v == false or v == nil then return 0 end
    return math.tointeger(v) and (v & 0xFFFF) or (math.floor(v) & 0xFFFF)
end

-- Defines an API function. fn(...) gets the decoded arguments (and the
-- register table as the last argument) and returns the result.
function api.def(module, ord, name, signature, fn)
    local args, ret = signature:match("^([^:]*):?(.*)$")
    args = args:gsub("%s", "")
    if ret == "" then ret = "w" end
    local def = {module = module, ord = ord, name = name, sig = args, ret = ret, fn = fn, bytes = sigBytes(args)}
    api.byName[module .. "." .. name:upper()] = def
    api.byOrd[module] = api.byOrd[module] or {}
    if ord then api.byOrd[module][ord] = def end
    return def
end

-- The thunk index for a definition, made on first use.
local function thunkFor(def)
    local idx = api.thunkOf[def]
    if idx then return idx end
    idx = nextThunk
    nextThunk = nextThunk + 1
    api.thunkOf[def] = idx
    api.defOfThunk[idx] = def
    local sig, bytes, ret, fn, full = def.sig, def.bytes, def.ret, def.fn, def.module .. "." .. def.name
    thunks[idx] = function(R)
        local args, n = readArgs(R, sig)
        args[n + 1] = R
        if api.trace then
            local parts = {}
            for i = 1, n do
                local a = args[i]
                parts[i] = type(a) == "string" and string.format("%q", a) or type(a) == "number" and string.format("0x%X", a) or tostring(a)
            end
            host.log(string.rep("  ", cpu.depth()) .. full .. "(" .. table.concat(parts, ", ") .. ")")
        end
        api.counts[full] = (api.counts[full] or 0) + 1
        -- return to the caller first, so a callback made by fn runs on a clean stack
        retf(R, bytes)
        local r1, r2 = fn(table.unpack(args, 1, n + 1))
        if ret == "l" then
            local v = r1
            if v == true then v = 1 elseif not v then v = 0 end
            if r2 then v = (r2 << 16) | (v & 0xFFFF) end
            v = math.tointeger(v) or math.floor(v)
            R.ax, R.dx = v & 0xFFFF, (v >> 16) & 0xFFFF
        elseif ret == "w" then
            R.ax = toWord(r1)
            if r2 then R.dx = toWord(r2) end
        end
        if api.trace and ret ~= "v" then
            host.log(string.rep("  ", cpu.depth()) .. "  -> " .. string.format("%04X:%04X", R.dx, R.ax))
        end
    end
    return idx
end

-- Unimplemented imports: a stub that logs once and returns 0. The argument
-- count must still be right, so these come from a table of signatures.
local warned = {}
function api.stub(module, ord, name, sig)
    return api.def(module, ord, name, sig, function()
        if not warned[name] then
            warned[name] = true
            host.log("Win16: " .. module .. "." .. name .. " is not implemented (returning 0)")
        end
        return 0
    end)
end

-- The loader's resolver: returns the thunk's far address, or a constant.
function api.resolve(module, ord, name)
    local def
    if ord then def = api.byOrd[module] and api.byOrd[module][ord]
    else def = api.byName[module .. "." .. name:upper()] end
    if not def then
        error(string.format("import %s.%s is not in the Win16 layer", module, ord or name), 0)
    end
    if def.const then return nil, def.const end
    return cpu.THUNK_SEL, thunkFor(def)
end

-- A constant import (KERNEL.__WINFLAGS, ...).
function api.const(module, ord, name, value)
    local d = api.def(module, ord, name, "", function() return value end)
    d.const = value
end

-- The far address of a Lua function callable from 16-bit code (for window
-- procedures of built-in classes, GetProcAddress results, ...).
local luaProcs = {}
function api.farproc(name, sig, fn)
    local def = luaProcs[name]
    if not def then
        def = {module = "LUA", name = name, sig = sig:match("^([^:]*)"):gsub("%s", ""), ret = sig:match(":(.*)$") or "w", fn = fn}
        def.bytes = sigBytes(def.sig)
        luaProcs[name] = def
    end
    return (cpu.THUNK_SEL << 16) | thunkFor(def), def
end

-- The Lua function behind a far address, when it is one of ours.
function api.luaproc(fp)
    if (fp >> 16) ~= cpu.THUNK_SEL then return nil end
    local def = api.defOfThunk[fp & 0xFFFF]
    if def then return def.fn, def end
end

-- ---- scratch memory for structures Lua hands to 16-bit code -------------------------
-- A 64 KB segment used as a stack: api.push(size) returns sel, off, linear;
-- api.pop(mark) releases back to a mark taken with api.mark().

local scratch = {}
function api.initScratch()
    scratch.base = cpu.lalloc(0x10000)
    scratch.sel = cpu.newsel(scratch.base, 0xFFFF)
    scratch.top = 0x10
end
function api.mark() return scratch.top end
function api.release(m) scratch.top = m end
function api.alloc(size)
    local off = scratch.top
    scratch.top = (scratch.top + size + 3) & ~3
    if scratch.top > 0xFFF0 then error("scratch memory exhausted") end
    mem.fill(scratch.base + off, size, 0)
    return (scratch.sel << 16) | off, scratch.base + off
end
-- A string in scratch memory: returns the far pointer.
function api.str(s)
    local fp, lin = api.alloc(#s + 1)
    mem.write(lin, s .. "\0")
    return fp, lin
end

-- ---- small helpers ----------------------------------------------------------------------

-- Writes a string into a 16-bit buffer of size n (with the NUL), returns the length copied.
function api.putstr(lin, s, n)
    if not lin or (n and n <= 0) then return 0 end
    if n and #s > n - 1 then s = s:sub(1, n - 1) end
    mem.write(lin, s .. "\0")
    return #s
end

function api.s16(v) return v >= 0x8000 and v - 0x10000 or v end

-- RECT (4 INTs) at a linear address
function api.getrect(lin)
    if not lin then return nil end
    local s = api.s16
    return {s(rw(lin)), s(rw(lin + 2)), s(rw(lin + 4)), s(rw(lin + 6))}
end
function api.setrect(lin, r)
    if not lin then return end
    mem.ww(lin, r[1] & 0xFFFF); mem.ww(lin + 2, r[2] & 0xFFFF)
    mem.ww(lin + 4, r[3] & 0xFFFF); mem.ww(lin + 6, r[4] & 0xFFFF)
end
function api.getpt(lin)
    return api.s16(rw(lin)), api.s16(rw(lin + 2))
end
function api.setpt(lin, x, y)
    mem.ww(lin, x & 0xFFFF); mem.ww(lin + 2, y & 0xFFFF)
end

-- POINT packed in a LONG (lParam of mouse messages, MAKELONG(x, y))
function api.mkpt(x, y) return ((y & 0xFFFF) << 16) | (x & 0xFFFF) end
function api.unpt(l) return api.s16(l & 0xFFFF), api.s16((l >> 16) & 0xFFFF) end

function api.lo(l) return l & 0xFFFF end
function api.hi(l) return (l >> 16) & 0xFFFF end
function api.mklong(lo, hi) return ((hi & 0xFFFF) << 16) | (lo & 0xFFFF) end

return api

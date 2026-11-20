-- KERNEL: the task, memory (global and local heaps), files, profiles,
-- modules, and DOS (INT 21h / DOS3Call).

local api = require("win16.api")
local cpu = require("recomp.cpu")
local dosfs = require("win16.dosfs")
local profile = require("win16.profile")

local kernel = {}
local def = api.def
local rw, ww, rb, wb = mem.rw, mem.ww, mem.rb, mem.wb

kernel.task = nil      -- {R=, inst=, hInstance=, psp=, cmdShow=, cmdLine=, path=}
kernel.modules = {}    -- module name -> {handle=, name=, file=}

-- ---- global memory: a handle is the selector -------------------------------------------

local globals = {}     -- selector -> {base=, size=, flags=, lock=}

function kernel.galloc(flags, size)
    if size > 0x10000 then return 0 end   -- huge blocks: not needed by Program Manager
    local alloc = math.max(size, 16)
    local base = cpu.lalloc(alloc)
    local sel = cpu.newsel(base, math.max(alloc, 1) - 1, false)
    globals[sel] = {base = base, size = size, alloc = alloc, flags = flags, lock = 0}
    return sel
end

function kernel.gfree(h)
    local g = globals[h]
    if not g then return h end
    globals[h] = nil
    if not g.discarded then cpu.lfree(g.base) end
    cpu.freesel(h)
    return 0
end

function kernel.global(h) return globals[h] end

function kernel.grealloc(h, size, flags)
    local g = globals[h]
    if not g then return 0 end
    if flags & 0x80 ~= 0 then   -- GMEM_MODIFY: flags only
        g.flags = (g.flags & ~0x7F00) | (flags & 0x7F00)
        return h
    end
    if size == 0 then
        -- GMEM_MOVEABLE with size 0 discards the block: GlobalLock fails and
        -- GlobalSize says 0 until it is reallocated
        if flags & 0x2 ~= 0 then
            if not g.discarded then
                cpu.lfree(g.base)
                g.discarded = true
                g.size, g.alloc = 0, 0
                g.lock = 0
            end
            return h
        end
        size = 16
    end
    if size > 0x10000 then return 0 end
    if g.discarded then
        local base = cpu.lalloc(size)
        g.base, g.size, g.alloc, g.discarded = base, size, size, false
        cpu.setsel(h, base, size - 1)
        return h
    end
    if size <= g.alloc then
        if (flags & 0x40) ~= 0 and size > g.size then mem.fill(g.base + g.size, size - g.size, 0) end
        g.size = size
        return h
    end
    local base = cpu.lalloc(size)
    mem.move(base, g.base, g.size)
    cpu.lfree(g.base)
    g.base, g.size, g.alloc = base, size, size
    cpu.setsel(h, base, size - 1)
    return h
end

-- A handle (selector) or a far pointer's selector -> the block's linear base
function kernel.glin(h)
    local g = globals[h]
    return g and not g.discarded and g.base or nil
end

-- ---- local heaps: one per data segment (the task's DGROUP, each DLL's) ----------------

local lheaps = {}      -- selector -> {free=, used=, start=}

local function heapOf(ds)
    ds = ds or (kernel.task and kernel.task.dgroup)
    return ds and lheaps[ds], ds
end

local function lheapInit(start, stop, ds)
    ds = ds or kernel.task.dgroup
    start = (start + 3) & ~3
    lheaps[ds] = {free = {{at = start, size = stop - start}}, used = {}, start = start}
end
kernel.lheapInit = lheapInit

function kernel.lalloc(flags, size, ds)
    local heap
    heap, ds = heapOf(ds)
    if not heap then return 0 end
    size = (math.max(size, 2) + 3) & ~3
    for i, f in ipairs(heap.free) do
        if f.size >= size then
            local at = f.at
            f.at, f.size = f.at + size, f.size - size
            if f.size == 0 then table.remove(heap.free, i) end
            heap.used[at] = size
            if flags & 0x40 ~= 0 then mem.fill(cpu.selbase(ds) + at, size, 0) end
            return at
        end
    end
    return 0
end

function kernel.lsize(at, ds)
    local heap = heapOf(ds)
    return heap and heap.used[at] or 0
end

function kernel.lfree(at, ds)
    local heap = heapOf(ds)
    local size = heap and heap.used[at]
    if not size then return at end
    heap.used[at] = nil
    local free = heap.free
    local i = 1
    while i <= #free and free[i].at < at do i = i + 1 end
    table.insert(free, i, {at = at, size = size})
    if i < #free and free[i].at + free[i].size == free[i + 1].at then
        free[i].size = free[i].size + free[i + 1].size
        table.remove(free, i + 1)
    end
    if i > 1 and free[i - 1].at + free[i - 1].size == free[i].at then
        free[i - 1].size = free[i - 1].size + free[i].size
        table.remove(free, i)
    end
    return 0
end

function kernel.lrealloc(at, size, flags, ds)
    local heap
    heap, ds = heapOf(ds)
    if not heap then return 0 end
    if flags & 0x80 ~= 0 then return at end   -- LMEM_MODIFY
    local old = heap.used[at]
    if not old then return 0 end
    local need = (math.max(size, 2) + 3) & ~3
    if need <= old then return at end
    local n = kernel.lalloc(0, size, ds)
    if n == 0 then return 0 end
    local base = cpu.selbase(ds)
    mem.move(base + n, base + at, old)
    if flags & 0x40 ~= 0 then mem.fill(base + n + old, heap.used[n] - old, 0) end
    kernel.lfree(at, ds)
    return n
end

-- ---- strings ----------------------------------------------------------------------------

local function str(fp)
    local l = cpu.flat(fp)
    return l and mem.cstr(l) or nil
end

-- ---- the task ---------------------------------------------------------------------------

-- Sets up the registers for a program's entry point and its PSP, the way the
-- loader does before jumping to it.
function kernel.startTask(inst, opts)
    local mod = inst.module
    local R = cpu.newregs()
    local dgroup = inst.dgroup
    local dseg = mod.segments[mod.autoData]
    local minsize = math.max(dseg.minalloc, dseg.length)
    local sp = mod.sp
    if sp == 0 then sp = (minsize + mod.stack) & 0xFFFE end
    -- PSP with the command line and the environment
    local env = "PATH=C:\\WINDOWS;C:\\WINDOWS\\SYSTEM\0COMSPEC=C:\\COMMAND.COM\0windir=C:\\WINDOWS\0\0\1\0" ..
                opts.path .. "\0"
    local envSel = kernel.galloc(0, #env + 16)
    mem.write(kernel.glin(envSel), env)
    local psp = kernel.galloc(0, 256)
    local pb = kernel.glin(psp)
    ww(pb, 0x20CD)
    ww(pb + 0x2C, envSel)
    local cl = opts.cmdLine or ""
    wb(pb + 0x80, #cl)
    -- the C runtime reads the command line up to a NUL; DOS ends it with CR
    mem.write(pb + 0x81, cl .. "\0\r")

    local task = {R = R, inst = inst, hInstance = dgroup, psp = psp, cmdShow = opts.cmdShow or 1,
                  path = opts.path, dgroup = dgroup, dgroupBase = inst.bases[mod.autoData],
                  stackLow = minsize, stackHigh = sp, heapStart = sp, module = mod}
    lheapInit(sp + 0x10, 0xFFF0, dgroup)
    cpu.setseg(R, "ds", dgroup)
    cpu.setseg(R, "es", psp)
    cpu.setseg(R, "ss", inst.sels[mod.ss] or dgroup)
    R.sp = sp
    R.bx = mod.stack
    R.cx = mod.heap
    R.di = dgroup
    R.si = 0
    R.bp = 0
    R.ax = 0
    R.cs, R.ip = inst.sels[mod.cs], mod.ip
    return task
end

def("KERNEL", 91, "InitTask", ":w", function(R)
    local t = kernel.task
    local base = t.dgroupBase
    -- the instance data at DS:0
    ww(base + 0x0A, t.stackLow)
    ww(base + 0x0C, t.stackHigh)
    ww(base + 0x0E, t.stackHigh)
    ww(base + 0x06, t.heapStart)
    R.cx = t.stackLow + 0x100
    R.di = t.hInstance
    R.si = 0
    cpu.setseg(R, "es", t.psp)
    R.bx = 0x81
    R.dx = t.cmdShow
    return 1
end)

def("KERNEL", 30, "WaitEvent", "h", function() return 0 end)
def("KERNEL", 152, "GetNumTasks", "", function() return 1 end)
def("KERNEL", 107, "SetErrorMode", "w", function(m)
    local old = kernel.errorMode or 0
    kernel.errorMode = m
    return old
end)
api.const("KERNEL", 178, "__WINFLAGS", 0x0001 | 0x0004 | 0x0020 | 0x0400)  -- PMODE, CPU386, ENHANCED, 80x87
def("KERNEL", 169, "GetFreeSpace", "w:l", function() return 0x00F00000 end)
def("KERNEL", 323, "IsRomModule", "h", function() return 0 end)

-- ---- memory -------------------------------------------------------------------------------

def("KERNEL", 15, "GlobalAlloc", "w l", function(flags, size) return kernel.galloc(flags, size) end)
def("KERNEL", 16, "GlobalReAlloc", "h l w", function(h, size, flags) return kernel.grealloc(h, size, flags) end)
def("KERNEL", 17, "GlobalFree", "h", function(h) return kernel.gfree(h) end)
def("KERNEL", 18, "GlobalLock", "h:l", function(h)
    local g = globals[h]
    if not g then
        if cpu.sel(h) then return h << 16 end   -- a segment that isn't a global block (DGROUP, ...)
        return 0
    end
    if g.discarded then return 0 end
    g.lock = g.lock + 1
    return h << 16
end)
def("KERNEL", 19, "GlobalUnlock", "h", function(h)
    local g = globals[h]
    if g and g.lock > 0 then g.lock = g.lock - 1 end
    return g and g.lock > 0
end)
def("KERNEL", 20, "GlobalSize", "h:l", function(h)
    local g = globals[h]
    return g and g.size or 0
end)
-- GlobalFlags: lock count, GMEM_DISCARDABLE 0x100, GMEM_DISCARDED 0x4000
def("KERNEL", 22, "GlobalFlags", "h", function(h)
    local g = globals[h]
    if not g then return 0 end
    return (g.lock & 0xFF) | (g.flags & 0x100) | (g.discarded and 0x4000 or 0)
end)

-- the local heap calls work on the heap in the caller's DS
def("KERNEL", 5, "LocalAlloc", "w w", function(flags, size, R) return kernel.lalloc(flags, size, R.ds) end)
def("KERNEL", 7, "LocalFree", "h", function(h, R) return kernel.lfree(h, R.ds) end)
def("KERNEL", 6, "LocalReAlloc", "h w w", function(h, size, flags, R) return kernel.lrealloc(h, size, flags, R.ds) end)
def("KERNEL", 8, "LocalLock", "h", function(h) return h end)
def("KERNEL", 9, "LocalUnlock", "h", function() return 0 end)
def("KERNEL", 10, "LocalSize", "h", function(h, R) return kernel.lsize(h, R.ds) end)
def("KERNEL", 11, "LocalHandle", "w", function(h) return h end)
def("KERNEL", 13, "LocalCompact", "w", function() return 0x4000 end)
-- LocalInit(segment, start, end): a heap in a segment (0: the caller's DS);
-- start 0 means "after the static data", where the end is the segment's size
def("KERNEL", 4, "LocalInit", "w w w", function(seg, start, stop, R)
    if seg == 0 then seg = R.ds end
    if not cpu.sel(seg) then return 0 end
    if start == 0 then
        -- the heap goes after the segment's data (pEnd is then its size;
        -- it may grow to the end of the segment here)
        start = 16
        local m = kernel.instances[seg]
        if m and m.dataEnd then start = m.dataEnd end
        stop = 0xFFF0
    end
    lheapInit(start, stop, seg)
    return 1
end)

def("KERNEL", 54, "GetInstanceData", "h w i", function() return 0 end)
def("KERNEL", 121, "LocalShrink", "h w", function() return 0xFFF0 end)
def("KERNEL", 25, "GlobalCompact", "l:l", function() return 0x00F00000 end)
def("KERNEL", 23, "LockSegment", "w", function(s, R) return s == 0xFFFF and R.ds or s end)
def("KERNEL", 24, "UnlockSegment", "w", function(s, R) return s == 0xFFFF and R.ds or s end)
def("KERNEL", 191, "GlobalPageLock", "h", function() return 1 end)
def("KERNEL", 192, "GlobalPageUnlock", "h", function() return 0 end)
-- GlobalDosAlloc: DX = a (pretend) real-mode paragraph, AX = the selector
def("KERNEL", 184, "GlobalDosAlloc", "l:l", function(size)
    local h = kernel.galloc(0x40, size)
    if h == 0 then return 0 end
    return (0x9000 << 16) | h
end)
def("KERNEL", 185, "GlobalDosFree", "w", function(h) return kernel.gfree(h) end)

-- ---- selectors ------------------------------------------------------------------------------

def("KERNEL", 175, "AllocSelector", "w", function(s)
    local d = s ~= 0 and cpu.sel(s)
    local n = cpu.newsel(d and d.base or 0, d and d.limit or 0, d and d.code)
    return n
end)
def("KERNEL", 176, "FreeSelector", "w", function(s)
    if globals[s] then return s end
    cpu.freesel(s)
    return 0
end)
def("KERNEL", 186, "GetSelectorBase", "w:l", function(s) return cpu.selbase(s) end)
def("KERNEL", 187, "SetSelectorBase", "w l", function(s, base)
    local d = cpu.sel(s)
    if not d then return 0 end
    cpu.setsel(s, base, d.limit)
    return s
end)
def("KERNEL", 189, "SetSelectorLimit", "w l", function(s, limit)
    local d = cpu.sel(s)
    if not d then return 0 end
    cpu.setsel(s, d.base, limit)
    return 0
end)
api.const("KERNEL", 113, "__AHSHIFT", 3)
api.const("KERNEL", 114, "__AHINCR", 8)

-- ---- the system ----------------------------------------------------------------------------

def("KERNEL", 3, "GetVersion", ":l", function() return (0x0500 << 16) | 0x0A03 end)  -- Windows 3.10, DOS 5.0
def("KERNEL", 132, "GetWinFlags", ":l", function() return 0x0001 | 0x0004 | 0x0020 | 0x0400 end)
def("KERNEL", 207, "IsDBCSLeadByte", "w", function() return 0 end)
def("KERNEL", 115, "OutputDebugString", "s:v", function(s) host.log("debug: " .. tostring(s)) end)
def("KERNEL", 1, "FatalExit", "i:v", function(code) error("FatalExit(" .. code .. ")", 0) end)
def("KERNEL", 137, "FatalAppExit", "w s:v", function(_, msg) error("FatalAppExit: " .. tostring(msg), 0) end)

-- ---- local atoms ------------------------------------------------------------------------------

local atoms, atomNames, nextAtom = {}, {}, 0xC000
def("KERNEL", 70, "AddAtom", "r", function(name)
    if type(name) == "number" then return name end
    local key = name:upper()
    if atoms[key] then atoms[key].refs = atoms[key].refs + 1; return atoms[key].atom end
    local a = nextAtom
    nextAtom = nextAtom + 1
    atoms[key] = {atom = a, refs = 1}
    atomNames[a] = name
    return a
end)
def("KERNEL", 69, "FindAtom", "r", function(name)
    if type(name) == "number" then return name end
    local a = atoms[name:upper()]
    return a and a.atom or 0
end)
def("KERNEL", 71, "DeleteAtom", "w", function(a)
    local name = atomNames[a]
    if not name then return 0 end
    local e = atoms[name:upper()]
    e.refs = e.refs - 1
    if e.refs <= 0 then atoms[name:upper()] = nil; atomNames[a] = nil end
    return 0
end)
def("KERNEL", 72, "GetAtomName", "w p i", function(a, buf, n)
    local name = atomNames[a] or (a < 0xC000 and ("#" .. a)) or nil
    if not name then return 0 end
    return api.putstr(buf, name, n)
end)

-- ---- resources ---------------------------------------------------------------------------------

-- FindResource gives a handle to the resource's bytes (kept until
-- LoadResource copies them into a global block).
local found = {}
local nextFound = 1
def("KERNEL", 60, "FindResource", "h r r", function(inst, name, rtype)
    local m = kernel.neModule(inst)
    if not m then return 0 end
    local data = m:resource(rtype, name)
    if not data then return 0 end
    local h = nextFound
    nextFound = nextFound + 1
    found[h] = data
    return h
end)
def("KERNEL", 61, "LoadResource", "h h", function(inst, hres)
    local data = found[hres]
    if not data then return 0 end
    local g = kernel.galloc(0x2, #data)
    if g == 0 then return 0 end
    mem.write(kernel.glin(g), data)
    return g
end)
def("KERNEL", 63, "FreeResource", "h", function(h)
    if globals[h] then kernel.gfree(h) end
    return 0
end)
def("KERNEL", 65, "SizeofResource", "h h", function(_, hres) return found[hres] and #found[hres] or 0 end)

-- MakeProcInstance: a small thunk `mov ax, DS / jmp far proc`, in real code.
local procThunks
def("KERNEL", 51, "MakeProcInstance", "f h:l", function(proc, inst)
    if not procThunks then
        procThunks = {base = cpu.lalloc(0x10000), used = 0}
        procThunks.sel = cpu.newsel(procThunks.base, 0xFFFF, true)
    end
    local ds = kernel.task.dgroup
    local off = procThunks.used
    procThunks.used = off + 8
    local at = procThunks.base + off
    wb(at, 0xB8); ww(at + 1, ds)                      -- mov ax, ds
    wb(at + 3, 0xEA); ww(at + 4, proc & 0xFFFF); ww(at + 6, proc >> 16)   -- jmp far proc
    return (procThunks.sel << 16) | off
end)
def("KERNEL", 52, "FreeProcInstance", "f:v", function() end)

-- ---- strings ---------------------------------------------------------------------------------

def("KERNEL", 88, "lstrcpy", "f f:l", function(dst, src)
    local d = cpu.flat(dst)
    if d then mem.write(d, (str(src) or "") .. "\0") end
    return dst
end)
def("KERNEL", 89, "lstrcat", "f f:l", function(dst, src)
    local d = cpu.flat(dst)
    if d then
        local s = mem.cstr(d)
        mem.write(d + #s, (str(src) or "") .. "\0")
    end
    return dst
end)
def("KERNEL", 90, "lstrlen", "f", function(s) return #(str(s) or "") end)

-- ---- profiles ----------------------------------------------------------------------------------

-- Fills ret with the value, or with the key/section list (each NUL-terminated,
-- a double NUL at the end) when key (or app) is NULL.
local function profileString(file, app, key, default, ret, size)
    if not ret or size <= 0 then return 0 end
    if not app or not key then
        local list = profile.keys(file, app)
        local out = {}
        local used = 0
        for _, k in ipairs(list) do
            if used + #k + 2 > size then break end
            out[#out + 1] = k .. "\0"
            used = used + #k + 1
        end
        local s = table.concat(out) .. "\0"
        mem.write(ret, s)
        return math.max(#s - 1, 0)
    end
    local v = profile.get(file, app, key)
    if v == nil then v = default or "" end
    return api.putstr(ret, v, size)
end

def("KERNEL", 58, "GetProfileString", "s s s p i", function(app, key, default, ret, size)
    return profileString(profile.resolve(nil), app, key, default, ret, size)
end)
def("KERNEL", 128, "GetPrivateProfileString", "s s s p i s", function(app, key, default, ret, size, file)
    return profileString(profile.resolve(file), app, key, default, ret, size)
end)
def("KERNEL", 127, "GetPrivateProfileInt", "s s i s", function(app, key, default, file)
    local v = app and key and profile.get(profile.resolve(file), app, key)
    if not v then return default end
    local n = tonumber(v:match("^%s*(%-?%d+)"))
    return n or 0
end)
def("KERNEL", 129, "WritePrivateProfileString", "s s s s", function(app, key, value, file)
    if not app then profile.flush(profile.resolve(file)); return 1 end
    return profile.set(profile.resolve(file), app, key, value)
end)
def("KERNEL", 59, "WriteProfileString", "s s s", function(app, key, value)
    if not app then profile.flush(); return 1 end
    return profile.set(profile.resolve(nil), app, key, value)
end)
def("KERNEL", 57, "GetProfileInt", "s s i", function(app, key, default)
    local v = profile.get(profile.resolve(nil), app, key)
    return v and tonumber(v:match("^%s*(%-?%d+)")) or default
end)

-- ---- files ---------------------------------------------------------------------------------------

def("KERNEL", 134, "GetWindowsDirectory", "p w", function(buf, size) return api.putstr(buf, dosfs.windows, size) end)
def("KERNEL", 135, "GetSystemDirectory", "p w", function(buf, size) return api.putstr(buf, dosfs.system, size) end)
def("KERNEL", 136, "GetDriveType", "i", function(d)
    -- 0 cannot determine, 1 doesn't exist, 2 removable, 3 fixed, 4 remote
    if d == 2 then return 3 end
    if host.platform() == "Windows" and d >= 0 and d < 26 then
        local st = host.stat(string.char(65 + d) .. ":\\")
        return st and 3 or 0
    end
    return 0
end)

local HFILE_ERROR = 0xFFFF

def("KERNEL", 85, "_lopen", "s i", function(name, mode)
    if not name then return HFILE_ERROR end
    local h = dosfs.open(name, mode & 3, false)
    return h or HFILE_ERROR
end)
def("KERNEL", 83, "_lcreat", "s i", function(name)
    if not name then return HFILE_ERROR end
    return dosfs.open(name, 2, true) or HFILE_ERROR
end)
def("KERNEL", 81, "_lclose", "h", function(h) return dosfs.close(h) and 0 or HFILE_ERROR end)
def("KERNEL", 82, "_lread", "h p w", function(h, buf, n)
    local s = dosfs.readh(h, n)
    if not s then return HFILE_ERROR end
    if buf and #s > 0 then mem.write(buf, s) end
    return #s
end)
def("KERNEL", 86, "_lwrite", "h p w", function(h, buf, n)
    local s = (buf and n > 0) and mem.read(buf, n) or ""
    local r = dosfs.writeh(h, s)
    return r or HFILE_ERROR
end)
def("KERNEL", 84, "_llseek", "h n i:l", function(h, off, origin)
    local p = dosfs.seek(h, off, origin)
    return p or 0xFFFFFFFF
end)

-- OpenFile(name, OFSTRUCT*, style). OFSTRUCT: cBytes, fFixedDisk, nErrCode,
-- reserved[4], szPathName[128].
def("KERNEL", 74, "OpenFile", "s p w", function(name, of, style)
    local OF_PARSE, OF_DELETE, OF_EXIST, OF_CREATE, OF_REOPEN = 0x100, 0x200, 0x4000, 0x1000, 0x8000
    if style & OF_REOPEN ~= 0 and of then name = mem.cstr(of + 8) end
    if not name then return HFILE_ERROR end
    local full = dosfs.full(name)
    -- a bare name is searched for: the current folder, then WINDOWS, SYSTEM
    if not name:find("[\\/:]") and style & OF_CREATE == 0 then
        for _, dir in ipairs({dosfs.cwd, dosfs.windows, dosfs.system}) do
            local cand = dosfs.full(dir .. "\\" .. name)
            if dosfs.exists(cand) then full = cand; break end
        end
    end
    local function fill(err)
        if not of then return end
        wb(of, 136); wb(of + 1, 1); ww(of + 2, err or 0)
        api.putstr(of + 8, full, 128)
    end
    if style & OF_PARSE ~= 0 then fill(0); return 0 end
    if style & OF_DELETE ~= 0 then
        local ok = dosfs.remove(full)
        fill(ok and 0 or 2)
        return ok and 1 or HFILE_ERROR
    end
    if style & OF_CREATE ~= 0 then
        local h = dosfs.open(full, 2, true)
        fill(h and 0 or 3)
        if not h then return HFILE_ERROR end
        if style & OF_EXIST ~= 0 then dosfs.close(h); return 1 end
        return h
    end
    if style & OF_EXIST ~= 0 then
        local ok = dosfs.exists(full)
        fill(ok and 0 or 2)
        return ok and 1 or HFILE_ERROR
    end
    local h = dosfs.open(full, style & 3, false)
    fill(h and 0 or 2)
    return h or HFILE_ERROR
end)

-- ---- modules ----------------------------------------------------------------------------------

-- The system DLLs are the Win16 layer's own (Lua) functions; any other
-- module (a .CPL applet, COMMDLG.DLL, VER.DLL, ...) is the real 16-bit file,
-- loaded, relocated and started like Windows' loader does.
--
-- kernel.instances: hInstance or hModule -> {name=, mod=, inst=, hModule=,
-- hInstance=, path=, refs=}; kernel.byName: module name -> the same.
kernel.instances = {}
kernel.byName = {}

-- Lua modules: a handle per name, so GetModuleHandle / GetProcAddress work
local function luaModule(name)
    if name == "KRNL386" or name == "KRNL286" then name = "KERNEL" end
    if not api.byOrd[name] then return nil end
    local m = kernel.byName[name]
    if not m then
        local h = kernel.galloc(0, 16)
        m = {name = name, lua = true, hModule = h, hInstance = h, refs = 1}
        kernel.byName[name] = m
        kernel.instances[h] = m
        kernel.modules[h] = name
    end
    return m
end

local function baseName(name)
    return (name:upper():gsub("^.*[\\/:]", ""):gsub("%.%w*$", ""))
end

-- Finds a module's file: as given, then in the Windows and System
-- directories, then the Windows 3.1 files themselves.
local function readModuleFile(name)
    local tries = {}
    if name:find("[\\:]") then tries[#tries + 1] = name end
    local file = name:gsub("^.*[\\/:]", "")
    if not file:find("%.") then file = file .. ".DLL" end
    tries[#tries + 1] = dosfs.windows .. "\\" .. file
    tries[#tries + 1] = dosfs.system .. "\\" .. file
    for _, t in ipairs(tries) do
        local data = dosfs.read(t)
        if data then return data, dosfs.full(t) end
    end
    local boot = require("boot")
    local data = kernel.dataDir and boot.dataFile(kernel.dataDir, file:upper())
    if data then return data, dosfs.system .. "\\" .. file:upper() end
end

local loadModule

-- The loader's resolver for every module: Lua functions for the system
-- DLLs, entry points of loaded 16-bit modules for the rest.
function kernel.resolve(modName, ord, name)
    if api.byOrd[modName] or modName == "KRNL386" then return api.resolve(modName == "KRNL386" and "KERNEL" or modName, ord, name) end
    local m = kernel.byName[modName] or loadModule(modName)
    if not m or m.lua then
        error(string.format("import %s.%s: no such module", modName, ord or name), 0)
    end
    if not ord then
        ord = m.mod.names[name:upper()]
        if not ord then error(string.format("import %s.%s: no such export", modName, name), 0) end
    end
    return m.inst.entryAddr(ord)
end

-- Loads (or finds) a 16-bit module and runs its LibEntry. Returns the record.
loadModule = function(name)
    local key = baseName(name)
    local m = kernel.byName[key] or luaModule(key)
    if m then m.refs = m.refs + 1; return m end
    local data, path = readModuleFile(name)
    if not data then return nil, 2 end
    local mod, err = require("recomp.ne").parse(data, path)
    if not mod then host.log("Win16: " .. path .. ": " .. tostring(err)); return nil, 11 end
    if mod.flags & 0x8000 == 0 then return nil, 11 end    -- a program, not a library
    m = {name = mod.name or key, mod = mod, path = path, refs = 1}
    kernel.byName[key] = m
    if mod.name and mod.name ~= key then kernel.byName[mod.name] = m end
    local inst = require("recomp.loader").load(mod, kernel.resolve)
    m.inst = inst
    m.hModule = kernel.galloc(0, 16)
    m.hInstance = inst.dgroup or m.hModule
    kernel.instances[m.hModule] = m
    kernel.instances[m.hInstance] = m
    kernel.modules[m.hModule] = m.name
    if inst.dgroup then
        local dseg = mod.segments[mod.autoData]
        -- the static data and its uninitialized part: a heap goes after both
        m.dataEnd = math.max(dseg.length, dseg.minalloc < 0x10000 and dseg.minalloc or 0, 16)
        kernel.instances[inst.dgroup] = m
    end
    host.log(string.format("Win16: loaded %s (%d segments, %d imports)", path, #mod.segments, inst.stats.imports))
    if api.trace then
        local t = {}
        for i, sel in ipairs(inst.sels) do t[#t + 1] = string.format("%d=%04X", i, sel) end
        host.log("  selectors " .. table.concat(t, " "))
    end
    -- LibEntry: DI = hInstance, DS = DGROUP, CX = heap size, ES:SI = command line
    if mod.cs ~= 0 then
        local R = kernel.task.R
        local ax = cpu.call16(R, inst.sels[mod.cs], mod.ip, {}, {
            di = m.hInstance, ds = inst.dgroup or 0, cx = mod.heap, si = 0, es = 0})
        if ax == 0 then host.log("Win16: " .. m.name .. "'s LibEntry failed") end
    end
    return m
end
kernel.loadModule = loadModule

-- Starts another Windows program (WinExec of CONTROL.EXE, ...) as a task
-- beside the running ones. Returns its hInstance, or an error code < 32.
function kernel.exec(path, cmdLine, show)
    local file = path:upper():gsub("^.*[\\:]", "")
    local data = dosfs.read(path)
    if not data and kernel.dataDir then data = require("boot").dataFile(kernel.dataDir, file) end
    if not data then return 2 end
    local mod = require("recomp.ne").parse(data, file)
    if not mod then return 11 end
    if mod.flags & 0x8000 ~= 0 then return 11 end
    local tasks = require("win16.tasks")
    local prev = kernel.task
    local task
    local ok, err = pcall(require("recomp.loader").load, mod, kernel.resolve, {program = true, beforeRelocs = function(inst)
        task = kernel.startTask(inst, {path = dosfs.full(path), cmdShow = show or 1, cmdLine = cmdLine or ""})
        tasks.switch(task)
    end})
    tasks.switch(prev)
    if not ok then
        host.log("Win16: " .. file .. ": " .. tostring(err))
        return 11
    end
    tasks.add(task)
    host.log("Win16: started " .. file)
    return task.hInstance
end

-- hInstance/hModule (or a module name) -> the record
function kernel.moduleOf(h)
    if type(h) == "string" then return kernel.byName[baseName(h)] end
    return kernel.instances[h]
end

-- The parsed NE module behind an instance handle (the task's when it's 0 or
-- the task's own).
function kernel.neModule(h)
    local t = kernel.task
    if not h or h == 0 or (t and (h == t.hInstance or h == t.dgroup)) then return t and t.module end
    local m = kernel.instances[h]
    if m and m.mod then return m.mod end
    return t and t.module
end

-- A module that is only resources here (the display driver): GetModuleHandle
-- and FindResource reach it.
function kernel.addResourceModule(name, mod)
    if not mod or kernel.byName[name] then return end
    local h = kernel.galloc(0, 16)
    local m = {name = name, mod = mod, hModule = h, hInstance = h, refs = 1, resourcesOnly = true}
    kernel.byName[name] = m
    kernel.instances[h] = m
    kernel.modules[h] = name
end

kernel.moduleHandle = function(name)
    local m = luaModule(baseName(name))
    return m and m.hModule
end

def("KERNEL", 95, "LoadLibrary", "s", function(name)
    if not name then return 2 end
    local m, err = loadModule(name)
    if not m then return err or 2 end
    return m.hInstance
end)
def("KERNEL", 96, "FreeLibrary", "h:v", function(h)
    local m = kernel.instances[h]
    if m then m.refs = math.max(m.refs - 1, 0) end
end)
def("KERNEL", 47, "GetModuleHandle", "r", function(name, R)
    local t = kernel.task
    if type(name) ~= "string" then
        -- a selector: the module whose data or code it is
        local m = kernel.instances[name]
        if m then return m.hModule end
        return t.hInstance
    end
    local key = baseName(name)
    if t.module.name and key == t.module.name then return t.hInstance end
    local m = kernel.byName[key] or luaModule(key)
    return m and m.hModule or 0
end)
def("KERNEL", 48, "GetModuleUsage", "h", function(h)
    local m = kernel.instances[h]
    return m and m.refs or 1
end)
def("KERNEL", 50, "GetProcAddress", "h r:l", function(h, name)
    local m = kernel.instances[h]
    if m and m.resourcesOnly then return 0 end
    if m and m.mod then
        local ord = type(name) == "number" and name or m.mod.names[name:upper()]
        if not ord or not m.mod.entries[ord] then return 0 end
        local sel, off = m.inst.entryAddr(ord)
        return ((sel or 0) << 16) | off
    end
    local mn = m and m.name or kernel.modules[h]
    if not mn then return 0 end
    local d
    if type(name) == "number" then d = api.byOrd[mn][name] else d = api.byName[mn .. "." .. name:upper()] end
    if not d then
        host.log("Win16: GetProcAddress(" .. mn .. ", " .. tostring(name) .. "): not in the Win16 layer")
        return 0
    end
    local sel, off = api.resolve(mn, d.ord, d.name)
    return ((sel or 0) << 16) | off
end)
def("KERNEL", 49, "GetModuleFileName", "h p i", function(h, buf, size)
    local m = kernel.instances[h]
    local path
    if m and m.path then path = m.path
    elseif m then path = dosfs.system .. "\\" .. m.name .. ".DLL"
    else path = kernel.task.path end
    return api.putstr(buf, path, size)
end)

-- Resources: LockResource on a handle Windows gave out for one
-- (LoadResource isn't imported; USER's loaders keep theirs in global blocks).
def("KERNEL", 62, "LockResource", "h:l", function(h)
    if globals[h] then return h << 16 end
    return 0
end)

-- WinExec(cmdline, show) -> > 31 on success
def("KERNEL", 166, "WinExec", "s w", function(cmd, show)
    local launch = require("win16.launch")
    return launch.run(cmd or "", show)
end)

-- ---- DOS ------------------------------------------------------------------------------------------

local dta = nil   -- far pointer of the disk transfer area
local findState = {}

local function dosString(R, segName, reg)
    return mem.cstr(R[segName .. "b"] + R[reg])
end

local function setCarry(R, err)
    R.cf = err ~= nil and err ~= 0
    if R.cf then R.ax = err end
end

local function fillFind(R, list, i)
    local e = list[i]
    if not e then return false end
    local d = cpu.flat(dta)
    if not d then return false end
    wb(d + 0x15, e.dir and 0x10 or 0x20)
    ww(d + 0x16, 0); ww(d + 0x18, 0x1A21)
    mem.wd(d + 0x1A, e.size or 0)
    api.putstr(d + 0x1E, e.name, 13)
    return true
end

local function dos(R)
    local ah = R.ax >> 8
    local al = R.ax & 0xFF
    if api.trace then
        host.log(string.format("  INT 21h AX=%04X BX=%04X CX=%04X DX=%04X DS=%04X ES=%04X", R.ax, R.bx, R.cx, R.dx, R.ds, R.es))
    end
    if ah == 0x30 then          -- version: 5.0
        R.ax = 0x0005; R.bx = 0; R.cx = 0
    elseif ah == 0x19 then      -- current drive
        R.ax = (R.ax & 0xFF00) | (dosfs.cwd:byte(1) - 65)
    elseif ah == 0x0E then      -- set drive
        local d = string.char(65 + (R.dx & 0xFF))
        if d ~= dosfs.cwd:sub(1, 1) then dosfs.cwd = d .. ":\\" end
        R.ax = (R.ax & 0xFF00) | 26
    elseif ah == 0x47 then      -- current directory (without drive and leading \)
        api.putstr(R.dsb + R.si, dosfs.cwd:sub(4), 64)
        setCarry(R, nil)
    elseif ah == 0x3B then      -- chdir
        local p = dosfs.full(dosString(R, "ds", "dx"))
        local ok, isdir = dosfs.exists(p)
        if ok and isdir then dosfs.cwd = p; setCarry(R, nil) else setCarry(R, 3) end
    elseif ah == 0x1A then
        dta = (R.ds << 16) | R.dx
    elseif ah == 0x2F then
        local s = dta and (dta >> 16) or 0
        cpu.setseg(R, "es", s); R.bx = dta and (dta & 0xFFFF) or 0
    elseif ah == 0x4E then      -- find first
        local list = dosfs.find(dosString(R, "ds", "dx"))
        local attr = R.cx
        local filtered = {}
        for _, e in ipairs(list) do
            if not e.dir or attr & 0x10 ~= 0 then filtered[#filtered + 1] = e end
        end
        findState[dta or 0] = {list = filtered, i = 1}
        if fillFind(R, filtered, 1) then setCarry(R, nil) else setCarry(R, 18) end
    elseif ah == 0x4F then      -- find next
        local st = findState[dta or 0]
        if st then st.i = st.i + 1 end
        if st and fillFind(R, st.list, st.i) then setCarry(R, nil) else setCarry(R, 18) end
    elseif ah == 0x3D then      -- open
        local h, err = dosfs.open(dosString(R, "ds", "dx"), al & 3, false)
        if h then R.ax = h; setCarry(R, nil) else setCarry(R, err) end
    elseif ah == 0x3C then      -- create
        local h, err = dosfs.open(dosString(R, "ds", "dx"), 2, true)
        if h then R.ax = h; setCarry(R, nil) else setCarry(R, err) end
    elseif ah == 0x3E then
        if dosfs.close(R.bx) then setCarry(R, nil) else setCarry(R, 6) end
    elseif ah == 0x3F then
        local s = dosfs.readh(R.bx, R.cx)
        if not s then setCarry(R, 6) else mem.write(R.dsb + R.dx, s); R.ax = #s; setCarry(R, nil) end
    elseif ah == 0x40 then
        local n = dosfs.writeh(R.bx, R.cx > 0 and mem.read(R.dsb + R.dx, R.cx) or "")
        if not n then setCarry(R, 6) else R.ax = n; setCarry(R, nil) end
    elseif ah == 0x42 then
        local off = (R.cx << 16) | R.dx
        if off >= 0x80000000 then off = off - 0x100000000 end
        local p = dosfs.seek(R.bx, off, al)
        if p then R.ax = p & 0xFFFF; R.dx = p >> 16; setCarry(R, nil) else setCarry(R, 6) end
    elseif ah == 0x41 then
        if dosfs.remove(dosString(R, "ds", "dx")) then setCarry(R, nil) else setCarry(R, 2) end
    elseif ah == 0x56 then
        if dosfs.rename(dosString(R, "ds", "dx"), mem.cstr(R.esb + R.di)) then setCarry(R, nil) else setCarry(R, 5) end
    elseif ah == 0x43 then      -- attributes
        local ok, isdir = dosfs.exists(dosString(R, "ds", "dx"))
        if ok then R.cx = isdir and 0x10 or 0x20; setCarry(R, nil) else setCarry(R, 2) end
    elseif ah == 0x39 then
        if dosfs.mkdir(dosString(R, "ds", "dx")) then setCarry(R, nil) else setCarry(R, 5) end
    elseif ah == 0x36 then      -- disk free: 32 KB clusters
        local free = host.disk_free(dosfs.windowsHost())
        local clusters = math.min(free // 32768, 0xFFFF)
        R.ax = 64; R.bx = clusters; R.cx = 512; R.dx = 0xFFFF
    elseif ah == 0x2A then
        local t = os.date("*t")
        R.cx = t.year; R.dx = (t.month << 8) | t.day; R.ax = (R.ax & 0xFF00) | (t.wday - 1)
    elseif ah == 0x2C then
        local t = os.date("*t")
        R.cx = (t.hour << 8) | t.min; R.dx = (t.sec << 8)
    elseif ah == 0x44 then      -- ioctl: get device info: a file on drive C
        R.dx = 0x0002; setCarry(R, nil)
    elseif ah == 0x57 then      -- file date and time: get (AL=0) from the file, set (AL=1) accepted
        local f = dosfs.file(R.bx)
        if not f then setCarry(R, 6)
        else
            if al == 0 then
                local hp = dosfs.hostPath(f.path)
                local st = hp and host.stat(hp)
                local t = os.date("*t", st and st.mtime or os.time())
                R.cx = (t.hour << 11) | (t.min << 5) | (t.sec // 2)
                R.dx = ((t.year - 1980) << 9) | (t.month << 5) | t.day
            end
            setCarry(R, nil)
        end
    elseif ah == 0x4C then
        error({exit = al}, 0)
    elseif ah == 0x25 or ah == 0x35 then   -- set/get vector: ignored
        if ah == 0x35 then cpu.setseg(R, "es", 0); R.bx = 0 end
    elseif ah == 0x48 then      -- allocate memory: no conventional memory here
        R.bx = 0; setCarry(R, 8)
    elseif ah == 0x59 then
        R.ax = 0; R.bx = 0; R.cx = 0
    else
        host.log(string.format("DOS: INT 21h AH=%02Xh not implemented", ah))
        setCarry(R, 1)
    end
end
kernel.dos = dos
cpu.ints[0x21] = dos

-- INT 2Fh, the multiplex interrupt: Windows answers as itself (enhanced
-- mode 3.10) and has no virtual devices to offer.
cpu.ints[0x2F] = function(R)
    local ax = R.ax
    if ax == 0x1600 then R.ax = 0x0A03          -- enhanced mode, version 3.10
    elseif ax == 0x1683 then R.bx = 1           -- the system VM
    elseif ax == 0x1684 then cpu.setseg(R, "es", 0); R.di = 0   -- no device API
    elseif ax == 0x1689 then -- kernel idle
    elseif (ax >> 8) == 0x16 then -- other Windows calls: nothing to report
    else R.ax = ax & 0xFF00 end                 -- no multiplex handler installed
end

-- DOS3Call: INT 21h with the registers as they are (no stack arguments).
def("KERNEL", 102, "DOS3Call", ":v", function(R)
    -- the registers seen by the call are the caller's: api returned first,
    -- which only moved SP and CS:IP
    dos(R)
end)

return kernel

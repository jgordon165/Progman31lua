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
    cpu.lfree(g.base)
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
    if size == 0 then size = 16 end
    if size > 0x10000 then return 0 end
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
    return g and g.base
end

-- ---- the local heap (in DGROUP, above the stack) ----------------------------------------

local lheap = {free = {}, used = {}}

local function lheapInit(start, stop)
    start = (start + 3) & ~3
    lheap.free = {{at = start, size = stop - start}}
    lheap.used = {}
    lheap.start = start
end

function kernel.lalloc(flags, size)
    size = (math.max(size, 2) + 3) & ~3
    for i, f in ipairs(lheap.free) do
        if f.size >= size then
            local at = f.at
            f.at, f.size = f.at + size, f.size - size
            if f.size == 0 then table.remove(lheap.free, i) end
            lheap.used[at] = size
            if flags & 0x40 ~= 0 then mem.fill(kernel.task.dgroupBase + at, size, 0) end
            return at
        end
    end
    return 0
end

function kernel.lfree(at)
    local size = lheap.used[at]
    if not size then return at end
    lheap.used[at] = nil
    local free = lheap.free
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
    mem.write(pb + 0x81, cl .. "\r")

    local task = {R = R, inst = inst, hInstance = dgroup, psp = psp, cmdShow = opts.cmdShow or 1,
                  path = opts.path, dgroup = dgroup, dgroupBase = inst.bases[mod.autoData],
                  stackLow = minsize, stackHigh = sp, heapStart = sp, module = mod}
    kernel.task = task
    lheapInit(sp + 0x10, 0xFFF0)
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

def("KERNEL", 5, "LocalAlloc", "w w", function(flags, size) return kernel.lalloc(flags, size) end)
def("KERNEL", 7, "LocalFree", "h", function(h) return kernel.lfree(h) end)

def("KERNEL", 54, "GetInstanceData", "h w i", function() return 0 end)

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

-- ---- modules -------------------------------------------------------------------------------------

-- Module handles for the system DLLs, so GetModuleHandle / LoadLibrary /
-- GetProcAddress work against the Win16 layer's functions.
local modHandles = {}
local function moduleHandle(name)
    name = name:upper():gsub("%.%a+$", ""):gsub("^.*\\", "")
    if name == "KRNL386" or name == "KRNL286" then name = "KERNEL" end
    if not api.byOrd[name] then return nil end
    if not modHandles[name] then
        modHandles[name] = kernel.galloc(0, 16)
        kernel.modules[modHandles[name]] = name
    end
    return modHandles[name]
end
kernel.moduleHandle = moduleHandle

def("KERNEL", 95, "LoadLibrary", "s", function(name)
    if not name then return 2 end
    local h = moduleHandle(name)
    return h or 2   -- 2: file not found
end)
def("KERNEL", 96, "FreeLibrary", "h:v", function() end)
def("KERNEL", 47, "GetModuleHandle", "r", function(name)
    if type(name) ~= "string" then return kernel.task.hInstance end
    if name:upper():gsub("%.EXE$", "") == "PROGMAN" then return kernel.task.hInstance end
    return moduleHandle(name) or 0
end)
def("KERNEL", 50, "GetProcAddress", "h r:l", function(h, name)
    local m = kernel.modules[h]
    if not m then return 0 end
    local d
    if type(name) == "number" then d = api.byOrd[m][name] else d = api.byName[m .. "." .. name:upper()] end
    if not d then
        host.log("Win16: GetProcAddress(" .. m .. ", " .. tostring(name) .. "): not in the Win16 layer")
        return 0
    end
    local sel, off = api.resolve(m, d.ord, d.name)
    return ((sel or 0) << 16) | off
end)
def("KERNEL", 49, "GetModuleFileName", "h p i", function(h, buf, size)
    local name = kernel.modules[h]
    local path = name and (dosfs.system .. "\\" .. name .. ".DLL") or kernel.task.path
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

-- DOS3Call: INT 21h with the registers as they are (no stack arguments).
def("KERNEL", 102, "DOS3Call", ":v", function(R)
    -- the registers seen by the call are the caller's: api returned first,
    -- which only moved SP and CS:IP
    dos(R)
end)

return kernel

-- Loads an NE module into the machine: each segment gets linear memory and
-- a selector, then the relocations are applied. Imports are resolved by
-- the caller's resolver (the Win16 layer hands back thunk addresses), and
-- exported functions get their prologues patched the way Windows' loader
-- patches them for a program (`push ds / pop ax` becomes `nop / nop`, so AX
-- carries the data segment in from the caller).

local cpu = require("recomp.cpu")
local ne = require("recomp.ne")

local loader = {}

-- resolver(moduleName, ordinal or nil, name or nil) -> sel, off  (or a
-- constant: nil, value)
function loader.load(mod, resolver, opts)
    opts = opts or {}
    local inst = {module = mod, sels = {}, bases = {}}
    -- memory and selectors
    for i, s in ipairs(mod.segments) do
        local size = math.max(s.length, s.minalloc)
        if s.offset == 0 then size = s.minalloc end
        if i == mod.autoData then
            -- DGROUP: static data, then the local heap and the stack
            size = math.min(size + mod.heap + mod.stack + 0x100, 0x10000)
            inst.dgroupSize = size
        end
        size = math.min(math.max(size, 16), 0x10000)
        local base = cpu.lalloc(0x10000)   -- room for the segment to grow to 64 KB
        local sel = cpu.newsel(base, 0xFFFF, not s.data)
        inst.sels[i], inst.bases[i] = sel, base
        if s.offset ~= 0 then mem.write(base, mod.data:sub(s.offset + 1, s.offset + s.length)) end
        s.allocated = size
    end
    inst.dgroup = mod.autoData ~= 0 and inst.sels[mod.autoData] or nil

    local function entryAddr(ord)
        local e = mod.entries[ord]
        if not e then error(string.format("%s: no entry point %d", mod.name, ord)) end
        if e.const then return nil, e.off end
        return inst.sels[e.seg], e.off
    end
    inst.entryAddr = entryAddr
    if opts.beforeRelocs then opts.beforeRelocs(inst) end

    -- relocations
    local stats = {imports = 0, internal = 0}
    for i, s in ipairs(mod.segments) do
        local base = inst.bases[i]
        for _, r in ipairs(mod:relocations(i)) do
            local sel, off
            if r.kind == 0 then
                if r.a == 0xFF then
                    sel, off = entryAddr(r.b)
                else
                    sel, off = inst.sels[r.a], r.b
                end
                stats.internal = stats.internal + 1
            elseif r.kind == 1 then
                sel, off = resolver(mod.modules[r.a], r.b, nil)
                stats.imports = stats.imports + 1
            elseif r.kind == 2 then
                sel, off = resolver(mod.modules[r.a], nil, mod:importName(r.b))
                stats.imports = stats.imports + 1
            else
                sel = false   -- OS fixups (floating-point emulation): nothing to do
            end
            if sel ~= false then
                local function patch(at)
                    if r.src == 0 then          -- low byte
                        mem.wb(base + at, ((r.additive and mem.rb(base + at) or 0) + (off or 0)) & 0xFF)
                    elseif r.src == 2 then      -- selector
                        mem.ww(base + at, sel or off or 0)
                    elseif r.src == 3 then      -- far pointer
                        local o = r.additive and ((mem.rw(base + at) + (off or 0)) & 0xFFFF) or (off or 0)
                        mem.ww(base + at, o)
                        mem.ww(base + at + 2, sel or 0)
                    elseif r.src == 5 then      -- offset
                        local o = r.additive and ((mem.rw(base + at) + (off or 0)) & 0xFFFF) or (off or 0)
                        mem.ww(base + at, o)
                    else
                        error(string.format("%s: relocation source type %d", mod.name, r.src))
                    end
                end
                if r.additive then
                    patch(r.offset)
                else
                    -- a chain through the bytes being fixed up, ending at FFFF
                    local at, guard = r.offset, 0
                    while at ~= 0xFFFF and guard < 0x8000 do
                        local nxt = mem.rw(base + at)
                        patch(at)
                        at = nxt
                        guard = guard + 1
                    end
                end
            end
        end
    end
    inst.stats = stats

    -- exported prologues: a program's become nops (AX brings DS from
    -- MakeProcInstance's thunk); a library's load its own DGROUP, as
    -- Windows' loader makes them (`mov ax, DGROUP`)
    if not opts.program and inst.dgroup then
        local patched = 0
        for _, e in pairs(mod.entries) do
            if not e.const and e.seg ~= 0 and (e.flags & 1) ~= 0 then
                local s = mod.segments[e.seg]
                if s and not s.data then
                    local at = inst.bases[e.seg] + e.off
                    local b0, b1, b2 = mem.rb(at), mem.rb(at + 1), mem.rb(at + 2)
                    if (b0 == 0x1E and b1 == 0x58 and b2 == 0x90) or (b0 == 0x8C and b1 == 0xD8 and b2 == 0x90) then
                        mem.wb(at, 0xB8)
                        mem.ww(at + 1, inst.dgroup)
                        patched = patched + 1
                    end
                end
            end
        end
        inst.stats.prologues = patched
    end
    if opts.program then
        local patched = 0
        for _, e in pairs(mod.entries) do
            if not e.const and e.seg ~= 0 and (e.flags & 1) ~= 0 then
                local s = mod.segments[e.seg]
                if s and not s.data then
                    local at = inst.bases[e.seg] + e.off
                    local b0, b1, b2 = mem.rb(at), mem.rb(at + 1), mem.rb(at + 2)
                    if (b0 == 0x1E and b1 == 0x58 and b2 == 0x90) or (b0 == 0x8C and b1 == 0xD8 and b2 == 0x90) then
                        mem.write(at, "\x90\x90\x90")
                        patched = patched + 1
                    end
                end
            end
        end
        inst.stats.prologues = patched
    end
    return inst
end

-- Reads and parses a module file through the host (expanding setup-disk
-- compression).
function loader.parseFile(path)
    local data, err = host.read(path, true)
    if not data then return nil, err end
    return ne.parse(data, path)
end

return loader

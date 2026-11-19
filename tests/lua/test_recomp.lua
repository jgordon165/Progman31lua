-- The recompiler against hand-assembled 8086/286 code: each case runs a
-- snippet to a HLT and checks registers and flags.

local cpu = require("recomp.cpu")

local failures = 0
local function check(name, cond, msg)
    if not cond then
        failures = failures + 1
        host.log("FAIL " .. name .. (msg and (": " .. msg) or ""))
    end
end

local code = cpu.lalloc(0x10000)
local data = cpu.lalloc(0x10000)
local CS = cpu.newsel(code, 0xFFFF, true)
local DS = cpu.newsel(data, 0xFFFF)
cpu.ints[-1] = function(R) R.halted = true; R.cs = cpu.THUNK_SEL; R.ip = cpu.SENTINEL end
cpu.THUNK_SEL = cpu.THUNK_SEL or cpu.newsel(cpu.lalloc(16), 15, true)

local function hexbytes(s)
    local out = {}
    for h in s:gmatch("%x%x") do out[#out + 1] = string.char(tonumber(h, 16)) end
    return table.concat(out)
end

local function run(bytes, init)
    cpu.flush()
    mem.write(code, hexbytes(bytes) .. "\xF4")
    local R = cpu.newregs()
    cpu.setseg(R, "ds", DS); cpu.setseg(R, "es", DS); cpu.setseg(R, "ss", DS)
    R.sp = 0xFFF0
    for k, v in pairs(init or {}) do R[k] = v end
    R.cs, R.ip = CS, 0
    cpu.run(R)
    return R
end

local function regs(name, R, want)
    for k, v in pairs(want) do
        check(name, R[k] == v, string.format("%s = %s, want %s", k, tostring(R[k]), tostring(v)))
    end
end

-- mov ax,1234 / add ax,0EDCC -> 0, CF ZF
regs("add carry", run("B83412 05CCED"), {ax = 0, cf = true, zf = true, sf = false, of = false})
-- mov al,7F / add al,1 -> 80, OF SF
regs("add overflow", run("B07F 0401"), {ax = 0x80, of = true, sf = true, cf = false})
-- mov ax,5 / sub ax,6 -> FFFF, CF SF
regs("sub borrow", run("B80500 2D0600"), {ax = 0xFFFF, cf = true, sf = true, zf = false})
-- stc / mov ax,1 / adc ax,1 -> 3
regs("adc", run("F9 B80100 150100"), {ax = 3})
-- stc / mov ax,5 / sbb ax,2 -> 2
regs("sbb", run("F9 B80500 1D0200"), {ax = 2})
-- mov cx,3 / xor ax,ax / l: inc ax / loop l -> ax 3
regs("loop", run("B90300 31C0 40 E2FD"), {ax = 3, cx = 0, zf = false})
-- mov ax,1 / cmp ax,2 / jl +3 / mov bx,9 / mov dx,7 -> bx 0 dx 7 (jl taken)
regs("jl", run("B80100 3D0200 7C03 BB0900 BA0700"), {bx = 0, dx = 7})
-- signed: mov ax,8000 / cmp ax,1 / jg -> not taken (ax negative)
regs("jg", run("B80080 3D0100 7F03 BB0900"), {bx = 9})
-- call/ret: call +3 / jmp +4 / mov ax,2A / ret ; end
regs("call ret", run("E80300 EB05 90 B82A00 C3"), {ax = 0x2A})
-- push/pop: mov ax,1111 / push ax / pop bx
regs("push pop", run("B81111 50 5B"), {bx = 0x1111, sp = 0xFFF0})
-- memory: mov word [0010],BEEF / mov si,0010 / mov ax,[si] / add byte [si],1
local R = run("C7061000EFBE BE1000 8B04 800401")
regs("memory", R, {ax = 0xBEEF})
check("memory write", mem.rw(data + 0x10) == 0xBEF0, string.format("%04X", mem.rw(data + 0x10)))
-- mul: mov ax,300 / mov bx,300 / mul bx -> dx:ax = 0x90000
regs("mul", run("B80003 BB0003 F7E3"), {ax = 0, dx = 9, cf = true})
-- div: mov dx,1 / mov ax,0 / mov bx,10 / div bx -> 0x1999 r 6
regs("div", run("BA0100 B80000 BB1000 F7F3"), {ax = 0x1000, dx = 0})
-- idiv: mov ax,-7 / cwd / mov bx,2 / idiv bx -> -3 r -1
regs("idiv", run("B8F9FF 99 BB0200 F7FB"), {ax = 0xFFFD, dx = 0xFFFF})
-- imul three-operand: mov bx,-3 / imul ax,bx,7 -> -21
regs("imul3", run("BBFDFF 6BC307"), {ax = (-21) & 0xFFFF})
-- shifts: mov ax,8001 / shl ax,1 -> 2, CF ; mov bx,8000 / sar bx,4 -> F800
regs("shl", run("B80180 D1E0"), {ax = 2, cf = true})
regs("sar", run("BB0080 C1FB04"), {bx = 0xF800})
-- rol: mov al,81 / rol al,1 -> 03 CF
regs("rol", run("B081 D0C0"), {ax = 3, cf = true})
-- rcr: stc / mov ax,0 / rcr ax,1 -> 8000, CF clear
regs("rcr", run("F9 B80000 D1D8"), {ax = 0x8000, cf = false})
-- rep movsw: copy 4 words from 0x100 to 0x200
mem.write(data + 0x100, "ABCDEFGH")
run("BE0001 BF0002 B90400 FC F3A5")
check("rep movsw", mem.read(data + 0x200, 8) == "ABCDEFGH", mem.read(data + 0x200, 8))
-- repne scasb: find 'E' in "ABCDEFGH" at 0x100
regs("repne scasb", run("BF0001 B90800 B045 FC F2AE"), {di = 0x105, cx = 3, zf = true})
-- rep stosb with std (backwards)
run("BF0703 B90400 B07A FD F3AA FC")
check("rep stosb backwards", mem.read(data + 0x304, 4) == "zzzz", mem.read(data + 0x304, 4))
-- les: mov word [0],1234 / mov word [2],DS / les bx,[0]
mem.ww(data, 0x1234); mem.ww(data + 2, DS)
R = run("C41E0000")
regs("les", R, {bx = 0x1234, es = DS})
-- enter/leave: enter 8,0 / mov ax,sp / leave
R = run("C8080000 89E0 C9")
regs("enter leave", R, {ax = 0xFFE6, sp = 0xFFF0})
-- xchg, cbw, cwd, lea
regs("cbw", run("B080 98"), {ax = 0xFF80})
regs("lea", run("BB1000 BE0500 8D4003"), {ax = 0x18})
-- pushf/popf round trip keeps CF
regs("pushf popf", run("F9 9C F8 9D"), {cf = true})
-- daa: mov al,0F / add al,1 / daa -> 16
regs("daa", run("B00F 0401 27"), {ax = 0x16})
-- neg: mov ax,5 / neg ax -> FFFB CF
regs("neg", run("B80500 F7D8"), {ax = 0xFFFB, cf = true})
-- 8-bit high registers: mov ax,1234 / mov ah,al / add ah,1
regs("high byte", run("B83412 88C4 80C401"), {ax = 0x3534})
-- jcxz taken
regs("jcxz", run("B90000 E303 BB0100"), {bx = 0})
-- segment override: mov ax,[es:0010] where ES=DS
mem.ww(data + 0x10, 0x5555)
regs("es override", run("26A11000"), {ax = 0x5555})
-- flag liveness: inc ax / add bx,1 / the jz reads add's ZF
regs("liveness", run("B8FFFF BB0000 40 83C301 7403 BA0100"), {dx = 1, ax = 0})

-- A far call through the thunk selector reaches Lua and returns with RETF n.
local called
cpu.thunks[7] = function(R2)
    local a = mem.rw(R2.ssb + R2.sp + 4)
    called = a
    R2.ax = a * 2
    -- retf 2
    local ip = mem.rw(R2.ssb + R2.sp)
    local cs = mem.rw(R2.ssb + R2.sp + 2)
    R2.sp = (R2.sp + 6) & 0xFFFF
    R2.cs, R2.ip = cs, ip
end
local th = cpu.THUNK_SEL
R = run(string.format("6A15 9A0700%02X%02X", th & 0xFF, th >> 8))
check("thunk call", called == 0x15 and R.ax == 0x2A and R.sp == 0xFFF0, tostring(called) .. " " .. tostring(R.ax))

-- call16: run a 16-bit far procedure from Lua (mov ax,[bp+6]... retf 2)
mem.write(code + 0x800, hexbytes("55 89E5 8B4606 D1E0 5D CA0200"))
local R3 = cpu.newregs()
cpu.setseg(R3, "ds", DS); cpu.setseg(R3, "ss", DS); R3.sp = 0xFF00
local ax = cpu.call16(R3, CS, 0x800, {21})
check("call16", ax == 42 and R3.sp == 0xFF00, tostring(ax))

host.log(string.format("recomp: %d blocks, %d instructions compiled; %s", cpu.stats.blocks, cpu.stats.insns,
    failures == 0 and "all passed" or (failures .. " FAILED")))
return failures == 0 and 0 or 1

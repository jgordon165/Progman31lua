# Architecture

## The recompiler (`scripts/recomp/`)

**Machine model.** Windows 3.1 runs programs in 16-bit protected mode. The
host provides one flat 16 MB linear space (`mem.rb/rw/wb/ww`, C++). Selectors
(`index << 3 | 7`, as Windows hands them out) map to a base and a limit in
`cpu.lua`. A segment register is kept with its base (`R.ds`, `R.dsb`), so a
memory access in generated code is `rw(dsb + offset)`.

**Blocks.** `x86.lua` decodes from `CS:IP` to the first control transfer
(jump, call, return, interrupt, loop) or 128 instructions. It emits a Lua
function that loads the eight general registers and six flags into locals,
runs the instructions, and stores them back on every exit with the next
`R.ip`. The source is `load()`ed once and cached by `CS << 16 | IP`. Run with
`--dump <folder>` to read the generated code.

**Flags.** Each decoded instruction records which flags it reads and writes.
A backward pass over the block keeps only the flag computations a later
instruction (or a block exit, where all are live) can observe. In `cmp ax,
bx / jl`, all of CMP's flags stay. In `inc si / add di, 2 / ...`, INC's
flags are dropped.

**Leaving 16-bit code.** Every import is relocated to `THUNK:n`, a selector
with no code behind it. When the dispatcher reaches it, it calls the Win16
function, which decodes its Pascal arguments from the stack, pops them (RETF n)
and sets AX/DX. Callbacks into the program (window and dialog procedures) go
through `cpu.call16`, which pushes the arguments and a return address of
`THUNK:FFFF` and runs a nested dispatcher until that address is reached.

**Loader.** `loader.lua` gives each NE segment its own selector over 64 KB of
linear memory and applies the relocation records (chained and additive;
selector, offset and far-pointer fixups). Like Windows' loader for a
program, it patches the exported functions' `push ds / pop ax` prologue to
NOPs, so AX carries the instance's data segment in from MakeProcInstance
thunks and from USER.

## The Win16 layer (`scripts/win16/`)

| File | |
|---|---|
| `api.lua` | registry of functions by module/ordinal, Pascal signatures, thunks, scratch memory for structures handed to 16-bit code |
| `signatures.lua` | the signature of every import, so unimplemented ones still keep the stack balanced |
| `kernel.lua` | the task (InitTask, PSP, instance data), global and local heaps, files, profiles, modules, DOS (INT 21h) |
| `dosfs.lua` | the DOS file system Program Manager sees |
| `profile.lua` | .INI files |
| `region.lua`, `handles.lua` | rectangle-list regions; USER/GDI handles |

## The host (`src/`)

`host.cpp` exposes three Lua modules: `mem` (linear memory), `fb`
(surfaces with GDI semantics: ROP3 blits, mono/colour conversion, raster
fonts from .FON files, clipping to rectangle lists) and `host` (window,
input events as Windows virtual keys, files, launching programs).
`main.cpp` runs `scripts/main.lua`. Lua owns the message loop, because the
program's own `GetMessage` loop is what drives everything.

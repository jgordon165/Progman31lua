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
| `gdi.lua` | DCs, brushes, raster fonts from the user's .FON files, bitmaps, regions, icons (HICONs are global blocks in Windows 3.1's internal format, 4 bits per pixel) |
| `user.lua` | windows, classes, z-order and visible regions, update regions and painting, the message queue, input, focus and activation |
| `defwnd.lua` | DefWindowProc: frames and captions from the display driver's OBM bitmaps, hit testing, moving and sizing, system commands, minimized windows |
| `usermisc.lua` | the rest of USER's API: window words, placement, rectangles, DrawText, accelerators, resources, atoms, hooks, wsprintf, carets |
| `scroll.lua`, `menu.lua`, `mdi.lua` | window scroll bars; menus (popups are overlays drawn over the screen at each present); MDI |
| `controls.lua`, `dialog.lua` | BUTTON, STATIC, EDIT, LISTBOX, COMBOBOX; dialog templates, the modal loop, the dialog manager, MessageBox |
| `dragdrop.lua` | DragObject, which moves items between groups |
| `resources.lua`, `pe.lua`, `shell.lua` | icons/cursors/bitmaps from NE modules; icons from modern PE programs; SHELL (ExtractIcon, ShellExecute, About) |
| `launch.lua` | WinExec/ShellExecute: Windows 3.1 programs start their modern counterparts (`[Programs]` in PROGMAN31.INI) |
| `setup.lua` | first run: Setup's DDE conversation, from SETUP.INF |

### Painting

Every DC is clipped to its window's visible region: the window, minus the
windows above it at every level, minus its own children. When a window
moves, shows or hides, the screen area involved is "damaged": every window
under it gets its frame redrawn and that part of its client area
invalidated. Program Manager then repaints in its own message loop, as in
Windows. Things drawn over the screen for a moment (menus, the move/size
outline, the icon being dragged, combo box lists) are overlays: they're drawn
onto the screen just before each present and taken away right after.

### Testing

`tests/lua/test_progman.lua` runs Program Manager headless from an empty
home with scripted input (`--script`). It checks that Setup's groups exist,
that File > Run and double-clicking start the right programs, and that a
dragged item lands in the other group's `.GRP` file.

## The host (`src/`)

`host.cpp` exposes three Lua modules: `mem` (linear memory), `fb`
(surfaces with GDI semantics: ROP3 blits, mono/colour conversion, raster
fonts from .FON files, clipping to rectangle lists) and `host` (window,
input events as Windows virtual keys, files, launching programs).
`main.cpp` runs `scripts/main.lua`. Lua owns the message loop, because the
program's own `GetMessage` loop is what drives everything.

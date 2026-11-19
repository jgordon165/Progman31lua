# Progman31lua

[![CI-build](https://github.com/jgordon165/Progman31lua/actions/workflows/ci-build.yml/badge.svg)](https://github.com/jgordon165/Progman31lua/actions/workflows/ci-build.yml)
[![code-analysis](https://github.com/jgordon165/Progman31lua/actions/workflows/code-analysis.yml/badge.svg)](https://github.com/jgordon165/Progman31lua/actions/workflows/code-analysis.yml)

**Program Manager from Windows 3.1 (1992), running as a modern application.**
The original 16-bit `PROGMAN.EXE` is *dynamically recompiled*: its x86 code
is translated to Lua one basic block at a time as it runs, and its calls into
Windows are served by a Win16 layer written in Lua. A small C++ host (SDL2)
provides memory, drawing, input and files. It starts with the Windows 3.1
logo screen, as Windows did.

A sister project of [Solitairepack](https://github.com/jgordon165/Solitairepack)
and [Tetrispack](https://github.com/jgordon165/Tetrispack), on the same build
and release pipelines.

**No Windows code or data is included.** Program Manager, the logo, the
fonts and the icons are read at runtime from your own Windows 3.1 files: an
installed `WINDOWS` folder, or the setup disks/CD, where they're compressed
(`PROGMAN.EX_`) and expanded on the fly, as Setup would. Those files are
git-ignored, and release packages are checked for them.

> **Status:** early. The host, the recompiler (with its tests), the NE
> loader and the KERNEL side of the Win16 layer are in; USER, GDI and SHELL
> are being built out to bring Program Manager's windows up.

## Build

Requires CMake 3.20+ and a C++20 compiler. SDL2 and Lua 5.4 are downloaded
and built automatically.

```
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build --config Release
ctest --test-dir build -C Release
```

## Run

```
build\Release\progman31lua.exe --data E:\
build\Release\progman31lua.exe --data C:\WIN31\WINDOWS
```

Without `--data` it looks in a `data` folder beside the program, then the
root of each drive (so a mounted Windows 3.1 CD or disk image is found).

| Option | |
|---|---|
| `--data <folder>` | your Windows 3.1 files (installed folder or setup disks) |
| `--home <folder>` | where Program Manager's `C:\WINDOWS` lives (`PROGMAN.INI`, the `.GRP` group files); default: your app data folder |
| `--screen WxH` | window size (default 800x600) |
| `--no-logo` | skip the startup screen |
| `--trace` | log every Windows call Program Manager makes |
| `--dump <folder>` | write each recompiled block's Lua source there |

## How it works

```
PROGMAN.EXE (NE, 16-bit)                     scripts/recomp/
   │  ne.lua ─ parse segments, relocations, entries, resources
   │  loader.lua ─ selectors + linear memory, fixups; imports → THUNK:n
   ▼
CS:IP ──► x86.lua: decode a basic block ──► Lua source ──► load() ──► cache
              (flag liveness: only flags something can read are computed)
   │
   │ far call THUNK:n
   ▼
scripts/win16/  KERNEL · USER · GDI · SHELL · KEYBOARD  (Pascal calls)
   │  callbacks (WndProc, DlgProc) re-enter the recompiler: cpu.call16
   ▼
src/ (C++/SDL2): mem (16 MB linear), fb (GDI raster ops, raster fonts), host (files, window, input)
```

Program Manager's view of the disk: `C:\WINDOWS` is a per-user folder, with
reads falling back to your Windows 3.1 files, so it can find
`NOTEPAD.EXE`'s icon on the setup disk. The rest of `C:` and the other drives
are the real ones, so items can point at modern programs. Starting a Windows
3.1 accessory starts its modern counterpart (Notepad, Calculator, Paint,
File Explorer, ...).

See [docs/architecture.md](docs/architecture.md).

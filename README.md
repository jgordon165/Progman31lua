# Progman31lua

<img src="assets/progman31lua.png" width="96" align="right" alt="Progman31lua's icon">

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

## What works

- **The real Program Manager**: groups, icons, drag and drop between groups,
  File > New/Properties/Run/Delete, Change Icon, Options, Window > Cascade /
  Tile / Arrange Icons, minimized groups, the keyboard (accelerators,
  Alt+letter menus, Ctrl+F4/F6), Help > About. Settings and groups are
  saved as Program Manager always did, in `PROGMAN.INI` and `.GRP` files.
- **First run**: Program Manager starts empty, as it did before Windows Setup
  filled it. Progman31lua then plays Setup's part and sends Program Manager
  Setup's DDE commands from your `SETUP.INF` (`[CreateGroup(Main)]`,
  `[AddItem(WINFILE.EXE,File Manager)]`, ...). Program Manager builds its
  own Main, Accessories, Games and StartUp groups, with the icons taken out
  of your Windows 3.1 programs.
- **Control Panel, the original**: Control Panel's icon starts Windows
  3.1's own `CONTROL.EXE`, recompiled and running beside Program Manager
  as a second task (cooperatively, as Windows 3.1 ran programs), with its
  applets loaded from your `MAIN.CPL`, `CPWIN386.CPL`, `DRIVERS.CPL` and
  `SND.CPL` (and the `COMMDLG`, `VER` and `LZEXPAND` DLLs they use). All
  twelve open: Color, Fonts, Ports, Mouse, Desktop, Keyboard, Printers,
  International, Date/Time, 386 Enhanced, Drivers and Sound. What they
  change takes effect: a colour scheme recolours Program Manager at once
  and is kept in `WIN.INI`; Swap Left/Right Buttons swaps them. Setting
  the date or time moves Windows' clock only, never your computer's.
  `CONTROL.INI` and `SYSTEM.INI` come from your setup disks' templates,
  as Setup made them.
- **Starting programs**: the other Windows 3.1 programs can't run on 64-bit
  Windows yet, so each starts its modern counterpart (Notepad, Calculator,
  Paint, File Explorer, Control Panel, ...). The map is `[Programs]` in
  `PROGMAN31.INI` in Program Manager's Windows folder; edit it to taste.
  Solitaire starts [Solitairepack](https://github.com/jgordon165/Solitairepack)
  when it's installed beside Progman31lua. Items you add that point at modern
  programs or documents start them directly, and show their own icons
  (reduced to Windows 3.1's 16 colours).
- **Your games**: the Games group shows the `games` folder beside the
  program. Put a folder in it for each game with a shortcut inside
  (`games\Raptor\Raptor.lnk`); Windows shortcuts (`.lnk`) and Internet
  shortcuts (`.url`, as Steam makes them) up to four folders down each
  become an item, named after the shortcut and with its icon, and running
  the item opens the shortcut. Program Manager sees the folder as
  `C:\WINDOWS\GAMES`, long names as 8.3 aliases
  (`C:\WINDOWS\GAMES\ONEMUS~1\ONEMUS~1.LNK`). Each start brings the group
  up to date over DDE (`[DeleteItem(...)]`, `[AddItem(...)]`): items for
  shortcuts that are gone are removed, new ones added, and items you add by
  hand are left alone. With a games folder, Setup's Solitaire and
  Minesweeper make way for it; without one, the Games group is Setup's.
- **The look**: the window frames, buttons, arrows and check boxes come from
  your VGA display driver; the System and MS Sans Serif fonts from your
  `.FON` files. The startup screen is your `VGALOGO.RLE` on black,
  rebranded as it loads: "WINRETRO, Version 3.2", with RETRO in Microsoft
  Works' box colours, and "WITH FATALS ENTERTAINMENT PACK" where the
  copyright lines were, "Fatals" in raised gold script: a big upright F on the line, "atals"
  (joined up) on a line above, level with the F's top: Windows
  3.1's own Script font (`SCRIPT.FON`, a vector font drawn with a round pen). The letters are the logo's own
  (`scripts/logo.lua`); any other logo file is shown as it is.
- **As a modern app**: the host window is Program Manager's frame. Its
  caption is the window's title bar, and resizing the window resizes
  Program Manager. `--desktop` shows the whole Windows 3.1 desktop instead.

Not there yet: Windows Help (`.HLP`), dropping files from Explorer onto a
group, and the other Windows 3.1 accessories on the recompiler (the way
Control Panel runs; `*` in `[Programs]` asks for that).

## Icon

`assets/progman31lua.ico` is the app's own icon, an original drawing (not Microsoft's): a retro monitor showing three launcher tiles. `tools/make_icon.py` draws it at every size from 16 to 256 px. The Windows build carries it in the executable, so it shows in Explorer, on shortcuts and on the window.

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
| `--games <folder>` | the folder the Games group shows; default: `games` beside the program |
| `--screen WxH` | window size (default 800x600) |
| `--no-logo` | skip the startup screen |
| `--desktop` | the whole Windows 3.1 desktop instead of just Program Manager |
| `--program <name>` | run another Windows 3.1 program instead of Program Manager (`--program CONTROL.EXE`) |
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

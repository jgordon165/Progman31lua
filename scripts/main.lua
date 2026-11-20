-- Progman31lua: boots Windows 3.1's Program Manager on the recompiler.
--
-- Options:
--   --data <folder>     the Windows 3.1 files: an installed WINDOWS folder or
--                       the setup disk/CD (PROGMAN.EX_ ...). Default: a data
--                       folder beside the program, then each drive's root
--                       and WINDOWS folder.
--   --home <folder>     where the emulated C:\WINDOWS lives (PROGMAN.INI, the
--                       .GRP files). Default: the per-user app data folder.
--   --games <folder>    the folder the Games group shows (default: "games"
--                       beside the program)
--   --fresh             start from an empty home (tests)
--   --screen WxH        the size of the Program Manager window (default 800x600)
--   --desktop           show the whole Windows 3.1 desktop instead of just
--                       Program Manager's window
--   --no-logo           skip the startup screen
--   --test <file.lua>   run a test script instead
--   --exit-after <ms>   quit after that long (tests)
--   --dump <folder>     write each recompiled block's Lua source there

local opts = {}
do
    local a = host.args
    local i = 1
    while i <= #a do
        local k = a[i]
        if k:sub(1, 2) == "--" then
            local name = k:sub(3)
            local v = a[i + 1]
            if v and v:sub(1, 2) ~= "--" and name ~= "headless" and name ~= "fresh" and name ~= "desktop" and name ~= "no-logo" then
                opts[name] = v
                i = i + 1
            else
                opts[name] = true
            end
        end
        i = i + 1
    end
end
OPTS = opts

if opts.test then
    local chunk = assert(loadfile(opts.test))
    return chunk(opts)
end

local boot = require("boot")
return boot.run(opts)

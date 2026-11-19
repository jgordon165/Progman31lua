-- The Win16 layer: brings up the machine (thunks, scratch memory), the API
-- modules, the file system and the system resources, then loads
-- PROGMAN.EXE and runs it.

local cpu = require("recomp.cpu")
local ne = require("recomp.ne")
local loader = require("recomp.loader")
local api = require("win16.api")

local win16 = {}

local state = {}
win16.state = state

-- The system modules whose resources the layer uses, from the Windows 3.1
-- files: icons and cursors (USER.EXE), the window-frame bitmaps (the VGA
-- display driver), and the fonts.
local function loadSystemModule(data, name)
    local boot = require("boot")
    local bytes = boot.dataFile(data, name)
    if not bytes then return nil end
    local m = ne.parse(bytes, name)
    return m
end

function win16.init(cfg)
    state.cfg = cfg
    cpu.THUNK_SEL = cpu.newsel(cpu.lalloc(16), 0xFFFF, true)
    api.initScratch()
    if cfg.opts.trace then api.trace = true end
    if type(cfg.opts.dump) == "string" then cpu.dump = cfg.opts.dump; host.mkdir(cfg.opts.dump) end

    require("win16.signatures")
    local dosfs = require("win16.dosfs")
    dosfs.init(cfg.home, cfg.data)
    require("win16.defaults").install()

    local sys = {}
    sys.user = loadSystemModule(cfg.data, "USER.EXE")
    sys.display = loadSystemModule(cfg.data, "VGA.DRV")
    sys.sysfont = loadSystemModule(cfg.data, "VGASYS.FON")
    sys.sansfont = loadSystemModule(cfg.data, "SSERIFE.FON")
    sys.fixfont = loadSystemModule(cfg.data, "VGAFIX.FON")
    state.sys = sys

    local kernel = require("win16.kernel")
    local gdi = require("win16.gdi")
    gdi.init(cfg.screenW, cfg.screenH, sys)
    local user = require("win16.user")
    user.init(cfg, sys)
    require("win16.shell")
    require("win16.keyboard")

    -- PROGMAN.EXE
    local boot = require("boot")
    local bytes = boot.dataFile(cfg.data, "PROGMAN.EXE")
    if not bytes then error("PROGMAN.EXE could not be read from " .. cfg.data) end
    local mod, err = ne.parse(bytes, "PROGMAN.EXE")
    if not mod then error("PROGMAN.EXE: " .. err) end
    local inst = loader.load(mod, api.resolve, {program = true})
    state.progman = inst
    host.log(string.format("PROGMAN.EXE: %d segments, %d imports, %d internal fixups, %d prologues patched",
        #mod.segments, inst.stats.imports, inst.stats.internal, inst.stats.prologues or 0))
    local task = kernel.startTask(inst, {path = "C:\\WINDOWS\\PROGMAN.EXE", cmdShow = 1, cmdLine = ""})
    user.setTask(task, mod)
    state.task = task
end

function win16.run()
    local task = state.task
    local ok, err = pcall(cpu.run, task.R)
    local user = require("win16.user")
    user.shutdown()
    if not ok then
        if type(err) == "table" and err.exit then return err.exit end
        if type(err) == "table" and err.quit then return err.code or 0 end
        local R = task.R
        local msg = tostring(err) .. string.format("\n(at %04X:%04X)", R.cs, R.ip)
        host.log("Program Manager stopped: " .. msg)
        if not host.headless then host.message_box("Program Manager", msg) end
        return 1
    end
    return 0
end

return win16

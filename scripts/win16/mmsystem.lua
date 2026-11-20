-- MMSYSTEM: the little of it Control Panel's Sound applet uses. Sounds are
-- played by the host when it can; there is one wave output device.

local api = require("win16.api")
local dosfs = require("win16.dosfs")
local profile = require("win16.profile")

local def = api.def

-- sndPlaySound(name, flags): a .WAV file, or a [sounds] entry of WIN.INI
-- (SND_ASYNC 1, SND_NODEFAULT 2, SND_MEMORY 4, SND_LOOP 8, SND_NOSTOP 16)
def("MMSYSTEM", 2, "sndPlaySound", "s w", function(name, flags)
    if not name then return 1 end
    if flags & 4 ~= 0 then return 0 end
    local file = name
    local entry = profile.get(profile.resolve(nil), "sounds", name)
    if entry then file = entry:match("^([^,]*)") end
    local full = dosfs.full(file:find("\\\\") and file or (dosfs.windows .. "\\\\" .. file))
    if not full:match("%.%w+$") then full = full .. ".WAV" end
    local hp = dosfs.hostFile(full)
    if not hp then
        if flags & 2 == 0 then host.beep() end
        return 0
    end
    if host.play_wav then host.play_wav(hp) else host.beep() end
    return 1
end)
def("MMSYSTEM", 401, "waveOutGetNumDevs", "", function() return 1 end)

return {}

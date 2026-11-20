-- A new home's WIN.INI, as Windows 3.1 Setup would have written its
-- defaults, and the program map for launching.

local dosfs = require("win16.dosfs")
local profile = require("win16.profile")

local defaults = {}

local WIN_INI = [[
[windows]
spooler=yes
load=
run=
Beep=yes
NullPort=None
BorderWidth=3
CursorBlinkRate=530
DoubleClickSpeed=452
Programs=com exe bat pif
Documents=
DeviceNotSelectedTimeout=15
TransmissionRetryTimeout=45
KeyboardDelay=2
KeyboardSpeed=31
ScreenSaveActive=0
ScreenSaveTimeOut=120

[Desktop]
Pattern=(None)
Wallpaper=(None)
GridGranularity=0
IconSpacing=75
TileWallpaper=0

[Extensions]
cal=calendar.exe ^.cal
crd=cardfile.exe ^.crd
trm=terminal.exe ^.trm
txt=notepad.exe ^.txt
ini=notepad.exe ^.ini
pcx=pbrush.exe ^.pcx
bmp=pbrush.exe ^.bmp
wri=write.exe ^.wri
rec=recorder.exe ^.rec
hlp=winhelp.exe ^.hlp

[intl]
sLanguage=enu
sCountry=United States
iCountry=1
iDate=0
iTime=0
iTLZero=0
iCurrency=0
iCurrDigits=2
iNegCurr=0
iLzero=0
iDigits=2
iMeasure=1
s1159=AM
s2359=PM
sCurrency=$
sThousand=,
sDecimal=.
sDate=/
sTime=:
sList=,
sShortDate=M/d/yy
sLongDate=dddd, MMMM dd, yyyy

[colors]
Background=192 192 192
AppWorkspace=255 255 255
Window=255 255 255
WindowText=0 0 0
Menu=255 255 255
MenuText=0 0 0
ActiveTitle=0 0 128
InactiveTitle=255 255 255
TitleText=255 255 255
ActiveBorder=192 192 192
InactiveBorder=192 192 192
WindowFrame=0 0 0
Scrollbar=192 192 192
ButtonFace=192 192 192
ButtonShadow=128 128 128
ButtonText=0 0 0
GrayText=192 192 192
Hilight=0 0 128
HilightText=255 255 255
InactiveTitleText=0 0 0
ButtonHilight=255 255 255
]]

function defaults.install()
    local win = dosfs.windows .. "\\WIN.INI"
    if not dosfs.hostFile(win) then dosfs.write(win, (WIN_INI:gsub("\n", "\r\n"))) end
    profile.flush()
    require("win16.launch").installDefaults()
end

-- Whether Program Manager has groups yet (PROGMAN.INI's [Groups]).
function defaults.hasGroups()
    local ini = dosfs.windows .. "\\PROGMAN.INI"
    if not dosfs.hostFile(ini) then return false end
    local keys = profile.keys(ini, "Groups")
    for _, k in ipairs(keys) do
        if k:upper():match("^GROUP%d+$") then return true end
    end
    return false
end

return defaults

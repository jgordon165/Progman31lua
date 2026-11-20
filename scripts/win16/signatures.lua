-- Pascal signatures of every Win16 function Program Manager imports (and a
-- few more it reaches through GetProcAddress), so that even a function the
-- Win16 layer doesn't implement yet pops the right number of bytes. The
-- real implementations (kernel.lua, user.lua, gdi.lua, ...) replace these.

local api = require("win16.api")

local S = {
    USER = {
        {1, "MessageBox", "h s s w"}, {5, "InitApp", "h"}, {6, "PostQuitMessage", "i:v"},
        {7, "ExitWindows", "l w"}, {22, "SetFocus", "h"}, {23, "GetFocus", ""},
        {29, "ScreenToClient", "h p:v"}, {31, "IsIconic", "h"}, {32, "GetWindowRect", "h p:v"},
        {33, "GetClientRect", "h p:v"}, {34, "EnableWindow", "h w"}, {35, "IsWindowEnabled", "h"},
        {36, "GetWindowText", "h p i"}, {37, "SetWindowText", "h s:v"}, {38, "GetWindowTextLength", "h"},
        {39, "BeginPaint", "h p"}, {40, "EndPaint", "h p:v"},
        {41, "CreateWindow", "s s l i i i i h h h f"}, {42, "ShowWindow", "h i"},
        {45, "BringWindowToTop", "h"}, {47, "IsWindow", "h"}, {56, "MoveWindow", "h i i i i w"},
        {57, "RegisterClass", "p"}, {60, "GetActiveWindow", ""}, {61, "ScrollWindow", "h i i p p:v"},
        {62, "SetScrollPos", "h i i w"}, {63, "GetScrollPos", "h i"}, {64, "SetScrollRange", "h i i i w:v"},
        {65, "GetScrollRange", "h i p p:v"}, {66, "GetDC", "h"}, {68, "ReleaseDC", "h h"},
        {69, "SetCursor", "h"}, {71, "ShowCursor", "w"}, {72, "SetRect", "p i i i i:v"},
        {73, "SetRectEmpty", "p:v"}, {74, "CopyRect", "p p:v"}, {75, "IsRectEmpty", "p"},
        {76, "PtInRect", "p l"}, {77, "OffsetRect", "p i i:v"}, {78, "InflateRect", "p i i:v"},
        {79, "IntersectRect", "p p p"}, {80, "UnionRect", "p p p"}, {81, "FillRect", "h p h"},
        {84, "DrawIcon", "h i i h"}, {85, "DrawText", "h f i p w"}, {87, "DialogBox", "h r h f"},
        {88, "EndDialog", "h i:v"}, {91, "GetDlgItem", "h i"}, {92, "SetDlgItemText", "h i s:v"},
        {93, "GetDlgItemText", "h i p i"}, {96, "CheckRadioButton", "h i i i:v"},
        {97, "CheckDlgButton", "h i w:v"}, {98, "IsDlgButtonChecked", "h i"},
        {101, "SendDlgItemMessage", "h i w w l:l"}, {104, "MessageBeep", "w:v"}, {106, "GetKeyState", "i"},
        {107, "DefWindowProc", "h w w l:l"}, {108, "GetMessage", "p h w w"}, {109, "PeekMessage", "p h w w w"},
        {110, "PostMessage", "h w w l"}, {111, "SendMessage", "h w w l:l"}, {113, "TranslateMessage", "p"},
        {114, "DispatchMessage", "p:l"}, {118, "RegisterWindowMessage", "s"}, {121, "SetWindowsHook", "i f:l"},
        {124, "UpdateWindow", "h:v"}, {125, "InvalidateRect", "h p w:v"}, {126, "InvalidateRgn", "h h w:v"},
        {127, "ValidateRect", "h p:v"}, {129, "GetClassWord", "h i"}, {130, "SetClassWord", "h i w"},
        {133, "GetWindowWord", "h i"}, {134, "SetWindowWord", "h i w"}, {135, "GetWindowLong", "h i:l"},
        {136, "SetWindowLong", "h i l:l"}, {154, "CheckMenuItem", "h w w"}, {155, "EnableMenuItem", "h w w"},
        {156, "GetSystemMenu", "h w"}, {157, "GetMenu", "h"}, {159, "GetSubMenu", "h i"},
        {163, "CreateCaret", "h h i i:v"}, {164, "DestroyCaret", ":v"}, {165, "SetCaretPos", "i i:v"},
        {166, "HideCaret", "h:v"}, {167, "ShowCaret", "h:v"}, {171, "WinHelp", "h s w l"},
        {173, "LoadCursor", "h r"}, {174, "LoadIcon", "h r"}, {176, "LoadString", "h w p i"},
        {177, "LoadAccelerators", "h r"}, {178, "TranslateAccelerator", "h h p"},
        {179, "GetSystemMetrics", "i"}, {180, "GetSysColor", "i:l"}, {185, "GrayString", "h h f l i i i i i"},
        {188, "SetSysModalWindow", "h"}, {232, "SetWindowPos", "h h i i i i w:v"}, {235, "DefHookProc", "i w l f:l"},
        {262, "GetWindow", "h w"}, {268, "GlobalAddAtom", "r"}, {269, "GlobalDeleteAtom", "w"},
        {270, "GlobalFindAtom", "r"}, {272, "IsZoomed", "h"}, {287, "GetLastActivePopup", "h"},
        {368, "CopyIcon", "h h"}, {370, "GetWindowPlacement", "h p"}, {371, "SetWindowPlacement", "h p"},
        {372, "GetInternalIconHeader", "f p:v"}, {413, "DeleteMenu", "h w w"}, {414, "ModifyMenu", "h w w w f"},
        {420, "_wsprintf", ""}, {430, "lstrcmp", "s s"}, {431, "AnsiUpper", "f:l"}, {432, "AnsiLower", "f:l"},
        {433, "IsCharAlpha", "w"}, {434, "IsCharAlphaNumeric", "w"}, {437, "AnsiUpperBuff", "p w"},
        {445, "DefFrameProc", "h h w w l:l"}, {447, "DefMDIChildProc", "h w w l:l"},
        {451, "TranslateMDISysAccel", "h p"}, {457, "DestroyIcon", "h"}, {459, "DumpIcon", "f p p p:l"},
        {462, "CalcChildScroll", "h w:v"}, {464, "DragObject", "h h w w h h:l"}, {466, "DrawFocusRect", "h p:v"},
        {471, "lstrcmpi", "s s"}, {483, "SystemParametersInfo", "w w f w"},
    },
    GDI = {
        {1, "SetBkColor", "h l:l"}, {2, "SetBkMode", "h i"}, {9, "SetTextColor", "h l:l"},
        {29, "PatBlt", "h i i i i l"}, {33, "TextOut", "h i i f i"}, {34, "BitBlt", "h i i i i h i i l"},
        {45, "SelectObject", "h h"}, {47, "CombineRgn", "h h h i"}, {52, "CreateCompatibleDC", "h"},
        {57, "CreateFontIndirect", "p"}, {64, "CreateRectRgn", "i i i i"}, {66, "CreateSolidBrush", "l"},
        {68, "DeleteDC", "h"}, {69, "DeleteObject", "h"}, {80, "GetDeviceCaps", "h i"},
        {87, "GetStockObject", "i"}, {91, "GetTextExtent", "h f i:l"}, {93, "GetTextMetrics", "h p"},
        {104, "RectVisible", "h p"}, {156, "CreateDiscardableBitmap", "h i i"}, {172, "SetRectRgn", "h i i i i:v"},
        {351, "ExtTextOut", "h i i w p f w p"},
    },
    KEYBOARD = {
        {5, "AnsiToOem", "f f"}, {6, "OemToAnsi", "f f"}, {131, "MapVirtualKey", "w w"}, {133, "GetKeyNameText", "l p i"},
    },
    SHELL = {
        {9, "DragAcceptFiles", "h w:v"}, {11, "DragQueryFile", "h w p w"}, {12, "DragFinish", "h:v"},
        {13, "DragQueryPoint", "h p"}, {20, "ShellExecute", "h s s s s i"}, {21, "FindExecutable", "s s p"},
        {22, "ShellAbout", "h s s h"}, {34, "ExtractIcon", "h s w"}, {36, "ExtractAssociatedIcon", "h p p"},
        {37, "DoEnvironmentSubst", "p w:l"}, {39, "InternalExtractIcon", "h s w w"}, {102, "RegisterShellHook", "h w"},
    },
}

-- and what Control Panel, its applets (.CPL) and the system DLLs it loads
-- (COMMDLG, VER, LZEXPAND) import
local MORE = {
    USER = {
        {10, "SetTimer", "h w w f"}, {12, "KillTimer", "h w"}, {16, "ClipCursor", "p:v"},
        {18, "SetCapture", "h"}, {19, "ReleaseCapture", ":v"}, {20, "SetDoubleClickTime", "w:v"},
        {24, "RemoveProp", "h r"}, {25, "GetProp", "h r"}, {26, "SetProp", "h r h"},
        {28, "ClientToScreen", "h p:v"}, {46, "GetParent", "h"}, {53, "DestroyWindow", "h"},
        {58, "GetClassName", "h p i"}, {59, "SetActiveWindow", "h"}, {82, "InvertRect", "h p:v"},
        {83, "FrameRect", "h p h"}, {89, "CreateDialog", "h r h f"}, {90, "IsDialogMessage", "h p"},
        {94, "SetDlgItemInt", "h i w w:v"}, {95, "GetDlgItemInt", "h i p w"}, {99, "DlgDirSelect", "h p i"},
        {100, "DlgDirList", "h p i i w"}, {119, "GetMessagePos", ":l"}, {122, "CallWindowProc", "f h w w l:l"},
        {131, "GetClassLong", "h i:l"}, {168, "SetCaretBlinkTime", "w:v"}, {175, "LoadBitmap", "h r"},
        {181, "SetSysColors", "i p p:v"}, {186, "SwapMouseButton", "w"}, {189, "GetSysModalWindow", ""},
        {190, "GetUpdateRect", "h p w"}, {191, "ChildWindowFromPoint", "h l"}, {195, "DlgDirListComboBox", "h p i i w"},
        {200, "OpenComm", "s w w"}, {207, "CloseComm", "i"}, {214, "EscapeCommFunction", "i i:l"},
        {239, "DialogBoxParam", "h r h f l"}, {240, "DialogBoxIndirectParam", "h h h f l"},
        {242, "CreateDialogIndirectParam", "h f h f l"}, {243, "GetDialogBaseUnits", ":l"},
        {244, "EqualRect", "p p"}, {249, "GetAsyncKeyState", "i"}, {251, "SendDriverMessage", "h w l l:l"},
        {252, "OpenDriver", "s s l"}, {253, "CloseDriver", "h l l:l"}, {254, "GetDriverModuleHandle", "h"},
        {257, "GetNextDriver", "h l"}, {277, "GetDlgCtrlID", "h"}, {410, "InsertMenu", "h w w w f"},
        {421, "wvsprintf", "p s f"}, {435, "IsCharUpper", "w"}, {436, "IsCharLower", "w"},
        {472, "AnsiNext", "f:l"}, {512, "WNetGetConnection", "s p p"}, {513, "WNetGetCaps", "w"},
        {514, "WNetDeviceMode", "h"}, {515, "WNetBrowseDialog", "h w p"}, {517, "WNetAddConnection", "s s s"},
        {518, "WNetCancelConnection", "s w"}, {519, "WNetGetError", "p"}, {520, "WNetGetErrorText", "w p p"},
        {525, "WNetConnectDialog", "h w"}, {527, "WNetConnectionDialog", "h w"},
    },
    GDI = {
        {3, "SetMapMode", "h i"}, {11, "SetWindowOrg", "h i i:l"}, {12, "SetWindowExt", "h i i:l"},
        {13, "SetViewportOrg", "h i i:l"}, {14, "SetViewportExt", "h i i:l"}, {19, "LineTo", "h i i"},
        {20, "MoveTo", "h i i:l"}, {21, "ExcludeClipRect", "h i i i i"}, {27, "Rectangle", "h i i i i"},
        {36, "Polygon", "h p i"}, {38, "Escape", "h i i f f"}, {40, "FillRgn", "h h h"},
        {44, "SelectClipRgn", "h h"}, {51, "CreateCompatibleBitmap", "h i i"}, {53, "CreateDC", "s s s p"},
        {56, "CreateFont", "i i i i i w w w w w w w w s"}, {60, "CreatePatternBrush", "h"}, {61, "CreatePen", "i i l"},
        {65, "CreateRectRgnIndirect", "p"}, {81, "GetMapMode", "h"}, {82, "GetObject", "h i p"},
        {94, "GetViewportExt", "h:l"}, {96, "GetWindowExt", "h:l"}, {119, "AddFontResource", "f"},
        {128, "MulDiv", "i i i"}, {136, "RemoveFontResource", "f"}, {150, "UnrealizeObject", "h"},
        {153, "CreateIC", "s s s p"}, {154, "GetNearestColor", "h l:l"}, {161, "PtInRegion", "h i i"},
        {245, "GetSpoolJob", "w l"}, {310, "CreateScalableFontResource", "w s s s"},
        {313, "GetRasterizerCaps", "p w"}, {350, "GetCharWidth", "h w w p"}, {442, "CreateDIBitmap", "h p l p p w"},
        {467, "GDI467", "f f"},
    },
    KERNEL = {
        {1, "FatalExit", "i:v"}, {3, "GetVersion", ":l"}, {23, "LockSegment", "w"}, {24, "UnlockSegment", "w"},
        {25, "GlobalCompact", "l:l"}, {60, "FindResource", "h r r"}, {61, "LoadResource", "h h"},
        {63, "FreeResource", "h"}, {70, "AddAtom", "r"}, {71, "DeleteAtom", "w"}, {72, "GetAtomName", "w p i"},
        {115, "OutputDebugString", "s:v"}, {121, "LocalShrink", "h w"}, {132, "GetWinFlags", ":l"},
        {137, "FatalAppExit", "w s:v"}, {175, "AllocSelector", "w"}, {176, "FreeSelector", "w"},
        {184, "GlobalDosAlloc", "l:l"}, {185, "GlobalDosFree", "w"}, {186, "GetSelectorBase", "w:l"},
        {187, "SetSelectorBase", "w l"}, {189, "SetSelectorLimit", "w l"}, {191, "GlobalPageLock", "h"},
        {192, "GlobalPageUnlock", "h"}, {207, "IsDBCSLeadByte", "w"},
    },
    MMSYSTEM = {
        {2, "sndPlaySound", "s w"}, {401, "waveOutGetNumDevs", ""},
    },
}
for module, list in pairs(MORE) do
    S[module] = S[module] or {}
    for _, e in ipairs(list) do table.insert(S[module], e) end
end

for module, list in pairs(S) do
    for _, e in ipairs(list) do api.stub(module, e[1], e[2], e[3]) end
end

return S

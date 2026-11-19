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

for module, list in pairs(S) do
    for _, e in ipairs(list) do api.stub(module, e[1], e[2], e[3]) end
end

return S

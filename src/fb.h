// Software surfaces with Windows GDI semantics, drawn by the Win16 layer in
// Lua: the screen and every memory bitmap are a Surface. Operations take a
// ternary raster operation (ROP3) and are clipped to a list of rectangles
// (the visible region of the window being drawn), so overlapping windows
// behave as they do in Windows.
#pragma once

#include "formats/fnt.h"

#include <cstdint>
#include <memory>
#include <vector>

namespace fb {

// 0x00RRGGBB, as a Windows COLORREF with red and blue swapped.
using Color = uint32_t;

struct Rect {
    int x0, y0, x1, y1;   // x1, y1 exclusive
};

struct Surface {
    int w = 0, h = 0;
    bool mono = false;           // a monochrome bitmap: pixels are 0 or 0xFFFFFF
    std::vector<Color> px;

    Color& at(int x, int y) { return px[static_cast<size_t>(y) * w + x]; }
    Color get(int x, int y) const { return px[static_cast<size_t>(y) * w + x]; }
};

// The clip list every drawing call uses; empty = the whole surface.
struct Clip {
    std::vector<Rect> rects;
    bool all = true;
};

// Generic ROP3 on 24 bits: bit i of the rop is the result for
// (P << 2 | S << 1 | D) == i.
inline Color rop3(uint8_t rop, Color p, Color s, Color d) {
    switch (rop) {
        case 0x00: return 0;
        case 0xFF: return 0xFFFFFF;
        case 0xCC: return s;
        case 0xF0: return p;
        case 0x55: return ~d & 0xFFFFFF;
        case 0x66: return s ^ d;
        case 0x88: return s & d;
        case 0xEE: return s | d;
        case 0x5A: return p ^ d;
        case 0x33: return ~s & 0xFFFFFF;
        case 0xAA: return d;
        default: break;
    }
    Color r = 0;
    for (int i = 0; i < 8; ++i) {
        if (!(rop >> i & 1)) continue;
        const Color a = (i & 4) ? p : ~p;
        const Color b = (i & 2) ? s : ~s;
        const Color c = (i & 1) ? d : ~d;
        r |= a & b & c;
    }
    return r & 0xFFFFFF;
}

// ROP2 (SetROP2's R2_* codes, 1..16) for lines.
Color rop2(int code, Color pen, Color d);

// Brushes: a solid colour, or an 8x8 pattern of colours.
struct Brush {
    bool pattern = false;
    Color color = 0;
    Color pat[64]{};
    Color at(int x, int y) const { return pattern ? pat[(y & 7) * 8 + (x & 7)] : color; }
};

void patBlt(Surface& d, const Clip& clip, int x, int y, int w, int h, uint8_t rop, const Brush& br);

// Copies with a ROP3. Mono source to colour: 0 -> textColor, 1 -> bkColor.
// Colour source to mono: bkColor -> 1 (white), anything else -> 0.
void bitBlt(Surface& d, const Clip& clip, int dx, int dy, int w, int h, const Surface& s, int sx, int sy,
            uint8_t rop, const Brush& br, Color textColor, Color bkColor);

void stretchBlt(Surface& d, const Clip& clip, int dx, int dy, int dw, int dh, const Surface& s, int sx, int sy,
                int sw, int sh, uint8_t rop, const Brush& br, Color textColor, Color bkColor);

void line(Surface& d, const Clip& clip, int x0, int y0, int x1, int y1, int rop2code, Color pen);

// Draws text in a raster font at (x, y) = the top-left of the cell.
// opaque: fills each cell with bk first. extraBold draws each glyph twice.
// Returns the advance width.
int text(Surface& d, const Clip& clip, const tp::Font& f, int x, int y, const std::string& s, Color fg, Color bk,
         bool opaque, bool bold, bool underline);
int textWidth(const tp::Font& f, const std::string& s, bool bold);

}  // namespace fb

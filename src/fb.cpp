#include "fb.h"

#include <algorithm>
#include <cstdlib>

namespace fb {

Color rop2(int code, Color pen, Color d) {
    const Color P = pen & 0xFFFFFF, D = d & 0xFFFFFF, M = 0xFFFFFF;
    switch (code) {
        case 1: return 0;                  // R2_BLACK
        case 2: return ~(P | D) & M;       // R2_NOTMERGEPEN
        case 3: return ~P & D & M;         // R2_MASKNOTPEN
        case 4: return ~P & M;             // R2_NOTCOPYPEN
        case 5: return P & ~D & M;         // R2_MASKPENNOT
        case 6: return ~D & M;             // R2_NOT
        case 7: return P ^ D;              // R2_XORPEN
        case 8: return ~(P & D) & M;       // R2_NOTMASKPEN
        case 9: return P & D;              // R2_MASKPEN
        case 10: return ~(P ^ D) & M;      // R2_NOTXORPEN
        case 11: return D;                 // R2_NOP
        case 12: return (~P | D) & M;      // R2_MERGENOTPEN
        case 14: return (P | ~D) & M;      // R2_MERGEPENNOT
        case 15: return P | D;             // R2_MERGEPEN
        case 16: return M;                 // R2_WHITE
        default: return P;                 // R2_COPYPEN (13)
    }
}

namespace {

// Calls fn(x0, y0, x1, y1) for each part of r inside the clip and surface.
template <class F>
void forClipped(const Surface& d, const Clip& clip, Rect r, F fn) {
    r.x0 = std::max(r.x0, 0);
    r.y0 = std::max(r.y0, 0);
    r.x1 = std::min(r.x1, d.w);
    r.y1 = std::min(r.y1, d.h);
    if (r.x0 >= r.x1 || r.y0 >= r.y1) return;
    if (clip.all) {
        fn(r.x0, r.y0, r.x1, r.y1);
        return;
    }
    for (const Rect& c : clip.rects) {
        const int x0 = std::max(r.x0, c.x0), y0 = std::max(r.y0, c.y0);
        const int x1 = std::min(r.x1, c.x1), y1 = std::min(r.y1, c.y1);
        if (x0 < x1 && y0 < y1) fn(x0, y0, x1, y1);
    }
}

bool usesSource(uint8_t rop) { return ((rop >> 2) & 0x33) != (rop & 0x33); }
bool usesPattern(uint8_t rop) { return ((rop >> 4) & 0x0F) != (rop & 0x0F); }

Color toMono(Color c) { return c ? 0xFFFFFF : 0; }

}  // namespace

void patBlt(Surface& d, const Clip& clip, int x, int y, int w, int h, uint8_t rop, const Brush& br) {
    if (w < 0) { x += w; w = -w; }
    if (h < 0) { y += h; h = -h; }
    forClipped(d, clip, {x, y, x + w, y + h}, [&](int x0, int y0, int x1, int y1) {
        for (int yy = y0; yy < y1; ++yy)
            for (int xx = x0; xx < x1; ++xx) {
                Color& px = d.at(xx, yy);
                Color p = br.at(xx, yy);
                if (d.mono) p = toMono(p);
                px = rop3(rop, p, 0, px);
                if (d.mono) px = toMono(px);
            }
    });
}

void bitBlt(Surface& d, const Clip& clip, int dx, int dy, int w, int h, const Surface& s, int sx, int sy,
            uint8_t rop, const Brush& br, Color textColor, Color bkColor) {
    stretchBlt(d, clip, dx, dy, w, h, s, sx, sy, w, h, rop, br, textColor, bkColor);
}

void stretchBlt(Surface& d, const Clip& clip, int dx, int dy, int dw, int dh, const Surface& s, int sx, int sy,
                int sw, int sh, uint8_t rop, const Brush& br, Color textColor, Color bkColor) {
    if (dw == 0 || dh == 0 || sw == 0 || sh == 0) return;
    const bool needSrc = usesSource(rop);
    const bool needPat = usesPattern(rop);
    forClipped(d, clip, {dx, dy, dx + dw, dy + dh}, [&](int x0, int y0, int x1, int y1) {
        for (int yy = y0; yy < y1; ++yy) {
            const int syy = sy + static_cast<int>((static_cast<long long>(yy - dy) * sh) / dh);
            for (int xx = x0; xx < x1; ++xx) {
                Color src = 0;
                if (needSrc) {
                    const int sxx = sx + static_cast<int>((static_cast<long long>(xx - dx) * sw) / dw);
                    if (sxx < 0 || syy < 0 || sxx >= s.w || syy >= s.h) continue;
                    src = s.get(sxx, syy);
                    if (s.mono && !d.mono) src = src ? bkColor : textColor;
                    else if (!s.mono && d.mono) src = (src == bkColor) ? 0xFFFFFF : 0;
                }
                Color pat = needPat ? br.at(xx, yy) : 0;
                if (d.mono) pat = toMono(pat);
                Color& px = d.at(xx, yy);
                px = rop3(rop, pat, src, px);
                if (d.mono) px = toMono(px);
            }
        }
    });
}

void line(Surface& d, const Clip& clip, int x0, int y0, int x1, int y1, int code, Color pen) {
    // Bresenham, excluding the last point as GDI does.
    const int dx = std::abs(x1 - x0), sx = x0 < x1 ? 1 : -1;
    const int dy = -std::abs(y1 - y0), sy = y0 < y1 ? 1 : -1;
    int err = dx + dy;
    for (;;) {
        if (x0 == x1 && y0 == y1) break;
        forClipped(d, clip, {x0, y0, x0 + 1, y0 + 1}, [&](int px, int py, int, int) {
            Color& c = d.at(px, py);
            c = rop2(code, d.mono ? toMono(pen) : pen, c);
            if (d.mono) c = toMono(c);
        });
        const int e2 = 2 * err;
        if (e2 >= dy) { err += dy; x0 += sx; }
        if (e2 <= dx) { err += dx; y0 += sy; }
    }
}

int textWidth(const tp::Font& f, const std::string& s, bool bold) {
    int w = 0;
    for (unsigned char c : s) w += f.glyph(c).width + (bold ? 1 : 0);
    return w;
}

int text(Surface& d, const Clip& clip, const tp::Font& f, int x, int y, const std::string& s, Color fg, Color bk,
         bool opaque, bool bold, bool underline) {
    if (d.mono) { fg = toMono(fg); bk = toMono(bk); }
    const int start = x;
    for (unsigned char c : s) {
        const auto& g = f.glyph(c);
        const int cw = g.width + (bold ? 1 : 0);
        forClipped(d, clip, {x, y, x + cw, y + f.height}, [&](int x0, int y0, int x1, int y1) {
            for (int yy = y0; yy < y1; ++yy)
                for (int xx = x0; xx < x1; ++xx) {
                    const int gx = xx - x, gy = yy - y;
                    bool on = gx < g.width && g.bits[static_cast<size_t>(gy) * g.width + gx];
                    if (bold && gx > 0 && gx - 1 < g.width) on = on || g.bits[static_cast<size_t>(gy) * g.width + gx - 1];
                    if (underline && gy == f.ascent + 1) on = true;
                    if (on) d.at(xx, yy) = fg;
                    else if (opaque) d.at(xx, yy) = bk;
                }
        });
        x += cw;
    }
    return x - start;
}

}  // namespace fb

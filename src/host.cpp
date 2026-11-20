#include "host.h"

#include "fb.h"
#include "formats/binreader.h"
#include "formats/dib.h"
#include "formats/expand.h"
#include "formats/fnt.h"

extern "C" {
#include "lauxlib.h"
#include "lua.h"
}

#include <SDL.h>
#ifdef _WIN32
#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>
// after windows.h
#include <shellapi.h>
#else
#include <spawn.h>
#include <sys/wait.h>
#include <unistd.h>
extern char** environ;
#endif
#include <algorithm>
#include <chrono>
#include <cstdio>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <memory>
#include <string>
#include <vector>

namespace fs = std::filesystem;

namespace {

HostConfig* g_cfg = nullptr;

// ---- mem: the linear address space of the 16-bit machine ---------------------

constexpr uint32_t kMemSize = 16u << 20;
constexpr uint32_t kMemMask = kMemSize - 1;
std::vector<uint8_t> g_mem(kMemSize);

inline uint32_t addr(lua_State* L, int i) { return static_cast<uint32_t>(luaL_checkinteger(L, i)) & kMemMask; }

int m_rb(lua_State* L) { lua_pushinteger(L, g_mem[addr(L, 1)]); return 1; }
int m_rw(lua_State* L) {
    const uint32_t a = addr(L, 1);
    lua_pushinteger(L, g_mem[a] | g_mem[(a + 1) & kMemMask] << 8);
    return 1;
}
int m_rd(lua_State* L) {
    const uint32_t a = addr(L, 1);
    uint32_t v = 0;
    for (int i = 3; i >= 0; --i) v = v << 8 | g_mem[(a + i) & kMemMask];
    lua_pushinteger(L, v);
    return 1;
}
int m_wb(lua_State* L) { g_mem[addr(L, 1)] = static_cast<uint8_t>(luaL_checkinteger(L, 2)); return 0; }
int m_ww(lua_State* L) {
    const uint32_t a = addr(L, 1);
    const lua_Integer v = luaL_checkinteger(L, 2);
    g_mem[a] = static_cast<uint8_t>(v);
    g_mem[(a + 1) & kMemMask] = static_cast<uint8_t>(v >> 8);
    return 0;
}
int m_wd(lua_State* L) {
    const uint32_t a = addr(L, 1);
    const lua_Integer v = luaL_checkinteger(L, 2);
    for (int i = 0; i < 4; ++i) g_mem[(a + i) & kMemMask] = static_cast<uint8_t>(v >> (8 * i));
    return 0;
}
int m_read(lua_State* L) {
    const uint32_t a = addr(L, 1);
    const lua_Integer n = luaL_checkinteger(L, 2);
    if (n <= 0) { lua_pushliteral(L, ""); return 1; }
    if (a + static_cast<uint64_t>(n) > kMemSize) return luaL_error(L, "mem.read past the end");
    lua_pushlstring(L, reinterpret_cast<const char*>(&g_mem[a]), static_cast<size_t>(n));
    return 1;
}
int m_write(lua_State* L) {
    const uint32_t a = addr(L, 1);
    size_t n = 0;
    const char* s = luaL_checklstring(L, 2, &n);
    if (a + static_cast<uint64_t>(n) > kMemSize) return luaL_error(L, "mem.write past the end");
    std::memcpy(&g_mem[a], s, n);
    return 0;
}
int m_fill(lua_State* L) {
    const uint32_t a = addr(L, 1);
    const lua_Integer n = luaL_checkinteger(L, 2);
    if (n <= 0) return 0;
    if (a + static_cast<uint64_t>(n) > kMemSize) return luaL_error(L, "mem.fill past the end");
    std::memset(&g_mem[a], static_cast<int>(luaL_optinteger(L, 3, 0)), static_cast<size_t>(n));
    return 0;
}
int m_move(lua_State* L) {
    const uint32_t d = addr(L, 1), s = addr(L, 2);
    const lua_Integer n = luaL_checkinteger(L, 3);
    if (n <= 0) return 0;
    if (d + static_cast<uint64_t>(n) > kMemSize || s + static_cast<uint64_t>(n) > kMemSize)
        return luaL_error(L, "mem.move past the end");
    std::memmove(&g_mem[d], &g_mem[s], static_cast<size_t>(n));
    return 0;
}
// mem.cstr(addr [, max]) -> the NUL-terminated string there
int m_cstr(lua_State* L) {
    uint32_t a = addr(L, 1);
    const lua_Integer max = luaL_optinteger(L, 2, 65536);
    std::string s;
    for (lua_Integer i = 0; i < max && g_mem[a]; ++i, a = (a + 1) & kMemMask) s.push_back(static_cast<char>(g_mem[a]));
    lua_pushlstring(L, s.data(), s.size());
    return 1;
}
// mem.find(addr, max, byte) -> offset of the first byte == value, or nil
int m_find(lua_State* L) {
    const uint32_t a = addr(L, 1);
    const lua_Integer max = luaL_checkinteger(L, 2);
    const uint8_t v = static_cast<uint8_t>(luaL_checkinteger(L, 3));
    for (lua_Integer i = 0; i < max; ++i)
        if (g_mem[(a + i) & kMemMask] == v) { lua_pushinteger(L, i); return 1; }
    return 0;
}

// ---- fb: surfaces -------------------------------------------------------------

std::vector<std::unique_ptr<fb::Surface>> g_surf;   // [0] is the screen
std::vector<std::unique_ptr<tp::Font>> g_fonts;
fb::Clip g_clip;

fb::Surface& surf(lua_State* L, int i) {
    const lua_Integer id = luaL_checkinteger(L, i);
    if (id < 0 || id >= static_cast<lua_Integer>(g_surf.size()) || !g_surf[id]) luaL_error(L, "bad surface %d", (int)id);
    return *g_surf[static_cast<size_t>(id)];
}

int newSurface(int w, int h, bool mono) {
    auto s = std::make_unique<fb::Surface>();
    s->w = std::max(w, 0);
    s->h = std::max(h, 0);
    s->mono = mono;
    s->px.assign(static_cast<size_t>(s->w) * s->h, mono ? 0 : 0);
    for (size_t i = 1; i < g_surf.size(); ++i)
        if (!g_surf[i]) { g_surf[i] = std::move(s); return static_cast<int>(i); }
    g_surf.push_back(std::move(s));
    return static_cast<int>(g_surf.size() - 1);
}

int iarg(lua_State* L, int i) { return static_cast<int>(luaL_checkinteger(L, i)); }
fb::Color carg(lua_State* L, int i) { return static_cast<fb::Color>(luaL_optinteger(L, i, 0)) & 0xFFFFFF; }

fb::Brush brushArg(lua_State* L, int i) {
    fb::Brush b;
    if (lua_istable(L, i)) {
        b.pattern = true;
        for (int k = 0; k < 64; ++k) {
            lua_rawgeti(L, i, k + 1);
            b.pat[k] = static_cast<fb::Color>(lua_tointeger(L, -1)) & 0xFFFFFF;
            lua_pop(L, 1);
        }
    } else {
        b.color = carg(L, i);
    }
    return b;
}

// fb.new(w, h [, mono]) -> id
int f_new(lua_State* L) {
    lua_pushinteger(L, newSurface(iarg(L, 1), iarg(L, 2), lua_toboolean(L, 3)));
    return 1;
}
int f_free(lua_State* L) {
    const lua_Integer id = luaL_checkinteger(L, 1);
    if (id > 0 && id < static_cast<lua_Integer>(g_surf.size())) g_surf[static_cast<size_t>(id)].reset();
    return 0;
}
// fb.size(id) -> w, h, mono
int f_size(lua_State* L) {
    auto& s = surf(L, 1);
    lua_pushinteger(L, s.w);
    lua_pushinteger(L, s.h);
    lua_pushboolean(L, s.mono);
    return 3;
}
// fb.resize(id, w, h): keeps the top-left of the old contents
int f_resize(lua_State* L) {
    auto& s = surf(L, 1);
    const int w = iarg(L, 2), h = iarg(L, 3);
    std::vector<fb::Color> px(static_cast<size_t>(w) * h, 0);
    for (int y = 0; y < std::min(h, s.h); ++y)
        for (int x = 0; x < std::min(w, s.w); ++x) px[static_cast<size_t>(y) * w + x] = s.get(x, y);
    s.w = w;
    s.h = h;
    s.px = std::move(px);
    return 0;
}
// fb.clip(nil | {x0, y0, x1, y1, ...})
int f_clip(lua_State* L) {
    g_clip.rects.clear();
    g_clip.all = !lua_istable(L, 1);
    if (!g_clip.all) {
        const lua_Integer n = luaL_len(L, 1);
        for (lua_Integer i = 1; i + 3 <= n; i += 4) {
            fb::Rect r{};
            lua_rawgeti(L, 1, i); r.x0 = static_cast<int>(lua_tointeger(L, -1));
            lua_rawgeti(L, 1, i + 1); r.y0 = static_cast<int>(lua_tointeger(L, -1));
            lua_rawgeti(L, 1, i + 2); r.x1 = static_cast<int>(lua_tointeger(L, -1));
            lua_rawgeti(L, 1, i + 3); r.y1 = static_cast<int>(lua_tointeger(L, -1));
            lua_pop(L, 4);
            if (r.x0 < r.x1 && r.y0 < r.y1) g_clip.rects.push_back(r);
        }
    }
    return 0;
}
// fb.patblt(id, x, y, w, h, rop, brush)
int f_patblt(lua_State* L) {
    fb::patBlt(surf(L, 1), g_clip, iarg(L, 2), iarg(L, 3), iarg(L, 4), iarg(L, 5),
               static_cast<uint8_t>(luaL_checkinteger(L, 6)), brushArg(L, 7));
    return 0;
}
// fb.bitblt(dst, dx, dy, w, h, src, sx, sy, rop, brush, textColor, bkColor)
int f_bitblt(lua_State* L) {
    auto& d = surf(L, 1);
    auto& s = surf(L, 6);
    if (&d == &s) {  // overlapping copy (ScrollWindow): copy the source first
        fb::Surface tmp = s;
        fb::bitBlt(d, g_clip, iarg(L, 2), iarg(L, 3), iarg(L, 4), iarg(L, 5), tmp, iarg(L, 7), iarg(L, 8),
                   static_cast<uint8_t>(luaL_checkinteger(L, 9)), brushArg(L, 10), carg(L, 11), carg(L, 12));
    } else {
        fb::bitBlt(d, g_clip, iarg(L, 2), iarg(L, 3), iarg(L, 4), iarg(L, 5), s, iarg(L, 7), iarg(L, 8),
                   static_cast<uint8_t>(luaL_checkinteger(L, 9)), brushArg(L, 10), carg(L, 11), carg(L, 12));
    }
    return 0;
}
// fb.stretchblt(dst, dx, dy, dw, dh, src, sx, sy, sw, sh, rop, brush, textColor, bkColor)
int f_stretchblt(lua_State* L) {
    auto& d = surf(L, 1);
    fb::Surface s = surf(L, 6);
    fb::stretchBlt(d, g_clip, iarg(L, 2), iarg(L, 3), iarg(L, 4), iarg(L, 5), s, iarg(L, 7), iarg(L, 8), iarg(L, 9),
                   iarg(L, 10), static_cast<uint8_t>(luaL_checkinteger(L, 11)), brushArg(L, 12), carg(L, 13), carg(L, 14));
    return 0;
}
// fb.line(id, x0, y0, x1, y1, rop2, color)
int f_line(lua_State* L) {
    fb::line(surf(L, 1), g_clip, iarg(L, 2), iarg(L, 3), iarg(L, 4), iarg(L, 5), iarg(L, 6), carg(L, 7));
    return 0;
}
// fb.pixel(id, x, y [, color]) -> color (nil when outside)
int f_pixel(lua_State* L) {
    auto& s = surf(L, 1);
    const int x = iarg(L, 2), y = iarg(L, 3);
    if (x < 0 || y < 0 || x >= s.w || y >= s.h) return 0;
    if (!lua_isnoneornil(L, 4)) {
        bool inside = g_clip.all;
        for (const auto& r : g_clip.rects) inside = inside || (x >= r.x0 && x < r.x1 && y >= r.y0 && y < r.y1);
        if (inside) s.at(x, y) = s.mono ? (carg(L, 4) ? 0xFFFFFF : 0) : carg(L, 4);
    }
    lua_pushinteger(L, s.get(x, y));
    return 1;
}
// fb.dib(bytes [, mono]) -> id, w, h: a device-independent bitmap (no file
// header) as a new surface. mono: 1-bit DIBs keep two levels.
int f_dib(lua_State* L) {
    size_t n = 0;
    const char* s = luaL_checklstring(L, 1, &n);
    const bool mono = lua_toboolean(L, 2);
    try {
        const tp::Image img = tp::decodeDib({reinterpret_cast<const uint8_t*>(s), n});
        const int id = newSurface(img.width, img.height, mono);
        auto& d = *g_surf[static_cast<size_t>(id)];
        for (size_t i = 0; i < img.rgba.size(); ++i) {
            const uint32_t p = img.rgba[i];
            fb::Color c = (p & 0xFF) << 16 | (p & 0xFF00) | ((p >> 16) & 0xFF);
            d.px[i] = mono ? (c ? 0xFFFFFF : 0) : c;
        }
        lua_pushinteger(L, id);
        lua_pushinteger(L, img.width);
        lua_pushinteger(L, img.height);
        return 3;
    } catch (const std::exception& ex) {
        lua_pushnil(L);
        lua_pushstring(L, ex.what());
        return 2;
    }
}
// fb.bits(id, bytes, widthBytes): fills a mono surface from 1-bit rows
// (device-dependent, top row first, as CreateBitmap takes them).
int f_bits(lua_State* L) {
    auto& d = surf(L, 1);
    size_t n = 0;
    const auto* b = reinterpret_cast<const uint8_t*>(luaL_checklstring(L, 2, &n));
    const int wb = iarg(L, 3);
    for (int y = 0; y < d.h; ++y)
        for (int x = 0; x < d.w; ++x) {
            const size_t i = static_cast<size_t>(y) * wb + x / 8;
            const bool on = i < n && (b[i] & (0x80 >> (x & 7)));
            d.at(x, y) = on ? 0xFFFFFF : 0;
        }
    return 0;
}
// fb.save_bmp(id, path) -> ok
int f_save_bmp(lua_State* L) {
    auto& s = surf(L, 1);
    const char* path = luaL_checkstring(L, 2);
    SDL_Surface* out = SDL_CreateRGBSurfaceWithFormat(0, s.w, s.h, 32, SDL_PIXELFORMAT_XRGB8888);
    if (!out) { lua_pushboolean(L, 0); return 1; }
    for (int y = 0; y < s.h; ++y)
        std::memcpy(static_cast<uint8_t*>(out->pixels) + static_cast<size_t>(y) * out->pitch, &s.px[static_cast<size_t>(y) * s.w],
                    static_cast<size_t>(s.w) * 4);
    lua_pushboolean(L, SDL_SaveBMP(out, path) == 0);
    SDL_FreeSurface(out);
    return 1;
}
// fb.font(bytes) -> id, metrics
int f_font(lua_State* L) {
    size_t n = 0;
    const char* s = luaL_checklstring(L, 1, &n);
    try {
        auto f = std::make_unique<tp::Font>(tp::parseFnt({reinterpret_cast<const uint8_t*>(s), n}));
        lua_pushinteger(L, static_cast<lua_Integer>(g_fonts.size()));
        lua_newtable(L);
        auto set = [&](const char* k, int v) { lua_pushinteger(L, v); lua_setfield(L, -2, k); };
        lua_pushstring(L, f->face.c_str()); lua_setfield(L, -2, "face");
        set("points", f->points); set("height", f->height); set("ascent", f->ascent);
        set("internal_leading", f->internalLeading); set("external_leading", f->externalLeading);
        set("avg_width", f->avgWidth); set("max_width", f->maxWidth); set("weight", f->weight);
        set("charset", f->charSet); set("pitch_family", f->pitchAndFamily);
        set("first_char", f->firstChar); set("last_char", f->lastChar);
        set("default_char", f->defaultChar); set("break_char", f->breakChar);
        set("italic", f->italic); set("underline", f->underline);
        g_fonts.push_back(std::move(f));
        return 2;
    } catch (const std::exception& ex) {
        lua_pushnil(L);
        lua_pushstring(L, ex.what());
        return 2;
    }
}
const tp::Font& fontArg(lua_State* L, int i) {
    const lua_Integer id = luaL_checkinteger(L, i);
    if (id < 0 || id >= static_cast<lua_Integer>(g_fonts.size())) luaL_error(L, "bad font");
    return *g_fonts[static_cast<size_t>(id)];
}
// fb.text(id, font, x, y, s, fg, bk, opaque, bold, underline) -> width
int f_text(lua_State* L) {
    size_t n = 0;
    const char* s = luaL_checklstring(L, 5, &n);
    lua_pushinteger(L, fb::text(surf(L, 1), g_clip, fontArg(L, 2), iarg(L, 3), iarg(L, 4), std::string(s, n), carg(L, 6),
                                carg(L, 7), lua_toboolean(L, 8), lua_toboolean(L, 9), lua_toboolean(L, 10)));
    return 1;
}
// fb.text_width(font, s, bold) -> width
int f_text_width(lua_State* L) {
    size_t n = 0;
    const char* s = luaL_checklstring(L, 2, &n);
    lua_pushinteger(L, fb::textWidth(fontArg(L, 1), std::string(s, n), lua_toboolean(L, 3)));
    return 1;
}
// fb.char_width(font, byte) -> width
int f_char_width(lua_State* L) {
    lua_pushinteger(L, fontArg(L, 1).glyph(static_cast<unsigned char>(luaL_checkinteger(L, 2))).width);
    return 1;
}

// ---- host: window, input, files --------------------------------------------

SDL_Window* g_win = nullptr;
SDL_Renderer* g_ren = nullptr;
SDL_Texture* g_tex = nullptr;
int g_texW = 0, g_texH = 0;
std::vector<SDL_Cursor*> g_cursors;

// The canvas (the screen surface) is shown at an integer-ish scale with
// letterboxing; mouse positions are mapped back through it.
void canvasRect(SDL_Rect& out) {
    int ww = 0, wh = 0;
    SDL_GetRendererOutputSize(g_ren, &ww, &wh);
    const auto& s = *g_surf[0];
    const double sx = static_cast<double>(ww) / s.w, sy = static_cast<double>(wh) / s.h;
    const double k = std::min(sx, sy);
    out.w = static_cast<int>(s.w * k);
    out.h = static_cast<int>(s.h * k);
    out.x = (ww - out.w) / 2;
    out.y = (wh - out.h) / 2;
}

void toCanvas(int wx, int wy, int& cx, int& cy) {
    if (!g_ren) { cx = wx; cy = wy; return; }
    int ww = 0, wh = 0, lw = 0, lh = 0;
    SDL_GetWindowSize(g_win, &ww, &wh);
    SDL_GetRendererOutputSize(g_ren, &lw, &lh);
    const double px = ww ? static_cast<double>(lw) / ww : 1, py = wh ? static_cast<double>(lh) / wh : 1;
    SDL_Rect r;
    canvasRect(r);
    const auto& s = *g_surf[0];
    cx = r.w ? static_cast<int>((wx * px - r.x) * s.w / r.w) : wx;
    cy = r.h ? static_cast<int>((wy * py - r.y) * s.h / r.h) : wy;
}

// host.window(w, h, title): opens the window with a w x h screen surface.
int h_window(lua_State* L) {
    const int w = iarg(L, 1), h = iarg(L, 2);
    const char* title = luaL_optstring(L, 3, "Program Manager");
    g_surf[0]->w = w;
    g_surf[0]->h = h;
    g_surf[0]->px.assign(static_cast<size_t>(w) * h, 0);
    if (!g_win) {
        const double k = g_cfg->scale > 0 ? g_cfg->scale : 1.0;
        g_win = SDL_CreateWindow(title, SDL_WINDOWPOS_CENTERED, SDL_WINDOWPOS_CENTERED, static_cast<int>(w * k),
                                 static_cast<int>(h * k), SDL_WINDOW_RESIZABLE | SDL_WINDOW_ALLOW_HIGHDPI);
        if (!g_win) return luaL_error(L, "SDL_CreateWindow: %s", SDL_GetError());
        g_ren = SDL_CreateRenderer(g_win, -1, SDL_RENDERER_PRESENTVSYNC);
        if (!g_ren) g_ren = SDL_CreateRenderer(g_win, -1, SDL_RENDERER_SOFTWARE);
        if (!g_ren) return luaL_error(L, "SDL_CreateRenderer: %s", SDL_GetError());
        SDL_SetHint(SDL_HINT_RENDER_SCALE_QUALITY, "nearest");
    }
    return 0;
}
int h_title(lua_State* L) {
    if (g_win) SDL_SetWindowTitle(g_win, luaL_checkstring(L, 1));
    return 0;
}
// host.window_size() -> drawable w, h of the window (the client area)
int h_window_size(lua_State* L) {
    int w = g_surf[0]->w, h = g_surf[0]->h;
    if (g_win) SDL_GetWindowSize(g_win, &w, &h);
    lua_pushinteger(L, w);
    lua_pushinteger(L, h);
    return 2;
}
int h_set_window_size(lua_State* L) {
    if (g_win) SDL_SetWindowSize(g_win, iarg(L, 1), iarg(L, 2));
    return 0;
}
int h_present(lua_State* L) {
    if (!g_ren) return 0;
    auto& s = *g_surf[0];
    if (!g_tex || g_texW != s.w || g_texH != s.h) {
        if (g_tex) SDL_DestroyTexture(g_tex);
        g_tex = SDL_CreateTexture(g_ren, SDL_PIXELFORMAT_XRGB8888, SDL_TEXTUREACCESS_STREAMING, s.w, s.h);
        g_texW = s.w;
        g_texH = s.h;
    }
    SDL_UpdateTexture(g_tex, nullptr, s.px.data(), s.w * 4);
    SDL_SetRenderDrawColor(g_ren, 0, 0, 0, 255);
    SDL_RenderClear(g_ren);
    SDL_Rect r;
    canvasRect(r);
    SDL_RenderCopy(g_ren, g_tex, nullptr, &r);
    SDL_RenderPresent(g_ren);
    (void)L;
    return 0;
}

// SDL keys to Windows virtual-key codes.
int vkOf(SDL_Keycode k) {
    if (k >= SDLK_a && k <= SDLK_z) return 'A' + (k - SDLK_a);
    if (k >= SDLK_0 && k <= SDLK_9) return '0' + (k - SDLK_0);
    if (k >= SDLK_F1 && k <= SDLK_F12) return 0x70 + (k - SDLK_F1);
    switch (k) {
        case SDLK_BACKSPACE: return 0x08; case SDLK_TAB: return 0x09; case SDLK_RETURN: return 0x0D;
        case SDLK_KP_ENTER: return 0x0D; case SDLK_LSHIFT: case SDLK_RSHIFT: return 0x10;
        case SDLK_LCTRL: case SDLK_RCTRL: return 0x11; case SDLK_LALT: case SDLK_RALT: return 0x12;
        case SDLK_PAUSE: return 0x13; case SDLK_CAPSLOCK: return 0x14; case SDLK_ESCAPE: return 0x1B;
        case SDLK_SPACE: return 0x20; case SDLK_PAGEUP: return 0x21; case SDLK_PAGEDOWN: return 0x22;
        case SDLK_END: return 0x23; case SDLK_HOME: return 0x24; case SDLK_LEFT: return 0x25;
        case SDLK_UP: return 0x26; case SDLK_RIGHT: return 0x27; case SDLK_DOWN: return 0x28;
        case SDLK_INSERT: return 0x2D; case SDLK_DELETE: return 0x2E;
        case SDLK_KP_0: return 0x60; case SDLK_KP_1: return 0x61; case SDLK_KP_2: return 0x62;
        case SDLK_KP_3: return 0x63; case SDLK_KP_4: return 0x64; case SDLK_KP_5: return 0x65;
        case SDLK_KP_6: return 0x66; case SDLK_KP_7: return 0x67; case SDLK_KP_8: return 0x68;
        case SDLK_KP_9: return 0x69; case SDLK_KP_MULTIPLY: return 0x6A; case SDLK_KP_PLUS: return 0x6B;
        case SDLK_KP_MINUS: return 0x6D; case SDLK_KP_PERIOD: return 0x6E; case SDLK_KP_DIVIDE: return 0x6F;
        case SDLK_NUMLOCKCLEAR: return 0x90; case SDLK_SCROLLLOCK: return 0x91;
        case SDLK_SEMICOLON: return 0xBA; case SDLK_EQUALS: return 0xBB; case SDLK_COMMA: return 0xBC;
        case SDLK_MINUS: return 0xBD; case SDLK_PERIOD: return 0xBE; case SDLK_SLASH: return 0xBF;
        case SDLK_BACKQUOTE: return 0xC0; case SDLK_LEFTBRACKET: return 0xDB; case SDLK_BACKSLASH: return 0xDC;
        case SDLK_RIGHTBRACKET: return 0xDD; case SDLK_QUOTE: return 0xDE;
        default: return 0;
    }
}

void pushEvent(lua_State* L, int& n, std::initializer_list<lua_Integer> vals, const char* kind, const char* str = nullptr) {
    lua_newtable(L);
    lua_pushstring(L, kind);
    lua_rawseti(L, -2, 1);
    int i = 2;
    for (lua_Integer v : vals) { lua_pushinteger(L, v); lua_rawseti(L, -2, i++); }
    if (str) { lua_pushstring(L, str); lua_rawseti(L, -2, i++); }
    lua_rawseti(L, -2, ++n);
}

// host.pump(timeout_ms) -> list of events, each {kind, ...}:
//   {"down", x, y, button(1 left, 2 right, 3 middle), clicks}, {"up", x, y, button},
//   {"move", x, y}, {"wheel", dy}, {"key", vk, down(1/0), repeat, scancode},
//   {"char", byte}, {"resize", w, h}, {"focus", 1/0}, {"quit"}
int h_pump(lua_State* L) {
    const int timeout = static_cast<int>(luaL_optinteger(L, 1, 0));
    lua_newtable(L);
    int n = 0;
    SDL_Event e;
    bool got = timeout > 0 ? SDL_WaitEventTimeout(&e, timeout) : SDL_PollEvent(&e);
    while (got) {
        int cx = 0, cy = 0;
        switch (e.type) {
            case SDL_QUIT: pushEvent(L, n, {}, "quit"); break;
            case SDL_MOUSEBUTTONDOWN:
            case SDL_MOUSEBUTTONUP: {
                toCanvas(e.button.x, e.button.y, cx, cy);
                const int b = e.button.button == SDL_BUTTON_LEFT ? 1 : e.button.button == SDL_BUTTON_RIGHT ? 2 : 3;
                pushEvent(L, n, {cx, cy, b, e.button.clicks}, e.type == SDL_MOUSEBUTTONDOWN ? "down" : "up");
                break;
            }
            case SDL_MOUSEMOTION:
                toCanvas(e.motion.x, e.motion.y, cx, cy);
                pushEvent(L, n, {cx, cy}, "move");
                break;
            case SDL_MOUSEWHEEL: pushEvent(L, n, {e.wheel.y}, "wheel"); break;
            case SDL_KEYDOWN:
            case SDL_KEYUP: {
                const int vk = vkOf(e.key.keysym.sym);
                if (vk) pushEvent(L, n, {vk, e.type == SDL_KEYDOWN ? 1 : 0, e.key.repeat, e.key.keysym.scancode}, "key");
                break;
            }
            case SDL_TEXTINPUT:
                for (const char* p = e.text.text; *p; ++p) {
                    const unsigned char c = static_cast<unsigned char>(*p);
                    if (c < 0x80) pushEvent(L, n, {c}, "char");
                    else if ((c & 0xE0) == 0xC0 && p[1]) {   // two-byte UTF-8 -> Latin-1 (ANSI)
                        const int cp = ((c & 0x1F) << 6) | (static_cast<unsigned char>(p[1]) & 0x3F);
                        if (cp < 256) pushEvent(L, n, {cp}, "char");
                        ++p;
                    }
                }
                break;
            case SDL_WINDOWEVENT:
                if (e.window.event == SDL_WINDOWEVENT_SIZE_CHANGED) pushEvent(L, n, {e.window.data1, e.window.data2}, "resize");
                else if (e.window.event == SDL_WINDOWEVENT_FOCUS_GAINED) pushEvent(L, n, {1}, "focus");
                else if (e.window.event == SDL_WINDOWEVENT_FOCUS_LOST) pushEvent(L, n, {0}, "focus");
                else if (e.window.event == SDL_WINDOWEVENT_EXPOSED) pushEvent(L, n, {}, "expose");
                break;
            default: break;
        }
        got = SDL_PollEvent(&e);
    }
    return 1;
}

int h_ticks(lua_State* L) { lua_pushinteger(L, static_cast<lua_Integer>(SDL_GetTicks64())); return 1; }
int h_sleep(lua_State* L) { SDL_Delay(static_cast<Uint32>(luaL_checkinteger(L, 1))); return 0; }

// host.cursor("arrow" | "wait" | "ibeam" | "cross" | "sizeall" | "sizens" | "sizewe" | "sizenwse" | "sizenesw" | "no" | "hand" | "hide")
int h_cursor(lua_State* L) {
    static const char* names[] = {"arrow", "ibeam", "wait", "cross", "sizenwse", "sizenesw", "sizewe", "sizens", "sizeall", "no", "hand"};
    static const SDL_SystemCursor ids[] = {SDL_SYSTEM_CURSOR_ARROW, SDL_SYSTEM_CURSOR_IBEAM, SDL_SYSTEM_CURSOR_WAIT,
                                           SDL_SYSTEM_CURSOR_CROSSHAIR, SDL_SYSTEM_CURSOR_SIZENWSE, SDL_SYSTEM_CURSOR_SIZENESW,
                                           SDL_SYSTEM_CURSOR_SIZEWE, SDL_SYSTEM_CURSOR_SIZENS, SDL_SYSTEM_CURSOR_SIZEALL,
                                           SDL_SYSTEM_CURSOR_NO, SDL_SYSTEM_CURSOR_HAND};
    const std::string want = luaL_checkstring(L, 1);
    if (want == "hide") { SDL_ShowCursor(SDL_DISABLE); return 0; }
    SDL_ShowCursor(SDL_ENABLE);
    if (g_cursors.empty())
        for (auto id : ids) g_cursors.push_back(SDL_CreateSystemCursor(id));
    for (size_t i = 0; i < sizeof(names) / sizeof(*names); ++i)
        if (want == names[i] && g_cursors[i]) SDL_SetCursor(g_cursors[i]);
    return 0;
}

int h_capture(lua_State* L) { SDL_CaptureMouse(lua_toboolean(L, 1) ? SDL_TRUE : SDL_FALSE); return 0; }

fs::path u8path(const char* s) {
#if defined(__cpp_char8_t)
    return fs::path(reinterpret_cast<const char8_t*>(s));
#else
    return fs::u8path(s);
#endif
}
std::string u8str(const fs::path& p) {
    const auto s = p.u8string();
    return std::string(s.begin(), s.end());
}

// host.read(path [, expand]) -> bytes | nil, err. expand: undo SZDD/KWAJ.
int h_read(lua_State* L) {
    std::ifstream f(u8path(luaL_checkstring(L, 1)), std::ios::binary);
    if (!f) { lua_pushnil(L); lua_pushliteral(L, "cannot open"); return 2; }
    std::vector<uint8_t> data((std::istreambuf_iterator<char>(f)), std::istreambuf_iterator<char>());
    if (lua_toboolean(L, 2)) {
        try { data = tp::expand(std::move(data)); }
        catch (const std::exception& ex) { lua_pushnil(L); lua_pushstring(L, ex.what()); return 2; }
    }
    lua_pushlstring(L, reinterpret_cast<const char*>(data.data()), data.size());
    return 1;
}
// host.expanded_name(bytes, packedName) -> the name Setup would give it
int h_expanded_name(lua_State* L) {
    size_t n = 0;
    const char* s = luaL_checklstring(L, 1, &n);
    lua_pushstring(L, tp::expandedName({reinterpret_cast<const uint8_t*>(s), n}, luaL_checkstring(L, 2)).c_str());
    return 1;
}
// host.packed(bytes) -> true when SZDD/KWAJ
int h_packed(lua_State* L) {
    size_t n = 0;
    const char* s = luaL_checklstring(L, 1, &n);
    lua_pushboolean(L, tp::packingOf({reinterpret_cast<const uint8_t*>(s), n}) != tp::Packing::None);
    return 1;
}
int h_write(lua_State* L) {
    size_t n = 0;
    const char* s = luaL_checklstring(L, 2, &n);
    std::ofstream f(u8path(luaL_checkstring(L, 1)), std::ios::binary | std::ios::trunc);
    if (f) f.write(s, static_cast<std::streamsize>(n));
    lua_pushboolean(L, static_cast<bool>(f));
    return 1;
}
// host.stat(path) -> nil | {size=, dir=, mtime= (seconds)}
int h_stat(lua_State* L) {
    std::error_code ec;
    const fs::path p = u8path(luaL_checkstring(L, 1));
    const auto st = fs::status(p, ec);
    if (ec || !fs::exists(st)) return 0;
    lua_newtable(L);
    const bool dir = fs::is_directory(st);
    lua_pushboolean(L, dir); lua_setfield(L, -2, "dir");
    lua_pushinteger(L, dir ? 0 : static_cast<lua_Integer>(fs::file_size(p, ec))); lua_setfield(L, -2, "size");
    const auto t = fs::last_write_time(p, ec);
    const auto sys = std::chrono::time_point_cast<std::chrono::system_clock::duration>(
        t - fs::file_time_type::clock::now() + std::chrono::system_clock::now());
    const auto secs = std::chrono::duration_cast<std::chrono::seconds>(sys.time_since_epoch()).count();
    lua_pushinteger(L, static_cast<lua_Integer>(secs)); lua_setfield(L, -2, "mtime");
    return 1;
}
// host.list(dir) -> {{name=, dir=, size=}, ...} | nil
int h_list(lua_State* L) {
    std::error_code ec;
    fs::directory_iterator it(u8path(luaL_checkstring(L, 1)), ec);
    if (ec) return 0;
    lua_newtable(L);
    int i = 0;
    for (const auto& e : it) {
        lua_newtable(L);
        lua_pushstring(L, u8str(e.path().filename()).c_str()); lua_setfield(L, -2, "name");
        const bool dir = e.is_directory(ec);
        lua_pushboolean(L, dir); lua_setfield(L, -2, "dir");
        lua_pushinteger(L, dir ? 0 : static_cast<lua_Integer>(e.file_size(ec))); lua_setfield(L, -2, "size");
        lua_rawseti(L, -2, ++i);
    }
    return 1;
}
int h_mkdir(lua_State* L) {
    std::error_code ec;
    fs::create_directories(u8path(luaL_checkstring(L, 1)), ec);
    lua_pushboolean(L, !ec);
    return 1;
}
int h_remove(lua_State* L) {
    std::error_code ec;
    lua_pushboolean(L, fs::remove(u8path(luaL_checkstring(L, 1)), ec));
    return 1;
}
int h_rename(lua_State* L) {
    std::error_code ec;
    fs::rename(u8path(luaL_checkstring(L, 1)), u8path(luaL_checkstring(L, 2)), ec);
    lua_pushboolean(L, !ec);
    return 1;
}
// host.disk_free(path) -> free bytes, total bytes
int h_disk_free(lua_State* L) {
    std::error_code ec;
    const auto sp = fs::space(u8path(luaL_checkstring(L, 1)), ec);
    lua_pushinteger(L, ec ? 0 : static_cast<lua_Integer>(sp.available));
    lua_pushinteger(L, ec ? 0 : static_cast<lua_Integer>(sp.capacity));
    return 2;
}

// host.launch(file, params, dir, show) -> ok, err
// Windows: ShellExecute (so documents open in their program too).
// Elsewhere: the file run with the parameters split on spaces.
int h_launch(lua_State* L) {
    const char* file = luaL_checkstring(L, 1);
    const char* params = luaL_optstring(L, 2, "");
    const char* dir = luaL_optstring(L, 3, "");
#ifdef _WIN32
    auto wide = [](const char* s) {
        const int n = MultiByteToWideChar(CP_UTF8, 0, s, -1, nullptr, 0);
        std::wstring w(static_cast<size_t>(n > 0 ? n - 1 : 0), L'\0');
        if (n > 1) MultiByteToWideChar(CP_UTF8, 0, s, -1, w.data(), n);
        return w;
    };
    const int show = static_cast<int>(luaL_optinteger(L, 4, SW_SHOWNORMAL));
    const auto r = reinterpret_cast<intptr_t>(ShellExecuteW(nullptr, L"open", wide(file).c_str(),
        *params ? wide(params).c_str() : nullptr, *dir ? wide(dir).c_str() : nullptr, show));
    lua_pushboolean(L, r > 32);
    lua_pushinteger(L, static_cast<lua_Integer>(r));
    return 2;
#else
    if (g_cfg->headless) { lua_pushboolean(L, 1); return 1; }   // tests never start programs
    std::vector<std::string> argv{file};
    std::string cur;
    for (const char* p = params;; ++p) {
        if (*p == ' ' || !*p) { if (!cur.empty()) argv.push_back(cur); cur.clear(); if (!*p) break; }
        else cur.push_back(*p);
    }
    std::vector<char*> av;
    for (auto& a : argv) av.push_back(a.data());
    av.push_back(nullptr);
    std::string cwd = dir;
    pid_t pid = 0;
    posix_spawn_file_actions_t fa;
    posix_spawn_file_actions_init(&fa);
#if defined(__GLIBC__) && (__GLIBC__ > 2 || (__GLIBC__ == 2 && __GLIBC_MINOR__ >= 29))
    if (!cwd.empty()) posix_spawn_file_actions_addchdir_np(&fa, cwd.c_str());
#endif
    const int rc = posix_spawnp(&pid, file, &fa, nullptr, av.data(), environ);
    posix_spawn_file_actions_destroy(&fa);
    lua_pushboolean(L, rc == 0);
    lua_pushinteger(L, rc);
    return 2;
#endif
}
int h_platform(lua_State* L) { lua_pushstring(L, SDL_GetPlatform()); return 1; }
int h_base_path(lua_State* L) {
    char* p = SDL_GetBasePath();
    lua_pushstring(L, p ? p : "./");
    SDL_free(p);
    return 1;
}
int h_pref_path(lua_State* L) {
    char* p = SDL_GetPrefPath("jgordon165", "Progman31lua");
    lua_pushstring(L, p ? p : "./");
    SDL_free(p);
    return 1;
}
int h_message_box(lua_State* L) {
    if (!g_cfg->headless)
        SDL_ShowSimpleMessageBox(SDL_MESSAGEBOX_WARNING, luaL_checkstring(L, 1), luaL_checkstring(L, 2), g_win);
    return 0;
}
int h_log(lua_State* L) {
    std::fprintf(stderr, "%s\n", luaL_checkstring(L, 1));
    std::fflush(stderr);
    return 0;
}
int h_beep(lua_State* L) { (void)L; return 0; }

}  // namespace

void openHostLibs(lua_State* L, HostConfig* cfg) {
    g_cfg = cfg;
    if (g_surf.empty()) g_surf.push_back(std::make_unique<fb::Surface>());

    static const luaL_Reg memf[] = {
        {"rb", m_rb}, {"rw", m_rw}, {"rd", m_rd}, {"wb", m_wb}, {"ww", m_ww}, {"wd", m_wd},
        {"read", m_read}, {"write", m_write}, {"fill", m_fill}, {"move", m_move}, {"cstr", m_cstr},
        {"find", m_find}, {nullptr, nullptr}};
    luaL_newlib(L, memf);
    lua_pushinteger(L, kMemSize);
    lua_setfield(L, -2, "size");
    lua_setglobal(L, "mem");

    static const luaL_Reg fbf[] = {
        {"new", f_new}, {"free", f_free}, {"size", f_size}, {"resize", f_resize}, {"clip", f_clip},
        {"patblt", f_patblt}, {"bitblt", f_bitblt}, {"stretchblt", f_stretchblt}, {"line", f_line},
        {"pixel", f_pixel}, {"dib", f_dib}, {"bits", f_bits}, {"save_bmp", f_save_bmp}, {"font", f_font},
        {"text", f_text}, {"text_width", f_text_width}, {"char_width", f_char_width}, {nullptr, nullptr}};
    luaL_newlib(L, fbf);
    lua_setglobal(L, "fb");

    static const luaL_Reg hostf[] = {
        {"window", h_window}, {"title", h_title}, {"window_size", h_window_size}, {"set_window_size", h_set_window_size},
        {"present", h_present}, {"pump", h_pump}, {"ticks", h_ticks}, {"sleep", h_sleep}, {"cursor", h_cursor},
        {"capture", h_capture}, {"read", h_read}, {"write", h_write}, {"stat", h_stat}, {"list", h_list},
        {"mkdir", h_mkdir}, {"remove", h_remove}, {"rename", h_rename}, {"disk_free", h_disk_free},
        {"expanded_name", h_expanded_name}, {"packed", h_packed}, {"launch", h_launch}, {"platform", h_platform},
        {"base_path", h_base_path}, {"pref_path", h_pref_path}, {"message_box", h_message_box}, {"log", h_log},
        {"beep", h_beep}, {nullptr, nullptr}};
    luaL_newlib(L, hostf);
    lua_newtable(L);
    for (size_t i = 0; i < cfg->args.size(); ++i) {
        lua_pushstring(L, cfg->args[i].c_str());
        lua_rawseti(L, -2, static_cast<lua_Integer>(i + 1));
    }
    lua_setfield(L, -2, "args");
    lua_pushboolean(L, cfg->headless);
    lua_setfield(L, -2, "headless");
    lua_setglobal(L, "host");
}

void closeHost() {
    for (auto* c : g_cursors) if (c) SDL_FreeCursor(c);
    g_cursors.clear();
    if (g_tex) SDL_DestroyTexture(g_tex);
    if (g_ren) SDL_DestroyRenderer(g_ren);
    if (g_win) SDL_DestroyWindow(g_win);
    g_tex = nullptr; g_ren = nullptr; g_win = nullptr;
}

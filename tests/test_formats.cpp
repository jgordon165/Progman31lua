// File-format tests. Without Windows files: synthetic inputs. With
// PROGMAN31LUA_DATA set to a Windows 3.1 folder or setup disk: the real
// PROGMAN.EXE, the startup logo and the System font too.

#include "formats/binreader.h"
#include "formats/dib.h"
#include "formats/expand.h"
#include "formats/fnt.h"
#include "formats/ne.h"

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <string>
#include <vector>

namespace fs = std::filesystem;

static int g_fail = 0;
#define CHECK(c)                                                         \
    do {                                                                 \
        if (!(c)) {                                                      \
            std::fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, #c); \
            ++g_fail;                                                    \
        }                                                                \
    } while (0)

static void put16(std::vector<uint8_t>& v, size_t at, uint16_t x) { v[at] = x & 0xFF; v[at + 1] = x >> 8; }

// A two-character 8x2 font: 'A' (width 3) and 'B' (width 9, two byte columns).
static void testFnt() {
    std::vector<uint8_t> f(118 + 3 * 4 + 16, 0);
    put16(f, 0, 0x200);
    put16(f, 68, 8);        // points
    put16(f, 74, 2);        // ascent
    put16(f, 88, 2);        // height
    f[95] = 'A'; f[96] = 'B'; f[97] = 0;
    const size_t bits = 118 + 3 * 4;
    put16(f, 118, 3); put16(f, 120, static_cast<uint16_t>(bits));
    put16(f, 122, 9); put16(f, 124, static_cast<uint16_t>(bits + 2));
    f[bits] = 0xA0; f[bits + 1] = 0x40;                       // A: rows 101, 010
    f[bits + 2] = 0xFF; f[bits + 3] = 0x00; f[bits + 4] = 0x80; f[bits + 5] = 0x00;  // B: row0 9 on, row1 off
    const tp::Font font = tp::parseFnt(f);
    CHECK(font.height == 2 && font.firstChar == 'A' && font.lastChar == 'B');
    CHECK(font.glyph('A').width == 3);
    CHECK(font.glyph('A').bits[0] == 1 && font.glyph('A').bits[1] == 0 && font.glyph('A').bits[4] == 1);
    CHECK(font.glyph('B').width == 9 && font.glyph('B').bits[8] == 1 && font.glyph('B').bits[9 + 8] == 0);
}

// SZDD: literal bytes only.
static void testSzdd() {
    std::vector<uint8_t> z = {'S', 'Z', 'D', 'D', 0x88, 0xF0, 0x27, 0x33, 'A', 'E', 3, 0, 0, 0, 0xFF, 'a', 'b', 'c'};
    const auto out = tp::expand(z);
    CHECK(out.size() == 3 && out[0] == 'a' && out[2] == 'c');
    CHECK(tp::expandedName(z, "TEST.EX_") == "TEST.EXE");
}

static fs::path findCi(const fs::path& dir, const std::string& name) {
    std::error_code ec;
    for (const auto& e : fs::directory_iterator(dir, ec)) {
        std::string n = e.path().filename().string();
        for (auto& c : n) c = static_cast<char>(std::toupper(static_cast<unsigned char>(c)));
        if (n == name) return e.path();
    }
    return {};
}

static void testData(const fs::path& dir) {
    fs::path p = findCi(dir, "PROGMAN.EXE");
    if (p.empty()) p = findCi(dir, "PROGMAN.EX_");
    CHECK(!p.empty());
    if (!p.empty()) {
        const tp::NeFile ne = tp::NeFile::load(p.string());
        CHECK(ne.moduleName() == "PROGMAN");
        CHECK(ne.find(static_cast<uint16_t>(tp::ResType::Menu), "PROGMAN") || !ne.resources().empty());
    }
    fs::path logo = findCi(dir, "VGALOGO.RLE");
    if (logo.empty()) logo = findCi(dir, "VGALOGO.RL_");
    if (!logo.empty()) {
        const auto bytes = tp::expand(tp::readFile(logo.string()));
        CHECK(bytes.size() > 14 && bytes[0] == 'B' && bytes[1] == 'M');
        const tp::Image img = tp::decodeDib(std::span<const uint8_t>(bytes).subspan(14));
        CHECK(img.width > 100 && img.height > 100);
    }
    fs::path sys = findCi(dir, "VGASYS.FON");
    if (sys.empty()) sys = findCi(dir, "VGASYS.FO_");
    if (!sys.empty()) {
        const tp::NeFile fon(tp::expand(tp::readFile(sys.string())));
        int fonts = 0;
        for (const auto& r : fon.resources())
            if (r.typeId == static_cast<uint16_t>(tp::ResType::Font)) {
                const tp::Font f = tp::parseFnt(fon.read(r));
                CHECK(f.height > 0 && f.face == "System");
                ++fonts;
            }
        CHECK(fonts > 0);
    }
}

int main() {
    try {
        testFnt();
        testSzdd();
        if (const char* d = std::getenv("PROGMAN31LUA_DATA")) testData(d);
    } catch (const std::exception& ex) {
        std::fprintf(stderr, "FAIL: %s\n", ex.what());
        ++g_fail;
    }
    std::printf("%s\n", g_fail ? "FAILED" : "formats: all passed");
    return g_fail ? 1 : 0;
}

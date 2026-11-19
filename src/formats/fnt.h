// Windows 2.x/3.x raster fonts (.FNT), the FONT resources inside a .FON
// file such as Windows 3.1's VGASYS.FON (the System font) and SSERIFE.FON
// (MS Sans Serif). See docs/formats.md.
#pragma once

#include <cstdint>
#include <span>
#include <string>
#include <vector>

namespace tp {

struct Font {
    std::string face;
    int points = 0, height = 0, ascent = 0, internalLeading = 0, externalLeading = 0;
    int avgWidth = 0, maxWidth = 0, weight = 400, charSet = 0, pitchAndFamily = 0;
    bool italic = false, underline = false, strikeOut = false;
    int firstChar = 0, lastChar = 0, defaultChar = 0, breakChar = 0;
    // One glyph per character from firstChar..lastChar: its width and its
    // pixels, row-major, one byte (0/1) per pixel, height rows.
    struct Glyph {
        int width = 0;
        std::vector<uint8_t> bits;
    };
    std::vector<Glyph> glyphs;

    const Glyph& glyph(unsigned char c) const;
};

// Throws FormatError on a corrupt font.
Font parseFnt(std::span<const uint8_t> data);

}  // namespace tp

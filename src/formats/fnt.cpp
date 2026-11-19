#include "formats/fnt.h"

#include "formats/binreader.h"

namespace tp {

const Font::Glyph& Font::glyph(unsigned char c) const {
    int i = c - firstChar;
    if (i < 0 || i >= static_cast<int>(glyphs.size())) i = defaultChar;
    if (i < 0 || i >= static_cast<int>(glyphs.size())) i = 0;
    return glyphs.at(static_cast<size_t>(i));
}

Font parseFnt(std::span<const uint8_t> data) {
    BinReader r(data);
    const uint16_t version = r.u16At(0);
    if (version != 0x200 && version != 0x300) throw FormatError("FNT: unsupported version");
    const uint16_t type = r.u16At(66);
    if (type & 1) throw FormatError("FNT: vector fonts are not supported");
    Font f;
    f.points = r.u16At(68);
    f.ascent = r.u16At(74);
    f.internalLeading = r.u16At(76);
    f.externalLeading = r.u16At(78);
    f.italic = r.u8At(80) != 0;
    f.underline = r.u8At(81) != 0;
    f.strikeOut = r.u8At(82) != 0;
    f.weight = r.u16At(83);
    f.charSet = r.u8At(85);
    const int pixWidth = r.u16At(86);
    f.height = r.u16At(88);
    f.pitchAndFamily = r.u8At(90);
    f.avgWidth = r.u16At(91);
    f.maxWidth = r.u16At(93);
    f.firstChar = r.u8At(95);
    f.lastChar = r.u8At(96);
    f.defaultChar = r.u8At(97);
    f.breakChar = r.u8At(98);
    const uint32_t faceOff = r.u32At(105);
    if (faceOff && faceOff < data.size())
        for (size_t i = faceOff; i < data.size() && data[i]; ++i) f.face.push_back(static_cast<char>(data[i]));
    if (f.lastChar < f.firstChar || f.height <= 0 || f.height > 256) throw FormatError("FNT: bad header");

    const int count = f.lastChar - f.firstChar + 1;
    const size_t table = version == 0x200 ? 118 : 148;
    const size_t entry = version == 0x200 ? 4 : 6;
    f.glyphs.resize(static_cast<size_t>(count));
    for (int i = 0; i < count; ++i) {
        const size_t e = table + static_cast<size_t>(i) * entry;
        int w = r.u16At(e);
        const uint32_t off = version == 0x200 ? r.u16At(e + 2) : r.u32At(e + 2);
        if (w == 0) w = pixWidth;
        if (w > 256) throw FormatError("FNT: glyph too wide");
        auto& g = f.glyphs[static_cast<size_t>(i)];
        g.width = w;
        g.bits.assign(static_cast<size_t>(w) * f.height, 0);
        // Column-major: each 8-pixel-wide column of bytes, top to bottom.
        const int cols = (w + 7) / 8;
        for (int c = 0; c < cols; ++c)
            for (int y = 0; y < f.height; ++y) {
                const uint8_t b = r.u8At(off + static_cast<size_t>(c) * f.height + y);
                for (int k = 0; k < 8; ++k) {
                    const int x = c * 8 + k;
                    if (x < w && (b & (0x80 >> k))) g.bits[static_cast<size_t>(y) * w + x] = 1;
                }
            }
    }
    return f;
}

}  // namespace tp

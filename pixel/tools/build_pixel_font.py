#!/usr/bin/env python3
"""Build PixelTerm-Regular.ttf: VT323 (SIL OFL 1.1) plus pixel-art glyphs it lacks.

VT323 has no triangles or block elements, but the Pixel theme uses them
everywhere (cursor arrows, cyclers, progress blocks). Drawing them on the
font's own 80-unit pixel grid keeps them crisp and matching. Renamed per the
OFL so it can't be confused with the upstream font.

usage: build_pixel_font.py VT323-Regular.ttf PixelTerm-Regular.ttf
"""
import sys
from fontTools.ttLib import TTFont
from fontTools.pens.ttGlyphPen import TTGlyphPen

U = 80  # one "pixel" in font units (VT323 strokes are 80 units wide)

# Each glyph: list of rows, top row first. '#' = pixel on. Bottom row sits at y=base.
GLYPHS = {
    0x25B6: (0, ["#....", "##...", "###..", "####.", "###..", "##...", "#...."]),  # ▶
    0x25C0: (0, ["....#", "...##", "..###", ".####", "..###", "...##", "....#"]),  # ◀
    0x25BC: (1, ["#####", ".###.", "..#.."]),                                     # ▼
    0x25B2: (1, ["..#..", ".###.", "#####"]),                                     # ▲
    0x25B8: (1, [".#...", ".##..", ".###.", ".##..", ".#..."]),                   # ▸
    0x25C2: (1, ["...#.", "..##.", ".###.", "..##.", "...#."]),                   # ◂
    0x25A0: (1, [".###.", ".###.", ".###."]),                                     # ■
    0x25A1: (1, [".###.", ".#.#.", ".###."]),                                     # □
    0x25CF: (1, [".###.", "#####", "#####", ".###."]),                            # ●
    0x25CB: (1, [".###.", "#...#", "#...#", ".###."]),                            # ○
}
# rows above baseline before the glyph starts (vertical placement, in pixels)

def rect(pen, x0, y0, x1, y1):
    # clockwise in y-up space = filled in TrueType
    pen.moveTo((x0, y0)); pen.lineTo((x0, y1)); pen.lineTo((x1, y1)); pen.lineTo((x1, y0)); pen.closePath()

def draw_rows(pen, rows, base):
    n = len(rows)
    for r, row in enumerate(rows):
        y0 = (base + n - 1 - r) * U
        x = 0
        while x < len(row):
            if row[x] == "#":
                s = x
                while x < len(row) and row[x] == "#":
                    x += 1
                rect(pen, s * U, y0, x * U, y0 + U)
            else:
                x += 1

def main(src, dst):
    f = TTFont(src)
    glyf, hmtx = f["glyf"], f["hmtx"]
    order = f.getGlyphOrder()

    def add(name, cp, drawfn):
        pen = TTGlyphPen(None)
        drawfn(pen)
        g = pen.glyph()
        if name not in glyf.glyphs:
            order.append(name)
        glyf[name] = g
        g.recalcBounds(glyf)
        hmtx[name] = (400, g.xMin if hasattr(g, "xMin") else 0)
        for t in f["cmap"].tables:
            if t.isUnicode():
                t.cmap[cp] = name

    for cp, (base, rows) in GLYPHS.items():
        add("px%04X" % cp, cp, lambda pen, rows=rows, base=base: draw_rows(pen, rows, base))

    # Block elements span the full line box (descender to ascender)
    asc, desc = f["hhea"].ascent, f["hhea"].descent
    add("px2588", 0x2588, lambda pen: rect(pen, 0, desc, 400, asc))           # █
    def shade(pen, keep):
        rows = (asc - desc) // U
        for r in range(rows):
            for c in range(5):
                if keep(r, c):
                    rect(pen, c * U, desc + r * U, (c + 1) * U, desc + (r + 1) * U)
    add("px2591", 0x2591, lambda pen: shade(pen, lambda r, c: r % 2 == 0 and c % 2 == 0))  # ░
    add("px2592", 0x2592, lambda pen: shade(pen, lambda r, c: (r + c) % 2 == 0))           # ▒
    add("px2593", 0x2593, lambda pen: shade(pen, lambda r, c: not (r % 2 == 0 and c % 2 == 0)))  # ▓

    f.setGlyphOrder(order)
    f["maxp"].numGlyphs = len(order)
    if "post" in f and hasattr(f["post"], "extraNames"):
        f["post"].formatType = 3.0  # drop glyph names table, avoids post v2 bookkeeping

    for rec in f["name"].names:
        if rec.nameID in (1, 16):
            rec.string = "PixelTerm"
        elif rec.nameID == 4:
            rec.string = "PixelTerm Regular"
        elif rec.nameID == 6:
            rec.string = "PixelTerm-Regular"
        elif rec.nameID == 3:
            rec.string = "PixelTerm-Regular;derived-from-VT323"
    f.save(dst)
    print("wrote", dst, len(order), "glyphs")

if __name__ == "__main__":
    main(*sys.argv[1:3])

#!/usr/bin/env python3
"""Write pixel-art SVG icons over KOReader's stock ones (resources/icons/mdlight).

Each icon is ASCII art on an 8x8-ish grid ('#' = black pixel), drawn as
plain rectangles with crispEdges so it stays sharp at any size on e-ink.
usage: build_pixel_icons.py <koreader repo>/resources/icons/mdlight
"""
import os, sys

ICONS = {
    "chevron.left":  ["....#...", "...##...", "..###...", ".####...", "..###...", "...##...", "....#..."],
    "chevron.right": ["...#....", "...##...", "...###..", "...####.", "...###..", "...##...", "...#...."],
    "chevron.first": ["...#...#", "..##..##", ".###.###", "########", ".###.###", "..##..##", "...#...#"],
    "chevron.last":  ["#...#...", "##..##..", "###.###.", "########", "###.###.", "##..##..", "#...#..."],
    "chevron.up":    ["........", "...#....", "..###...", ".#####..", "#######.", "........"],
    "chevron.down":  ["........", "#######.", ".#####..", "..###...", "...#....", "........"],
    "back.top":      ["..#.....", ".###....", "#####...", "..#.....", "..#.....", "..#####.", "........"],
    "back.top.rtl":  [".....#..", "....###.", "...#####", ".....#..", ".....#..", ".#####..", "........"],
    "close":         ["##....##", ".##..##.", "..####..", "...##...", "..####..", ".##..##.", "##....##"],
    "check":         [".......#", "......##", "#....##.", "##..##..", ".####...", "..##...."],
    "home":          ["...##...", "..####..", ".######.", "########", ".#....#.", ".#.##.#.", ".#.##.#."],
    "plus":          ["...##...", "...##...", "########", "########", "...##...", "...##..."],
    "appbar.menu":   ["########", "........", "########", "........", "########"],
    "appbar.settings": ["..#..#..", ".######.", ".##..##.", "###..###", ".##..##.", ".######.", "..#..#.."],
    "appbar.search": [".####...", "#....#..", "#....#..", "#....#..", ".####...", ".....##.", "......##"],
    "appbar.tools":  ["######..", "######..", "..##....", "..##....", "..##....", "..##....", "..##...."],
    "appbar.filebrowser": ["###.....", "#..####.", "#......#", "#......#", "#......#", "########"],
    "appbar.navigation":  ["##.....##", "#.##.##.#", "#...#...#", "#...#...#", "#...#...#", "###.#.###", "...###..."],
    "appbar.typeset":     ["...##...", "..#..#..", ".#....#.", ".######.", "#......#", "#......#"],
}

def svg(rows):
    h, w = len(rows), max(len(r) for r in rows)
    size = max(w, h) + 2
    ox, oy = (size - w) // 2, (size - h) // 2
    rects = []
    for y, row in enumerate(rows):
        x = 0
        while x < len(row):
            if row[x] == "#":
                s = x
                while x < len(row) and row[x] == "#":
                    x += 1
                rects.append(f"M{s+ox:g} {y+oy:g}h{x-s}v1h-{x-s}z")
            else:
                x += 1
    return (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {size} {size}" '
            f'width="48" height="48" shape-rendering="crispEdges" fill="#000">'
            + '<path d="' + "".join(rects) + '"/></svg>\n')

if __name__ == "__main__":
    out = sys.argv[1]
    for name, rows in ICONS.items():
        with open(os.path.join(out, name + ".svg"), "w") as f:
            f.write(svg(rows))
    print("wrote", len(ICONS), "icons to", out)

--[[--
Drawing helpers for the Pixel theme.

Everything here paints plain rectangles onto a blitbuffer, so it stays crisp
on e-ink (no anti-aliasing, no gradients).
]]

local Blitbuffer = require("ffi/blitbuffer")

local Paint = {}

local function rect(bb, x, y, w, h, color)
    if w <= 0 or h <= 0 then return end
    if Blitbuffer.isColor8(color) then
        bb:paintRect(x, y, w, h, color)
    else
        bb:paintRectRGB32(x, y, w, h, color)
    end
end
Paint.rect = rect

--- Fill a box whose four corners are cut out by n px (a chunky "plus" shape).
function Paint.notchedFill(bb, x, y, w, h, color, n)
    if not n or n <= 0 or w <= 2 * n or h <= 2 * n then
        return rect(bb, x, y, w, h, color)
    end
    rect(bb, x + n, y, w - 2 * n, h, color)
    rect(bb, x, y + n, n, h - 2 * n, color)
    rect(bb, x + w - n, y + n, n, h - 2 * n, color)
end

--- A border b px thick whose corners are notched out: the pixel-art box.
function Paint.notchedBorder(bb, x, y, w, h, b, color, n)
    n = n or b
    if w <= 2 * n or h <= 2 * n then
        return rect(bb, x, y, w, h, color)
    end
    rect(bb, x + n, y, w - 2 * n, b, color)          -- top
    rect(bb, x + n, y + h - b, w - 2 * n, b, color)  -- bottom
    rect(bb, x, y + n, b, h - 2 * n, color)          -- left
    rect(bb, x + w - b, y + n, b, h - 2 * n, color)  -- right
end

--- A dashed horizontal line: `on` px of ink, then `off` px of gap.
function Paint.dashes(bb, x, y, w, h, on, off, color)
    local cx = x
    while cx < x + w do
        rect(bb, cx, y, math.min(on, x + w - cx), h, color)
        cx = cx + on + off
    end
end

--- n square cells in a row; the first `filled` are solid, the rest outlined.
-- Returns the width actually used.
function Paint.blocks(bb, x, y, cell, n, filled, gap, border, color)
    for i = 1, n do
        local cx = x + (i - 1) * (cell + gap)
        if i <= filled then
            rect(bb, cx, y, cell, cell, color)
        else
            rect(bb, cx, y, cell, border, color)
            rect(bb, cx, y + cell - border, cell, border, color)
            rect(bb, cx, y, border, cell, color)
            rect(bb, cx + cell - border, y, border, cell, color)
        end
    end
    return n * cell + (n - 1) * gap
end

--- Draw ASCII pixel art: rows of "#" (on) and "." (off), each cell `cell` px.
function Paint.bitmap(bb, x, y, rows, cell, color)
    for r, row in ipairs(rows) do
        local c = 1
        while c <= #row do
            if row:sub(c, c) == "#" then
                local s = c
                while c <= #row and row:sub(c, c) == "#" do c = c + 1 end
                rect(bb, x + (s - 1) * cell, y + (r - 1) * cell, (c - s) * cell, cell, color)
            else
                c = c + 1
            end
        end
    end
end

-- The ten placeholder cover patterns from the mock-up (CSS gradients there).
-- Each draws into (x, y, w, h); s is one mock-up pixel in device pixels.
local function hstripes(bb, x, y, w, h, s, color, on, period)
    for yy = 0, h - 1, period * s do
        rect(bb, x, y + yy, w, math.min(on * s, h - yy), color)
    end
end
local function vstripes(bb, x, y, w, h, s, color, on, period)
    for xx = 0, w - 1, period * s do
        rect(bb, x + xx, y, math.min(on * s, w - xx), h, color)
    end
end
-- One filled square per tile, at (ox, oy) inside each tile of size t (mock-up px).
local function tiles(bb, x, y, w, h, s, color, t, sq, ox, oy)
    local T, S = t * s, sq * s
    for yy = 0, h - 1, T do
        for xx = 0, w - 1, T do
            local px, py = xx + ox * s, yy + oy * s
            if px < w and py < h then
                rect(bb, x + px, y + py, math.min(S, w - px), math.min(S, h - py), color)
            end
        end
    end
end
local function checker(bb, x, y, w, h, s, color, sq)
    local S = sq * s
    local row = 0
    for yy = 0, h - 1, S do
        local col = row % 2
        for xx = col * S, w - 1, 2 * S do
            rect(bb, x + xx, y + yy, math.min(S, w - xx), math.min(S, h - yy), color)
        end
        row = row + 1
    end
end

Paint.patterns = {
    function(bb, x, y, w, h, s, c) hstripes(bb, x, y, w, h, s, c, 2, 8) end,
    function(bb, x, y, w, h, s, c) tiles(bb, x, y, w, h, s, c, 8, 4, 4, 0) end,
    function(bb, x, y, w, h, s, c) checker(bb, x, y, w, h, s, c, 8) end,
    function(bb, x, y, w, h, s, c) vstripes(bb, x, y, w, h, s, c, 4, 12) end,
    function(bb, x, y, w, h, s, c) tiles(bb, x, y, w, h, s, c, 12, 6, 6, 6) end,
    function(bb, x, y, w, h, s, c) checker(bb, x, y, w, h, s, c, 4) end,
    function(bb, x, y, w, h, s, c)
        hstripes(bb, x, y, w, h, s, c, 2, 10)
        vstripes(bb, x, y, w, h, s, c, 2, 10)
    end,
    function(bb, x, y, w, h, s, c) hstripes(bb, x, y, w, h, s, c, 4, 8) end,
    function(bb, x, y, w, h, s, c) checker(bb, x, y, w, h, s, c, 12) end,
    function(bb, x, y, w, h, s, c) vstripes(bb, x, y, w, h, s, c, 2, 4) end,
}

--- Paint pattern number i (any integer, wraps around).
function Paint.pattern(bb, i, x, y, w, h, s, color)
    local n = #Paint.patterns
    Paint.patterns[((i - 1) % n) + 1](bb, x, y, w, h, s, color)
end

--- A stable small number from a string, to pick a pattern per book.
function Paint.hash(str)
    local h = 5381
    for i = 1, #(str or "") do
        h = (h * 33 + str:byte(i)) % 2147483647
    end
    return h
end

return Paint

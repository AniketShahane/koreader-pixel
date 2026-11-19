--[[--
Default covers for books that arrive without one.

Two designs, picked by where the book came from:

* Saved Page - for things that came from the web: links saved through Drive
               sync (and News downloader EPUBs), and .html / .mht files.
               A drawn browser window with the site in the address bar, the
               title in mono, a few grey "text lines" and the date it was saved.
* Pattern    - for everything else without a cover (TXT, Markdown, DOCX,
               FB2, EPUBs with no cover image...). A bold black-and-white
               pattern, chosen from the title so every book looks different,
               above a white panel with the title.

Books that have a real cover keep it. PDFs, CBZ comics and DjVu always do:
KOReader uses their first page.

Everything is solid black and white (one grey for the text lines), drawn
with plain rectangles so it stays crisp on e-ink. Covers are 3:4.
]]

local Archiver = require("ffi/archiver")
local Blitbuffer = require("ffi/blitbuffer")
local DataStorage = require("datastorage")
local Font = require("ui/font")
local LuaSettings = require("luasettings")
local Paint = require("pixel/paint")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local Theme = require("pixel/theme")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local util = require("util")
local Screen = require("device").screen

local INK = Blitbuffer.COLOR_BLACK
local PAPER = Blitbuffer.COLOR_WHITE
local GREY = Blitbuffer.Color8(0x88)

local SERIF_BOLD = "NotoSerif-Bold.ttf"
local MONO = "pixel/SpaceMono-Regular.ttf"
local MONO_BOLD = "pixel/SpaceMono-Bold.ttf"

local DefaultCover = {
    RATIO = 4 / 3, -- height / width
}

local WEB_EXT = { html = true, htm = true, xhtml = true, xhtm = true, mht = true, mhtml = true }

---------------------------------------------------------------------------
-- Where a book came from
---------------------------------------------------------------------------

-- Links saved by Drive sync: path -> { url = "https://...", saved = os.time() }
local registry
local function links()
    if not registry then
        registry = LuaSettings:open(DataStorage:getSettingsDir() .. "/pixel_saved_links.lua")
    end
    return registry
end

--- Remember that `path` was saved from `url` (called by Drive sync).
-- url may be false: "we looked and there's no URL to find".
function DefaultCover.rememberLink(path, url, saved)
    local reg = links()
    reg:saveSetting(path, { url = url or false, saved = saved or os.time() })
    reg:flush()
end

--- Is `path` in the saved-links list? (Even with an unknown URL.)
function DefaultCover.knownLink(path)
    return links():readSetting(path) ~= nil
end

-- EPUBs built by KOReader's News downloader (which Drive sync also uses)
-- say <dc:publisher>KOReader ...</dc:publisher>. Looked up once per file.
local made_by_koreader = {}
local function madeByKOReader(path)
    local cached = made_by_koreader[path]
    if cached ~= nil then return cached end
    local found = false
    local ok, err = pcall(function()
        local arc = Archiver.Reader:new()
        if not arc:open(path) then return end
        for entry in arc:iterate() do
            if entry.mode == "file" and entry.path:lower():match("%.opf$") then
                local opf = arc:extractToMemory(entry.path)
                found = opf and opf:match("<dc:publisher[^>]*>%s*KOReader") ~= nil or false
                break
            end
        end
        arc:close()
    end)
    if not ok then logger.dbg("Pixel/cover: can't read", path, err) end
    made_by_koreader[path] = found
    return found
end

--- "web" or "doc": which design a cover-less book gets.
function DefaultCover.kind(path)
    if DefaultCover.knownLink(path) then return "web" end
    local ext = (path:match("%.([%w]+)$") or ""):lower()
    if WEB_EXT[ext] then return "web" end
    if ext == "epub" and madeByKOReader(path) then return "web" end
    return "doc"
end

local function siteOf(url)
    if type(url) ~= "string" then return nil end
    local host = url:match("^%a[%w+.-]*://([^/?#:]+)")
    if not host then return nil end
    return (host:lower():gsub("^www%.", ""))
end

-- "A Survival Guide to a PhD | Andrej Karpathy blog" -> "A Survival Guide to a PhD"
local function articleTitle(title)
    for _, sep in ipairs({ " | ", " · ", " — ", " – ", " - " }) do
        local i = title:find(sep, 1, true)
        if i then
            local head, tail = title:sub(1, i - 1), title:sub(i + #sep)
            if #util.trim(head) >= 4 and #tail <= #head then return util.trim(head) end
        end
    end
    return title
end

--- The title to show for `path`: web articles lose a trailing " | Site name".
function DefaultCover.displayTitle(path, title)
    if not title or title == "" then return title end
    if articleTitle(title) == title then return title end -- nothing to cut: skip the lookup
    if DefaultCover.kind(path) == "web" then return articleTitle(title) end
    return title
end

--- Everything the cover shows. title/authors come from the book's metadata.
function DefaultCover.describe(path, title, authors)
    local kind = DefaultCover.kind(path)
    local name = (path:match("([^/]+)$") or "")
    local ext = (name:match("%.([%w]+)$") or ""):upper()
    title = util.trim(title or "")
    if title == "" then title = name:gsub("%.[%w]+$", "") end
    local d = { kind = kind, title = title, ext = ext, path = path }
    local mtime = lfs.attributes(path, "modification")
    if kind == "web" then
        local rec = links():readSetting(path) or {}
        d.title = articleTitle(title)
        d.site = siteOf(rec.url) or "saved link"
        local t = rec.saved or mtime
        d.date = t and Theme.upper(os.date("%b %d, %Y", t)):gsub(" 0(%d),", " %1,") or ""
        d.mtime = mtime
    else
        d.author = authors and util.trim((authors:gsub("\n.*", ""))) or ""
        d.mtime = mtime
    end
    return d
end

---------------------------------------------------------------------------
-- Drawing helpers
---------------------------------------------------------------------------

local function face(file, device_px)
    return Font:getFace(file, math.max(5, device_px) / (Screen:scaleBySize(1000) / 1000))
end

local function rect(bb, x, y, w, h, c)
    x, y, w, h = math.floor(x + 0.5), math.floor(y + 0.5), math.floor(w + 0.5), math.floor(h + 0.5)
    if w > 0 and h > 0 then bb:paintRect(x, y, w, h, c) end
end

-- One horizontal run from x0 to x1 (floats) on row y, clipped to [cx0, cx1).
local function run(bb, y, x0, x1, cx0, cx1)
    x0 = math.max(math.floor(x0 + 0.5), cx0)
    x1 = math.min(math.floor(x1 + 0.5), cx1)
    if x1 > x0 then bb:paintRect(x0, y, x1 - x0, 1, INK) end
end

local function rng(seed)
    seed = seed % 2147483646 + 1
    return function()
        seed = (seed * 16807) % 2147483647
        return (seed - 1) / 2147483646
    end
end

-- Text block: at most `max_h` tall, "…" when it doesn't fit. Returns its height.
local function textBlock(bb, str, fc, x, y, w, max_h)
    local args = { text = str, face = fc, width = w, fgcolor = INK, bgcolor = PAPER, line_height = 0.1 }
    local tb = TextBoxWidget:new(args)
    if tb:getSize().h > max_h then
        tb:free()
        local lh = tb.line_height_px or max_h
        args.height = math.max(lh, math.floor(max_h / lh) * lh)
        args.height_overflow_show_ellipsis = true
        tb = TextBoxWidget:new(args)
    end
    local h = tb:getSize().h
    tb:paintTo(bb, x, y)
    tb:free()
    return h
end

local function line(bb, str, fc, x, y, max_w, align_right)
    local t = TextWidget:new{ text = str, face = fc, fgcolor = INK, max_width = max_w }
    local s = t:getSize()
    t:paintTo(bb, align_right and (x + max_w - s.w) or x, y)
    t:free()
    return s
end

---------------------------------------------------------------------------
-- Pattern
---------------------------------------------------------------------------

-- The four motifs, each filling (0,0)-(W,H) of bb. u = 1% of the cover width.
local motifs = {}

-- Quarter circles, one per cell, in a random corner (a Truchet tiling).
motifs[1] = function(bb, W, H, u, rand)
    local c = W / 8
    for row = 0, math.ceil(H / c) - 1 do
        for col = 0, 7 do
            local x, y = col * c, row * c
            local k = math.floor(rand() * 4)
            local right, bottom = k % 2 == 1, k >= 2
            local cy = bottom and (y + c) or y
            local x0c, x1c = math.floor(x + 0.5), math.floor(x + c + 0.5)
            for py = math.floor(y + 0.5), math.min(math.floor(y + c + 0.5), H) - 1 do
                local dy = py + 0.5 - cy
                if math.abs(dy) <= c then
                    local half = math.sqrt(c * c - dy * dy)
                    if right then run(bb, py, x + c - half, x + c, x0c, x1c)
                    else run(bb, py, x, x + half, x0c, x1c) end
                end
            end
        end
    end
end

-- A grid of circles: filled, rings, halves and dots.
motifs[2] = function(bb, W, H, u, rand)
    local c = W / 7
    local r = c * 0.38
    local stroke = math.max(2, c * 0.13)
    local ri = r - stroke
    for row = 0, math.ceil(H / c) do
        for col = 0, 6 do
            local cx, cy = (col + 0.5) * c, (row + 0.5) * c
            local k = rand()
            local half = math.floor(rand() * 4) -- which half, for half discs
            local rr = k >= 0.9 and math.max(1.5, c * 0.1) or r
            for py = math.floor(cy - rr), math.ceil(cy + rr) do
                if py >= 0 and py < H then
                    local dy = py + 0.5 - cy
                    if math.abs(dy) <= rr then
                        local ho = math.sqrt(rr * rr - dy * dy)
                        if k < 0.4 or k >= 0.9 then
                            run(bb, py, cx - ho, cx + ho, 0, W)
                        elseif k < 0.7 then
                            if math.abs(dy) < ri then
                                local hi = math.sqrt(ri * ri - dy * dy)
                                run(bb, py, cx - ho, cx - hi, 0, W)
                                run(bb, py, cx + hi, cx + ho, 0, W)
                            else
                                run(bb, py, cx - ho, cx + ho, 0, W)
                            end
                        else
                            if half == 0 and dy <= 0 then run(bb, py, cx - ho, cx + ho, 0, W)
                            elseif half == 1 and dy >= 0 then run(bb, py, cx - ho, cx + ho, 0, W)
                            elseif half == 2 then run(bb, py, cx - ho, cx, 0, W)
                            elseif half == 3 then run(bb, py, cx, cx + ho, 0, W) end
                        end
                    end
                end
            end
        end
    end
end

-- Diagonal bands of random widths.
motifs[3] = function(bb, W, H, u, rand, seed)
    local slope = (math.floor(seed / 4) % 2 == 0) and 0.7 or -0.7 -- x shift per row
    local bands = {}
    local x = -H * 0.7 - 10 * u
    while x < W + H * 0.7 do
        local w = (2 + rand() * 9) * u
        table.insert(bands, { x, x + w })
        x = x + w + (1.5 + rand() * 6) * u
    end
    for py = 0, H - 1 do
        local shift = (slope > 0) and (py * slope) or ((py - H) * slope)
        for _, b in ipairs(bands) do run(bb, py, b[1] + shift, b[2] + shift, 0, W) end
    end
end

-- Concentric rings around a bottom corner.
motifs[4] = function(bb, W, H, u, rand, seed)
    local from_left = (math.floor(seed / 8) % 2) == 1
    local rings, r, on = {}, 6 * u, true
    while r < 1.6 * (W + H) do
        local w = (2 + rand() * 6) * u
        if on then table.insert(rings, { r, r + w }) end
        r, on = r + w, not on
    end
    for py = 0, H - 1 do
        local dy = H - (py + 0.5)
        for _, g in ipairs(rings) do
            if dy < g[2] then
                local xo = math.sqrt(g[2] * g[2] - dy * dy)
                local xi = dy < g[1] and math.sqrt(g[1] * g[1] - dy * dy) or 0
                if from_left then run(bb, py, xi, xo, 0, W)
                else run(bb, py, W - xo, W - xi, 0, W) end
            end
        end
    end
end

local function paintPattern(bb, d, W, H)
    local u = W / 100
    local seed = Paint.hash(d.title)
    local PH = math.floor(H * 0.60)
    local motif = seed % #motifs + 1
    motifs[motif](bb, W, PH, u, rng(seed), seed)

    -- White panel with a heavy rule on top
    local rule = math.max(2, math.floor(1.6 * u + 0.5))
    rect(bb, 0, PH, W, rule, INK)
    local pad_x, pad_t, pad_b = 8 * u, 5 * u, 5 * u
    local meta_px = math.max(9, 4 * u)
    local meta_face = face(MONO, meta_px)
    local meta_h = math.ceil(meta_px * 1.5)
    local ty = PH + rule + pad_t
    local title_px = (#d.title > 34 and 6.6 or 8.2) * u
    local avail = H - pad_b - meta_h - 2 * u - ty
    textBlock(bb, d.title, face(SERIF_BOLD, title_px), math.floor(pad_x), math.floor(ty), math.floor(W - 2 * pad_x), math.floor(avail))

    local my = math.floor(H - pad_b - meta_h)
    local left = d.author ~= "" and d.author or ""
    local right = d.ext ~= "" and d.ext or ""
    local mw = math.floor(W - 2 * pad_x)
    local rs = right ~= "" and line(bb, right, meta_face, math.floor(pad_x), my, mw, true) or { w = 0 }
    if left ~= "" then line(bb, left, meta_face, math.floor(pad_x), my, mw - rs.w - math.floor(3 * u)) end
end

---------------------------------------------------------------------------
-- Saved Page
---------------------------------------------------------------------------

local function paintSavedPage(bb, d, W, H)
    local u = W / 100
    local pad = 7 * u
    local foot_px = math.max(9, 3.8 * u)
    local foot_h = math.ceil(foot_px * 1.6)
    local b = math.max(2, math.floor(1.4 * u + 0.5)) -- window border
    local n = math.max(2, math.floor(2 * u + 0.5))   -- notched corners, like the rest of Pixel
    local wx, wy = math.floor(pad), math.floor(pad)
    local ww = math.floor(W - 2 * pad)
    local wh = math.floor(H - 2 * pad - foot_h)
    Paint.notchedBorder(bb, wx, wy, ww, wh, b, INK, n)

    -- Window bar: three square buttons and the address box
    local url_px = math.max(9, 3.8 * u)
    local bar_pad = math.floor(2.6 * u + 0.5)
    local box_h = math.ceil(url_px * 1.7)
    local bar_h = bar_pad * 2 + box_h
    rect(bb, wx, wy + b + bar_h, ww, b, INK)
    local dot = math.max(5, math.floor(3.4 * u + 0.5))
    local dot_b = math.max(1, math.floor(0.7 * u + 0.5))
    local bx = wx + b + bar_pad
    local by = wy + b + bar_pad + math.floor((box_h - dot) / 2)
    for i = 0, 2 do
        local x = bx + i * (dot + math.floor(1.8 * u + 0.5))
        Paint.notchedBorder(bb, x, by, dot, dot, dot_b, INK, 0)
    end
    local ux = bx + 3 * dot + 2 * math.floor(1.8 * u + 0.5) + math.floor(2.4 * u)
    local uw = wx + ww - b - bar_pad - ux
    local uy = wy + b + bar_pad
    Paint.notchedBorder(bb, ux, uy, uw, box_h, dot_b, INK, dot_b)
    local uf = face(MONO, url_px)
    local tw = TextWidget:new{ text = d.site, face = uf, fgcolor = INK, max_width = uw - math.floor(4 * u) }
    tw:paintTo(bb, ux + math.floor(2 * u), uy + math.floor((box_h - tw:getSize().h) / 2))
    tw:free()

    -- Page body: title, then grey lines at the bottom
    local body_x = wx + b + math.floor(6 * u)
    local body_w = ww - 2 * b - math.floor(12 * u)
    local body_y = wy + 2 * b + bar_h + math.floor(6.5 * u)
    local body_bottom = wy + wh - b - math.floor(6 * u)
    local lh = math.max(2, math.floor(2.2 * u + 0.5))
    local lg = math.max(2, math.floor(2.6 * u + 0.5))
    local widths = { 1, 0.92, 1, 0.64 }
    local lines_h = #widths * lh + (#widths - 1) * lg
    local ly = body_bottom - lines_h
    for i, f in ipairs(widths) do
        rect(bb, body_x, ly + (i - 1) * (lh + lg), math.floor(body_w * f), lh, GREY)
    end
    local title_px = (#d.title > 34 and 6.8 or 8.6) * u
    textBlock(bb, d.title, face(MONO_BOLD, title_px), body_x, body_y, body_w, ly - math.floor(5 * u) - body_y)

    -- Under the window
    local ff = face(MONO, foot_px)
    local fy = math.floor(H - pad - foot_h + (foot_h - foot_px * 1.3) / 2)
    local fw = math.floor(W - 2 * pad - 2 * u)
    local rs = line(bb, d.date or "", ff, wx + math.floor(u), fy, fw, true)
    line(bb, "SAVED LINK", ff, wx + math.floor(u), fy, fw - rs.w - math.floor(3 * u))
end

---------------------------------------------------------------------------
-- Rendering, with a small cache (tiles are rebuilt on every page turn)
---------------------------------------------------------------------------

local cache, cache_order, CACHE_MAX = {}, {}, 16

--- Biggest 3:4 size that fits in max_w x max_h.
function DefaultCover.fit(max_w, max_h)
    local w = math.min(max_w, math.floor(max_h / DefaultCover.RATIO))
    return math.max(1, w), math.max(1, math.floor(w * DefaultCover.RATIO))
end

--- A new blitbuffer (the caller owns it) with the default cover for `path`,
-- w x h px. title/authors from the book's metadata (may be nil).
function DefaultCover.render(path, title, authors, w, h)
    local d = DefaultCover.describe(path, title, authors)
    local key = table.concat({ path, w, h, d.kind, d.title, d.site or "", d.date or "", d.author or "" }, "\0")
    local hit = cache[key]
    if hit then return hit:copy() end

    local bb = Blitbuffer.new(w, h, Blitbuffer.TYPE_BB8)
    bb:fill(PAPER)
    local ok, err = pcall(d.kind == "web" and paintSavedPage or paintPattern, bb, d, w, h)
    if not ok then
        logger.warn("Pixel/cover: drawing failed for", path, err)
        bb:fill(PAPER)
    end

    cache[key] = bb:copy()
    table.insert(cache_order, key)
    if #cache_order > CACHE_MAX then
        local old = table.remove(cache_order, 1)
        if cache[old] then cache[old]:free() end
        cache[old] = nil
    end
    return bb
end

return DefaultCover

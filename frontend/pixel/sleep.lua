--[[--
The Pixel sleep screen ("Fade to paper").

The cover of the book you're reading fills the screen as big halftone dots
that shrink and fade into blank paper near the bottom. Below, small:

    CH 01 · LOOMINGS
    MOBY DICK                      38%
    HERMAN MELVILLE
    ███████░░░░░░░░░░░░░░░░░░░░░░
                         PRESS POWER

Shows the book you're reading (or last read). Without a cover, the pixel
whale from the mock-up stands in.
]]

local Blitbuffer = require("ffi/blitbuffer")
local BookList = require("ui/widget/booklist")
local Font = require("ui/font")
local Geom = require("ui/geometry")
local Paint = require("pixel/paint")
local RenderImage = require("ui/renderimage")
local TextWidget = require("ui/widget/textwidget")
local Theme = require("pixel/theme")
local Widget = require("ui/widget/widget")
local logger = require("logger")
local Screen = require("device").screen

local WHALE = {
    "......#.#.......",
    ".......#........",
    "...######.......",
    ".#########.....#",
    "###########...##",
    "#.##########.##.",
    "#############...",
    ".###########....",
}

local DESIGN_W = 450 -- the mock-up's width; everything below is in mock-up px

local SleepScreen = Widget:extend{
    ui = nil,        -- ReaderUI or FileManager
    file = nil,      -- the book (lastfile)
    image = nil,     -- its cover blitbuffer (we own it)
    width = nil, height = nil,
}

function SleepScreen:init()
    self.width = self.width or Screen:getWidth()
    self.height = self.height or Screen:getHeight()
    self.dimen = Geom:new{ x = 0, y = 0, w = self.width, h = self.height }
    self.f = self.width / DESIGN_W
    local ok, err = pcall(self.gather, self)
    if not ok then logger.warn("Pixel sleep screen:", err) end
    local ok2, dots = pcall(self.halftone, self)
    if not ok2 then logger.warn("Pixel sleep screen halftone:", dots) end
    self.dots = ok2 and dots or nil
    if self.image then
        self.image:free()
        self.image = nil
    end
end

-- Title, author, chapter and progress, from the open book or from history.
function SleepScreen:gather()
    local ui, file = self.ui, self.file
    local props, percent, chapter
    if ui and ui.document then
        props = ui.doc_props or {}
        local page = ui:getCurrentPage()
        local total = ui.document:getPageCount()
        percent = total > 0 and page / total or 0
        local Chrome = require("pixel/reader")
        local label = Chrome.chapterLabel(ui, page)
        local title = ui.toc and ui.toc:getTocTitleByPage(page) or ""
        -- "CHAPTER 1. Loomings." -> "LOOMINGS"
        title = title:gsub("^%s*[Cc][Hh][Aa][Pp][Tt][Ee][Rr]%s+[%dIVXLCDM]+[%.:]?%s*", "")
        title = title:gsub("[%.%s]+$", "")
        chapter = label ~= "" and (label .. (title ~= "" and (" · " .. Theme.upper(title)) or "")) or Theme.upper(title)
    elseif file then
        props = ui and ui.bookinfo and ui.bookinfo:getDocProps(file) or {}
        local info = BookList.getBookInfo(file)
        percent = info.percent_finished or 0
        chapter = "LAST READ"
    end
    props = props or {}
    local title = props.display_title or props.title
    if (not title or title == "") and file then
        title = (file:match("([^/]+)$") or ""):gsub("%.[%w]+$", "")
    end
    self.title = Theme.upper(require("pixel/library").shortTitle(title or "KOREADER"))
    local authors = props.authors or ""
    self.authors = Theme.upper((authors:gsub("\n", ", ")))
    self.percent = math.max(0, math.min(1, percent or 0))
    self.chapter = chapter or ""
end

-- Crop the cover to the screen's shape (a little above centre, where
-- titles and subjects usually are), shrink it to one value per dot, and
-- turn each value into a dot radius that also fades toward the bottom.
function SleepScreen:halftone()
    local bb = self.image
    if not bb then return nil end
    local W, H = self.width, self.height
    local iw, ih = bb:getWidth(), bb:getHeight()
    if iw < 8 or ih < 8 then return nil end
    local cell = math.max(6, math.floor(7 * self.f + 0.5))
    local cols, rows = math.ceil(W / cell), math.ceil(H / cell)
    -- cover-fit crop
    local cw, ch = iw, math.floor(iw * H / W + 0.5)
    if ch > ih then ch = ih; cw = math.floor(ih * W / H + 0.5) end
    local cx = math.floor((iw - cw) / 2)
    local cy = math.floor((ih - ch) * 0.4)
    local view = bb:viewport(cx, cy, cw, ch)
    local small = RenderImage:scaleBlitBuffer(view, cols, rows, false)
    local vals, lo, hi = {}, 255, 0
    for y = 0, rows - 1 do
        for x = 0, cols - 1 do
            local v = small:getPixel(x, y):getColor8().a
            vals[y * cols + x] = v
            if v < lo then lo = v end
            if v > hi then hi = v end
        end
    end
    if small ~= view then small:free() end
    local range = math.max(1, hi - lo)
    local radii = {}
    local rmax = cell * 0.72
    for y = 0, rows - 1 do
        for x = 0, cols - 1 do
            local v = (vals[y * cols + x] - lo) / range
            radii[y * cols + x] = (1 - v) ^ 0.9 * rmax
        end
    end
    return { cell = cell, cols = cols, rows = rows, radii = radii }
end

-- A filled disc made of horizontal runs (spans cached per radius).
local spans = {}
local function disc(bb, cx, cy, r, color)
    if r <= 0 then return end
    local s = spans[r]
    if not s then
        s = {}
        for dy = -r, r do s[dy] = math.floor(math.sqrt(r * r - dy * dy) + 0.5) end
        spans[r] = s
    end
    for dy = -r, r do
        local half = s[dy]
        bb:paintRect(cx - half, cy + dy, 2 * half + 1, 1, color)
    end
end

-- A face at a size in device px (not scaled by the interface size dial).
local function face(file, device_px)
    return Font:getFace(file, device_px / (Screen:scaleBySize(1000) / 1000))
end

local function text(str, fc, color, max_width)
    return TextWidget:new{ text = str, face = fc, fgcolor = color or Theme.ink, max_width = max_width }
end

function SleepScreen:paintTo(bb, x, y)
    local W, H, f = self.width, self.height, self.f
    local function P(n) return math.max(1, math.floor(n * f + 0.5)) end
    bb:paintRect(x, y, W, H, Theme.paper)

    -- Lay out the text block bottom-up first, so the dots can fade out above it.
    -- It stays small (the bottom fifth or so): the cover is the picture.
    local side = P(26)
    local inner = W - 2 * side
    local muted = Blitbuffer.Color8(0x55)
    local draw = {}

    local prompt = text("PRESS POWER", face(Theme.fonts.vt, P(15)), muted)
    local ps = prompt:getSize()
    local py = y + H - P(22) - ps.h
    table.insert(draw, { prompt, x + W - side - ps.w, py })

    local bar_h = P(5)
    local bar_y = py - P(6) - bar_h

    local cursor = bar_y - P(8)
    if self.authors and self.authors ~= "" then
        local a = text(self.authors, face(Theme.fonts.mono, P(9)), Theme.ink, inner)
        local as = a:getSize()
        cursor = cursor - as.h
        table.insert(draw, { a, x + side, cursor })
        cursor = cursor - P(4)
    end

    -- Title and percent on one line; long titles shrink, then get cut with "…"
    local pct = text(math.floor(self.percent * 100 + 0.5) .. "%", face(Theme.fonts.vt, P(20)))
    local pcs = pct:getSize()
    local title_w = inner - pcs.w - P(12)
    local size, t = P(40), nil
    for _ = 1, 6 do
        if t then t:free() end
        t = TextWidget:new{ text = self.title or "", face = face(Theme.fonts.vt, size) }
        if t:getSize().w <= title_w or size <= P(26) then break end
        size = math.floor(size * 0.9)
    end
    t:free()
    t = text(self.title or "", face(Theme.fonts.vt, size), Theme.ink, title_w)
    local ts = t:getSize()
    local title_y = cursor - ts.h
    table.insert(draw, { t, x + side - P(1), title_y })
    -- percent shares the title's baseline
    local base = title_y + t:getBaseline()
    table.insert(draw, { pct, x + W - side - pcs.w, base - pct:getBaseline() })
    local top = title_y + math.floor(ts.h * 0.15)
    if self.chapter and self.chapter ~= "" then
        local c = text(self.chapter, face(Theme.fonts.vt, P(15)), muted, inner)
        local cs = c:getSize()
        local cy = top - P(4) - cs.h
        table.insert(draw, { c, x + side, cy })
        top = cy
    end
    top = top - P(10)

    -- The cover as dots, shrinking to nothing just above the text
    local d = self.dots
    if d then
        local c = d.cell
        local fade_end = math.max(c, top - y)
        for r = 0, d.rows - 1 do
            local cyp = r * c + math.floor(c / 2)
            local t = math.min(1, cyp / fade_end)
            local fade = math.min(1, 1.6 * (1 - t) ^ 0.7) -- holds most of the picture, then melts
            if fade > 0 then
                for col = 0, d.cols - 1 do
                    local rad = d.radii[r * d.cols + col] * fade
                    if rad >= 0.6 then
                        disc(bb, x + col * c + math.floor(c / 2), y + cyp, math.floor(rad + 0.5), Theme.ink)
                    end
                end
            end
        end
    else
        local cell = P(14)
        Paint.bitmap(bb, x + math.floor((W - cell * 16) / 2), y + P(90), WHALE, cell, Theme.ink)
    end

    -- Progress bar, then the text
    bb:paintRect(x + side, bar_y, inner, bar_h, Blitbuffer.Color8(0xDD))
    local fill = math.floor(inner * self.percent + 0.5)
    if self.percent > 0 and fill < P(2) then fill = P(2) end
    if fill > 0 then bb:paintRect(x + side, bar_y, fill, bar_h, Theme.ink) end
    for _, it in ipairs(draw) do
        it[1]:paintTo(bb, it[2], it[3])
        it[1]:free()
    end
end

function SleepScreen:onCloseWidget()
    self.dots = nil
end

return SleepScreen

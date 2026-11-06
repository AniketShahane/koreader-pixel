--[[--
The Pixel sleep screen.

    MOBY DICK
    HERMAN MELVILLE
    [the book's cover, turned into chunky 4-grey pixel art]
    - - - - - - - - - - - - -
    CH 01 · LOOMINGS          3%
    ■■□□□□□□□□□□□□□□□□□□
    ▶ PRESS POWER TO CONTINUE

Shows the book you're reading (or last read). If it has no cover, the
pixel whale from the mock-up stands in.
]]

local BookList = require("ui/widget/booklist")
local Geom = require("ui/geometry")
local Paint = require("pixel/paint")
local RenderImage = require("ui/renderimage")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local Theme = require("pixel/theme")
local Widget = require("ui/widget/widget")
local logger = require("logger")
local Screen = require("device").screen

local px = Theme.px

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

local GREYS = { 0x00, 0x55, 0xAA, 0xFF }

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
    local ok, err = pcall(self.gather, self)
    if not ok then logger.warn("Pixel sleep screen:", err) end
    local ok2, art = pcall(self.pixelate, self)
    self.art = ok2 and art or nil
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

-- Downscale the cover to a coarse grid and snap every cell to one of four
-- greys: an 8-bit version of the real cover.
function SleepScreen:pixelate()
    local bb = self.image
    if not bb then return nil end
    local cols = 22
    local w, h = bb:getWidth(), bb:getHeight()
    if w < 8 or h < 8 then return nil end
    local rows = math.max(1, math.floor(cols * h / w + 0.5))
    local small = RenderImage:scaleBlitBuffer(bb, cols, rows, false)
    local vals, lo, hi = {}, 255, 0
    for y = 0, rows - 1 do
        for x = 0, cols - 1 do
            local v = small:getPixel(x, y):getColor8().a
            vals[y * cols + x] = v
            if v < lo then lo = v end
            if v > hi then hi = v end
        end
    end
    if small ~= bb then small:free() end
    -- Stretch the contrast so faded covers still read, then snap to 4 greys.
    local range = math.max(1, hi - lo)
    local grid = {}
    for y = 0, rows - 1 do
        local row = {}
        for x = 0, cols - 1 do
            local v = (vals[y * cols + x] - lo) * 255 / range
            row[x + 1] = GREYS[math.max(1, math.min(4, math.floor(v / 64) + 1))]
        end
        grid[y + 1] = row
    end
    return { cols = cols, rows = rows, grid = grid }
end

local function text(str, face, color, max_width)
    return TextWidget:new{ text = str, face = face, fgcolor = color or Theme.ink, max_width = max_width }
end

function SleepScreen:paintTo(bb, x, y)
    local W, H = self.width, self.height
    bb:paintRect(x, y, W, H, Theme.paper)
    local side = px(40)
    local inner = W - 2 * side

    -- Bottom-up anchors first: prompt, then the progress block above it
    local prompt = text("▶ PRESS POWER TO CONTINUE", Theme.face("vt", 26))
    local ps = prompt:getSize()
    local prompt_y = y + H - px(48) - ps.h
    prompt:paintTo(bb, x + math.floor((W - ps.w) / 2), prompt_y)
    prompt:free()

    local bar_h = px(14)
    local bar_y = prompt_y - px(44) - bar_h
    local row_face = Theme.face("vt", 22)
    local pct = text(math.floor(self.percent * 100 + 0.5) .. "%", row_face)
    local pcs = pct:getSize()
    local chap = text(self.chapter or "", row_face, Theme.ink, inner - pcs.w - px(12))
    local row_y = bar_y - px(6) - pcs.h
    chap:paintTo(bb, x + side, row_y)
    pct:paintTo(bb, x + W - side - pcs.w, row_y)
    chap:free(); pct:free()

    local segs, gap = 20, px(3)
    local seg_w = math.floor((inner - (segs - 1) * gap) / segs)
    local filled = math.floor(self.percent * segs + 0.5)
    if self.percent > 0 and filled == 0 then filled = 1 end
    for i = 1, segs do
        local sx = x + side + (i - 1) * (seg_w + gap)
        if i <= filled then
            bb:paintRect(sx, bar_y, seg_w, bar_h, Theme.ink)
        else
            local b = px(2)
            bb:paintRect(sx, bar_y, seg_w, b, Theme.ink)
            bb:paintRect(sx, bar_y + bar_h - b, seg_w, b, Theme.ink)
            bb:paintRect(sx, bar_y, b, bar_h, Theme.ink)
            bb:paintRect(sx + seg_w - b, bar_y, b, bar_h, Theme.ink)
        end
    end

    local dots_y = row_y - px(20) - px(12)
    Paint.dashes(bb, x + side, dots_y, inner, px(12), px(6), px(6), Theme.soft)

    -- Top-down: title (up to two lines), authors
    local title = TextBoxWidget:new{
        text = self.title or "", face = Theme.face("vt", 60), width = W - 2 * px(24),
        alignment = "center", line_height = -0.1, height = px(60) * 2, height_adjust = true,
        height_overflow_show_ellipsis = true,
    }
    local ty = y + px(40)
    title:paintTo(bb, x + px(24), ty)
    local th = title:getSize().h
    title:free()
    local auth_y = ty + th + px(4)
    local auth_h = 0
    if self.authors and self.authors ~= "" then
        local a = text(self.authors, Theme.face("vt", 20), Theme.muted, inner)
        local as = a:getSize()
        a:paintTo(bb, x + math.floor((W - as.w) / 2), auth_y)
        auth_h = as.h
        a:free()
    end

    -- The art fills what's left between the authors and the dashed line
    local top = auth_y + auth_h + px(18)
    local bottom = dots_y - px(18)
    local avail_h, avail_w = bottom - top, inner
    if self.art then
        local a = self.art
        local cell = math.max(2, math.floor(math.min(avail_w / a.cols, avail_h / a.rows)))
        local aw, ah = cell * a.cols, cell * a.rows
        local ax = x + math.floor((W - aw) / 2)
        local ay = top + math.floor((avail_h - ah) / 2)
        for r = 1, a.rows do
            local row = a.grid[r]
            local c = 1
            while c <= a.cols do
                local v = row[c]
                local s = c
                while c <= a.cols and row[c] == v do c = c + 1 end
                if v ~= 0xFF then
                    bb:paintRect(ax + (s - 1) * cell, ay + (r - 1) * cell, (c - s) * cell, cell, require("ffi/blitbuffer").Color8(v))
                end
            end
        end
        local B = px(4)
        Paint.notchedBorder(bb, ax - B - px(4), ay - B - px(4), aw + 2 * (B + px(4)), ah + 2 * (B + px(4)), B, Theme.ink, B)
    else
        local cell = math.max(2, math.min(px(12), math.floor(math.min(avail_w / 16, avail_h / 8))))
        local aw, ah = cell * 16, cell * 8
        Paint.bitmap(bb, x + math.floor((W - aw) / 2), top + math.floor((avail_h - ah) / 2), WHALE, cell, Theme.ink)
    end
end

function SleepScreen:onCloseWidget()
    self.art = nil
end

return SleepScreen

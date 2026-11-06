--[[--
Pixel reading screen chrome.

* A header in the top page margin: book title on the left, "CH 07" on the
  right, and a thick rule under both.
* A footer in the status-bar slot: "PG 12/612", one square per page of the
  current chapter (filled up to where you are), and minutes left in the
  chapter.

The header is a ReaderView "view module" (painted over the page). The
footer replaces how KOReader's own status bar paints, but keeps the bar
itself, so tapping it and hiding it work as before.
]]

local Geom = require("ui/geometry")
local TextWidget = require("ui/widget/textwidget")
local Theme = require("pixel/theme")
local Widget = require("ui/widget/widget")
local Screen = require("device").screen

local px = Theme.px

local ReaderChrome = {}

--- Space the page needs above the text for the header (device px).
function ReaderChrome.headerSpace() return Theme.px0(44) end
--- Height of the footer strip (device px).
function ReaderChrome.footerHeight() return Theme.px0(34) end

function ReaderChrome.headerEnabled()
    return G_reader_settings:nilOrTrue("pixel_reader_header")
end

local function label(str, face, color)
    return TextWidget:new{ text = str, face = face, fgcolor = color or Theme.ink }
end

--- "Moby Dick; Or, The Whale" -> "MOBY DICK"
function ReaderChrome.bookTitle(ui)
    local props = ui.doc_props or {}
    local title = props.display_title or props.title
    if not title or title == "" then
        title = (ui.document.file or ""):match("([^/]+)$") or ""
        title = title:gsub("%.[%w]+$", "")
    end
    return Theme.upper(require("pixel/library").shortTitle(title))
end

local ROMAN = { I = 1, V = 5, X = 10, L = 50, C = 100, D = 500, M = 1000 }
local function fromRoman(s)
    local n, prev = 0, 0
    for i = #s, 1, -1 do
        local v = ROMAN[s:sub(i, i)]
        if not v then return nil end
        if v < prev then n = n - v else n = n + v; prev = v end
    end
    return n > 0 and n or nil
end

--- "CH 07" for the chapter the page is in, or "" if the book has no TOC.
function ReaderChrome.chapterLabel(ui, page)
    local toc = ui.toc
    if not toc then return "" end
    local title = toc:getTocTitleByPage(page)
    if not title or title == "" then return "" end
    local up = title:upper()
    local num = up:match("CHAPTER%s+([%dIVXLCDM]+)%f[^%w]") or up:match("PART%s+([%dIVXLCDM]+)%f[^%w]")
        or up:match("^%s*([%d]+)[%.%s:]") or up:match("^%s*([IVXLCDM]+)%.")
    local n = num and (tonumber(num) or fromRoman(num))
    if not n then
        n = toc:getTocIndexByPage(page)
    end
    return n and string.format("CH %02d", n) or ""
end

---------------------------------------------------------------------------
-- Header (view module)
---------------------------------------------------------------------------

local Header = Widget:extend{ ui = nil }
ReaderChrome.Header = Header

function Header:init()
    self.dimen = Geom:new{ x = 0, y = 0, w = 0, h = 0 }
end

function Header:paintTo(bb, x, y)
    local ui = self.ui
    if not ui or not ui.document or not ReaderChrome.headerEnabled() then return end
    if not ui.rolling then return end -- PDFs/comics: no margin reserved for it, it would cover the page
    if ui.view and ui.view.view_mode == "scroll" then return end -- no fixed header while scrolling
    local cfg = ui.document.configurable
    if cfg and cfg.t_page_margin and Screen:scaleBySize(cfg.t_page_margin) < ReaderChrome.headerSpace() - px(4) then
        return -- book has a small top margin (opened before the theme): don't cover its text
    end
    local W = Screen:getWidth()
    local pad = px(20)
    local face = Theme.face("vt", 20)
    local page = ui:getCurrentPage()
    local right = ReaderChrome.paused and "PAUSED" or ReaderChrome.chapterLabel(ui, page)
    local r = label(right, face)
    local rs = r:getSize()
    local l = TextWidget:new{
        text = ReaderChrome.bookTitle(ui), face = face, fgcolor = Theme.ink,
        max_width = W - 2 * pad - rs.w - px(12),
    }
    local ty = y + px(7)
    l:paintTo(bb, x + pad, ty)
    r:paintTo(bb, x + W - pad - rs.w, ty)
    local rule_y = ty + math.max(l:getSize().h, rs.h) - px(2)
    bb:paintRect(x + pad, rule_y, W - 2 * pad, px(3), Theme.ink)
    self.dimen = Geom:new{ x = x, y = y, w = W, h = rule_y + px(3) - y }
    l:free(); r:free()
end

---------------------------------------------------------------------------
-- Footer (replaces how ReaderFooter paints)
---------------------------------------------------------------------------

local function footerData(ui)
    local page = ui:getCurrentPage()
    local total = ui.document:getPageCount()
    local toc = ui.toc
    local ch_count, ch_done, ch_left
    if toc then
        ch_count = toc:getChapterPageCount(page)
        ch_done = toc:getChapterPagesDone(page)
        ch_left = toc:getChapterPagesLeft(page)
    end
    if ch_count and ch_count > 0 and not ch_left then
        ch_left = total - page -- last chapter: no next chapter to count to
    end
    if not ch_count or ch_count <= 0 then -- no TOC: treat the book as one chapter
        ch_count, ch_done, ch_left = total, page - 1, total - page
    end
    local avg = ui.statistics and ui.statistics.avg_time
    if not avg or avg <= 0 then avg = 45 end -- until reading stats know better
    avg = math.max(15, math.min(avg, 240))   -- ignore skims and coffee breaks
    local minutes = math.max(1, math.ceil(((ch_left or 0) + 1) * avg / 60))
    return page, total, ch_count, (ch_done or 0) + 1, minutes
end

function ReaderChrome.paintFooter(footer, bb, x, y)
    local ui = footer.ui
    local W, H = Screen:getWidth(), ReaderChrome.footerHeight()
    local y0 = Screen:getHeight() - H
    if footer.footer_content then -- the footer refreshes only this area
        footer.footer_content.dimen = Geom:new{ x = x, y = y0, w = W, h = H }
    end
    bb:paintRect(x, y0, W, H, Theme.paper)
    local ok, page, total, ch_count, ch_at, minutes = pcall(footerData, ui)
    if not ok then return end
    local pad = px(20)
    local face = Theme.face("vt", 20)
    local left = label(string.format("PG %d/%d", page, total), face)
    local right = label(string.format("%d MIN", minutes), face)
    local ls, rs = left:getSize(), right:getSize()
    local ty = y0 + math.floor((H - ls.h) / 2) - px(1)
    left:paintTo(bb, x + pad, ty)
    right:paintTo(bb, x + W - pad - rs.w, ty)

    -- One square per chapter page (at most 24; larger chapters are scaled down)
    local n = math.min(ch_count, 24)
    local filled = math.max(1, math.min(n, math.ceil(ch_at / ch_count * n)))
    local cell, gap = px(10), px(2)
    local avail = W - 2 * pad - ls.w - rs.w - px(24)
    while n * cell + (n - 1) * gap > avail and cell > px(5) do
        cell = cell - 1
    end
    local bw = n * cell + (n - 1) * gap
    local bx = x + pad + ls.w + math.floor((avail + px(24) - bw) / 2)
    local by = ty + left:getBaseline() - cell
    require("pixel/paint").blocks(bb, bx, by, cell, n, filled, gap, px(2), Theme.ink)
    left:free(); right:free()
end

--- Make a ReaderFooter instance paint the Pixel way and reserve our height.
function ReaderChrome.installFooter(footer)
    local orig_getHeight = footer.getHeight
    footer.getHeight = function(self)
        if self.mode == self.mode_list.off then return orig_getHeight(self) end
        return ReaderChrome.footerHeight()
    end
    footer.paintTo = function(self, bb, x, y)
        ReaderChrome.paintFooter(self, bb, x, y)
    end
    -- Our footer has no modes to cycle, so a tap on it opens OPTIONS
    -- (the strip above it alone is too thin to hit reliably).
    local orig_tap = footer.TapFooter
    footer.TapFooter = function(self, ges)
        if G_reader_settings:nilOrTrue("pixel_options_menu") and self.ui.rolling and self.ui.config then
            self.ui.config:onShowConfigMenu()
            return true
        end
        return orig_tap(self, ges)
    end
end

return ReaderChrome

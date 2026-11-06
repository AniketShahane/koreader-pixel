--[[--
The Pixel library: a wall of book covers.

Three parts, all drawn by hand so they match the mock-up exactly:

* Header  - "▶ LIBRARY", a book count, and ALL / READING / DONE / NEW tabs.
            Replaces the file manager's title bar (same methods, so the
            file manager doesn't notice).
* NavBar  - the black bar at the bottom: BOOKS / RECENT / FIND / SYNC / OPTIONS.
* Hero    - NOW READING: the book you're on, big, with chapter, minutes
            left and progress. The other books go 4 across under it.
* Tile    - one book: its whole cover in a notched pixel frame, the title
            under it (two lines), and a block progress bar. Books without a
            cover get one of the mock-up's ten pixel patterns.

Tiles are built by updateMosaicItem(), which the CoverBrowser plugin's
mosaic view calls instead of its own tile code when the theme is on. Cover
images still come from CoverBrowser's cache (BookInfoManager), so the real
cover of every EPUB/PDF shows up.
]]

local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InputContainer = require("ui/widget/container/inputcontainer")
local Paint = require("pixel/paint")
local RenderImage = require("ui/renderimage")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local Theme = require("pixel/theme")
local UIManager = require("ui/uimanager")
local Widget = require("ui/widget/widget")
local lfs = require("libs/libkoreader-lfs")
local util = require("util")
local Screen = Device.screen

local px = Theme.px

local Library = {}

local function inside(pos, r)
    return r and pos.x >= r.x and pos.x < r.x + r.w and pos.y >= r.y and pos.y < r.y + r.h
end

local function text(str, face, color, max_width)
    return TextWidget:new{ text = str, face = face, fgcolor = color or Theme.ink, max_width = max_width }
end

-- Make long titles readable on a tile: "Moby Dick; Or, The Whale" -> "Moby Dick".
function Library.shortTitle(title)
    if not title or title == "" then return "" end
    local head = title:match("^(.-)%s*[;:/]")
    if not head then
        for _, dash in ipairs({ " - ", " – ", " — " }) do
            local i = title:find(dash, 1, true)
            if i then head = title:sub(1, i - 1) break end
        end
    end
    if head and #head >= 4 then title = head end
    return util.trim(title)
end

-- With a status tab on (READING / DONE / NEW), show books only: a folder
-- tile reading "0 ITEMS" under DONE just looks broken.
do
    local FileChooser = require("ui/widget/filechooser")
    local orig_gen = FileChooser.genItemTableFromPath
    function FileChooser:genItemTableFromPath(path)
        local items, readable = orig_gen(self, path)
        -- Books only: folders are hidden (Settings > Pixel theme > Show folders in library
        -- brings them back), and always while a READING/DONE/NEW tab is active.
        local hide = FileChooser.show_filter.status or not G_reader_settings:isTrue("pixel_show_folders")
        if Theme.active and self.name == "filemanager" and type(items) == "table" then
            -- The NOW READING book is shown big above the grid, so not in it too.
            local hero = Library.heroFile(self)
            self.pixel_hero_excluded = nil
            local kept = {}
            for _, item in ipairs(items) do
                if hero and item.path == hero then
                    self.pixel_hero_excluded = true
                elseif not hide or item.is_file or item.is_go_up then
                    table.insert(kept, item)
                end
            end
            return kept, readable
        end
        return items, readable
    end
end

---------------------------------------------------------------------------
-- Header
---------------------------------------------------------------------------

local TABS = {
    { id = "all",     label = "ALL",     status = nil },
    { id = "reading", label = "READING", status = { reading = true, abandoned = true } },
    { id = "done",    label = "DONE",    status = { complete = true } },
    { id = "new",     label = "NEW",     status = { new = true } },
}

local function currentTab()
    local FileChooser = require("ui/widget/filechooser")
    local s = FileChooser.show_filter.status
    if not s then return "all" end
    for _, tab in ipairs(TABS) do
        if tab.status and util.tableEquals(tab.status, s) then return tab.id end
    end
    return "all"
end

local Header = InputContainer:extend{
    fm = nil,          -- the FileManager
    show_parent = nil,
    title = "",
    subtitle = "",
    right_icon = "plus",
}
Library.Header = Header

function Header:init()
    self.width = self.width or Screen:getWidth()
    self.height = px(78)
    self.dimen = Geom:new{ x = 0, y = 0, w = self.width, h = self.height }
    self.title_face = Theme.face("vt", 32)
    self.count_face = Theme.face("vt", 19)
    self.tab_face = Theme.face("vt", 17)
    -- The file manager anchors its folder menu under this.
    self.left_button = { image = { dimen = Geom:new{ x = 0, y = 0, w = px(140), h = px(44) } } }
    self.ges_events = {
        TapHeader = { GestureRange:new{ ges = "tap", range = function() return self.dimen end } },
        HoldHeader = { GestureRange:new{ ges = "hold", range = function() return self.dimen end } },
    }
end

-- TitleBar-compatible API used by FileManager / Menu
function Header:getHeight() return self.height end
function Header:getSize() return Geom:new{ w = self.width, h = self.height } end
function Header:generateVerticalLayout() return {} end
function Header:setLeftIcon() end
function Header:setTitle(title, no_refresh) self.title = title; self:_dirty(no_refresh) end
function Header:setSubTitle(subtitle, no_refresh) self.subtitle = subtitle; self:_dirty(no_refresh) end
function Header:setRightIcon(icon) self.right_icon = icon; self:_dirty() end

function Header:_dirty(no_refresh)
    if not no_refresh and self.dimen.y and self.show_parent then
        UIManager:setDirty(self.show_parent, "ui", self.dimen)
    end
end

function Header:_folderName()
    local fc = self.fm and self.fm.file_chooser
    local path = fc and fc.path
    local home = require("apps/filemanager/filemanagerutil").getHomeFolder()
    if not path or path == home or path == home .. "/" then return "LIBRARY" end
    local name = path:gsub("/$", ""):match("([^/]+)$") or path
    return Theme.upper(name)
end

function Header:_bookCount()
    local fc = self.fm and self.fm.file_chooser
    local n = 0
    for _, item in ipairs(fc and fc.item_table or {}) do
        if item.is_file then n = n + 1 end
    end
    if fc and fc.pixel_hero_excluded then n = n + 1 end -- the NOW READING book
    return n
end

function Header:paintTo(bb, x, y)
    self.dimen.x, self.dimen.y = x, y
    local pad = px(16)

    -- Row 1: "▶ LIBRARY" and the count, sharing a baseline
    local title = text("▶ " .. self:_folderName(), self.title_face, Theme.ink, self.width - px(150))
    local label
    if self.right_icon == "check" then
        label = "▶ SELECTING"
    else
        local n = self:_bookCount()
        label = n == 1 and "1 BOOK" or (n .. " BOOKS")
    end
    local count = text(label, self.count_face, Theme.muted)
    local ts, cs = title:getSize(), count:getSize()
    local row1_y = y + px(8)
    title:paintTo(bb, x + pad, row1_y)
    local cx = x + self.width - pad - cs.w
    local cy = row1_y + title:getBaseline() - count:getBaseline()
    count:paintTo(bb, cx, cy)
    self.title_rect = Geom:new{ x = x, y = y, w = pad + ts.w + px(8), h = px(46) }
    self.count_rect = Geom:new{ x = cx - px(8), y = y, w = cs.w + pad + px(8), h = px(46) }
    title:free(); count:free()

    -- Row 2: tabs. The active one is white text in a notched black box.
    local active = currentTab()
    local tx, ty = x + px(20), y + px(52)
    local tab_h = px(20)
    self.tab_rects = {}
    for _, tab in ipairs(TABS) do
        local is_active = tab.id == active
        local t = text(tab.label, self.tab_face, is_active and Theme.paper or Theme.ink)
        local s = t:getSize()
        local padx = is_active and px(8) or px(6)
        local w = s.w + 2 * padx
        if is_active then
            Paint.notchedFill(bb, tx, ty, w, tab_h, Theme.ink, px(3))
        end
        t:paintTo(bb, tx + padx, ty + math.floor((tab_h - s.h) / 2))
        table.insert(self.tab_rects, { tab = tab, rect = Geom:new{ x = tx, y = ty - px(6), w = w, h = tab_h + px(12) } })
        t:free()
        tx = tx + w + px(12) - (is_active and 0 or px(2))
    end
end

function Header:onTapHeader(_, ges)
    local pos = ges.pos
    if inside(pos, self.title_rect) then
        self.fm:onHome()
        return true
    end
    if inside(pos, self.count_rect) then
        self.fm:onShowPlusMenu()
        return true
    end
    for _, t in ipairs(self.tab_rects or {}) do
        if inside(pos, t.rect) then
            local FileChooser = require("ui/widget/filechooser")
            FileChooser.show_filter.status = t.tab.status and util.tableDeepCopy(t.tab.status) or nil
            self.fm.file_chooser:refreshPath()
            UIManager:setDirty(self.show_parent, "ui", self.dimen)
            return true
        end
    end
    return false -- let the top-of-screen tap open the main menu
end

function Header:onHoldHeader(_, ges)
    if inside(ges.pos, self.title_rect) then
        self.fm:onShowFolderMenu()
        return true
    end
    return false
end

---------------------------------------------------------------------------
-- Bottom navigation bar
---------------------------------------------------------------------------

local NavBar = InputContainer:extend{
    fm = nil,
    active = "books",
}
Library.NavBar = NavBar

function NavBar:init()
    self.width = Screen:getWidth()
    self.height = px(30)
    self.dimen = Geom:new{ x = 0, y = 0, w = self.width, h = self.height }
    self.face = Theme.face("vt", 18)
    local fm = self.fm
    self.items = {
        { id = "books",   label = "BOOKS",   cb = function() fm:onHome() end },
        { id = "recent",  label = "RECENT",  cb = function() fm.history:onShowHist() end },
        { id = "find",    label = "FIND",    cb = function() fm.filesearcher:onShowFileSearch() end },
        { id = "sync",    label = "SYNC",    cb = function() require("pixel/drive").syncInteractive(fm) end },
        { id = "options", label = "OPTIONS", cb = function() fm.menu:onShowMenu() end },
    }
    self.ges_events = {
        TapNav = { GestureRange:new{ ges = "tap", range = function() return self.dimen end } },
    }
end

function NavBar:getSize() return Geom:new{ w = self.width, h = self.height } end

function NavBar:paintTo(bb, x, y)
    self.dimen.x, self.dimen.y = x, y
    bb:paintRect(x, y, self.width, self.height, Theme.ink)
    local slice = self.width / #self.items
    for i, item in ipairs(self.items) do
        local is_active = item.id == self.active
        local t = text((is_active and "▶" or "") .. item.label, self.face, is_active and Theme.paper or Theme.soft)
        local s = t:getSize()
        local cx = x + math.floor((i - 0.5) * slice - s.w / 2)
        t:paintTo(bb, cx, y + math.floor((self.height - s.h) / 2))
        t:free()
    end
end

function NavBar:onTapNav(_, ges)
    local i = math.floor((ges.pos.x - self.dimen.x) / (self.width / #self.items)) + 1
    local item = self.items[math.max(1, math.min(#self.items, i))]
    if item then item.cb() end
    return true
end

---------------------------------------------------------------------------
-- Tile
---------------------------------------------------------------------------

local FOLDER = {
    ".####.......",
    "#....######.",
    "#..........#",
    "#..........#",
    "#..........#",
    "#..........#",
    "############",
}

local Tile = Widget:extend{
    width = nil, height = nil,
    title = "",          -- shown in the strip
    ext = nil,           -- ".epub"
    status = nil,        -- "new" | "reading" | "complete" | "abandoned"
    percent = nil,       -- 0..1
    cover_bb = nil,      -- owned: freed with the tile
    is_dir = false,
    dir_label = nil,     -- "12 ITEMS"
    is_current = false,  -- the book you're reading now
    loading = false,
    dim = false,
}
Library.Tile = Tile

-- Layout shared by Tile and the cover size we ask CoverBrowser to cache.
-- The whole cover shows (shrunk to fit, never cropped), sitting on the
-- bottom of its box so covers line up; the title goes under it, then progress.
function Library.tileLayout(w, h)
    local L = {}
    L.border = px(4)
    L.gap = px(4)
    L.title_face = Theme.face("vt", 14)
    L.title_h = px(30)  -- about two lines; the real height comes from the font
    L.prog_h = px(16)
    L.box_h = h - L.gap - L.title_h - L.prog_h
    L.cover_w = w - 2 * L.border   -- the biggest the cover can be
    L.cover_h = L.box_h - 2 * L.border
    return L
end

-- The NOW READING cover, in mock-up px.
local HERO_COVER_W, HERO_COVER_H = 120, 168

--- How big a thumbnail CoverBrowser should cache: sharp on a tile, and on
-- the NOW READING card once that book is the one you're reading.
function Library.coverSpecs(w, h)
    local L = Library.tileLayout(w, h)
    return {
        max_cover_w = math.max(math.floor(L.cover_w * 1.5), px(HERO_COVER_W + 10)),
        max_cover_h = math.max(math.floor(L.cover_h * 1.5), px(HERO_COVER_H + 10)),
    }
end

--- Scale a cover to fit inside max_w x max_h, keeping its shape. Frees the
-- original if a new buffer was made.
local function fitCover(bb, max_w, max_h)
    local sw, sh = bb:getWidth(), bb:getHeight()
    local scale = math.min(max_w / sw, max_h / sh)
    local tw = math.max(1, math.floor(sw * scale))
    local th = math.max(1, math.floor(sh * scale))
    if tw == sw and th == sh then return bb end
    local scaled = RenderImage:scaleBlitBuffer(bb, tw, th, false)
    if scaled ~= bb then bb:free() end
    return scaled
end

--- Text in at most max_lines lines, "…" when it doesn't fit.
local function textLines(str, face, width, max_lines, fg, bg)
    local args = {
        text = str, face = face, width = width, line_height = 0,
        fgcolor = fg or Theme.ink, bgcolor = bg or Theme.paper,
    }
    local tb = TextBoxWidget:new(args)
    local lh = tb.line_height_px
    if lh and tb:getSize().h > max_lines * lh + 1 then
        tb:free()
        args.height = max_lines * lh
        args.height_overflow_show_ellipsis = true
        tb = TextBoxWidget:new(args)
    end
    return tb
end

function Tile:init()
    self.dimen = Geom:new{ x = 0, y = 0, w = self.width, h = self.height }
    self.L = Library.tileLayout(self.width, self.height)
    local L = self.L
    if self.cover_bb then
        self.cover_bb = fitCover(self.cover_bb, L.cover_w, L.cover_h)
        self.art_w, self.art_h = self.cover_bb:getWidth(), self.cover_bb:getHeight()
    else -- pattern or folder: a 2:3 card
        self.art_w = math.min(L.cover_w, math.floor(L.cover_h * 2 / 3))
        self.art_h = math.min(L.cover_h, math.floor(self.art_w * 3 / 2))
    end
    self.pattern_i = Paint.hash(self.title or "") % #Paint.patterns + 1
end

function Tile:getSize() return Geom:new{ w = self.width, h = self.height } end

function Tile:free()
    if self.cover_bb then
        self.cover_bb:free()
        self.cover_bb = nil
    end
end

function Tile:_progressLabel()
    if self.is_dir then return self.dir_label or "" end
    if self.loading then return "…" end
    if self.status == "complete" then return "CLEAR" end
    if self.status == "abandoned" then return "HOLD" end
    if self.status == "new" or not self.percent then return "NEW" end
    local pct = math.floor(self.percent * 100 + 0.5)
    if pct == 0 and self.percent > 0 then pct = 1 end -- started counts as 1%
    return pct .. "%"
end

function Tile:paintTo(bb, x, y)
    self.dimen.x, self.dimen.y = x, y
    local L = self.L
    local B = L.border
    local fw, fh = self.art_w + 2 * B, self.art_h + 2 * B
    local fx = x + math.floor((self.width - fw) / 2)
    local fy = y + L.box_h - fh
    local cx, cy = fx + B, fy + B

    -- The whole cover, or a pixel pattern
    if self.cover_bb then
        bb:blitFrom(self.cover_bb, cx, cy, 0, 0, self.art_w, self.art_h)
    else
        bb:paintRect(cx, cy, self.art_w, self.art_h, Theme.paper)
        Paint.pattern(bb, self.pattern_i, cx, cy, self.art_w, self.art_h, px(1), Theme.pattern)
        if self.is_dir then
            local cell = px(4)
            local bw, bh = #FOLDER[1] * cell, #FOLDER * cell
            local bx = cx + math.floor((self.art_w - bw) / 2)
            local by = cy + math.floor((self.art_h - bh) / 2)
            Paint.notchedFill(bb, bx - px(6), by - px(6), bw + px(12), bh + px(12), Theme.paper, px(3))
            Paint.bitmap(bb, bx, by, FOLDER, cell, Theme.ink)
        end
    end

    -- File-type tag: off (kept for anyone who wants it back: set show_ext)
    if self.ext and self.show_ext then
        local tag = text(self.ext, Theme.face("vt", 14), Theme.paper)
        local s = tag:getSize()
        local tx, ty, th = cx + px(4), cy + px(4), px(15)
        bb:paintRect(tx, ty, s.w + 2 * px(4), th, Theme.ink)
        tag:paintTo(bb, tx + px(4), ty + math.floor((th - s.h) / 2))
        tag:free()
    end

    Paint.notchedBorder(bb, fx, fy, fw, fh, B, Theme.ink, B)

    -- Title under the cover, up to two lines (white on black for the book you're reading)
    local ty = y + L.box_h + L.gap
    local pad = self.is_current and px(3) or 0
    local fg, bg = Theme.ink, Theme.paper
    if self.is_current then fg, bg = Theme.paper, Theme.ink end
    local t = textLines(Theme.upper(self.title or ""), L.title_face, fw - 2 * pad, 2, fg, bg)
    local t_h = math.min(t:getSize().h, L.title_h)
    if self.is_current then bb:paintRect(fx, ty, fw, t_h, Theme.ink) end
    t:paintTo(bb, fx + pad, ty)
    t:free()

    -- Progress blocks and a label, as wide as the cover
    local uy = y + L.box_h + L.gap + L.title_h
    local label = text(self:_progressLabel(), Theme.face("vt", 14), Theme.ink)
    local ls = label:getSize()
    local cell = px(6)
    if not self.is_dir then
        local filled = 0
        if self.status == "complete" then filled = 5
        elseif self.percent then
            filled = math.floor(self.percent * 5 + 0.5)
            if filled == 0 and self.percent > 0 then filled = 1 end -- started = one block
        end
        local by = uy + label:getBaseline() - cell - px(0.5)
        for i = 1, 5 do
            local color = i <= filled and Theme.ink or Blitbuffer.Color8(0xC8)
            bb:paintRect(fx + (i - 1) * (cell + px(2)), by, cell, cell, color)
        end
    end
    label:paintTo(bb, fx + fw - ls.w, uy)
    label:free()

    if self.dim then
        bb:lightenRect(x, y, self.width, self.height, 0.6)
    end
end

---------------------------------------------------------------------------
-- NOW READING: the book you're on, big, above the other books
---------------------------------------------------------------------------

--- The book to feature above the grid, or nil.
function Library.heroFile(fc)
    if not Theme.active or not fc or fc.name ~= "filemanager" or fc.display_mode_type ~= "mosaic" then return end
    if not G_reader_settings:nilOrTrue("pixel_now_reading") then return end
    if Screen:getWidth() > Screen:getHeight() then return end -- portrait only
    local file = G_reader_settings:readSetting("lastfile")
    if not file or lfs.attributes(file, "mode") ~= "file" then return end
    if require("ui/widget/booklist").getBookStatus(file) == "complete" then return end
    return file
end

--- Height of the card, including the "▶ SHELF" line under it. extra: more
-- room for the cover, when the row of books below doesn't need it.
function Library.heroHeight(extra)
    return px(HERO_COVER_H) + (extra or 0) + 2 * px(4) + px(12) + px(16)
end

--- The tile height a w-wide tile really uses (a typical 2:3 cover, up to a
-- little taller), so spare room can go to the NOW READING cover instead.
function Library.tileIdealHeight(w)
    local L = Library.tileLayout(w, 0)
    return math.floor(L.cover_w * 1.55) + 2 * L.border + L.gap + L.title_h + L.prog_h
end

local Hero = InputContainer:extend{
    width = nil,
    file = nil,
    bim = nil,     -- CoverBrowser's BookInfoManager
    margin = 0,    -- left/right padding, same as between tiles
    extra_h = 0,   -- spare height the cover may use
}
Library.Hero = Hero

function Hero:init()
    self.height = Library.heroHeight(self.extra_h)
    self.dimen = Geom:new{ x = 0, y = 0, w = self.width, h = self.height }
    self.ges_events = {
        TapHero = { GestureRange:new{ ges = "tap", range = function() return self.card_rect or self.dimen end } },
    }
    local file, BIM = self.file, self.bim
    self.cover_h = px(HERO_COVER_H) + self.extra_h
    local ch = self.cover_h
    local cw = math.floor(ch * HERO_COVER_W / HERO_COVER_H)

    -- Cover from CoverBrowser's cache; extract it now if it's missing or too small
    local info = BIM and BIM:getBookInfo(file, true)
    local want = { max_cover_w = cw + px(10), max_cover_h = ch + px(10) }
    if BIM and (not info or not info.cover_fetched
            or (info.has_cover and BIM.isCachedCoverInvalid(info, want))) then
        if info and info.cover_bb then info.cover_bb:free() end
        pcall(BIM.extractBookInfo, BIM, file, want)
        info = BIM:getBookInfo(file, true)
    end
    info = info or {}
    if info.has_cover and not info.ignore_cover and info.cover_bb then
        self.cover_bb = fitCover(info.cover_bb, cw, ch)
    elseif info.cover_bb then
        info.cover_bb:free()
    end

    local name = (file:match("([^/]+)$") or ""):gsub("%.[%w]+$", "")
    local title = (not info.ignore_meta and info.title) or name:match("^.-%s+%-%s+(.+)$") or name
    self.title = Theme.upper(Library.shortTitle(title))
    local authors = (not info.ignore_meta and info.authors) or name:match("^(.-)%s+%-%s+.+$") or ""
    self.author = Theme.upper((authors:gsub("\n.*", "")))

    local BookList = require("ui/widget/booklist")
    self.percent = math.max(0, math.min(1, BookList.getBookInfo(file).percent_finished or 0))
    local ok, ds = pcall(BookList.getDocSettings, file)
    local where = ok and ds and ds:readSetting("pixel_where")
    if type(where) == "table" and where.minutes then
        local ch_label = (where.chapter and where.chapter ~= "") and (where.chapter .. " · ") or ""
        self.meta = ch_label .. where.minutes .. " MIN LEFT"
    else
        self.meta = "LAST READ"
    end
end

function Hero:getSize() return Geom:new{ w = self.width, h = self.height } end

function Hero:free()
    if self.cover_bb then
        self.cover_bb:free()
        self.cover_bb = nil
    end
end

function Hero:paintTo(bb, x, y)
    self.dimen.x, self.dimen.y = x, y
    local m, B = self.margin, px(4)
    local ch = self.cover_h
    local aw, ah
    if self.cover_bb then
        aw, ah = self.cover_bb:getWidth(), self.cover_bb:getHeight()
    else
        aw, ah = math.floor(ch * 2 / 3), ch
    end
    local fw, fh = aw + 2 * B, ah + 2 * B
    local area_h = ch + 2 * B
    local fx, fy = x + m, y + area_h - fh

    -- The cover
    if self.cover_bb then
        bb:blitFrom(self.cover_bb, fx + B, fy + B, 0, 0, aw, ah)
    else
        bb:paintRect(fx + B, fy + B, aw, ah, Theme.paper)
        Paint.pattern(bb, Paint.hash(self.title) % #Paint.patterns + 1, fx + B, fy + B, aw, ah, px(1), Theme.pattern)
    end
    Paint.notchedBorder(bb, fx, fy, fw, fh, B, Theme.ink, B)

    -- Info next to it, bottom-aligned with the cover
    local ix = fx + fw + px(16)
    local iw = x + self.width - m - ix
    local chip = text("▶ NOW READING", Theme.face("vt", 14), Theme.paper)
    local title = textLines(self.title, Theme.face("vt", 30), iw, 2)
    local author = self.author ~= "" and text(self.author, Theme.face("vt", 15), Theme.muted, iw) or nil
    local meta = text(self.meta, Theme.face("vt", 15), Theme.ink, iw)
    local pct_n = math.floor(self.percent * 100 + 0.5)
    if pct_n == 0 and self.percent > 0 then pct_n = 1 end
    local pct = text(pct_n .. "%", Theme.face("vt", 15), Theme.ink)
    local btn = text("CONTINUE ▶", Theme.face("vt", 16), Theme.ink)

    local gap = px(5)
    local chip_h = chip:getSize().h + px(2)
    local cell = px(10)
    local bar_h = math.max(cell, pct:getSize().h)
    local btn_h = btn:getSize().h + px(6)
    local total = chip_h + gap + title:getSize().h + (author and (px(2) + author:getSize().h) or 0)
        + gap + meta:getSize().h + gap + bar_h + px(8) + btn_h
    local cy = y + area_h - total

    local cs = chip:getSize()
    Paint.notchedFill(bb, ix, cy, cs.w + 2 * px(6), chip_h, Theme.ink, px(3))
    chip:paintTo(bb, ix + px(6), cy + px(1))
    cy = cy + chip_h + gap
    title:paintTo(bb, ix, cy)
    cy = cy + title:getSize().h
    if author then
        cy = cy + px(2)
        author:paintTo(bb, ix, cy)
        cy = cy + author:getSize().h
    end
    cy = cy + gap
    meta:paintTo(bb, ix, cy)
    cy = cy + meta:getSize().h + gap
    -- Ten blocks of progress
    local filled = math.floor(self.percent * 10 + 0.5)
    if filled == 0 and self.percent > 0 then filled = 1 end
    local by = cy + math.floor((bar_h - cell) / 2)
    for i = 1, 10 do
        local color = i <= filled and Theme.ink or Blitbuffer.Color8(0xC8)
        bb:paintRect(ix + (i - 1) * (cell + px(2)), by, cell, cell, color)
    end
    pct:paintTo(bb, ix + 10 * (cell + px(2)) + px(6), cy + math.floor((bar_h - pct:getSize().h) / 2))
    cy = cy + bar_h + px(8)
    local bs = btn:getSize()
    local bw = bs.w + 2 * px(8)
    Paint.notchedBorder(bb, ix, cy, bw, btn_h, px(2), Theme.ink, px(3))
    btn:paintTo(bb, ix + px(8), cy + px(3))

    self.card_rect = Geom:new{ x = x, y = y, w = self.width, h = area_h }
    chip:free(); title:free(); if author then author:free() end
    meta:free(); pct:free(); btn:free()

    -- "▶ SHELF" and a dashed line, over the other books
    local sy = y + area_h + px(12)
    local shelf = text("▶ SHELF", Theme.face("vt", 15), Theme.ink)
    local ss = shelf:getSize()
    shelf:paintTo(bb, x + m, sy)
    local lx = x + m + ss.w + px(8)
    Paint.dashes(bb, lx, sy + math.floor(ss.h / 2), x + self.width - m - lx, px(2), px(5), px(3), Theme.ink)
    shelf:free()
end

function Hero:onTapHero()
    local fm = require("apps/filemanager/filemanager").instance
    if fm then
        require("apps/filemanager/filemanagerutil").openFile(fm, self.file)
    end
    return true
end

---------------------------------------------------------------------------
-- Glue for CoverBrowser's mosaic view (called from mosaicmenu.lua)
---------------------------------------------------------------------------

--- Build (or rebuild) the tile for one MosaicMenuItem.
function Library.updateMosaicItem(item, BookInfoManager)
    local w, h = item.width, item.height
    local tile
    item.is_directory = not (item.entry.is_file or item.entry.file)
    if item.is_directory then
        local name = (item.text or ""):gsub("/$", "")
        local n = tostring(item.mandatory or ""):match("^(%d+)")
        item.menu.cover_specs = item.do_cover_image and Library.coverSpecs(w, h) or false
        tile = Tile:new{
            width = w, height = h, is_dir = true, title = name,
            dir_label = n and (n .. (n == "1" and " ITEM" or " ITEMS")) or "",
        }
    else
        item.file_deleted = item.entry.dim
        local cover_specs = Library.coverSpecs(w, h)
        item.menu.cover_specs = item.do_cover_image and cover_specs or false

        local bookinfo = BookInfoManager:getBookInfo(item.filepath, item.do_cover_image)
        if bookinfo and item.do_cover_image and not bookinfo.ignore_cover and not item.file_deleted then
            if bookinfo.cover_fetched then
                if bookinfo.has_cover and not item.menu.no_refresh_covers
                        and BookInfoManager.isCachedCoverInvalid(bookinfo, cover_specs) then
                    if bookinfo.cover_bb then bookinfo.cover_bb:free() end
                    bookinfo = nil -- cached thumbnail too small: extract again
                end
            else
                bookinfo = nil
            end
        end

        local filename = item.filepath:match("([^/]+)$") or item.text or ""
        local ext = filename:match("%.([%w]+)$")
        local base = filename:gsub("%.[%w]+$", "")
        -- "Author - Title.txt": the title is the part after the dash
        local file_title = base:match("^.-%s+%-%s+(.+)$") or base
        local book_info = item.menu.getBookInfo(item.filepath)
        item.been_opened = book_info.been_opened
        local is_current = item.filepath == G_reader_settings:readSetting("lastfile")

        if bookinfo then
            item.bookinfo_found = true
            item.percent_finished = book_info.percent_finished
            item.status = book_info.status
            local cover
            if item.do_cover_image and bookinfo.has_cover and not bookinfo.ignore_cover and bookinfo.cover_bb then
                cover = bookinfo.cover_bb -- the tile owns it now
                item.menu._has_cover_images = true
                item._has_cover_image = true
            elseif bookinfo.cover_bb then
                bookinfo.cover_bb:free()
            end
            local title = (not bookinfo.ignore_meta and bookinfo.title) or file_title
            if title == base then title = file_title end -- "title" was just the file name
            tile = Tile:new{
                width = w, height = h,
                title = Library.shortTitle(title),
                ext = ext and ("." .. ext:lower()),
                status = item.been_opened and (book_info.status or "reading") or "new",
                percent = book_info.percent_finished,
                cover_bb = cover,
                is_current = is_current,
                dim = item.file_deleted,
            }
        else
            if item.init_done then return end -- still unknown: keep the placeholder
            if item.do_cover_image then item.cover_specs = cover_specs end
            tile = Tile:new{
                width = w, height = h, title = file_title, ext = ext and ("." .. ext:lower()),
                loading = true, dim = item.file_deleted, is_current = is_current,
            }
        end
    end

    local container = item._underline_container
    if container[1] then container[1]:free() end
    container[1] = tile
end

return Library

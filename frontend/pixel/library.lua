--[[--
The Pixel library: a wall of book covers.

Three parts, all drawn by hand so they match the mock-up exactly:

* Header  - "▶ LIBRARY", a book count, and ALL / READING / DONE / NEW tabs.
            Replaces the file manager's title bar (same methods, so the
            file manager doesn't notice).
* NavBar  - the black bar at the bottom: BOOKS / RECENT / FIND / SYNC / OPTIONS.
* Tile    - one book: its cover in a notched pixel frame, a title strip,
            and a block progress bar underneath. Books without a cover get
            one of the mock-up's ten pixel patterns, picked from the title.

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
local TextWidget = require("ui/widget/textwidget")
local Theme = require("pixel/theme")
local UIManager = require("ui/uimanager")
local Widget = require("ui/widget/widget")
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
        if Theme.active and self.name == "filemanager" and hide and type(items) == "table" then
            local kept = {}
            for _, item in ipairs(items) do
                if item.is_file or item.is_go_up then table.insert(kept, item) end
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
function Library.tileLayout(w, h)
    local L = {}
    L.border = px(4)
    L.under_h = px(21)
    L.frame_h = h - L.under_h
    L.strip_h = px(21)
    L.rule = px(3)
    L.cover_w = w - 2 * L.border
    L.cover_h = L.frame_h - 2 * L.border - L.strip_h - L.rule
    return L
end

--- How big a thumbnail CoverBrowser should cache so we can crop-to-fill.
function Library.coverSpecs(w, h)
    local L = Library.tileLayout(w, h)
    return { max_cover_w = math.floor(L.cover_w * 1.5), max_cover_h = math.floor(L.cover_h * 1.5) }
end

function Tile:init()
    self.dimen = Geom:new{ x = 0, y = 0, w = self.width, h = self.height }
    self.L = Library.tileLayout(self.width, self.height)
    local L = self.L
    if self.cover_bb then
        -- Scale to fill the cover box, keep the top (where titles usually are).
        local sw, sh = self.cover_bb:getWidth(), self.cover_bb:getHeight()
        local scale = math.max(L.cover_w / sw, L.cover_h / sh)
        local tw, th = math.max(L.cover_w, math.ceil(sw * scale)), math.max(L.cover_h, math.ceil(sh * scale))
        local scaled = RenderImage:scaleBlitBuffer(self.cover_bb, tw, th, false)
        if scaled ~= self.cover_bb then
            self.cover_bb:free()
        end
        self.cover_bb = scaled
        self.crop_x = math.floor((tw - L.cover_w) / 2)
        self.crop_y = math.floor((th - L.cover_h) * 0.08)
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
    local w = self.width
    local cx, cy = x + B, y + B

    -- Cover area: real cover (cropped to fill) or a pixel pattern
    bb:paintRect(cx, cy, L.cover_w, L.cover_h, Theme.paper)
    if self.cover_bb then
        bb:blitFrom(self.cover_bb, cx, cy, self.crop_x, self.crop_y, L.cover_w, L.cover_h)
    else
        Paint.pattern(bb, self.pattern_i, cx, cy, L.cover_w, L.cover_h, px(1), Theme.pattern)
        if self.is_dir then
            local cell = px(4)
            local bw, bh = #FOLDER[1] * cell, #FOLDER * cell
            local bx = cx + math.floor((L.cover_w - bw) / 2)
            local by = cy + math.floor((L.cover_h - bh) / 2)
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

    -- Rule, then the title strip (inverted for the book you're reading)
    local ry = cy + L.cover_h
    bb:paintRect(cx, ry, L.cover_w, L.rule, Theme.ink)
    local sy = ry + L.rule
    local fg = Theme.ink
    if self.is_current then
        bb:paintRect(cx, sy, L.cover_w, L.strip_h, Theme.ink)
        fg = Theme.paper
    else
        bb:paintRect(cx, sy, L.cover_w, L.strip_h, Theme.paper)
    end
    local t = text(Theme.upper(self.title or ""), Theme.face("vt", 15.5), fg, L.cover_w - 2 * px(5))
    t:paintTo(bb, cx + px(5), sy + math.floor((L.strip_h - t:getSize().h) / 2))
    t:free()

    -- The notched frame on top of everything
    Paint.notchedBorder(bb, x, y, w, L.frame_h, B, Theme.ink, B)

    -- Under the tile: progress blocks and a label
    local uy = y + L.frame_h + px(3)
    local label = text(self:_progressLabel(), Theme.face("vt", 15), Theme.ink)
    local ls = label:getSize()
    local cell = px(7)
    if not self.is_dir then
        local filled = 0
        if self.status == "complete" then filled = 5
        elseif self.percent then
            filled = math.floor(self.percent * 5 + 0.5)
            if filled == 0 and self.percent > 0 then filled = 1 end -- started = one block
        end
        local bx = x + px(1)
        local by = uy + label:getBaseline() - cell - px(0.5)
        for i = 1, 5 do
            local color = i <= filled and Theme.ink or Blitbuffer.Color8(0xC8)
            bb:paintRect(bx + (i - 1) * (cell + px(2)), by, cell, cell, color)
        end
    end
    label:paintTo(bb, x + w - ls.w - px(1), uy)
    label:free()

    if self.dim then
        bb:lightenRect(x, y, w, self.height, 0.6)
    end
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

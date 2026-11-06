--[[--
The Pixel OPTIONS menu, a game-style pause menu for the reading screen.

    ┌──────────── OPTIONS ────────────┐
    │ ▶ FONT     ◀  space-mono   ▶    │
    │   SIZE     ◀  ■■■□□        ▶    │
    │   SPACING  ◀  NORMAL       ▶    │
    │ - - - - - - - - - - - - - - - - │
    │ CONTENTS   BOOKMARKS    SEARCH  │
    │         ALL SETTINGS ▶          │
    └─────────────────────────────────┘

Opens where KOReader's bottom settings panel would (tap the bottom of the
page). "ALL SETTINGS" opens that full panel. Tap outside to close.
Line spacing is set per font, so NORMAL looks the same in every font.
]]

local Device = require("device")
local Event = require("ui/event")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InputContainer = require("ui/widget/container/inputcontainer")
local Paint = require("pixel/paint")
local TextWidget = require("ui/widget/textwidget")
local Theme = require("pixel/theme")
local UIManager = require("ui/uimanager")
local Screen = Device.screen

local px = Theme.px

-- Reading fonts: crengine family name, label, and the font's natural line
-- height in em (so spacing can be set in real em, whatever the font).
local FONTS = {
    { face = "Space Mono",    label = "space-mono", file = "pixel/SpaceMono-Regular.ttf",   natural = 1.48 },
    { face = "DM Mono",       label = "dm-mono",    file = "pixel/DMMono-Regular.ttf",      natural = 1.30 },
    { face = "IBM Plex Mono", label = "plex-mono", file = "pixel/IBMPlexMono-Regular.ttf", natural = 1.30 },
    { face = "PixelTerm",     label = "pixelterm", file = "pixel/PixelTerm-Regular.ttf",    natural = 1.00 },
    { face = "Noto Serif",    label = "noto-serif", file = "noto/NotoSerif-Regular.ttf",    natural = 1.36 },
}
local SIZES = { 15, 16.5, 18, 19.5, 21 }  -- smaller than the mock-up: easier on a 6" screen
local SPACINGS = { { "TIGHT", 1.45 }, { "NORMAL", 1.6 }, { "LOOSE", 1.8 } }

local Options = InputContainer:extend{
    ui = nil,
    modal = true,
    on_more = nil, -- opens the stock settings panel
}
Options.FONTS, Options.SIZES, Options.SPACINGS = FONTS, SIZES, SPACINGS

local function nearest(list, value, key)
    local best, bd = 1, math.huge
    for i, v in ipairs(list) do
        local d = math.abs((key and v[key] or v) - value)
        if d < bd then best, bd = i, d end
    end
    return best
end

function Options:init()
    self.ges_events = {
        TapOptions = { GestureRange:new{ ges = "tap", range = Geom:new{
            x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() } } },
    }
    if Device:hasKeys() then
        self.key_events = { Close = { { Device.input.group.Back } } }
    end
    self:readState()
    self.cursor = 1
    self:measure()
end

-- Measure the content so the box hugs it, and sit just above the footer.
-- (Re-run after SIZE changes: the whole interface scales with it.)
function Options:measure()
    local function h(str, size)
        local t = TextWidget:new{ text = str, face = Theme.face("vt", size) }
        local v = t:getSize().h
        t:free()
        return v
    end
    local height = px(4) + px(12) + h("OPTIONS", 38) + px(12) + 3 * px(34)
        + px(10) + px(4) + px(10) + px(26) + h("ALL", 18) + px(14) + px(4)
    local W = Screen:getWidth() - 2 * px(18)
    local bottom = Screen:getHeight() - require("pixel/reader").footerHeight() - px(6)
    self.dimen = Geom:new{ x = px(18), y = bottom - height, w = W, h = height }
end

function Options:readState()
    local ui = self.ui
    local face = ui.font and ui.font.font_face or FONTS[1].face
    self.font_i = 1
    for i, f in ipairs(FONTS) do if f.face == face then self.font_i = i end end
    self.custom_font = FONTS[self.font_i].face ~= face and face or nil
    local size = ui.document.configurable.font_size or 22
    self.size_i = nearest(SIZES, size)
    self.spacing_i = ui.doc_settings:readSetting("pixel_spacing") or 2
end

function Options:spacingPercent()
    local natural = FONTS[self.font_i].natural
    local pct = SPACINGS[self.spacing_i][2] / natural * 100
    return math.floor(pct / 5 + 0.5) * 5
end

function Options:apply(what)
    local ui = self.ui
    if what == "font" then
        self.custom_font = nil
        ui:handleEvent(Event:new("SetFont", FONTS[self.font_i].face))
        ui:handleEvent(Event:new("SetLineSpace", self:spacingPercent()))
    elseif what == "size" then
        ui:handleEvent(Event:new("SetFontSize", SIZES[self.size_i]))
        -- one dial: menus, library and dialogs follow the book text size
        G_reader_settings:saveSetting("pixel_ui_scale", Theme.uiScaleForFontSize(SIZES[self.size_i]))
        local old = self.dimen
        self:measure()
        UIManager:setDirty("all", "ui", old:combine(self.dimen))
        return
    elseif what == "spacing" then
        ui.doc_settings:saveSetting("pixel_spacing", self.spacing_i)
        ui:handleEvent(Event:new("SetLineSpace", self:spacingPercent()))
    end
    UIManager:setDirty("all", "ui")
end

local function text(str, face, color)
    return TextWidget:new{ text = str, face = face, fgcolor = color or Theme.ink }
end

function Options:paintTo(bb)
    local d = self.dimen
    local B = px(4)
    -- Fade the page behind the menu (the "paused" look), keep the header crisp
    local top = require("pixel/reader").headerSpace()
    if d.y - px(3) > top then
        bb:lightenRect(0, top, Screen:getWidth(), d.y - px(3) - top, 0.55)
    end
    bb:paintRect(d.x - px(3), d.y - px(3), d.w + px(6), d.h + px(6), Theme.paper) -- clean margin
    Paint.notchedFill(bb, d.x, d.y, d.w, d.h, Theme.paper, B)
    Paint.notchedBorder(bb, d.x, d.y, d.w, d.h, B, Theme.ink, B)
    local cx, cw = d.x + B + px(16), d.w - 2 * B - 2 * px(16)
    local y = d.y + B + px(12)

    local title = text("OPTIONS", Theme.face("vt", 38))
    title:paintTo(bb, d.x + math.floor((d.w - title:getSize().w) / 2), y)
    y = y + title:getSize().h + px(12)
    title:free()

    local row_face = Theme.face("vt", 20)
    local row_h = px(34)
    local value_w = px(120)
    local arrows_w = px(30)
    local right = cx + cw
    self.rows = {}
    local rows = {
        { id = "font", label = "FONT" },
        { id = "size", label = "SIZE" },
        { id = "spacing", label = "SPACING" },
    }
    for i, row in ipairs(rows) do
        local lab = text((self.cursor == i and "▶ " or "\u{2002}\u{2002}") .. row.label, row_face)
        local ty = y + math.floor((row_h - lab:getSize().h) / 2)
        lab:paintTo(bb, cx, ty)
        lab:free()
        local next_x = right - arrows_w
        local val_x = next_x - value_w
        local prev_x = val_x - arrows_w
        local la, ra = text("◀", row_face), text("▶", row_face)
        la:paintTo(bb, prev_x + math.floor((arrows_w - la:getSize().w) / 2), ty)
        ra:paintTo(bb, next_x + math.floor((arrows_w - ra:getSize().w) / 2), ty)
        la:free(); ra:free()
        -- the value
        if row.id == "font" then
            local f = FONTS[self.font_i]
            local name = self.custom_font and self.custom_font:lower() or f.label
            local v = TextWidget:new{ text = name, face = require("ui/font"):getFace(f.file, Theme.fs(12.5)),
                fgcolor = Theme.ink, max_width = value_w }
            local vs = v:getSize()
            v:paintTo(bb, val_x + math.floor((value_w - vs.w) / 2), y + math.floor((row_h - vs.h) / 2))
            v:free()
        elseif row.id == "size" then
            local cell, gap = px(14), px(3)
            local n = #SIZES
            local bw = n * cell + (n - 1) * gap
            Paint.blocks(bb, val_x + math.floor((value_w - bw) / 2), y + math.floor((row_h - cell) / 2),
                cell, n, self.size_i, gap, px(2), Theme.ink)
        else
            local v = text(SPACINGS[self.spacing_i][1], row_face)
            local vs = v:getSize()
            v:paintTo(bb, val_x + math.floor((value_w - vs.w) / 2), ty)
            v:free()
        end
        local pad = px(6)
        self.rows[i] = {
            id = row.id,
            prev = Geom:new{ x = prev_x - pad, y = y, w = arrows_w + 2 * pad, h = row_h },
            next = Geom:new{ x = next_x - pad, y = y, w = arrows_w + 2 * pad, h = row_h },
        }
        y = y + row_h
    end

    -- dashed rule
    y = y + px(10)
    Paint.dashes(bb, cx, y, cw, px(4), px(4), px(4), Theme.ink)
    y = y + px(4) + px(10)

    -- shortcuts
    local face = Theme.face("vt", 18)
    local links = { { id = "toc", label = "CONTENTS" }, { id = "bookmarks", label = "BOOKMARKS" }, { id = "search", label = "SEARCH" } }
    local widgets, total = {}, 0
    for _, l in ipairs(links) do
        local w = text(l.label, face)
        table.insert(widgets, w)
        total = total + w:getSize().w
    end
    local gap = (cw - total) / (#links - 1)
    local lx = cx
    self.links = {}
    for i, w in ipairs(widgets) do
        local s = w:getSize()
        w:paintTo(bb, math.floor(lx), y)
        table.insert(self.links, { id = links[i].id, rect = Geom:new{ x = math.floor(lx) - px(6), y = y - px(8), w = s.w + px(12), h = s.h + px(16) } })
        lx = lx + s.w + gap
        w:free()
    end
    y = y + px(26)

    local more = text("ALL SETTINGS ▶", face, Theme.muted)
    local ms = more:getSize()
    local mx = d.x + math.floor((d.w - ms.w) / 2)
    more:paintTo(bb, mx, y)
    self.more_rect = Geom:new{ x = mx - px(8), y = y - px(8), w = ms.w + px(16), h = ms.h + px(16) }
    more:free()
end

local function inside(pos, r)
    return r and pos.x >= r.x and pos.x < r.x + r.w and pos.y >= r.y and pos.y < r.y + r.h
end

function Options:onTapOptions(_, ges)
    local pos = ges.pos
    if not inside(pos, self.dimen) then
        return self:onClose()
    end
    for i, row in ipairs(self.rows or {}) do
        local dir = inside(pos, row.prev) and -1 or (inside(pos, row.next) and 1 or nil)
        if dir then
            self.cursor = i
            if row.id == "font" then
                self.font_i = (self.font_i - 1 + dir) % #FONTS + 1
            elseif row.id == "size" then
                self.size_i = math.max(1, math.min(#SIZES, self.size_i + dir))
            else
                self.spacing_i = math.max(1, math.min(#SPACINGS, self.spacing_i + dir))
            end
            self:apply(row.id)
            return true
        end
    end
    for _, l in ipairs(self.links or {}) do
        if inside(pos, l.rect) then
            self:onClose()
            local ui = self.ui
            if l.id == "toc" then ui.toc:onShowToc()
            elseif l.id == "bookmarks" then ui.bookmark:onShowBookmark()
            else ui.search:onShowFulltextSearchInput() end
            return true
        end
    end
    if inside(pos, self.more_rect) then
        self:onClose()
        if self.on_more then self.on_more() end
        return true
    end
    return true
end

function Options:onClose()
    UIManager:close(self, "ui")
    require("pixel/reader").paused = false
    if self.ui and self.ui.dialog then UIManager:setDirty(self.ui.dialog, "ui") end
    return true
end

return Options

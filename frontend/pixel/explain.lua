--[[--
The Pixel "Explain" box: an RPG-style dialog where Claude explains the word
you long-pressed.

    ┌─CLAUDE─────────────────────────────┐
    │ CATO!          person · Roman ...  │
    │ ▸ MEANING  Cato the Younger — ...  │
    │ ▸ HERE     As Julius Caesar ...    │
    │ ▸ DEEPER   The night he died ...   │
    │ [▶ PISTOL] [▶ HYPOS]            ▼  │
    └────────────────────────────────────┘

States: "loading" (while Claude thinks; tap to cancel), "result", "error".
The box sits at the bottom of the screen, or at the top when the word you
picked is in the lower half (so it never covers the word).

Taps: a related-word chip explains that word; DICT opens the normal
dictionary; anywhere else closes the box.
]]

local Device = require("device")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InputContainer = require("ui/widget/container/inputcontainer")
local Paint = require("pixel/paint")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local Theme = require("pixel/theme")
local UIManager = require("ui/uimanager")
local Screen = Device.screen

local px = Theme.px

local ExplainDialog = InputContainer:extend{
    word = "",
    word_box = nil,      -- screen rect of the selected word: we stay clear of it
    anchor_top = false,
    state = "loading",   -- "loading" | "result" | "error"
    expanded = false,    -- DEEPER shown (tap ▼)
    result = nil,
    error = nil,         -- message, or "nokey"
    on_close = nil,      -- function()
    on_related = nil,    -- function(word)
    on_dictionary = nil, -- function()
    modal = true,
    dismiss_callback = nil, -- set by Trapper while loading
}

function ExplainDialog:init()
    self.ges_events = {
        TapDialog = { GestureRange:new{ ges = "tap", range = Geom:new{
            x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() } } },
    }
    if Device:hasKeys() then
        self.key_events = { Close = { { Device.input.group.Back } } }
    end
    self:layout()
end

local function tw(str, face, color, max_width)
    return TextWidget:new{ text = str, face = face, fgcolor = color or Theme.ink, max_width = max_width }
end

-- A labelled paragraph: the pixel-font label sits in the first few columns
-- of a monospace text box (we pad the text with spaces under the label).
function ExplainDialog:_section(label, body, width)
    local lab = tw(label, Theme.face("vt", 17))
    local face = Theme.face("mono", 12)
    local space = tw("\u{00A0}", face)
    local n = math.ceil((lab:getSize().w + px(3)) / math.max(1, space:getSize().w))
    space:free()
    local box = TextBoxWidget:new{
        text = string.rep("\u{00A0}", n) .. (body or ""),
        face = face,
        width = width,
        line_height = 0.4,
        fgcolor = Theme.ink,
        height = self.section_max_h, -- nil = no limit
        height_adjust = true,
        height_overflow_show_ellipsis = true,
    }
    return { label = lab, box = box, h = box:getSize().h }
end

function ExplainDialog:_freeContent()
    for _, s in ipairs(self.sections or {}) do
        s.label:free(); s.box:free()
    end
    for _, c in ipairs(self.chips or {}) do c.w:free() end
    if self.head then self.head:free() end
    if self.kind then self.kind:free() end
    self.sections, self.chips, self.head, self.kind = {}, {}, nil, nil
end

function ExplainDialog:layout()
    self:_freeContent()
    local W = Screen:getWidth() - 2 * px(14)
    local inner_w = W - 2 * px(14) - 2 * px(4)
    self.W = W

    local r = self.result or {}
    -- Keep the whole box (and its buttons) on screen: each of the three
    -- sections gets at most a share of the free height.
    local free_h = Screen:getHeight() - px(40) - px(14) - px(34) - px(150)
    self.section_max_h = math.max(px(40), math.floor(free_h / 3))
    local headword = (self.state == "result" and r.headword ~= "" and r.headword) or self.word
    local kind
    if self.state == "loading" then kind = "THINKING…"
    elseif self.state == "error" then kind = "HMM."
    else kind = r.kind or "" end

    self.head = tw(Theme.upper(headword) .. "!", Theme.face("vt", 36), Theme.ink, inner_w)
    -- The label goes beside the headword if it fits, else on its own line below.
    local beside = inner_w - self.head:getSize().w - px(16)
    self.kind = tw(kind, Theme.face("vt", 16), Theme.muted)
    self.kind_below = self.kind:getSize().w > beside
    if self.kind_below then
        self.kind:free()
        self.kind = tw(kind, Theme.face("vt", 16), Theme.muted, inner_w)
    end

    if self.state == "loading" then
        table.insert(self.sections, self:_section("▸ ONE SEC", "Reading the passage around “" .. self.word .. "”… (tap to cancel)", inner_w))
    elseif self.state == "error" then
        local msg = self.error
        if msg == "nokey" then
            msg = "Explain needs a Claude API key. Add one in Settings > Pixel theme, or copy a file named claude_api_key.txt into the koreader folder over USB."
        end
        table.insert(self.sections, self:_section("▸ OOPS", msg, inner_w))
    else
        table.insert(self.sections, self:_section("▸ MEANING", r.meaning, inner_w))
        table.insert(self.sections, self:_section("▸ HERE", r.here, inner_w))
        if self.expanded then
            table.insert(self.sections, self:_section("▸ DEEPER", r.deeper, inner_w))
        end
    end

    -- Chips: related words, then DICT
    if self.state == "result" then
        for _, word in ipairs(r.related or {}) do
            table.insert(self.chips, { word = word, w = tw("▶ " .. Theme.upper(word), Theme.face("vt", 18), Theme.paper) })
        end
    end
    if self.on_dictionary and self.state ~= "loading" then
        table.insert(self.chips, { dict = true, w = tw("DICT", Theme.face("vt", 18), Theme.paper) })
    end
    -- ▼ reveals DEEPER, like "next" in a game dialog; ▲ folds it back
    self.has_more = self.state == "result" and r.deeper and r.deeper ~= ""
    self.more = tw(self.has_more and (self.expanded and "▲ LESS" or "▼ MORE") or "", Theme.face("vt", 18))

    -- Chips must fit on one row next to the ▼: drop related words that
    -- don't fit (DICT always stays, at the end).
    local function chip_w(c) return c.w:getSize().w + 2 * px(7) end
    local budget = inner_w - self.more:getSize().w - px(16)
    local dict = (#self.chips > 0 and self.chips[#self.chips].dict) and self.chips[#self.chips] or nil
    if dict then budget = budget - chip_w(dict) - px(10) end
    local kept = {}
    for _, c in ipairs(self.chips) do
        if not c.dict then
            if chip_w(c) <= budget then
                table.insert(kept, c)
                budget = budget - chip_w(c) - px(10)
            else
                c.w:free()
            end
        end
    end
    if dict then table.insert(kept, dict) end
    self.chips = kept

    -- Height of the box
    local pad_top, pad_bottom = px(20), px(12)
    local h = pad_top + self.head:getSize().h
    if self.kind_below then h = h + self.kind:getSize().h end
    for _, s in ipairs(self.sections) do h = h + px(4) + s.h end
    self.chip_h = px(22)
    local chip_row = (#self.chips > 0 or self.has_more) and (px(10) + self.chip_h) or 0
    h = h + chip_row + pad_bottom + 2 * px(4)
    self.box_h = h

    local tag_over = px(14)
    local sh = Screen:getHeight()
    local bottom_edge = sh - require("pixel/reader").footerHeight() - px(4) -- keep the footer visible
    local y_top, y_bottom = px(40), bottom_edge - h - tag_over
    if y_bottom < px(14) then y_bottom = px(14) end
    local y = self.anchor_top and y_top or y_bottom
    local wb = self.word_box
    if wb then
        -- Pick the side that doesn't cover the word (or covers it least).
        local function overlap(top)
            local a, b = top, top + h + tag_over
            return math.max(0, math.min(b, wb.y + wb.h) - math.max(a, wb.y))
        end
        local ot, ob = overlap(y_top), overlap(y_bottom)
        if ot ~= ob then y = ot < ob and y_top or y_bottom end
    end
    local old = self.dimen
    self.dimen = Geom:new{ x = px(14), y = y, w = W, h = h + tag_over }
    return old
end

function ExplainDialog:paintTo(bb, x, y)
    -- (UIManager passes 0,0 for full-screen-positioned widgets; we place ourselves)
    local d = self.dimen
    local bx, by = d.x, d.y + px(14)
    local W, H, B = self.W, self.box_h, px(4)
    -- A white margin around the box so page text never peeks around the tag
    bb:paintRect(bx - px(3), d.y - px(2), W + px(6), H + (by - d.y) + px(5), Theme.paper)
    Paint.notchedFill(bb, bx, by, W, H, Theme.paper, B)
    Paint.notchedBorder(bb, bx, by, W, H, B, Theme.ink, B)

    -- Name tag over the top border
    local tag = tw("CLAUDE", Theme.face("vt", 20), Theme.paper)
    local ts = tag:getSize()
    local tag_w, tag_h = ts.w + 2 * px(8), px(22)
    Paint.notchedFill(bb, bx + px(14), d.y, tag_w, tag_h, Theme.ink, px(3))
    tag:paintTo(bb, bx + px(14) + px(8), d.y + math.floor((tag_h - ts.h) / 2))
    tag:free()

    local cx = bx + B + px(14)
    local cy = by + B + px(16)
    local inner_w = W - 2 * B - 2 * px(14)

    -- Headword and kind, on one baseline
    local hs, ks = self.head:getSize(), self.kind:getSize()
    self.head:paintTo(bb, cx, cy)
    if self.kind_below then
        cy = cy + hs.h - px(4)
        self.kind:paintTo(bb, cx, cy)
        cy = cy + ks.h + px(4)
    else
        self.kind:paintTo(bb, cx + inner_w - ks.w, cy + self.head:getBaseline() - self.kind:getBaseline())
        cy = cy + hs.h
    end

    for _, s in ipairs(self.sections) do
        cy = cy + px(4)
        s.box:paintTo(bb, cx, cy)
        -- label baseline on the first text line's baseline
        s.label:paintTo(bb, cx, cy + s.box.line_glyph_baseline - s.label:getBaseline())
        cy = cy + s.h
    end

    -- Chips row
    cy = cy + px(10)
    local chip_x = cx + px(3)
    for _, c in ipairs(self.chips) do
        local s = c.w:getSize()
        local w = s.w + 2 * px(7)
        Paint.notchedFill(bb, chip_x - px(3), cy, w, self.chip_h, Theme.ink, px(3))
        c.w:paintTo(bb, chip_x - px(3) + px(7), cy + math.floor((self.chip_h - s.h) / 2))
        c.rect = Geom:new{ x = chip_x - px(6), y = cy - px(6), w = w + px(6), h = self.chip_h + px(12) }
        chip_x = chip_x + w + px(10)
    end
    local ms = self.more:getSize()
    local mx = cx + inner_w - ms.w
    self.more:paintTo(bb, mx, cy + math.floor((self.chip_h - ms.h) / 2))
    self.more_rect = self.has_more and Geom:new{ x = mx - px(12), y = cy - px(10), w = ms.w + px(20), h = self.chip_h + px(20) } or nil
end

-- Our dimen plus the white margin painted around the box.
function ExplainDialog:_area(g)
    g = g or self.dimen
    return Geom:new{ x = g.x - px(4), y = g.y - px(3), w = g.w + px(8), h = g.h + px(10) }
end

function ExplainDialog:_inside(pos, r)
    return r and pos.x >= r.x and pos.x < r.x + r.w and pos.y >= r.y and pos.y < r.y + r.h
end

function ExplainDialog:onTapDialog(_, ges)
    local pos = ges.pos
    if self.state == "loading" then
        self:onClose()
        return true
    end
    if self:_inside(pos, self.more_rect) then
        self.expanded = not self.expanded
        self:update(self.state, self.result, self.error)
        return true
    end
    for _, c in ipairs(self.chips or {}) do
        if self:_inside(pos, c.rect) then
            if c.dict then
                self:onClose(true)
                if self.on_dictionary then self.on_dictionary() end
            elseif self.on_related then
                self.on_related(c.word)
            end
            return true
        end
    end
    self:onClose()
    return true
end

--- Swap in a new state and repaint (the box may change height).
function ExplainDialog:update(state, result, err, word)
    self.state, self.result, self.error = state, result, err
    if word then self.word = word end
    local old = self:layout()
    local area = old and self:_area(old):combine(self:_area()) or self:_area()
    UIManager:setDirty("all", "ui", area)
end

function ExplainDialog:setResult(result) self:update("result", result, nil) end
function ExplainDialog:setError(err) self:update("error", nil, err) end
function ExplainDialog:setLoading(word) self.expanded = false; self:update("loading", nil, nil, word) end

function ExplainDialog:onClose(keep_selection)
    if self.dismiss_callback then
        local cb = self.dismiss_callback
        self.dismiss_callback = nil
        cb() -- cancels a request in flight
    end
    UIManager:close(self, "ui", self:_area())
    if self.on_close then self.on_close(keep_selection) end
    return true
end

function ExplainDialog:onCloseWidget()
    self:_freeContent()
end

return ExplainDialog

--[[--
Restyles KOReader's stock widgets for the Pixel theme.

Runs once at start-up (from Theme.install, called by reader.lua), after the
settings and fonts are known but before any widget is built. It changes:

* fonts: UI labels in PixelTerm (VT323), running text in Space Mono;
* boxes: every rounded frame gets notched "pixel" corners instead;
* borders: window borders get chunkier;
* labels: titles and short button labels in capitals;
* list footers: "Page 2 of 5" becomes "PG 2/5".

Each change is small and self-contained, so a KOReader update that moves
things around breaks one tweak, not the app.
]]

local Chrome = {}

-- Visual size compensation: VT323's letters are small for their nominal size.
local PIXEL_SCALE = 1.3
local MONO_SCALE = 0.95

local function installFonts(Theme)
    local Font = require("ui/font")
    local vt, mono, monob = Theme.fonts.vt, Theme.fonts.mono, Theme.fonts.monob

    -- Short UI labels: pixel font. "pxui" is our own alias, used for buttons.
    local pixel_aliases = { "tfont", "smalltfont", "x_smalltfont", "ffont", "smallffont",
                            "largeffont", "pgfont", "rifont", "scfont", "hpkfont", "pxui" }
    -- Running text (messages, menus, dictionary): mono.
    local mono_aliases = { "cfont", "hfont", "infont", "smallinfont", "infofont",
                           "smallinfofont", "x_smallinfofont", "xx_smallinfofont" }
    local scale = {}
    for _, k in ipairs(pixel_aliases) do Font.fontmap[k] = vt; scale[k] = PIXEL_SCALE end
    for _, k in ipairs(mono_aliases) do Font.fontmap[k] = mono; scale[k] = MONO_SCALE end
    Font.fontmap.smallinfofontbold = monob
    scale.smallinfofontbold = MONO_SCALE
    Font.sizemap.pxui = Font.sizemap.cfont

    -- Real bold for Space Mono; no fake bold for the pixel font (it smears).
    Font.bold_font_variant[mono] = monob
    Font.regular_font_variant[monob] = mono
    Font.bold_font_variant[Theme.fonts.monoi] = "pixel/SpaceMono-BoldItalic.ttf"

    local orig_getFace = Font.getFace
    local function noLigatures(face)
        -- the pixel font has no "fi"/"fl" ligatures; a fallback font's look out of place
        if face and face.realname == vt and not face.pixel_features then
            face.hb_features = { "+kern", "-liga", "-clig" }
            face.pixel_features = true
        end
        return face
    end
    function Font:getFace(font, size, faceindex)
        local k = font and scale[font]
        if not k then return noLigatures(orig_getFace(self, font, size, faceindex)) end
        local asked = size or self.sizemap[font] or 20
        local face = orig_getFace(self, font, asked * k * Theme.uiScale(), faceindex)
        -- Report the size the caller asked for: stock "shrink to fit" loops
        -- retry with orig_size - 1, which must not get scaled up again.
        if face then face.orig_size = asked end
        return noLigatures(face)
    end

    local orig_getAdjustedFace = Font.getAdjustedFace
    function Font:getAdjustedFace(face, bold)
        if face and face.realname == vt then
            return face, false
        end
        return orig_getAdjustedFace(self, face, bold)
    end
end

local function installSizes(Theme)
    local Size = require("ui/size")
    Size.border.window = Theme.px(2.5)
    Size.border.thick = Theme.px(2)
    Size.border.button = Theme.px(1.5)
    Size.line.thick = Theme.px(1.5)
end

-- Notched-corner frames. A FrameContainer is drawn "pixel style" when it has
-- a radius (any rounded box in stock KOReader) or an explicit `notch`.
local function installFrames(Theme)
    local BD = require("ui/bidi")
    local FrameContainer = require("ui/widget/container/framecontainer")
    local Geom = require("ui/geometry")
    local Paint = require("pixel/paint")
    local orig_paintTo = FrameContainer.paintTo

    function FrameContainer:paintTo(bb, x, y)
        local notch = self.notch
        if not notch then
            if not self.radius or self.radius <= 0 then
                return orig_paintTo(self, bb, x, y)
            end
            notch = math.max(self.bordersize or 0, Theme.px(1))
        end
        local my_size = self:getSize()
        if not self.dimen then
            self.dimen = Geom:new{ x = x, y = y, w = my_size.w, h = my_size.h }
        else
            self.dimen.x = x
            self.dimen.y = y
        end
        local w = self.width or my_size.w
        local h = self.height or my_size.h
        local shift_x = 0
        if BD.mirroredUILayout() and self.allow_mirroring then
            shift_x = w - my_size.w
        end
        local m = self.margin
        if self.background then
            Paint.notchedFill(bb, x + m, y + m, w - 2 * m, h - 2 * m, self.background, notch)
        end
        if self.stripe_width and self.stripe_color and not self.stripe_over then
            bb:hatchRect(x, y, w, h, self.stripe_width, self.stripe_color)
        end
        if self.bordersize > 0 then
            Paint.notchedBorder(bb, x + m, y + m, w - 2 * m, h - 2 * m, self.bordersize, self.color, notch)
        end
        if self[1] then
            self[1]:paintTo(bb,
                x + m + self.bordersize + self._padding_left + shift_x,
                y + m + self.bordersize + self._padding_top)
        end
        if self.inner_bordersize > 0 then
            bb:paintInnerBorder(x + m, y + m, w - 2 * m, h - 2 * m, self.inner_bordersize, self.color)
        end
        if self.stripe_width and self.stripe_color and self.stripe_over then
            local pad = m + math.max(self.bordersize, self.inner_bordersize)
            bb:hatchRect(x + pad, y + pad, w - pad * 2, h - pad * 2,
                self.stripe_width, self.stripe_color, self.stripe_over_alpha)
        end
        local b = self.bordersize
        if self.invert then
            bb:invertRect(x + b, y + b, w - 2 * b, h - 2 * b)
        end
        if self.dim then
            bb:lightenRect(x + b, y + b, w - 2 * b, h - 2 * b)
        end
    end
end

local function installLabels(Theme)
    local upper = Theme.upper

    local TitleBar = require("ui/widget/titlebar")
    local orig_tb_init = TitleBar.init
    function TitleBar:init()
        self.title = upper(self.title)
        return orig_tb_init(self)
    end
    local orig_tb_setTitle = TitleBar.setTitle
    function TitleBar:setTitle(title, no_refresh)
        return orig_tb_setTitle(self, upper(title), no_refresh)
    end

    local Button = require("ui/widget/button")
    Button.text_font_face = "pxui"
    Button.text_font_bold = false
    local function short_upper(t)
        if type(t) == "string" and #t <= 32 and not t:find("\n") then return upper(t) end
        return t
    end
    local orig_btn_init = Button.init
    function Button:init()
        self.text = short_upper(self.text)
        return orig_btn_init(self)
    end
    local orig_btn_setText = Button.setText
    function Button:setText(text, width)
        return orig_btn_setText(self, short_upper(text), width)
    end

    local Menu = require("ui/widget/menu")
    local orig_updatePageInfo = Menu.updatePageInfo
    function Menu:updatePageInfo(select_number)
        orig_updatePageInfo(self, select_number)
        if self.page_info_text and #self.item_table > 0 and self.page and self.page_num then
            self.page_info_text:setText(string.format("PG %d/%d", self.page, self.page_num))
        end
    end

    local TouchMenu = require("ui/widget/touchmenu")
    local orig_tm_updateItems = TouchMenu.updateItems
    function TouchMenu:updateItems(...)
        local ret = orig_tm_updateItems(self, ...)
        if self.page_info_text and self.page_num and self.page_num > 1 then
            self.page_info_text:setText(string.format("PG %d/%d", self.page, self.page_num))
        end
        return ret
    end
end

-- First run with the theme: reading defaults that match the mock-up. Books
-- you already opened keep their own settings; everything stays changeable.
-- Space Mono replaced IBM Plex Mono as the default reading font (Nov 2026):
-- move earlier installs over once, unless the reader picked another font.
local function migrateFont()
    if G_reader_settings:isTrue("pixel_font_space_done") then return end
    local cur = G_reader_settings:readSetting("cre_font")
    if cur == nil or cur == "IBM Plex Mono" then
        G_reader_settings:saveSetting("cre_font", "Space Mono")
        G_reader_settings:saveSetting("copt_line_spacing", 110)
    end
    G_reader_settings:makeTrue("pixel_font_space_done")
end

local function applyDefaults(Theme)
    if G_reader_settings:isTrue("pixel_defaults_done") then return migrateFont() end
    local Screen = require("device").screen
    local unit = Screen:scaleBySize(1000) / 1000 -- KOReader margins are in scaled px
    local function margin(mockup_px) return math.floor(Theme.px0(mockup_px) / unit + 0.5) end
    G_reader_settings:saveSetting("cre_font", "Space Mono")
    G_reader_settings:saveSetting("copt_font_size", 18)
    G_reader_settings:saveSetting("copt_line_spacing", 110) -- 1.6 em with Space Mono's tall lines
    G_reader_settings:saveSetting("copt_h_page_margins", { margin(24), margin(24) })
    G_reader_settings:saveSetting("copt_sync_t_b_page_margins", 0)
    G_reader_settings:saveSetting("copt_t_page_margin", margin(44)) -- room for the Pixel header
    G_reader_settings:saveSetting("copt_b_page_margin", margin(4))
    local CssTweaks = require("ui/data/css_tweaks")
    local tweaks = G_reader_settings:readSetting("style_tweaks")
        or require("util").tableDeepCopy(CssTweaks.DEFAULT_GLOBAL_STYLE_TWEAKS)
    for _, id in ipairs{ "pixel_headings", "pixel_paragraphs", "text_align_most_left", "hyphenate_all_auto", "margin_body_0" } do
        tweaks[id] = true
    end
    G_reader_settings:saveSetting("style_tweaks", tweaks)
    G_reader_settings:saveSetting("screensaver_type", "pixel")
    G_reader_settings:makeTrue("pixel_defaults_done")
    G_reader_settings:makeTrue("pixel_font_space_done")
end

function Chrome.install(Theme)
    -- Without our fonts every title would be nil: refuse, and stay stock.
    local lfs = require("libs/libkoreader-lfs")
    local fontdir = require("fontlist").fontdir
    for _, file in pairs(Theme.fonts) do
        if lfs.attributes(fontdir .. "/" .. file, "mode") ~= "file" then
            error("Pixel font missing: " .. fontdir .. "/" .. file)
        end
    end
    installFonts(Theme)   -- first: later requires build faces at load time
    installSizes(Theme)
    installFrames(Theme)
    installLabels(Theme)
    applyDefaults(Theme)
end

return Chrome

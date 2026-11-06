--[[--
Pixel theme: a retro game-terminal look for KOReader.

This module holds the design tokens (sizes, fonts, colours) that every
other Pixel module reads, so the whole look can be tuned in one place.

Sizes come from the design mock-ups, which were drawn on a 372 px wide
screen. `Theme.px(n)` turns a mock-up pixel into device pixels, and
`Theme.fs(n)` turns a mock-up font size into a KOReader font size, so the
proportions match on any screen (a Paperwhite is 1236 px wide: 1 mock-up
pixel = 3.3 device pixels).

The theme is on by default. Turning it off (Settings > Pixel theme) needs
a restart, because it restyles widgets before they are built.
]]

local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Screen = Device.screen

local Theme = {
    installed = false,
    active = false,
    MOCKUP_WIDTH = 372,

    -- Font files, relative to KOReader's fonts/ folder.
    fonts = {
        vt    = "pixel/PixelTerm-Regular.ttf",     -- VT323 + pixel arrows/blocks: headings, UI
        mono  = "pixel/IBMPlexMono-Regular.ttf",   -- body text
        monoi = "pixel/IBMPlexMono-Italic.ttf",
        monob = "pixel/IBMPlexMono-SemiBold.ttf",
        space = "pixel/SpaceMono-Regular.ttf",
    },

    -- Colours. E-ink "white" already looks like the mock-up's warm paper,
    -- so we keep real white for contrast and use grey only for accents.
    ink = Blitbuffer.COLOR_BLACK,
    paper = Blitbuffer.COLOR_WHITE,
    muted = Blitbuffer.Color8(0x55),   -- secondary text (#555 in the mock-up)
    soft = Blitbuffer.Color8(0x9A),    -- inactive items on black bars
    pattern = Blitbuffer.Color8(0x8A), -- placeholder cover patterns
}

--- Is the theme switched on in settings? (default: yes)
function Theme.isEnabled()
    return G_reader_settings == nil or G_reader_settings:nilOrTrue("pixel_theme")
end

local function unit()
    return math.min(Screen:getWidth(), Screen:getHeight()) / Theme.MOCKUP_WIDTH
end

--- Mock-up pixels -> device pixels (never less than 1).
function Theme.px(n)
    return math.max(1, math.floor(n * unit() + 0.5))
end

--- Mock-up font px -> KOReader font size (Font:getFace scales it by scaleBySize).
function Theme.fs(n)
    return n * unit() / (Screen:scaleBySize(1000) / 1000)
end

--- A font face from the theme. kind is a key of Theme.fonts, size in mock-up px.
function Theme.face(kind, size)
    return require("ui/font"):getFace(Theme.fonts[kind] or kind, Theme.fs(size))
end

--- Uppercase that also handles accented letters (falls back to ASCII-only).
function Theme.upper(s)
    if type(s) ~= "string" then return s end
    local ok, utf8proc = pcall(require, "ffi/utf8proc")
    if ok and utf8proc and utf8proc.uppercase_dumb then
        local ok2, up = pcall(utf8proc.uppercase_dumb, s)
        if ok2 and up then return up end
    end
    return s:upper()
end

--- Called once from reader.lua, before any widget exists.
function Theme.install()
    if Theme.installed then return end
    Theme.installed = true
    if not Theme.isEnabled() then return end
    local ok, err = pcall(function() require("pixel/chrome").install(Theme) end)
    if ok then
        Theme.active = true
    else
        -- Never let a theme bug stop KOReader from starting.
        require("logger").err("Pixel theme failed to install:", err)
    end
end

return Theme

--[[--
Halftone transitions: things break into ink dots when they leave the screen
and build back up from dots when they arrive (like the Pixel sleep screen).

How it works
* Something is about to change the screen (a popup opens or closes, a page
  turns, a menu changes page). We copy the screen as it is now (`mark`).
* KOReader paints the new state into the screen buffer as usual. Just before
  it refreshes the e-ink, UIManager calls `beforeRefresh` (one line added to
  ui/uimanager.lua). We now have the old picture and the new picture.
* We flash ONE frame of dots over the changed area with the fast
  black-and-white "a2" refresh, put the real new picture back, and let
  KOReader's refresh run, made a flashing one so it wipes the specks that
  a2 leaves behind. So every transition is: dots, then the clean picture.

Settings > Pixel theme > Halftone transitions switches each group on or off.
]]

local Device = require("device")
local Blitbuffer = require("ffi/blitbuffer")
local ffi = require("ffi")
local logger = require("logger")
local time = require("ui/time")
local Screen = Device.screen

local floor, sqrt, min, max = math.floor, math.sqrt, math.min, math.max

local Transition = {
    installed = false,
    pending = nil,
    playing = false,
    MAX_AGE_S = 4,    -- forget a mark if nothing got painted after it
}

local function setting(key)
    return G_reader_settings == nil or G_reader_settings:nilOrTrue(key)
end

function Transition.enabled(group)
    local Theme = require("pixel/theme")
    if not Theme.active then return false end
    if group == "page" then return setting("pixel_transitions_pages") end
    return setting("pixel_transitions")
end

---------------------------------------------------------------------------
-- Marking: remember what the screen looks like before a change.
---------------------------------------------------------------------------

--- kind: "in" | "out" | "swap". group: "ui" | "page".
function Transition.mark(kind, group)
    group = group or "ui"
    if Transition.playing or not Transition.enabled(group) then return end
    if Device.screen_saver_mode then return end
    local UIManager = require("ui/uimanager")
    if not Transition.painted then return end -- nothing on screen yet
    if UIManager:getSuspendRepaints() then return end

    local p = Transition.pending
    if p and time.to_s(time.now() - p.at) < Transition.MAX_AGE_S then
        -- Several changes before one repaint (close one popup, open another):
        -- keep the oldest picture, and play it as one swap.
        if p.kind ~= kind then p.kind = "swap" end
        return
    end
    if p then Transition.drop() end
    local ok, snap = pcall(function() return Screen.bb:copy() end)
    if not ok or not snap then return end
    Transition.pending = {
        kind = kind,
        snap = snap,
        at = time.now(),
    }
end

function Transition.drop()
    local p = Transition.pending
    Transition.pending = nil
    if p and p.snap then p.snap:free() end
end

---------------------------------------------------------------------------
-- The dots
---------------------------------------------------------------------------

local u8p = ffi.typeof("uint8_t*")

-- A plain 8-bit grey copy of one screen rectangle (no rotation, no inversion).
local function grab(src, x, y, w, h)
    local bb = Blitbuffer.new(w, h, Blitbuffer.TYPE_BB8)
    bb:blitFrom(src, 0, 0, x, y, w, h)
    return bb
end

-- Dot cell size in device pixels: 16 on the 615 px wide design, so 32 on a Paperwhite.
local function cellSize()
    return max(4, floor(16 * min(Screen:getWidth(), Screen:getHeight()) / 615 + 0.5))
end

-- One halftone frame of `new`: every changed cell becomes one black dot, as big as
-- the cell is dark. Cells that did not change (a header that stays put) are copied
-- as they are. Each cell is read on a sparse grid (every 3rd pixel), so this is quick.
local function drawDots(frame, new, old, c)
    local w, h = new.w, new.h
    local fd, fs = ffi.cast(u8p, frame.data), frame.stride
    local nd, ns = ffi.cast(u8p, new.data), new.stride
    local od, os = ffi.cast(u8p, old.data), old.stride
    local half = c / 2
    for y0 = 0, h - 1, c do
        local bh = min(c, h - y0)
        for x0 = 0, w - 1, c do
            local bw = min(c, w - x0)
            local sum, n, changed = 0, 0, false
            for yy = y0 + 1, y0 + bh - 1, 3 do
                local nr, orow = nd + yy * ns, od + yy * os
                for xx = x0 + 1, x0 + bw - 1, 3 do
                    local v = nr[xx]
                    sum = sum + v
                    n = n + 1
                    local d = v - orow[xx]
                    if d > 12 or d < -12 then changed = true end
                end
            end
            if not changed or n == 0 then
                for yy = y0, y0 + bh - 1 do
                    ffi.copy(fd + yy * fs + x0, nd + yy * ns + x0, bw)
                end
            else
                local dark = 1 - sum / n / 255
                local rr = c * 0.72 * sqrt(dark)
                local r2 = rr * rr
                local mx, my = x0 + half, y0 + half
                for yy = y0, y0 + bh - 1 do
                    local row = fd + yy * fs
                    ffi.fill(row + x0, bw, 255)
                    local dy = yy + 0.5 - my
                    local span2 = r2 - dy * dy
                    if span2 > 0 then
                        local sp = sqrt(span2)
                        local xs = max(x0, floor(mx - sp + 0.5))
                        local xe = min(x0 + bw, floor(mx + sp + 0.5))
                        if xe > xs then ffi.fill(row + xs, xe - xs, 0) end
                    end
                end
            end
        end
    end
end

---------------------------------------------------------------------------
-- Playing it
---------------------------------------------------------------------------

-- One frame of dots with the fast "a2" refresh, then the real picture goes back
-- into the buffer. We don't wait for the panel: UIManager's flashing refresh that
-- follows is queued behind the dots, so the dots show and then get wiped clean.
local function play(p, x, y, w, h)
    local old = grab(p.snap, x, y, w, h)
    local new = grab(Screen.bb, x, y, w, h)
    local frame = Blitbuffer.new(w, h, Blitbuffer.TYPE_BB8)
    drawDots(frame, new, old, cellSize())
    Screen.bb:blitFrom(frame, x, y, 0, 0, w, h)
    Screen:refreshA2(x, y, w, h)
    Screen.bb:blitFrom(new, x, y, 0, 0, w, h)
    old:free(); new:free(); frame:free()
end

--- Called by UIManager:_repaint() after painting, before refreshing.
function Transition.beforeRefresh(refresh_stack)
    Transition.painted = true
    local p = Transition.pending
    if not p then return end
    Transition.pending = nil
    if Transition.playing or Device.screen_saver_mode then p.snap:free() return end
    if time.to_s(time.now() - p.at) > Transition.MAX_AGE_S then p.snap:free() return end

    -- The area to animate: everything about to be refreshed.
    local region
    for _, r in ipairs(refresh_stack) do
        region = region and region:combine(r.region) or r.region:copy()
    end
    local sw, sh = Screen:getWidth(), Screen:getHeight()
    if region then
        local x0, y0 = max(0, floor(region.x)), max(0, floor(region.y))
        local x1 = min(sw, floor(region.x + region.w + 0.5))
        local y1 = min(sh, floor(region.y + region.h + 0.5))
        local w, h = x1 - x0, y1 - y0
        -- Skip tiny changes (a clock, a highlight): only real screen changes get dots.
        if w > 0 and h > 0 and w * h >= sw * sh * 0.03 then
            Transition.playing = true
            local ok, err = pcall(play, p, x0, y0, w, h)
            Transition.playing = false
            if not ok then logger.warn("Pixel transition failed:", err) end
            -- The fast black-and-white frames leave specks behind; a flashing
            -- refresh of the same area wipes them, so the end picture is clean.
            for _, r in ipairs(refresh_stack) do
                if not r.mode:find("flash") and r.mode ~= "full" then r.mode = "flashui" end
            end
        end
    end
    p.snap:free()
end

---------------------------------------------------------------------------
-- Hooks: what counts as a transition
---------------------------------------------------------------------------

-- While a book is opening, its "Opening file" message comes and goes without dots,
-- so only the swap from library to book plays.
function Transition.isQuiet()
    return Transition.quiet_until ~= nil and time.now() < Transition.quiet_until
end

local function skipWidget(w)
    if type(w) ~= "table" then return true end
    return w.toast or w.invisible or w.name == "ScreenSaver" or w.name == "ScreenSaverLock"
        or w.pixel_no_transition
end

function Transition.install()
    if Transition.installed then return end
    Transition.installed = true
    local UIManager = require("ui/uimanager")
    UIManager.beforeRefreshHook = Transition.beforeRefresh

    -- Popups and screens opening/closing
    local orig_show, orig_close = UIManager.show, UIManager.close
    function UIManager:show(widget, ...)
        if widget and widget.covers_fullscreen then Transition.quiet_until = nil end
        if not skipWidget(widget) and not (Transition.isQuiet() and not widget.covers_fullscreen) then
            Transition.mark(widget.covers_fullscreen and "swap" or "in")
        end
        return orig_show(self, widget, ...)
    end
    function UIManager:close(widget, ...)
        -- (while a book opens, the library closing is part of the one library -> book swap)
        if not skipWidget(widget) and not Transition.isQuiet() and self:isWidgetShown(widget) then
            Transition.mark(widget.covers_fullscreen and "swap" or "out")
        end
        return orig_close(self, widget, ...)
    end

    -- Lists (library, TOC, bookmarks, file browser): changing page
    local Menu = require("ui/widget/menu")
    local orig_goto = Menu.onGotoPage
    function Menu:onGotoPage(page)
        if page ~= self.page then Transition.mark("swap") end
        return orig_goto(self, page)
    end
    local FileChooser = require("ui/widget/filechooser")
    local orig_cd = FileChooser.changeToPath
    function FileChooser:changeToPath(path, ...)
        if path ~= self.path then Transition.mark("swap") end
        return orig_cd(self, path, ...)
    end

    -- The top menu: tabs, sub-menus, back, pages
    local TouchMenu = require("ui/widget/touchmenu")
    local orig_tab, orig_back = TouchMenu.switchMenuTab, TouchMenu.backToUpperMenu
    local orig_next, orig_prev, orig_sel = TouchMenu.onNextPage, TouchMenu.onPrevPage, TouchMenu.onMenuSelect
    function TouchMenu:switchMenuTab(tab_num, ...)
        if tab_num ~= self.cur_tab then Transition.mark("swap") end
        return orig_tab(self, tab_num, ...)
    end
    function TouchMenu:backToUpperMenu(...)
        if self.item_table_stack and #self.item_table_stack > 0 then Transition.mark("swap") end
        return orig_back(self, ...)
    end
    function TouchMenu:onNextPage(...)
        if (self.page_num or 1) > 1 then Transition.mark("swap") end
        return orig_next(self, ...)
    end
    function TouchMenu:onPrevPage(...)
        if (self.page_num or 1) > 1 then Transition.mark("swap") end
        return orig_prev(self, ...)
    end
    function TouchMenu:onMenuSelect(item, tap_on_checkmark, ...)
        if not tap_on_checkmark and (item.sub_item_table or item.sub_item_table_func) then
            Transition.mark("swap")
        end
        return orig_sel(self, item, tap_on_checkmark, ...)
    end

    local ReaderUI = require("apps/reader/readerui")
    local orig_open = ReaderUI.showReader
    function ReaderUI:showReader(...)
        Transition.quiet_until = time.now() + time.s(8)
        return orig_open(self, ...)
    end

    -- Turning pages in a book
    local ReaderRolling = require("apps/reader/modules/readerrolling")
    local orig_roll = ReaderRolling.onGotoViewRel
    function ReaderRolling:onGotoViewRel(...)
        Transition.mark("swap", "page")
        return orig_roll(self, ...)
    end
    local ReaderPaging = require("apps/reader/modules/readerpaging")
    local orig_pview, orig_prel = ReaderPaging.onGotoViewRel, ReaderPaging.onGotoPageRel
    function ReaderPaging:onGotoViewRel(...)
        Transition.mark("swap", "page")
        return orig_pview(self, ...)
    end
    function ReaderPaging:onGotoPageRel(...)
        Transition.mark("swap", "page")
        return orig_prel(self, ...)
    end
end

return Transition

--[[--
Halftone transitions: things break into ink dots when they leave the screen
and build back up from dots when they arrive (like the Pixel sleep screen).

How it works
* Something is about to change the screen (a popup opens or closes, a page
  turns, a menu changes page). We copy the screen as it is now (`mark`).
* KOReader paints the new state into the screen buffer as usual. Just before
  it refreshes the e-ink, UIManager calls `beforeRefresh` (one line added to
  ui/uimanager.lua). We now have the old picture and the new picture.
* We play a few frames of dots over the changed area with the fast
  black-and-white "a2" refresh, put the real new picture back, and let
  KOReader's normal refresh run. That last refresh brings the greys back and
  cleans up any ghosting.

Kinds
* "in"   a popup opens: the popup forms out of dots over the page.
* "out"  a popup closes: the popup breaks into dots over the page.
* "swap" the whole thing changes (page turn, menu page, full-screen screen):
         the old picture dots away, the new one dots in.

Settings > Pixel theme > Halftone transitions switches each group on or off.
]]

local Device = require("device")
local Blitbuffer = require("ffi/blitbuffer")
local ffi = require("ffi")
local ffiUtil = require("ffi/util")
local logger = require("logger")
local time = require("ui/time")
local Screen = Device.screen

local bit = require("bit")
local band, bxor, rshift, tobit = bit.band, bit.bxor, bit.rshift, bit.tobit
local floor, sqrt, min, max = math.floor, math.sqrt, math.min, math.max

local Transition = {
    installed = false,
    pending = nil,
    playing = false,
    FRAME_S = 0.09,   -- shortest time a frame stays up (the e-ink is usually slower anyway)
    POPUP_STEPS = 5,  -- 4 dot frames for a popup opening or closing
    SWAP_STEPS = 4,   -- 3 out + 3 in when a screen or menu page changes
    PAGE_STEPS = 2,   -- page turns: ONE dot frame of the new page, then the clean page
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
        if p.kind ~= kind then
            p.kind = "swap"
            if p.steps == Transition.POPUP_STEPS then p.steps = Transition.SWAP_STEPS end
        end
        if group == "page" then p.steps = Transition.PAGE_STEPS; p.page = true end
        return
    end
    if p then Transition.drop() end
    local ok, snap = pcall(function() return Screen.bb:copy() end)
    if not ok or not snap then return end
    Transition.pending = {
        kind = kind,
        snap = snap,
        at = time.now(),
        page = group == "page",
        steps = group == "page" and Transition.PAGE_STEPS
            or (kind == "swap" and Transition.SWAP_STEPS or Transition.POPUP_STEPS),
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

local function rnd(a, b, s)
    local h = bxor(tobit(a * 374761393), tobit(b * 668265263), tobit(s * 1442695041))
    h = bxor(h, rshift(h, 13))
    h = tobit(h * 1274126177)
    h = bxor(h, rshift(h, 16))
    return band(h, 0xFFFFFF) / 16777216
end

local u8p = ffi.typeof("uint8_t*")

-- A plain 8-bit grey copy of one screen rectangle (no rotation, no inversion).
local function grab(src, x, y, w, h)
    local bb = Blitbuffer.new(w, h, Blitbuffer.TYPE_BB8)
    bb:blitFrom(src, 0, 0, x, y, w, h)
    return bb
end

-- Summed-area table of a grey buffer, so any cell's average is 4 lookups.
local function summed(bb)
    local w, h = bb.w, bb.h
    local w1 = w + 1
    local sat = ffi.new("uint32_t[?]", w1 * (h + 1))
    local data, stride = ffi.cast(u8p, bb.data), bb.stride
    for y = 0, h - 1 do
        local row, src, o1, o0 = 0, data + y * stride, (y + 1) * w1, y * w1
        for x = 0, w - 1 do
            row = row + src[x]
            sat[o1 + x + 1] = sat[o0 + x + 1] + row
        end
    end
    return { sat = sat, w = w, h = h, w1 = w1 }
end

-- Summed table of "this pixel changed", so unchanged parts (a header that
-- stays put) are left alone instead of turning into dots.
local function summedDiff(a, b)
    local w, h = a.w, a.h
    local w1 = w + 1
    local sat = ffi.new("uint32_t[?]", w1 * (h + 1))
    local da, db, sa, sb = ffi.cast(u8p, a.data), ffi.cast(u8p, b.data), a.stride, b.stride
    for y = 0, h - 1 do
        local row, pa, pb, o1, o0 = 0, da + y * sa, db + y * sb, (y + 1) * w1, y * w1
        for x = 0, w - 1 do
            local d = pa[x] - pb[x]
            if d > 12 or d < -12 then row = row + 1 end
            sat[o1 + x + 1] = sat[o0 + x + 1] + row
        end
    end
    return { sat = sat, w = w, h = h, w1 = w1 }
end

-- Both tables in one pass over the screen (summed of `a`, and "changed vs b").
local function summedWithDiff(a, b)
    local w, h = a.w, a.h
    local w1 = w + 1
    local sat = ffi.new("uint32_t[?]", w1 * (h + 1))
    local dif = ffi.new("uint32_t[?]", w1 * (h + 1))
    local da, db, sa, sb = ffi.cast(u8p, a.data), ffi.cast(u8p, b.data), a.stride, b.stride
    for y = 0, h - 1 do
        local row, drow, pa, pb, o1, o0 = 0, 0, da + y * sa, db + y * sb, (y + 1) * w1, y * w1
        for x = 0, w - 1 do
            local va = pa[x]
            local d = va - pb[x]
            row = row + va
            if d > 12 or d < -12 then drow = drow + 1 end
            sat[o1 + x + 1] = sat[o0 + x + 1] + row
            dif[o1 + x + 1] = dif[o0 + x + 1] + drow
        end
    end
    return { sat = sat, w = w, h = h, w1 = w1 }, { sat = dif, w = w, h = h, w1 = w1 }
end

local function cellAverage(S, x0, y0, x1, y1)
    local s, w1 = S.sat, S.w1
    return (s[y1 * w1 + x1] - s[y0 * w1 + x1] - s[y1 * w1 + x0] + s[y0 * w1 + x0]) / ((x1 - x0) * (y1 - y0))
end

-- Cell sizes in device pixels, from the 615 px wide design (x2 on a Paperwhite).
local function cellSizes()
    local s = min(Screen:getWidth(), Screen:getHeight()) / 615
    local out = {}
    for i, v in ipairs({ 3, 4, 6, 8, 12 }) do out[i] = max(2, floor(v * s + 0.5)) end
    return out
end

local function snap(v, list)
    local best, d = list[1], math.huge
    for _, x in ipairs(list) do
        local e = math.abs(x - v)
        if e < d then d, best = e, x end
    end
    return best
end

--[[ Draw the element (`S` = its summed table) as halftone dots into `frame`.
`p` is how present it is: 1 = sharp, 0 = gone. Cells that are gone keep
whatever `frame` already holds (the background). Same maths as the demo page. ]]
local function drawDots(frame, S, p, seed, sizes, D, keep)
    local q = 1 - p
    local c = snap(sizes[1] * 2 ^ (min(q / 0.6, 1) * 2), sizes)
    local k = q <= 0.6 and 1 or 1 - (q - 0.6) / 0.4
    local data, stride = ffi.cast(u8p, frame.data), frame.stride
    local kdata, kstride = ffi.cast(u8p, keep.data), keep.stride
    local w, h = S.w, S.h
    local half = c / 2
    local cy = 0
    for y0 = 0, h - 1, c do
        local bh = min(c, h - y0)
        local cx = 0
        for x0 = 0, w - 1, c do
            local bw = min(c, w - x0)
            local d = 1 - cellAverage(S, x0, y0, x0 + bw, y0 + bh) / 255
            local s1, w1 = D.sat, D.w1
            local changed = s1[(y0 + bh) * w1 + x0 + bw] - s1[y0 * w1 + x0 + bw] - s1[(y0 + bh) * w1 + x0] + s1[y0 * w1 + x0] > 0
            if not changed then
                for yy = 0, bh - 1 do
                    ffi.copy(data + (y0 + yy) * stride + x0, kdata + (y0 + yy) * kstride + x0, bw)
                end
            elseif rnd(cx, cy, seed) * 0.6 + (1 - d) * 0.4 < k then
                local rr = c * 0.72 * sqrt(d) * (0.55 + 0.45 * k)
                local r2 = rr * rr
                local mx = x0 + half
                local my = y0 + half
                for yy = 0, bh - 1 do
                    local row = data + (y0 + yy) * stride
                    ffi.fill(row + x0, bw, 255)
                    local dy = y0 + yy + 0.5 - my
                    local span2 = r2 - dy * dy
                    if span2 > 0 then
                        local sp = sqrt(span2)
                        local xs = max(x0, floor(mx - sp + 0.5))
                        local xe = min(x0 + bw, floor(mx + sp + 0.5))
                        if xe > xs then ffi.fill(row + xs, xe - xs, 0) end
                    end
                end
            end
            cx = cx + 1
        end
        cy = cy + 1
    end
end

---------------------------------------------------------------------------
-- Playing it
---------------------------------------------------------------------------

local function showFrame(frame, x, y, w, h, last_at)
    Screen.bb:blitFrom(frame, x, y, 0, 0, w, h)
    Screen:refreshA2(x, y, w, h)
    Screen:refreshWaitForLast()
    local spent = time.to_s(time.now() - last_at)
    if spent < Transition.FRAME_S then ffiUtil.usleep(floor((Transition.FRAME_S - spent) * 1e6)) end
    return time.now()
end

local function play(p, x, y, w, h)
    local sizes = cellSizes()
    local old = grab(p.snap, x, y, w, h)
    local new = grab(Screen.bb, x, y, w, h)
    local frame = Blitbuffer.new(w, h, Blitbuffer.TYPE_BB8)
    local K = p.steps
    local seed = floor(time.to_ms(time.now())) % 9973
    local at = time.now()
    if p.page then
        -- Page turns: one frame of the new page as dots, nothing else.
        local S, D = summedWithDiff(new, old)
        Screen:refreshWaitForLast()
        frame:fill(Blitbuffer.COLOR_WHITE)
        drawDots(frame, S, 0.5, seed, sizes, D, new)
        showFrame(frame, x, y, w, h, at)
        Screen.bb:blitFrom(new, x, y, 0, 0, w, h)
        old:free(); new:free(); frame:free()
        return
    end
    local D = summedDiff(old, new)
    Screen:refreshWaitForLast()

    local function frames(el, bg, from_p, to_p, dir)
        local S = summed(el)
        for i = from_p, to_p, dir do
            if bg then frame:blitFrom(bg, 0, 0, 0, 0, w, h) else frame:fill(Blitbuffer.COLOR_WHITE) end
            drawDots(frame, S, i / K, seed, sizes, D, new)
            at = showFrame(frame, x, y, w, h, at)
        end
    end

    if p.kind == "in" then
        frames(new, old, 1, K - 1, 1)          -- the popup forms over the page
    elseif p.kind == "out" then
        frames(old, new, K - 1, 1, -1)         -- the popup breaks up over the page
    else
        frames(old, nil, K - 1, 1, -1)         -- old picture dots away...
        frames(new, nil, 1, K - 1, 1)          -- ...new one dots in
    end

    -- Put the real picture back; UIManager's own refresh shows it next.
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

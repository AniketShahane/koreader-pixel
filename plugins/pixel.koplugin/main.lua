--[[--
Pixel theme plugin: connects the Pixel modules (frontend/pixel/) to the
reader and adds a "Pixel theme" menu at the top of Settings.

In the reader it:
* adds the title/chapter header and the PG / chapter-squares / MIN footer;
* makes long-pressing a word open the Claude "Explain" box (instead of the
  dictionary; the box has a DICT button for the dictionary);
* adds "Explain" to the menu you get after selecting several words;
* opens the Pixel OPTIONS menu when you tap the bottom of the page.

The library and sleep screen are themed by the core hooks, not here.
]]

local DataStorage = require("datastorage")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local LuaSettings = require("luasettings")
local NetworkMgr = require("ui/network/manager")
local Theme = require("pixel/theme")
local Trapper = require("ui/trapper")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger = require("logger")
local util = require("util")
local _ = require("gettext")
local T = require("ffi/util").template
local Screen = require("device").screen

local Pixel = WidgetContainer:extend{
    name = "pixel",
    is_doc_only = false,
}

---------------------------------------------------------------------------
-- Saved explanations: the same word in the same book is free and instant
-- the second time (and works offline).
---------------------------------------------------------------------------

local Cache = {}
local CACHE_MAX = 500

function Cache.open()
    if not Cache.store then
        Cache.store = LuaSettings:open(DataStorage:getSettingsDir() .. "/pixel_explanations.lua")
    end
    return Cache.store
end

local function cacheKey(req)
    -- "v2": bump when the prompt changes, so old answers aren't reused
    return table.concat({ "v2", req.title or "", (req.word or ""):lower(), (req.related_to or ""):lower() }, "\31")
end

function Cache.get(req)
    local e = Cache.open():readSetting(cacheKey(req))
    return e and e.result
end

function Cache.put(req, result)
    local store = Cache.open()
    store:saveSetting(cacheKey(req), { t = os.time(), result = result })
    local n, oldest_k, oldest_t = 0, nil, math.huge
    for k, v in pairs(store.data) do
        n = n + 1
        if type(v) == "table" and (v.t or 0) < oldest_t then oldest_k, oldest_t = k, v.t or 0 end
    end
    if n > CACHE_MAX and oldest_k then store:delSetting(oldest_k) end
    store:flush()
end

function Cache.clear()
    local store = Cache.open()
    store.data = {}
    store:flush()
end

---------------------------------------------------------------------------

function Pixel:init()
    self.ui.menu:registerToMainMenu(self)
    if Theme.active and self.ui.document then
        self:initReader()
    end
end

function Pixel:initReader()
    local ui = self.ui
    local ReaderChrome = require("pixel/reader")
    ui.view:registerViewModule("pixel_header", ReaderChrome.Header:new{ ui = ui })
    ReaderChrome.installFooter(ui.view.footer)
    ui.view.highlight.temp_drawer = "invert" -- selected word: white on black, like the mock-up

    local hl = ui.highlight
    if hl then
        local orig_lookup = hl.lookupDictWord
        self.orig_lookup = orig_lookup
        hl.lookupDictWord = function(this)
            local text = this.selected_text and this.selected_text.text
            -- Single words go to the dictionary unless the user turned this on
            if G_reader_settings:isTrue("pixel_explain_on_hold") and text and text ~= "" then
                return self:explainSelection(this)
            end
            return orig_lookup(this)
        end
        -- First button in the menu shown after selecting several words
        hl:addToHighlightDialog("00_pixel_explain", function(this)
            return {
                text = _("Explain with Claude"),
                callback = function() self:explainSelection(this, true) end,
            }
        end)
    end

    -- "ASK CLAUDE" in the dictionary popup, for when the dictionary misses
    -- the sense the book means (e.g. "hypos" in Moby-Dick isn't photography)
    if ui.dictionary and ui.dictionary.addToDictButtons then
        ui.dictionary:addToDictButtons({
            id = "pixel_ask_claude",
            menu_text = _("Ask Claude (Pixel theme)"),
            text = _("Ask Claude"),
            insert_first = true,
            show_func = function() return ui.document ~= nil end,
            callback = function(popup)
                local h = ui.highlight
                if h and h.selected_text and h.selected_text.text and h.selected_text.text ~= "" then
                    popup:onClose(true) -- keep the selection; Explain clears it when done
                    self:explainSelection(h)
                else
                    -- typed lookup, no selection in the book: explain the word alone
                    local word = popup.lookupword or popup.word
                    popup:onClose()
                    if word and word ~= "" then
                        local props = ui.doc_props or {}
                        self:runExplain({ word = word, title = props.display_title or props.title, author = props.authors },
                            false, nil, nil, nil)
                    end
                end
            end,
        })
    end

    local config = ui.config
    if config and ui.rolling then -- reflowable books (EPUB, FB2, TXT…); PDFs keep the stock panel
        local orig_show = config.onShowConfigMenu
        config.onShowConfigMenu = function(this)
            if G_reader_settings:nilOrTrue("pixel_options_menu") then
                return self:showOptions(function() orig_show(this) end)
            end
            return orig_show(this)
        end
    end
end

function Pixel:showOptions(open_stock_panel)
    local Options = require("pixel/options")
    require("pixel/reader").paused = true
    self.options_menu = Options:new{ ui = self.ui, on_more = open_stock_panel }
    UIManager:show(self.options_menu)
    UIManager:setDirty(self.ui.dialog, "ui")
    return true
end

---------------------------------------------------------------------------
-- Explain
---------------------------------------------------------------------------

function Pixel:explainSelection(hl, from_menu)
    local sel = hl.selected_text
    if not sel or not sel.text then return end
    local word = util.cleanupSelectedText(sel.text)
    local before, after = hl:getSelectedWordContext(40)

    -- Keep the box away from the word: if it's low on the page, use the top.
    local anchor_top = false
    local ok, box = pcall(function()
        return sel.sboxes and sel.sboxes[1] and hl.hold_pos
            and hl.view:pageToScreenTransform(hl.hold_pos.page, sel.sboxes[1])
    end)
    if not ok then box = nil end
    if box and box.y + box.h / 2 > Screen:getHeight() * 0.5 then
        anchor_top = true
    end

    if from_menu then
        hl:onClose(true) -- close the selection menu, keep the selection visible
    end

    -- The book engine marks selections in grey itself; swap that for the
    -- mock-up's white-on-black word.
    if self.ui.rolling and sel.sboxes and hl.hold_pos then
        pcall(function()
            self.ui.document:clearSelection()
            self.ui.view.highlight.temp = { [hl.hold_pos.page] = sel.sboxes }
            UIManager:setDirty(self.ui.dialog, "ui")
        end)
    end

    local props = self.ui.doc_props or {}
    local req = {
        word = word,
        before = before,
        after = after,
        title = props.display_title or props.title,
        author = props.authors,
    }
    self:runExplain(req, anchor_top, box, function(keep_selection)
        if not keep_selection then hl:clear() end
    end, function()
        if self.orig_lookup then self.orig_lookup(hl) end
    end)
end

function Pixel:runExplain(req, anchor_top, word_box, on_close, on_dictionary)
    local ExplainDialog = require("pixel/explain")
    local dialog
    dialog = ExplainDialog:new{
        word = req.word,
        anchor_top = anchor_top,
        word_box = word_box,
        on_close = function(keep)
            dialog.closed = true
            if on_close then on_close(keep) end
        end,
        on_dictionary = on_dictionary,
        on_related = function(word)
            self:fetch(dialog, {
                word = word, before = req.before, after = req.after,
                title = req.title, author = req.author, related_to = req.word,
            })
        end,
    }
    self.explain_box = dialog
    UIManager:show(dialog)
    self:fetch(dialog, req)
end

-- Don't leave our pop-ups behind when the book closes.
function Pixel:onCloseDocument()
    if self.explain_box and not self.explain_box.closed then
        self.explain_box:onClose()
    end
    self.explain_box = nil
    if self.options_menu then
        if UIManager:isWidgetShown(self.options_menu) then UIManager:close(self.options_menu) end
        require("pixel/reader").paused = false
        self.options_menu = nil
    end
end

function Pixel:fetch(dialog, req)
    local Claude = require("pixel/claude")
    if dialog.state ~= "loading" or dialog.word ~= req.word then
        dialog:setLoading(req.word)
    end
    local cached = Cache.get(req)
    if cached then
        dialog:setResult(cached)
        return
    end
    if not Claude.getKey() then
        dialog:setError("nokey")
        return
    end
    if not NetworkMgr:isOnline() and NetworkMgr:isConnected() then
        dialog:setError("Wi-Fi is on but there's no internet right now.")
        return
    end
    if not NetworkMgr:isOnline() then
        -- Ask to turn Wi-Fi on; if that doesn't happen, don't sit on THINKING.
        UIManager:scheduleIn(45, function()
            if not dialog.closed and dialog.state == "loading" and not dialog.dismiss_callback then
                dialog:setError("No connection. Turn on Wi-Fi and try again.")
            end
        end)
    end
    NetworkMgr:runWhenOnline(function()
        if dialog.closed then return end
        Trapper:wrap(function()
            local result, err = Claude.explain(req, dialog)
            dialog.dismiss_callback = nil
            if err == "cancelled" or dialog.closed then return end
            if result then
                Cache.put(req, result)
                dialog:setResult(result)
            else
                logger.warn("Pixel: explain failed:", err)
                dialog:setError(err)
            end
        end)
    end)
end

---------------------------------------------------------------------------
-- Menu
---------------------------------------------------------------------------

function Pixel:keyStatusText()
    local Claude = require("pixel/claude")
    local key, source = Claude.getKey()
    if not key then return _("Claude API key: not set") end
    local tail = key:sub(-4)
    local where = ({ env = _("from ANTHROPIC_API_KEY"), settings = _("saved"), file = _("from claude_api_key.txt") })[source]
    return _("Claude API key: …") .. tail .. " (" .. where .. ")"
end

function Pixel:editKey(touchmenu_instance)
    local dialog
    dialog = InputDialog:new{
        title = _("Claude API key"),
        input = G_reader_settings:readSetting("pixel_claude_api_key") or "",
        input_hint = "sk-ant-…",
        text_type = "password",
        description = _("Get a key at console.anthropic.com. Typing it is fiddly on a Kindle: you can instead copy a text file named claude_api_key.txt, containing just the key, into the koreader folder over USB."),
        buttons = {{
            { text = _("Cancel"), id = "close", callback = function() UIManager:close(dialog) end },
            { text = _("Remove"), callback = function()
                G_reader_settings:delSetting("pixel_claude_api_key")
                UIManager:close(dialog)
                if touchmenu_instance then touchmenu_instance:updateItems() end
            end },
            { text = _("Save"), is_enter_default = true, callback = function()
                local key = util.trim(dialog:getInputText() or "")
                if key ~= "" then G_reader_settings:saveSetting("pixel_claude_api_key", key) end
                UIManager:close(dialog)
                if touchmenu_instance then touchmenu_instance:updateItems() end
            end },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function Pixel:editDriveFolder(touchmenu_instance)
    local dialog
    dialog = InputDialog:new{
        title = _("Google Drive folder link"),
        description = _("Share the folder as \"Anyone with the link\", then paste its link (or ID). You can also put it in koreader/gdrive_folder.txt."),
        input = G_reader_settings:readSetting("pixel_gdrive_folder") or "",
        buttons = {{
            { text = _("Cancel"), id = "close", callback = function() UIManager:close(dialog) end },
            { text = _("Save"), is_enter_default = true, callback = function()
                local v = util.trim(dialog:getInputText() or "")
                if v == "" then
                    G_reader_settings:delSetting("pixel_gdrive_folder")
                elseif require("pixel/drive").parseFolderId(v) then
                    G_reader_settings:saveSetting("pixel_gdrive_folder", v)
                else
                    UIManager:show(InfoMessage:new{ text = _("That doesn't look like a Drive folder link.") })
                    return
                end
                UIManager:close(dialog)
                if touchmenu_instance then touchmenu_instance:updateItems() end
            end },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function Pixel:addToMainMenu(menu_items)
    local Claude = require("pixel/claude")
    local function toggle(key, after)
        return function(touchmenu_instance)
            G_reader_settings:flipNilOrTrue(key)
            if after then after(touchmenu_instance) end
        end
    end
    local function on(key) return function() return G_reader_settings:nilOrTrue(key) end end

    local model_items = {}
    for _i, m in ipairs(Claude.MODELS) do
        table.insert(model_items, {
            text = m.label,
            radio = true,
            checked_func = function() return Claude.getModel() == m.id end,
            callback = function() G_reader_settings:saveSetting("pixel_claude_model", m.id) end,
        })
    end

    menu_items.pixel_theme = {
        text = _("Pixel theme"),
        sub_item_table = {
            {
                text = _("Use the Pixel theme"),
                checked_func = function() return Theme.isEnabled() end,
                callback = function()
                    G_reader_settings:flipNilOrTrue("pixel_theme")
                    UIManager:askForRestart(_("Restart KOReader to switch the theme."))
                end,
                separator = true,
            },
            {
                text = _("Explain with Claude"),
                sub_item_table = {
                    {
                        text_func = function() return self:keyStatusText() end,
                        keep_menu_open = true,
                        callback = function(touchmenu_instance) self:editKey(touchmenu_instance) end,
                    },
                    {
                        text_func = function()
                            for _i, m in ipairs(Claude.MODELS) do
                                if m.id == Claude.getModel() then return _("Model: ") .. m.label end
                            end
                            return _("Model")
                        end,
                        sub_item_table = model_items,
                    },
                    {
                        text = _("Use Claude for single words too"),
                        help_text = _("Off (default): long-pressing one word opens the dictionary, and Claude explains phrases (select several words, then Explain with Claude). On: long-pressing one word asks Claude too."),
                        checked_func = function() return G_reader_settings:isTrue("pixel_explain_on_hold") end,
                        callback = function() G_reader_settings:flipNilOrFalse("pixel_explain_on_hold") end,
                    },
                    {
                        text = _("Forget saved explanations"),
                        keep_menu_open = true,
                        callback = function()
                            Cache.clear()
                            UIManager:show(InfoMessage:new{ text = _("Saved explanations cleared."), timeout = 2 })
                        end,
                    },
                },
            },
            {
                text = _("Google Drive sync"),
                sub_item_table = {
                    {
                        text = _("Sync now"),
                        callback = function() require("pixel/drive").syncInteractive(self.ui.file_chooser and self.ui or nil) end,
                    },
                    {
                        text_func = function()
                            local id = require("pixel/drive").getFolderId()
                            return id and T(_("Folder: %1…"), id:sub(1, 10)) or _("Folder link: not set")
                        end,
                        keep_menu_open = true,
                        callback = function(touchmenu_instance) self:editDriveFolder(touchmenu_instance) end,
                    },
                },
            },
            {
                text = _("Header with title and chapter"),
                checked_func = on("pixel_reader_header"),
                callback = toggle("pixel_reader_header", function()
                    if self.ui.document then UIManager:setDirty(self.ui.dialog, "full") end
                end),
            },
            {
                text = _("Pixel OPTIONS menu at the bottom"),
                help_text = _("Tapping the bottom of the page opens the Pixel OPTIONS menu. It has an ALL SETTINGS button for the full panel."),
                checked_func = on("pixel_options_menu"),
                callback = toggle("pixel_options_menu"),
            },
            {
                text = _("Pixel sleep screen"),
                checked_func = function() return G_reader_settings:readSetting("screensaver_type") == "pixel" end,
                callback = function()
                    if G_reader_settings:readSetting("screensaver_type") == "pixel" then
                        G_reader_settings:saveSetting("screensaver_type", "cover")
                    else
                        G_reader_settings:saveSetting("screensaver_type", "pixel")
                    end
                end,
            },
        },
    }
end

return Pixel

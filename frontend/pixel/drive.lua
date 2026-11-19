--[[--
Google Drive sync: download new books from one shared Drive folder.

Setup (once):
* In Google Drive, share the folder as "Anyone with the link: Viewer".
* Put the folder's link (or just its ID) in `koreader/gdrive_folder.txt`,
  or in Settings > Pixel theme > Google Drive sync > Folder link.
* Google Docs and Slides in the folder are exported (Docs as EPUB, Slides as PDF).
* Links saved with "Save to Drive" (a text file holding just a URL) become an
  EPUB of that web page.
* Optional: a Google API key in `koreader/google_api_key.txt` makes listing
  use the official Drive API. Without one, the public folder page is read.

SYNC (library bar) lists the folder and downloads every book that isn't on
the Kindle yet into the home folder. It never deletes or overwrites anything.
]]

local DataStorage = require("datastorage")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local util = require("util")

local http = require("socket.http")
local ltn12 = require("ltn12")
local socket = require("socket")
local socketutil = require("socketutil")
require("ssl.https")

local Drive = {}

-- Fallback list, used only if KOReader's document registry can't be loaded.
-- Normally any file KOReader can open is downloaded (see isBook).
Drive.BOOK_EXTS = {
    epub = true, epub3 = true, pdf = true, mobi = true, azw = true, prc = true, pdb = true,
    fb2 = true, fb3 = true, djvu = true, djv = true, cbz = true, cbr = true, cbt = true, chm = true,
    txt = true, md = true, rtf = true, doc = true, docx = true, docm = true, odt = true,
    html = true, htm = true, xhtml = true, htmlz = true, xps = true, oxps = true, pptx = true,
    jpg = true, jpeg = true, png = true, gif = true, webp = true, tif = true, tiff = true, svg = true,
}

-- Google Docs and Slides have no file to download: Drive exports them.
-- Docs become EPUB (reflowable, like a book), Slides become PDF.
-- https://developers.google.com/drive/api/guides/ref-export-formats
Drive.GOOGLE_EXPORTS = {
    document = { mime = "application/epub+zip", ext = "epub", url = "https://docs.google.com/document/d/%s/export?format=epub" },
    presentation = { mime = "application/pdf", ext = "pdf", url = "https://docs.google.com/presentation/d/%s/export/pdf" },
}
local GOOGLE_MIME_KIND = {
    ["application/vnd.google-apps.document"] = "document",
    ["application/vnd.google-apps.presentation"] = "presentation",
}

local function readFirstLine(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local l = f:read("*l")
    f:close()
    l = l and util.trim(l)
    return l ~= "" and l or nil
end

--- Pull the folder ID out of a Drive link, or return an ID as is.
function Drive.parseFolderId(s)
    if type(s) ~= "string" then return nil end
    s = util.trim(s)
    local id = s:match("/folders/([%w_%-]+)") or s:match("[?&]id=([%w_%-]+)")
    if not id and s:match("^[%w_%-]+$") and #s >= 10 then id = s end
    return id
end

function Drive.folderFile() return DataStorage:getDataDir() .. "/gdrive_folder.txt" end
function Drive.keyFile() return DataStorage:getDataDir() .. "/google_api_key.txt" end

function Drive.getFolderId()
    local s = G_reader_settings and G_reader_settings:readSetting("pixel_gdrive_folder")
    return Drive.parseFolderId(s) or Drive.parseFolderId(readFirstLine(Drive.folderFile()))
end

function Drive.getKey()
    return readFirstLine(Drive.keyFile())
end

function Drive.targetDir()
    local dir = G_reader_settings and G_reader_settings:readSetting("home_dir")
    if not dir or dir == "" then
        local Device = require("device")
        dir = Device.home_dir or DataStorage:getDataDir()
    end
    return dir
end

-- GET a URL, following redirects by hand (Google bounces downloads between hosts).
-- With `sink_file` the body goes to that open file; otherwise it is returned.
local function get(url, sink_file, depth)
    depth = depth or 0
    if depth > 6 then return nil, "too many redirects" end
    local body = {}
    socketutil:set_timeout(15, 120)
    local code, headers, status = socket.skip(1, http.request{
        url = url,
        method = "GET",
        redirect = false,
        headers = { ["user-agent"] = "KOReader-Pixel" },
        sink = sink_file and ltn12.sink.file(sink_file, nil) or socketutil.table_sink(body),
    })
    socketutil:reset_timeout()
    if headers == nil then return nil, tostring(status or code or "network unreachable") end
    if code == 301 or code == 302 or code == 303 or code == 307 or code == 308 then
        local loc = headers.location or headers.Location
        if not loc then return nil, "redirect without location" end
        if loc:sub(1, 1) == "/" then loc = url:match("^(https?://[^/]+)") .. loc end
        -- the redirect reply body (if any) went into the sink; for files we reopen below
        return code, loc
    end
    return code, sink_file and "" or table.concat(body)
end

local function urlencode(s)
    return (s:gsub("[^%w%-_%.~]", function(c) return string.format("%%%02X", string.byte(c)) end))
end

local function htmlUnescape(s)
    s = s:gsub("&#(%d+);", function(n) n = tonumber(n); return n and n < 256 and string.char(n) or "" end)
    s = s:gsub("&#x(%x+);", function(n) n = tonumber(n, 16); return n and n < 256 and string.char(n) or "" end)
    return (s:gsub("&quot;", '"'):gsub("&#39;", "'"):gsub("&lt;", "<"):gsub("&gt;", ">"):gsub("&amp;", "&"))
end

local function getFollow(url)
    for _ = 1, 6 do
        local code, body = get(url)
        if code == nil then return nil, body end
        if code >= 300 and code < 400 then url = body else return code, body end
    end
    return nil, "too many redirects"
end

--- List the folder. Returns { {id=, name=, size=}, ... } or nil, err.
function Drive.list(folder_id, key)
    local files = {}
    if key then
        local q = urlencode("'" .. folder_id .. "' in parents and trashed = false")
        local page
        repeat
            local url = "https://www.googleapis.com/drive/v3/files?q=" .. q
                .. "&fields=" .. urlencode("nextPageToken,files(id,name,size,mimeType)")
                .. "&pageSize=1000&supportsAllDrives=true&includeItemsFromAllDrives=true&key=" .. urlencode(key)
                .. (page and ("&pageToken=" .. urlencode(page)) or "")
            local code, body = getFollow(url)
            if code ~= 200 then
                return nil, code and ("Drive API error " .. code) or body
            end
            local ok, data = pcall(require("rapidjson").decode, body)
            if not ok or type(data) ~= "table" then return nil, "bad reply from Drive" end
            for _, f in ipairs(data.files or {}) do
                if f.mimeType ~= "application/vnd.google-apps.folder" then
                    table.insert(files, { id = f.id, name = f.name, size = tonumber(f.size),
                        mime = f.mimeType, google = GOOGLE_MIME_KIND[f.mimeType] })
                end
            end
            page = data.nextPageToken
        until not page
        return files
    end
    -- No key: read the public folder page.
    local code, body = getFollow("https://drive.google.com/embeddedfolderview?id=" .. folder_id .. "#list")
    if code ~= 200 then
        if code == 404 or code == 403 or code == 401 then
            return nil, "folder not found or not shared"
        end
        return nil, code and ("Drive error " .. code) or body
    end
    -- Each item: <div class="flip-entry" id="entry-ID"> <a href=".../file/d/ID/..."> ...
    -- <div class="flip-entry-title">NAME</div>. Cut the page at each entry start.
    local starts = {}
    for pos, id in body:gmatch('()id="entry%-([%w_%-]+)"') do
        table.insert(starts, { pos = pos, id = id })
    end
    for i, s in ipairs(starts) do
        local chunk = body:sub(s.pos, starts[i + 1] and starts[i + 1].pos - 1 or #body)
        local name = chunk:match('class="flip%-entry%-title"[^>]*>(.-)</div>')
        local is_folder = chunk:find("/folders/", 1, true) ~= nil
        if name and not is_folder then
            -- Google Docs/Slides link to docs.google.com/document/d/ID or /presentation/d/ID
            local google = chunk:match("docs%.google%.com/(%a+)/d/")
            table.insert(files, { id = s.id, name = util.trim(htmlUnescape(name)),
                google = google and Drive.GOOGLE_EXPORTS[google] and google or nil })
        end
    end
    if #files == 0 and body:find("ServiceLogin", 1, true) then
        return nil, "folder not shared (set it to Anyone with the link)"
    end
    return files
end

local registry_ok, DocumentRegistry = pcall(require, "document/documentregistry")
if not registry_ok then DocumentRegistry = nil end

-- Anything KOReader can open counts as a book (TXT, DOCX, HTML, MD, RTF, ODT…).
local function isBook(name)
    if DocumentRegistry then
        local ok, has = pcall(DocumentRegistry.hasProvider, DocumentRegistry, name)
        if ok then return has and true or false end
    end
    local ext = name:match("%.([%w]+)$")
    return ext and Drive.BOOK_EXTS[ext:lower()] or false
end
Drive.isBook = isBook

-- The name a Drive file gets on the Kindle: Google Docs/Slides get the
-- extension of the format they're exported to.
function Drive.localName(f)
    local exp = f.google and Drive.GOOGLE_EXPORTS[f.google]
    if exp and not f.name:lower():match("%." .. exp.ext .. "$") then
        return f.name .. "." .. exp.ext
    end
    return f.name
end

local function safeName(name)
    name = name:gsub("[/\\:%*%?\"<>|%c]", "_")
    return name
end

local function fileSize(path)
    return lfs.attributes(path, "size")
end

--- Download one file to path (via path..".part"). Returns true or nil, err.
function Drive.download(file, path, key)
    local exp = file.google and Drive.GOOGLE_EXPORTS[file.google]
    local url
    if exp then
        url = key
            and ("https://www.googleapis.com/drive/v3/files/" .. file.id .. "/export?mimeType=" .. urlencode(exp.mime) .. "&key=" .. urlencode(key))
            or string.format(exp.url, file.id)
    else
        url = key
            and ("https://www.googleapis.com/drive/v3/files/" .. file.id .. "?alt=media&supportsAllDrives=true&key=" .. urlencode(key))
            or ("https://drive.usercontent.google.com/download?id=" .. file.id .. "&export=download&confirm=t")
    end
    local part = path .. ".part"
    for _ = 1, 6 do
        local fh = io.open(part, "wb")
        if not fh then return nil, "can't write " .. part end
        local code, info = get(url, fh) -- the sink closes fh
        if code == nil then os.remove(part); return nil, info end
        if code >= 300 and code < 400 then
            url = info
        elseif code == 200 then
            -- Google sends an HTML page instead of the file when something's off
            local f = io.open(part, "rb")
            local head = f and f:read(512) or ""
            if f then f:close() end
            local is_html_book = not exp and (file.name or ""):lower():match("%.x?html?$")
            if not is_html_book and (head:find("<!DOCTYPE html", 1, true) or head:find("<html", 1, true)) then
                os.remove(part)
                return nil, "Google sent a web page instead of the file (is it shared?)"
            end
            if not exp and file.size and fileSize(part) ~= file.size then
                os.remove(part)
                return nil, "download was cut short"
            end
            os.remove(path)
            local ok, err = os.rename(part, path)
            if not ok then os.remove(part); return nil, err end
            return true
        else
            os.remove(part)
            return nil, "download error " .. code
        end
    end
    os.remove(part)
    return nil, "too many redirects"
end

---------------------------------------------------------------------------
-- Saved links: "Save to Drive" from a phone's share menu stores a web page
-- as a tiny text file holding only its URL, with no extension. Sync fetches
-- the page and saves the article as an EPUB (with its images), using the
-- News downloader plugin's EPUB builder.
---------------------------------------------------------------------------

local LINK_MAX_BYTES = 4096

-- Drive files already checked and found not to be links (id -> true), so
-- automatic syncs don't download them again. Kept for this KOReader session.
Drive.not_links = {}

-- Could this Drive file be a saved link? Only extension-less files, and only
-- small plain-text ones when Drive told us the type and size.
function Drive.mayBeLink(f)
    if f.google then return false end
    if f.name:match("%.[%w]+$") and not f.name:match("%s") then
        -- "notes.bin": a real extension. (Titles such as "Page | Site 2.0" have spaces.)
        return false
    end
    if f.mime and f.mime ~= "text/plain" then return false end
    if f.size and f.size > LINK_MAX_BYTES then return false end
    return true
end

-- The URL in a link file's text, or nil.
function Drive.parseLink(content)
    if type(content) ~= "string" then return nil end
    local text = util.trim(content:gsub("^\239\187\191", "")) -- strip a UTF-8 BOM
    local url = text:match("^(https?://%S+)$")
    return url
end

-- Read a small Drive file into memory (at most LINK_MAX_BYTES).
function Drive.readSmall(file, key)
    local url = key
        and ("https://www.googleapis.com/drive/v3/files/" .. file.id .. "?alt=media&supportsAllDrives=true&key=" .. urlencode(key))
        or ("https://drive.usercontent.google.com/download?id=" .. file.id .. "&export=download&confirm=t")
    for _ = 1, 6 do
        local chunks, total = {}, 0
        socketutil:set_timeout(15, 60)
        local code, headers = socket.skip(1, http.request{
            url = url,
            method = "GET",
            redirect = false,
            headers = { ["user-agent"] = "KOReader-Pixel" },
            sink = function(chunk)
                if chunk then
                    total = total + #chunk
                    if total > LINK_MAX_BYTES then return nil, "too big" end
                    table.insert(chunks, chunk)
                end
                return 1
            end,
        })
        socketutil:reset_timeout()
        if headers == nil then return nil, tostring(code or "network unreachable") end
        if code >= 300 and code < 400 then
            local loc = headers.location or headers.Location
            if not loc then return nil, "redirect without location" end
            if loc:sub(1, 1) == "/" then loc = url:match("^(https?://[^/]+)") .. loc end
            url = loc
        elseif code == 200 then
            if total > LINK_MAX_BYTES then return nil, "too big" end
            return table.concat(chunks)
        else
            return nil, "download error " .. tostring(code)
        end
    end
    return nil, "too many redirects"
end

local function loadEpubBackend()
    local ok, backend = pcall(require, "epubdownloadbackend")
    if not ok then
        -- The News downloader plugin may be disabled: load its builder by path.
        package.path = "plugins/newsdownloader.koplugin/?.lua;" .. package.path
        ok, backend = pcall(require, "epubdownloadbackend")
    end
    return ok and backend or nil, not ok and tostring(backend) or nil
end

-- Fetch a web page and save it at `path` (an .epub). Returns true or nil, err.
-- If the link points at a file KOReader opens (a PDF…), returns false and the
-- path to save that file under instead.
function Drive.saveArticle(url, path)
    local backend, berr = loadEpubBackend()
    if not backend then return nil, "can't load the EPUB builder: " .. tostring(berr) end
    local ok, content_type, content = pcall(backend.loadPage, backend, url)
    if not ok then return nil, "couldn't open the link (" .. tostring(content_type) .. ")" end
    content_type = util.trim(((content_type or "text/html"):match("^[^;]*")) or ""):lower()
    if content_type == "text/html" or content_type == "application/xhtml+xml" then
        -- No progress popups or questions in the middle of a sync: say yes to
        -- "continue without the images that failed".
        local Trapper = require("ui/trapper")
        local orig_info, orig_confirm = Trapper.info, Trapper.confirm
        Trapper.info = function() return true end
        Trapper.confirm = function() return true end
        local built_ok, built = pcall(backend.createEpub, backend, path, content, url, true, "", true)
        Trapper.info, Trapper.confirm = orig_info, orig_confirm
        if not built_ok then return nil, tostring(built) end
        if not built then return nil, "couldn't build the EPUB" end
        require("pixel/defaultcover").rememberLink(path, url)
        return true
    end
    -- A direct link to a document
    local ext = DocumentRegistry and DocumentRegistry:mimeToExt(content_type)
    if not ext then return nil, "the link isn't a web page or a book (" .. content_type .. ")" end
    local doc_path = path:gsub("%.epub$", "") .. "." .. ext
    local fh = io.open(doc_path, "wb")
    if not fh then return nil, "can't write " .. doc_path end
    fh:write(content)
    fh:close()
    require("pixel/defaultcover").rememberLink(doc_path, url)
    return true, doc_path
end

--- Blocking sync. Returns a summary table, or nil and an error.
-- { added = {names}, skipped = n, failed = {name = err}, others = n }
function Drive.sync()
    local folder = Drive.getFolderId()
    if not folder then return nil, "no folder set" end
    local key = Drive.getKey()
    local files, err = Drive.list(folder, key)
    if not files then return nil, err end
    local dir = Drive.targetDir()
    local res = { added = {}, skipped = 0, failed = {}, others = 0, other_names = {}, not_link_ids = {} }
    for _, f in ipairs(files) do
        local name = Drive.localName(f)
        local path = dir .. "/" .. safeName(name)
        if not isBook(path) and Drive.mayBeLink(f) and Drive.not_links[f.id] then
            res.others = res.others + 1
            table.insert(res.other_names, f.name)
        elseif not isBook(path) and Drive.mayBeLink(f) then
            local epub_name = name .. ".epub"
            local epub_path = dir .. "/" .. safeName(epub_name)
            if fileSize(epub_path) or fileSize(dir .. "/" .. safeName(name .. ".pdf")) then
                res.skipped = res.skipped + 1
                -- Saved before links were remembered: look up its URL once, for its cover
                local DefaultCover = require("pixel/defaultcover")
                if fileSize(epub_path) and not DefaultCover.knownLink(epub_path) then
                    local text = Drive.readSmall(f, key)
                    DefaultCover.rememberLink(epub_path, Drive.parseLink(text) or false,
                        lfs.attributes(epub_path, "modification"))
                end
            else
                local text, rerr = Drive.readSmall(f, key)
                local url = Drive.parseLink(text)
                if not url then
                    if rerr then logger.info("Pixel/Drive: not a link", f.name, rerr) end
                    if text or rerr == "too big" then table.insert(res.not_link_ids, f.id) end
                    res.others = res.others + 1
                    table.insert(res.other_names, f.name)
                else
                    local ok, saved = Drive.saveArticle(url, epub_path)
                    if ok then
                        table.insert(res.added, saved and saved:match("([^/]+)$") or epub_name)
                    else
                        logger.warn("Pixel/Drive: saving link failed", f.name, url, saved)
                        res.failed[f.name] = saved
                    end
                end
            end
        elseif not isBook(path) then
            res.others = res.others + 1
            table.insert(res.other_names, f.name)
        else
            if fileSize(path) then
                res.skipped = res.skipped + 1
            else
                local ok, derr = Drive.download(f, path, key)
                if ok then table.insert(res.added, name)
                else
                    logger.warn("Pixel/Drive: download failed", f.name, derr)
                    res.failed[f.name] = derr
                end
            end
        end
    end
    return res
end

local function summary(res)
    local lines = {}
    local n = #res.added
    if n == 0 then
        table.insert(lines, "No new books.")
    else
        table.insert(lines, (n == 1 and "1 new book:" or (n .. " new books:")))
        for i, name in ipairs(res.added) do
            if i > 8 then table.insert(lines, "  …and " .. (n - 8) .. " more"); break end
            table.insert(lines, "  " .. name)
        end
    end
    if res.skipped > 0 then table.insert(lines, res.skipped .. " already here.") end
    local nf = 0
    for name, e in pairs(res.failed) do
        nf = nf + 1
        if nf <= 3 then table.insert(lines, "Failed: " .. name .. " (" .. tostring(e) .. ")") end
    end
    if (res.others or 0) > 0 then
        local names = res.other_names or {}
        local shown = {}
        for i = 1, math.min(3, #names) do shown[i] = names[i] end
        local more = #names > 3 and (", …") or ""
        table.insert(lines, res.others .. " skipped (KOReader can't open them)"
            .. (#shown > 0 and (": " .. table.concat(shown, ", ") .. more) or "") .. ".")
    end
    return table.concat(lines, "\n")
end

local function encodeResult(res)
    return require("rapidjson").encode(res)
end

--- Sync with a "SYNCING" message, then refresh the library. `fm` optional.
function Drive.syncInteractive(fm)
    local UIManager = require("ui/uimanager")
    local InfoMessage = require("ui/widget/infomessage")
    local NetworkMgr = require("ui/network/manager")
    local Trapper = require("ui/trapper")
    if not Drive.getFolderId() then
        UIManager:show(InfoMessage:new{
            text = "Google Drive sync isn't set up.\n\nPut your shared folder's link in koreader/gdrive_folder.txt, "
                .. "or set it in Settings > Pixel theme > Google Drive sync.",
        })
        return
    end
    if Drive.busy then
        UIManager:show(InfoMessage:new{ text = "Google Drive sync is already running.", timeout = 3 })
        return
    end
    NetworkMgr:runWhenOnline(function()
        Trapper:wrap(function()
            Drive.busy = true
            local wait = InfoMessage:new{ text = "SYNCING GOOGLE DRIVE…\n\nTap to cancel." }
            UIManager:show(wait)
            UIManager:forceRePaint()
            local completed, raw = Trapper:dismissableRunInSubprocess(function()
                local ok, res, err = pcall(Drive.sync)
                if not ok then return "E" .. tostring(res) end
                if not res then return "E" .. tostring(err) end
                return "R" .. encodeResult(res)
            end, wait, true)
            local res, err
            if not completed then
                err = "cancelled"
            elseif raw == nil or raw == "" then
                -- helper process died (seen on macOS before the first secure connection): retry here
                local ok, r, e = pcall(Drive.sync)
                if ok then res, err = r, e else err = tostring(r) end
            elseif raw:sub(1, 1) == "R" then
                local ok, r = pcall(require("rapidjson").decode, raw:sub(2))
                if ok and type(r) == "table" then res = r else err = "bad result" end
            else
                err = raw:sub(2)
            end
            UIManager:close(wait)
            Drive.busy = false
            if res then
                Drive.rememberNotLinks(res)
                Drive.last_sync = os.time()
                res.added = res.added or {}
                res.failed = res.failed or {}
                res.skipped = res.skipped or 0
                if fm and fm.file_chooser then fm.file_chooser:refreshPath() end
                UIManager:show(InfoMessage:new{ text = summary(res), timeout = #res.added > 0 and 6 or 3 })
            elseif err ~= "cancelled" then
                UIManager:show(InfoMessage:new{ text = "Sync failed: " .. tostring(err) })
            end
        end)
    end)
end

function Drive.rememberNotLinks(res)
    for _, id in ipairs(res.not_link_ids or {}) do Drive.not_links[id] = true end
end

---------------------------------------------------------------------------
-- Automatic sync
--
-- Battery first: it never turns Wi-Fi on, and its timer is stopped while the
-- Kindle sleeps. It only checks when Wi-Fi is already connected:
-- * when Wi-Fi connects, and when KOReader starts with Wi-Fi on;
-- * a little after the Kindle wakes up (Wi-Fi takes a few seconds to come back);
-- * every 15 minutes while the Kindle is awake and connected.
-- A check is one small request listing the folder; files are downloaded only
-- when something is new. It runs in a background process, so reading isn't
-- interrupted, and shows a short note only when new books arrive.
---------------------------------------------------------------------------

Drive.AUTO_INTERVAL = 15 * 60 -- seconds between checks while awake
Drive.AUTO_MIN_GAP = 2 * 60   -- never check more often than this

function Drive.autoEnabled()
    return G_reader_settings:nilOrTrue("pixel_drive_autosync") and Drive.getFolderId() ~= nil
end

local function wifiConnected()
    local NetworkMgr = require("ui/network/manager")
    local ok, on = pcall(function() return NetworkMgr:isWifiOn() and NetworkMgr:isConnected() end)
    return ok and on and true or false
end

local function refreshLibrary()
    local ok, FM = pcall(require, "apps/filemanager/filemanager")
    if ok and FM.instance and FM.instance.file_chooser then FM.instance.file_chooser:refreshPath() end
end

--- Run one quiet sync in a background process. `why` is for the log.
function Drive.autoSync(why)
    if not Drive.autoEnabled() or Drive.busy then return end
    if Drive.last_sync and os.time() - Drive.last_sync < Drive.AUTO_MIN_GAP then return end
    if not wifiConnected() then return end
    local ffiutil = require("ffi/util")
    local UIManager = require("ui/uimanager")
    logger.info("Pixel/Drive: automatic sync", why)
    Drive.busy = true
    Drive.last_sync = os.time()
    local pid, fd = ffiutil.runInSubProcess(function(_, child_fd)
        local ok, res, err = pcall(Drive.sync)
        local out
        if not ok then out = "E" .. tostring(res)
        elseif not res then out = "E" .. tostring(err)
        else out = "R" .. encodeResult(res) end
        ffiutil.writeToFD(child_fd, out, true)
    end, true)
    if not pid then
        Drive.busy = false
        return
    end
    local raw = ""
    local started = os.time()
    local function finish()
        Drive.busy = false
        if raw:sub(1, 1) ~= "R" then
            logger.warn("Pixel/Drive: automatic sync failed", raw:sub(2))
            return
        end
        local ok, res = pcall(require("rapidjson").decode, raw:sub(2))
        if not ok or type(res) ~= "table" then return end
        Drive.rememberNotLinks(res)
        local added = res.added or {}
        if #added > 0 then
            refreshLibrary()
            local Notification = require("ui/widget/notification")
            local text = #added == 1 and ("New from Drive: " .. added[1]) or (#added .. " new books from Drive")
            Notification:notify(text, Notification.SOURCE_ALWAYS_SHOW)
        end
    end
    local function poll()
        if fd and ffiutil.getNonBlockingReadSize(fd) ~= 0 then
            raw = raw .. (ffiutil.readAllFromFD(fd) or "")
            fd = nil
        end
        if ffiutil.isSubProcessDone(pid) then
            if fd then raw = raw .. (ffiutil.readAllFromFD(fd) or ""); fd = nil end
            return finish()
        end
        if os.time() - started > 10 * 60 then -- stuck: give up
            ffiutil.terminateSubProcess(pid)
            raw = "Etimed out"
        end
        UIManager:scheduleIn(2, poll)
    end
    UIManager:scheduleIn(1, poll)
end

local function periodic()
    Drive.autoSync("periodic")
    if Drive.auto_started then
        require("ui/uimanager"):scheduleIn(Drive.AUTO_INTERVAL, periodic)
    end
end

--- Start the 15-minute check (once per KOReader session).
function Drive.autoStart()
    if Drive.auto_started then return end
    Drive.auto_started = true
    local UIManager = require("ui/uimanager")
    UIManager:scheduleIn(Drive.AUTO_INTERVAL, periodic)
    UIManager:scheduleIn(20, function() Drive.autoSync("start") end)
end

-- Going to sleep: stop the 15-minute timer, so nothing at all runs while asleep.
function Drive.onSuspend()
    require("ui/uimanager"):unschedule(periodic)
end

-- Wi-Fi comes back a few seconds after the Kindle wakes: look twice.
function Drive.onResume()
    local UIManager = require("ui/uimanager")
    if Drive.auto_started then
        UIManager:unschedule(periodic)
        UIManager:scheduleIn(Drive.AUTO_INTERVAL, periodic)
    end
    UIManager:scheduleIn(10, function() Drive.autoSync("resume") end)
    UIManager:scheduleIn(40, function() Drive.autoSync("resume") end)
end

function Drive.onNetworkConnected()
    require("ui/uimanager"):scheduleIn(5, function() Drive.autoSync("wifi connected") end)
end

return Drive

--[[--
Google Drive sync: download new books from one shared Drive folder.

Setup (once):
* In Google Drive, share the folder as "Anyone with the link: Viewer".
* Put the folder's link (or just its ID) in `koreader/gdrive_folder.txt`,
  or in Settings > Pixel theme > Google Drive sync > Folder link.
* Optional: a Google API key in `koreader/google_api_key.txt` makes listing
  use the official Drive API. Without one, the public folder page is read.

SYNC (library bar) lists the folder and downloads every book that isn't on
the Kindle yet into the home folder. It never deletes or overwrites anything.
]]

local DataStorage = require("datastorage")
local logger = require("logger")
local util = require("util")

local http = require("socket.http")
local ltn12 = require("ltn12")
local socket = require("socket")
local socketutil = require("socketutil")
require("ssl.https")

local Drive = {}

Drive.BOOK_EXTS = {
    epub = true, pdf = true, mobi = true, azw3 = true, fb2 = true, djvu = true,
    cbz = true, cbr = true, txt = true, rtf = true, doc = true, docx = true, html = true, htm = true,
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
                    table.insert(files, { id = f.id, name = f.name, size = tonumber(f.size) })
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
            table.insert(files, { id = s.id, name = util.trim(htmlUnescape(name)) })
        end
    end
    if #files == 0 and body:find("ServiceLogin", 1, true) then
        return nil, "folder not shared (set it to Anyone with the link)"
    end
    return files
end

local function isBook(name)
    local ext = name:match("%.([%w]+)$")
    return ext and Drive.BOOK_EXTS[ext:lower()] or false
end

local function safeName(name)
    name = name:gsub("[/\\:%*%?\"<>|%c]", "_")
    return name
end

local function fileSize(path)
    local lfs = require("libs/libkoreader-lfs")
    return lfs.attributes(path, "size")
end

--- Download one file to path (via path..".part"). Returns true or nil, err.
function Drive.download(file, path, key)
    local url = key
        and ("https://www.googleapis.com/drive/v3/files/" .. file.id .. "?alt=media&supportsAllDrives=true&key=" .. urlencode(key))
        or ("https://drive.usercontent.google.com/download?id=" .. file.id .. "&export=download&confirm=t")
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
            local is_html_book = (file.name or ""):lower():match("%.html?$")
            if not is_html_book and (head:find("<!DOCTYPE html", 1, true) or head:find("<html", 1, true)) then
                os.remove(part)
                return nil, "Google sent a web page instead of the file (is it shared?)"
            end
            if file.size and fileSize(part) ~= file.size then
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

--- Blocking sync. Returns a summary table, or nil and an error.
-- { added = {names}, skipped = n, failed = {name = err}, others = n }
function Drive.sync()
    local folder = Drive.getFolderId()
    if not folder then return nil, "no folder set" end
    local key = Drive.getKey()
    local files, err = Drive.list(folder, key)
    if not files then return nil, err end
    local dir = Drive.targetDir()
    local res = { added = {}, skipped = 0, failed = {}, others = 0 }
    for _, f in ipairs(files) do
        if not isBook(f.name) then
            res.others = res.others + 1
        else
            local path = dir .. "/" .. safeName(f.name)
            if fileSize(path) then
                res.skipped = res.skipped + 1
            else
                local ok, derr = Drive.download(f, path, key)
                if ok then table.insert(res.added, f.name)
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
    NetworkMgr:runWhenOnline(function()
        Trapper:wrap(function()
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
            if res then
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

return Drive

--[[--
Tiny Claude API client for the Pixel "Explain" feature.

Sends the selected word or phrase, the sentence around it, and the book's
title to the Claude Messages API, and gets back a short structured
explanation (JSON, enforced with a schema):

    { headword, kind, meaning, here, deeper, related = { "...", "..." } }

The API key is looked up in this order:
  1. the ANTHROPIC_API_KEY environment variable (handy on the Mac simulator),
  2. Settings > Pixel theme > Claude API key,
  3. a file named claude_api_key.txt in the koreader folder (easiest on a
     Kindle: copy it over USB).

The request itself is blocking, so callers run it in a subprocess
(see Claude.explainAsync) to keep the screen responsive.
]]

local DataStorage = require("datastorage")
local logger = require("logger")
local util = require("util")
-- Load the network stack here, in the main process, not first inside the
-- forked request process (some systems dislike initialising it after fork).
local http = require("socket.http")
local ltn12 = require("ltn12")
local rapidjson = require("rapidjson")
local socket = require("socket")
local socketutil = require("socketutil")
require("ssl.https")

local Claude = {}

Claude.ENDPOINT = "https://api.anthropic.com/v1/messages"
Claude.API_VERSION = "2026-10-21"
Claude.FALLBACK_BETA = "server-side-fallback-2026-07-01"

Claude.MODELS = {
    { id = "claude-opus-5-5",   label = "Claude Opus 5.5 (best answers)" },
    { id = "claude-sonnet-5-5", label = "Claude Sonnet 5.5 (faster)" },
    { id = "claude-haiku-5-5",  label = "Claude Haiku 5.5 (fastest, cheapest)" },
}
Claude.DEFAULT_MODEL = "claude-opus-5-5"

-- Server-side refusal fallbacks ("default" routing) are available on these.
local FALLBACK_MODELS = { ["claude-opus-5-5"] = true, ["claude-sonnet-5-5"] = true }

Claude.SYSTEM = [[
You explain words, names and ideas to someone reading a book on an e-reader. They just selected something they didn't understand. Explain it the way a smart, warm friend would: plain words, short sentences, no jargon, no filler. Never stop at a dictionary definition: always connect it to this passage and this book.

Fill in:
- headword: the selection as it should be displayed (fix capitalisation; if the selection cuts a name or phrase in half, give the whole thing).
- kind: a tiny label such as "noun · old medicine", "person · Roman senator, 95–46 BC", "phrase", "place". Under 40 characters.
- meaning: what it means in general. One sentence, under 25 words.
- here: what it means in this exact passage, and why the author used it. One or two sentences, under 45 words.
- deeper: one surprising, useful piece of background: history, word origin, or how it ties into the rest of the book. One or two sentences, under 45 words. Never spoil later events in the book.
- related: two other words or names from the passage (or closely tied to it) that the reader might also want explained. Just the words.

Write in the same language as the passage.]]

Claude.SCHEMA = {
    type = "object",
    properties = {
        headword = { type = "string" },
        kind = { type = "string" },
        meaning = { type = "string" },
        here = { type = "string" },
        deeper = { type = "string" },
        related = { type = "array", items = { type = "string" } },
    },
    required = { "headword", "kind", "meaning", "here", "deeper", "related" },
    additionalProperties = false,
}

function Claude.keyFile()
    return DataStorage:getDataDir() .. "/claude_api_key.txt"
end

--- The API key and where it came from ("env", "settings", "file"), or nil.
function Claude.getKey()
    local k = os.getenv("ANTHROPIC_API_KEY")
    if k and k ~= "" then return util.trim(k), "env" end
    k = G_reader_settings:readSetting("pixel_claude_api_key")
    if k and k ~= "" then return util.trim(k), "settings" end
    local f = io.open(Claude.keyFile(), "r")
    if f then
        k = f:read("*l")
        f:close()
        if k and util.trim(k) ~= "" then return util.trim(k), "file" end
    end
end

function Claude.getModel()
    return G_reader_settings:readSetting("pixel_claude_model") or Claude.DEFAULT_MODEL
end

--- Build the user message from what we know about the selection.
function Claude.buildPrompt(req)
    local lines = {}
    if req.title and req.title ~= "" then
        table.insert(lines, "Book: " .. req.title .. (req.author and req.author ~= "" and (" by " .. req.author) or ""))
    end
    local before, after = req.before or "", req.after or ""
    if req.related_to then
        -- A follow-up from a related-word chip: the passage marks the first word.
        table.insert(lines, "Passage (the reader first asked about the part between ⟦ and ⟧):")
        table.insert(lines, "…" .. before .. " ⟦" .. req.related_to .. "⟧ " .. after .. "…")
        table.insert(lines, "Now explain this related word or name instead (it may not appear in the passage): " .. req.word)
    else
        table.insert(lines, "Passage (the selection is between ⟦ and ⟧):")
        table.insert(lines, "…" .. before .. " ⟦" .. req.word .. "⟧ " .. after .. "…")
    end
    return table.concat(lines, "\n")
end

local function requestBody(req, model, with_fallbacks)
    local body = {
        model = model,
        max_tokens = 4000,
        system = Claude.SYSTEM,
        output_config = {
            effort = "low", -- short answers; keeps latency down on a Kindle
            format = { type = "json_schema", schema = Claude.SCHEMA },
        },
        messages = { { role = "user", content = Claude.buildPrompt(req) } },
    }
    if with_fallbacks then
        body.fallbacks = "default"
    end
    return body
end

local function post(key, body, with_fallbacks)
    local rapidjson = require("rapidjson")

    local payload = rapidjson.encode(body)
    local headers = {
        ["content-type"] = "application/json",
        ["content-length"] = tostring(#payload),
        ["x-api-key"] = key,
        ["anthropic-version"] = Claude.API_VERSION,
    }
    if with_fallbacks then
        headers["anthropic-beta"] = Claude.FALLBACK_BETA
    end
    local sink = {}
    socketutil:set_timeout(20, 90)
    local code, resp_headers, status = socket.skip(1, http.request{
        url = Claude.ENDPOINT,
        method = "POST",
        headers = headers,
        source = ltn12.source.string(payload),
        sink = socketutil.table_sink(sink),
    })
    socketutil:reset_timeout()
    if resp_headers == nil then
        return nil, status or code or "network unreachable"
    end
    return code, table.concat(sink)
end

--- Blocking call. Returns the raw JSON response text plus HTTP status,
-- or nil and an error string. Safe to run in a subprocess.
function Claude.requestRaw(req)
    local key = Claude.getKey()
    if not key then return nil, "nokey" end
    local model = req.model or Claude.getModel()
    local with_fallbacks = FALLBACK_MODELS[model] or false
    local code, text = post(key, requestBody(req, model, with_fallbacks), with_fallbacks)
    if code == 400 and with_fallbacks then
        -- If the fallback option is ever rejected, retry plainly once.
        logger.warn("Pixel/Claude: 400 with fallbacks, retrying without:", text)
        code, text = post(key, requestBody(req, model, false), false)
    end
    if not code then return nil, text end
    return code, text
end

local ERRORS = {
    [401] = "The API key was not accepted. Check it in Settings > Pixel theme.",
    [403] = "This API key isn't allowed to use that model.",
    [404] = "That model isn't available to this API key.",
    [429] = "Too many requests right now. Wait a moment and try again.",
    [529] = "Claude is busy right now. Try again in a moment.",
}

--- Turn (code, text) from requestRaw into a result table, or nil + message.
function Claude.parse(code, text)
    if not code then
        if text == "nokey" then return nil, "nokey" end
        return nil, "No connection to Claude (" .. tostring(text) .. "). Is Wi-Fi on?"
    end
    local rapidjson = require("rapidjson")
    local ok, data = pcall(rapidjson.decode, text or "")
    if code ~= 200 then
        local msg = ERRORS[code]
        if not msg and code >= 500 then msg = "Claude had a problem (" .. code .. "). Try again." end
        if not msg then
            local detail = ok and type(data) == "table" and type(data.error) == "table" and data.error.message
            msg = "Request failed (" .. tostring(code) .. ")" .. (detail and (": " .. tostring(detail)) or "")
        end
        return nil, msg
    end
    if not ok or type(data) ~= "table" then return nil, "Claude's answer couldn't be read." end
    if data.stop_reason == "refusal" then
        return nil, "Claude declined to explain this one."
    end
    local json_text
    for _, block in ipairs(data.content or {}) do
        if block.type == "text" and type(block.text) == "string" then
            json_text = (json_text or "") .. block.text
        end
    end
    if not json_text then return nil, "Claude sent an empty answer." end
    local ok2, result = pcall(rapidjson.decode, json_text)
    if not ok2 or type(result) ~= "table" then return nil, "Claude's answer couldn't be read." end
    local function str(v) return type(v) == "string" and v or "" end
    local related = {}
    if type(result.related) == "table" then
        for _, r in ipairs(result.related) do
            if type(r) == "string" and r ~= "" and #related < 3 then table.insert(related, r) end
        end
    end
    return {
        headword = str(result.headword),
        kind = str(result.kind),
        meaning = str(result.meaning),
        here = str(result.here),
        deeper = str(result.deeper),
        related = related,
        model = data.model,
    }
end

--- Run the request in a subprocess so the UI stays alive; the user can tap
-- to cancel. Must be called inside Trapper:wrap(). Returns result or nil, err.
function Claude.explain(req, trap_widget)
    local Trapper = require("ui/trapper")
    local completed, raw = Trapper:dismissableRunInSubprocess(function()
        local ok, code, text = pcall(Claude.requestRaw, req)
        if not ok then return "\n" .. tostring(code) end -- report errors instead of dying silently
        return tostring(code or "") .. "\n" .. tostring(text or "")
    end, trap_widget, true)
    if not completed then return nil, "cancelled" end
    if raw == nil or raw == "" then
        -- The helper process died without answering. Seen on macOS until the
        -- first secure connection is made in the main process. Ask directly
        -- instead (the screen waits a few seconds); later calls are fine.
        logger.warn("Pixel/Claude: request subprocess gave no answer, retrying in-process")
        local ok, code, text = pcall(Claude.requestRaw, req)
        if not ok then return Claude.parse(nil, tostring(code)) end
        return Claude.parse(code, text)
    end
    local code_s, text = raw:match("^([^\n]*)\n(.*)$")
    local code = tonumber(code_s)
    if not code then return Claude.parse(nil, text ~= "" and text or "network error") end
    return Claude.parse(code, text)
end

return Claude

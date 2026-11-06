--[[--
Dev-only remote control for the Mac simulator.

pixel/dev/ko writes one command per line into $KO_HOME/simdriver/cmd; we poll
it, run each line, and write results to $KO_HOME/simdriver/out. Commands:
  tap X Y | hold X Y | select X1 Y1 X2 Y2 | swipe X Y DIR [DIST] | key NAME | open PATH
  shot PATH | suspend | resume | lua CODE | home | quit
Coordinates are framebuffer pixels (1236x1648 on the Paperwhite-sized window).
]]
local DataStorage = require("datastorage")
local Device = require("device")
local Event = require("ui/event")
local Geom = require("ui/geometry")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger = require("logger")
local time = require("ui/time")

local dir = DataStorage:getDataDir() .. "/simdriver"
local cmd_file, out_file = dir .. "/cmd", dir .. "/out"
local started = false

local function out(s)
    local f = io.open(out_file, "a")
    if f then f:write(tostring(s), "\n") f:close() end
end

local function gesture(ges, x, y, extra)
    local ev = { ges = ges, pos = Geom:new{ x = x, y = y, w = 0, h = 0 }, time = time.now() }
    for k, v in pairs(extra or {}) do ev[k] = v end
    UIManager:sendEvent(Event:new("Gesture", ev))
end

local handlers = {}
function handlers.tap(x, y) gesture("tap", tonumber(x), tonumber(y)) end
function handlers.hold(x, y)
    x, y = tonumber(x), tonumber(y)
    gesture("hold", x, y)
    UIManager:scheduleIn(0.15, function() gesture("hold_release", x, y) end)
end
-- Select several words: press at (x1,y1), drag to (x2,y2), let go
function handlers.select(x1, y1, x2, y2)
    x1, y1, x2, y2 = tonumber(x1), tonumber(y1), tonumber(x2), tonumber(y2)
    gesture("hold", x1, y1)
    UIManager:scheduleIn(0.2, function()
        gesture("hold_pan", x2, y2, { direction = "east", distance = math.abs(x2 - x1), relative = { x = x2 - x1, y = y2 - y1 } })
        UIManager:scheduleIn(0.2, function() gesture("hold_release", x2, y2) end)
    end)
end
function handlers.swipe(x, y, dir_, dist)
    gesture("swipe", tonumber(x), tonumber(y), { direction = dir_, distance = tonumber(dist) or 300 })
end
function handlers.key(name)
    local Key = require("device/key")
    UIManager:sendEvent(Event:new("KeyPress", Key:new(name, {})))
end
function handlers.open(path) require("apps/reader/readerui"):showReader(path) end
function handlers.home()
    local ReaderUI = require("apps/reader/readerui")
    if ReaderUI.instance then ReaderUI.instance:onHome() end
end
function handlers.shot(path)
    UIManager:forceRePaint()
    Device.screen:shot(path)
    out("shot " .. path)
end
function handlers.suspend() Device:simulateSuspend() end
function handlers.resume() Device:simulateResume() end
function handlers.quit() UIManager:quit() end

local function run_line(line)
    local verb, rest = line:match("^(%S+)%s*(.*)$")
    if not verb then return end
    if verb == "lua" then
        local fn, err = loadstring(rest)
        if not fn then out("ERR " .. err) return end
        local ok, res = pcall(fn)
        out((ok and "OK " or "ERR ") .. tostring(res))
        return
    end
    local h = handlers[verb]
    if not h then out("ERR unknown " .. verb) return end
    local args = {}
    if verb == "open" or verb == "shot" then args = { rest } else
        for a in rest:gmatch("%S+") do table.insert(args, a) end
    end
    local ok, err = pcall(h, unpack(args))
    if not ok then out("ERR " .. tostring(err)) logger.err("simdriver", err) end
end

local function poll()
    local f = io.open(cmd_file, "r")
    if f then
        local data = f:read("*a")
        f:close()
        os.remove(cmd_file)
        for line in data:gmatch("[^\n]+") do run_line(line) end
        out("DONE")
    end
    UIManager:scheduleIn(0.2, poll)
end

local SimDriver = WidgetContainer:extend{ name = "simdriver" }
function SimDriver:init()
    if started then return end
    started = true
    require("libs/libkoreader-lfs").mkdir(dir)
    UIManager:scheduleIn(0.5, poll)
end
return SimDriver

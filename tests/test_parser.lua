#!/usr/bin/env lua
-- Standalone tests for Parser.parse and URL helpers (no KOReader runtime).

local script = debug.getinfo(1, "S").source
if script:sub(1, 1) == "@" then script = script:sub(2) end
local ROOT = os.getenv("QUICKRSS_ROOT") or script:match("(.+)/tests/") or "."

package.path = table.concat({
    ROOT .. "tests/stubs/?.lua",
    ROOT .. "quickrss.koplugin/?.lua",
    ROOT .. "quickrss.koplugin/modules/data/?.lua",
    ROOT .. "quickrss.koplugin/modules/lib/?.lua",
    package.path,
}, ";")

package.loaded["logger"]                  = require("logger")
package.loaded["modules/data/config"]     = require("config")
package.loaded["ui/network/manager"]      = { runWhenOnline = function(fn) fn() end }
package.loaded["ui/uimanager"]            = {}
package.loaded["ssl.https"]               = {}
package.loaded["ltn12"]                   = {}
package.loaded["socketutil"]              = {
    LARGE_BLOCK_TIMEOUT = 1,
    LARGE_TOTAL_TIMEOUT = 1,
    set_timeout = function() end,
    reset_timeout = function() end,
}
package.loaded["util"] = {
    urlEncode = function(s) return s end,
}
package.loaded["libs/libkoreader-lfs"] = {
    attributes = function() return nil end,
    mkdir = function() return true end,
    dir = function() return function() return nil end end,
}
package.loaded["ffi/util"] = {
    template = function(fmt, ...)
        local args = { ... }
        return fmt:gsub("%%(%d+)", function(i)
            return tostring(args[tonumber(i)] or "")
        end)
    end,
    runInSubProcess = function() return nil, nil end,
    writeToFD = function() end,
    readAllFromFD = function() return "" end,
    isSubProcessDone = function() return true end,
    getNonBlockingReadSize = function() return 0 end,
}
package.loaded["modules/data/http_fetch"] = {
    fetchRaw = function() return nil, "offline" end,
    fetchMany = function() return {} end,
}

local Parser = require("parser")

local failures = 0
local function check(name, cond, detail)
    if cond then
        print("  ok  " .. name)
    else
        failures = failures + 1
        print(" FAIL " .. name .. (detail and (": " .. detail) or ""))
    end
end

print("test_parser")

check("normalizeUrl adds scheme",
    Parser.normalizeUrl("feeds.example.com/rss") == "https://feeds.example.com/rss")
check("normalizeUrl keeps https",
    Parser.normalizeUrl("https://feeds.example.com/rss") == "https://feeds.example.com/rss")

local fixture_path = ROOT .. "tests/fixtures/sample_rss.xml"
local f = assert(io.open(fixture_path, "r"))
local xml = f:read("*a")
f:close()

local result, err = Parser.parse(xml)
check("parse succeeds", result ~= nil, err)
check("feed title", result and result.feed_title == "Test Feed")
check("article count", result and #result.articles == 2)
check("entity decode", result and result.articles[1].title == "Hello & World")
check("snippet present", result and result.articles[1].snippet ~= "")

local bad, bad_err = Parser.parse("<html>not a feed</html>")
check("reject bad xml", bad == nil and bad_err ~= nil)

if failures > 0 then
    print(failures .. " failure(s)")
    os.exit(1)
end
print("all parser tests passed")

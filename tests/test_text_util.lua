#!/usr/bin/env lua
-- Standalone tests for text_util.readingTime

local script = debug.getinfo(1, "S").source
if script:sub(1, 1) == "@" then script = script:sub(2) end
local ROOT = os.getenv("QUICKRSS_ROOT") or script:match("(.+)/tests/") or "."

package.path = table.concat({
    ROOT .. "quickrss.koplugin/?.lua",
    ROOT .. "quickrss.koplugin/modules/lib/?.lua",
    package.path,
}, ";")

local TextUtil = require("text_util")

local failures = 0
local function check(name, cond, detail)
    if cond then
        print("  ok  " .. name)
    else
        failures = failures + 1
        print(" FAIL " .. name .. (detail and (": " .. detail) or ""))
    end
end

print("test_text_util")

local words = string.rep("word ", 100)
check("short text nil", TextUtil.readingTime("too few words") == nil)
check("long text minutes", TextUtil.readingTime(words) == "~1 min")
check("long form", TextUtil.readingTime(words, true) == "~1 min read")
check("article plain prefers full_text",
    TextUtil.articlePlainText({ full_text = "a b c", content = "<p>x</p>" }) == "a b c")

if failures > 0 then
    print(failures .. " failure(s)")
    os.exit(1)
end
print("all text_util tests passed")

#!/usr/bin/env lua
-- Standalone tests for html_cleanup

local script = debug.getinfo(1, "S").source
if script:sub(1, 1) == "@" then script = script:sub(2) end
local ROOT = os.getenv("QUICKRSS_ROOT") or script:match("(.+)/tests/") or "."

package.path = table.concat({
    ROOT .. "quickrss.koplugin/?.lua",
    ROOT .. "quickrss.koplugin/modules/data/?.lua",
    package.path,
}, ";")

local HtmlCleanup = require("html_cleanup")

local failures = 0
local function check(name, cond, detail)
    if cond then
        print("  ok  " .. name)
    else
        failures = failures + 1
        print(" FAIL " .. name .. (detail and (": " .. detail) or ""))
    end
end

print("test_html_cleanup")

local empty_p = "<p></p><p>Hello</p><p>   </p>"
local stripped = HtmlCleanup.stripEmptyParagraphs(empty_p)
check("strip empty p", not stripped:find("<p></p>") and stripped:find("Hello"))

local brs = "a<br><br><br><br>b"
local collapsed = HtmlCleanup.collapseBreaks(brs)
check("collapse br", not collapsed:match("<br>%s*<br>%s*<br>%s*<br>"))

local html, headings = HtmlCleanup.clean(
    "<h2>Intro</h2><p></p><h3>Details</h3>", { headings = true })
check("heading count", headings and #headings == 2, tostring(headings and #headings))
check("heading ids", html:find('id="qrss%-h%-1"') and html:find('id="qrss%-h%-2"'))

local deduped = HtmlCleanup.stripLeadingTitle(
    "<h1>Title</h1><p>Body</p>", "Title")
check("strip leading title", not deduped:find("<h1>") and deduped:find("Body"))

if failures > 0 then
    print(failures .. " failure(s)")
    os.exit(1)
end
print("all html_cleanup tests passed")

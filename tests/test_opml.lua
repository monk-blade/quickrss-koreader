#!/usr/bin/env lua
-- Standalone tests for OPML read/write/merge (no KOReader runtime).

local script = debug.getinfo(1, "S").source
if script:sub(1, 1) == "@" then script = script:sub(2) end
local ROOT = os.getenv("QUICKRSS_ROOT") or script:match("(.+)/tests/") or "."

package.path = table.concat({
    ROOT .. "tests/stubs/?.lua",
    ROOT .. "quickrss.koplugin/?.lua",
    ROOT .. "quickrss.koplugin/modules/data/?.lua",
    package.path,
}, ";")

package.loaded["logger"]      = require("logger")
package.loaded["datastorage"] = require("datastorage")

local OPML = require("opml")

local failures = 0
local function check(name, cond, detail)
    if cond then
        print("  ok  " .. name)
    else
        failures = failures + 1
        print(" FAIL " .. name .. (detail and (": " .. detail) or ""))
    end
end

print("test_opml")

local fixture = ROOT .. "tests/fixtures/sample.opml"
local feeds = OPML.read(fixture)
check("read fixture", feeds and #feeds == 2, "count=" .. tostring(feeds and #feeds))
check("first feed name", feeds and feeds[1].name == "Feed One")
check("first feed url", feeds and feeds[1].url == "https://example.com/one.xml")

local tmp = (os.getenv("TMPDIR") or "/tmp") .. "/quickrss-opml-test.opml"
check("write tmp", OPML.write(tmp, feeds))

local roundtrip = OPML.read(tmp)
check("roundtrip count", roundtrip and #roundtrip == 2)

local merged = OPML.mergeFeeds(
    { { name = "A", url = "https://example.com/one.xml" } },
    { { name = "B", url = "https://example.com/two.xml" },
      { name = "C", url = "https://example.com/one.xml" } }
)
check("merge dedupes", merged and #merged == 2)

local nested_fixture = ROOT .. "tests/fixtures/nested.opml"
local nested = OPML.read(nested_fixture)
check("nested read count", nested and #nested == 3)
local folders = {}
for _, f in ipairs(nested or {}) do
    folders[f.url] = f.folder
end
check("nested folder one", folders["https://example.com/one.xml"] == "News")
check("nested folder two", folders["https://example.com/two.xml"] == "News/Tech")

local nested_tmp = (os.getenv("TMPDIR") or "/tmp") .. "/quickrss-nested.opml"
check("nested write", OPML.write(nested_tmp, nested))
local nested_roundtrip = OPML.read(nested_tmp)
check("nested roundtrip count", nested_roundtrip and #nested_roundtrip == 3)
os.remove(nested_tmp)

os.remove(tmp)

if failures > 0 then
    print(failures .. " failure(s)")
    os.exit(1)
end
print("all opml tests passed")

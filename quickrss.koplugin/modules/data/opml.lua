-- QuickRSS: OPML Module
-- Reads and writes the standard OPML 1.0 feed-list format so users can
-- manage their subscriptions from a computer (text editor, another RSS
-- reader, etc.) without touching the device UI.
--
-- Supports nested folder outlines.  Flat feeds at body level remain valid.
--
-- Public API:
--   OPML.read([path])          → { {name, url, folder?}, … }  or nil if missing
--   OPML.readTree([path])      → { name, feeds = {}, children = {} }
--   OPML.write([path], feeds)  → true on success (preserves folder field)
--   OPML.mergeFeeds(base, add) → merged feed list (dedupe by URL)
--   OPML.OPML_FILE             default path

local DataStorage = require("datastorage")
local Xml         = require("modules/lib/xml")
local logger      = require("logger")

local OPML_FILE = DataStorage:getDataDir() .. "/quickrss/feeds.opml"

local OPML = {}

local function unescAttr(s)
    return s:gsub("&lt;", "<"):gsub("&gt;", ">"):gsub("&quot;", '"')
            :gsub("&apos;", "'"):gsub("&amp;", "&")
end

local function getAttr(tag, name)
    local val = tag:match(name .. '%s*=%s*"([^"]*)"')
             or tag:match(name .. "%s*=%s*'([^']*)'")
    return val and unescAttr(val) or nil
end

local function escAttr(s)
    return (s or "")
        :gsub("&",  "&amp;")
        :gsub('"',  "&quot;")
        :gsub("'",  "&apos;")
        :gsub("<",  "&lt;")
        :gsub(">",  "&gt;")
end

local function joinFolder(parent, name)
    if not parent or parent == "" then return name end
    if not name or name == "" then return parent end
    return parent .. "/" .. name
end

-- Parse OPML body into a tree of folders and feeds.
local function parseTree(content)
    local root = { name = "", feeds = {}, children = {} }
    local stack = { root }
    local folder_stack = { "" }
    local outline_kinds = {}

    local handler = {
        starttag = function(_, tag, attrs)
            if tag:lower() ~= "outline" or not attrs then return end
            local text = attrs.text or attrs.title or ""
            local url  = attrs.xmlurl or attrs.xmlUrl
            if url and url ~= "" then
                local folder = folder_stack[#folder_stack]
                table.insert(stack[#stack].feeds, {
                    name = text,
                    url  = url,
                    folder = (folder ~= "" and folder) or nil,
                })
                table.insert(outline_kinds, "feed")
            else
                local folder = joinFolder(folder_stack[#folder_stack], text)
                local node = { name = text, feeds = {}, children = {} }
                table.insert(stack[#stack].children, node)
                table.insert(stack, node)
                table.insert(folder_stack, folder)
                table.insert(outline_kinds, "folder")
            end
        end,
        endtag = function(_, tag)
            if tag:lower() ~= "outline" then return end
            local kind = table.remove(outline_kinds)
            if kind == "folder" and #stack > 1 then
                table.remove(stack)
                table.remove(folder_stack)
            end
        end,
    }

    local ok, err = pcall(function()
        Xml.xmlParser(handler):parse(content)
    end)
    if not ok then
        logger.warn("QuickRSS: OPML XML parse failed, falling back to regex:", err)
        return nil
    end
    return root
end

local function flattenTree(node, parent_folder)
    local feeds = {}
    for _, feed in ipairs(node.feeds or {}) do
        local copy = { name = feed.name, url = feed.url }
        local folder = feed.folder or parent_folder
        if folder and folder ~= "" then copy.folder = folder end
        table.insert(feeds, copy)
    end
    for _, child in ipairs(node.children or {}) do
        local child_folder = joinFolder(parent_folder, child.name)
        local child_feeds = flattenTree(child, child_folder)
        for _, f in ipairs(child_feeds) do
            table.insert(feeds, f)
        end
    end
    return feeds
end

-- Legacy regex reader for malformed or simple OPML.
local function readFlatRegex(content)
    local feeds = {}
    for tag in content:gmatch("<outline%s+([^>]*)/?%s*>") do
        local name = getAttr(tag, "text")
        local url  = getAttr(tag, "xmlUrl") or getAttr(tag, "xmlurl")
        if name and url and url ~= "" then
            table.insert(feeds, { name = name, url = url })
        end
    end
    return feeds
end

function OPML.readTree(path)
    path = path or OPML_FILE
    local f = io.open(path, "r")
    if not f then return nil end
    local content = f:read("*a")
    f:close()
    return parseTree(content) or { name = "", feeds = readFlatRegex(content), children = {} }
end

function OPML.read(path)
    path = path or OPML_FILE
    local f = io.open(path, "r")
    if not f then return nil end
    local content = f:read("*a")
    f:close()

    local tree = parseTree(content)
    local feeds = tree and flattenTree(tree, "") or {}
    if #feeds == 0 then
        feeds = readFlatRegex(content)
    end
    logger.dbg("QuickRSS: loaded", #feeds, "feeds from OPML")
    return feeds
end

local function writeFolder(lines, indent, folder_name, feeds_in_folder, subfolders)
    table.insert(lines, string.format('%s<outline text="%s">', indent, escAttr(folder_name)))
    local child_indent = indent .. "  "
    for _, feed in ipairs(feeds_in_folder) do
        table.insert(lines, string.format(
            '%s<outline text="%s" type="rss" xmlUrl="%s"/>',
            child_indent, escAttr(feed.name), escAttr(feed.url)))
    end
    local names = {}
    for name in pairs(subfolders) do table.insert(names, name) end
    table.sort(names)
    for _, name in ipairs(names) do
        writeFolder(lines, child_indent, name,
            subfolders[name].feeds, subfolders[name].children)
    end
    table.insert(lines, indent .. "</outline>")
end

local function buildFolderTree(feeds)
    local root_feeds = {}
    local root_children = {}
    for _, feed in ipairs(feeds) do
        local f = feed.folder
        if not f or f == "" then
            table.insert(root_feeds, feed)
        else
            local top, rest = f:match("^([^/]+)/(.+)$")
            if not top then
                top, rest = f, nil
            end
            root_children[top] = root_children[top] or { feeds = {}, children = {} }
            if rest then
                local node = root_children[top]
                for part in rest:gmatch("[^/]+") do
                    node.children[part] = node.children[part] or { feeds = {}, children = {} }
                    node = node.children[part]
                end
                table.insert(node.feeds, feed)
            else
                table.insert(root_children[top].feeds, feed)
            end
        end
    end
    return root_feeds, root_children
end

function OPML.write(path, feeds)
    path = path or OPML_FILE
    feeds = feeds or {}
    local lines = {
        '<?xml version="1.0" encoding="UTF-8"?>',
        '<opml version="1.0">',
        '  <head><title>QuickRSS Feeds</title></head>',
        '  <body>',
    }

    local root_feeds, root_children = buildFolderTree(feeds)
    for _, feed in ipairs(root_feeds) do
        table.insert(lines, string.format(
            '    <outline text="%s" type="rss" xmlUrl="%s"/>',
            escAttr(feed.name), escAttr(feed.url)))
    end

    local top_names = {}
    for name in pairs(root_children) do table.insert(top_names, name) end
    table.sort(top_names)
    for _, name in ipairs(top_names) do
        writeFolder(lines, "    ", name,
            root_children[name].feeds, root_children[name].children)
    end

    table.insert(lines, '  </body>')
    table.insert(lines, '</opml>')

    local f, err = io.open(path, "w")
    if not f then
        logger.warn("QuickRSS: could not write OPML file:", path, err)
        return false
    end
    f:write(table.concat(lines, "\n") .. "\n")
    f:close()
    logger.dbg("QuickRSS: wrote", #feeds, "feeds to OPML")
    return true
end

OPML.OPML_FILE = OPML_FILE

function OPML.mergeFeeds(base, add)
    local seen = {}
    local merged = {}
    local function insert(feed)
        local url = (feed.url or ""):lower()
        if url ~= "" and not seen[url] then
            seen[url] = true
            local copy = { name = feed.name, url = feed.url }
            if feed.folder and feed.folder ~= "" then
                copy.folder = feed.folder
            end
            table.insert(merged, copy)
        end
    end
    for _, feed in ipairs(base or {}) do insert(feed) end
    for _, feed in ipairs(add or {}) do insert(feed) end
    return merged
end

return OPML

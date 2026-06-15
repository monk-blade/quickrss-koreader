-- QuickRSS: Article Export
-- Saves an article as a standalone HTML file plus local images for offline reading
-- on a computer or in another app.
--
-- Public API:
--   ArticleExport.sanitizeFilename(title)  → safe base name
--   ArticleExport.save(article, dir_path)  → path, err

local DataStorage = require("datastorage")
local HtmlCleanup   = require("modules/data/html_cleanup")
local Images      = require("modules/data/images")
local lfs         = require("libs/libkoreader-lfs")
local logger      = require("logger")

local IMAGE_DIR = Images.IMAGE_DIR
local SAVE_DIR  = DataStorage:getDataDir() .. "/quickrss/saved"

local ArticleExport = {}

local function escapeHtml(s)
    local r = (s or "")
        :gsub("&",  "&amp;")
        :gsub("<",  "&lt;")
        :gsub(">",  "&gt;")
        :gsub('"',  "&quot;")
        :gsub("'",  "&#39;")
    return r
end

local function formatDate(raw)
    if not raw or raw == "" then return nil end
    local d = raw:match("%a+,%s+(%d+%s+%a+%s+%d+)")
    if d then return d end
    d = raw:match("(%d%d%d%d%-%d%d%-%d%d)")
    if d then return d end
    return raw
end

local function datePrefix(raw)
    local iso = raw and raw:match("(%d%d%d%d%-%d%d%-%d%d)")
    if iso then return iso end
    return os.date("%Y-%m-%d")
end

-- Produce a filesystem-safe slug from a title (ASCII alnum + hyphen).
function ArticleExport.sanitizeFilename(title)
    title = (title or "article"):gsub("^%s+", ""):gsub("%s+$", "")
    title = title:gsub("[%c%/%\\%:%*%?%\"<>%|%&]", " ")
    title = title:gsub("%s+", "-"):gsub("%-+", "-"):gsub("^%-", ""):gsub("%-$", "")
    if title == "" then title = "article" end
    if #title > 80 then title = title:sub(1, 80) end
    return title
end

local function copyFile(src, dst)
    local inf = io.open(src, "rb")
    if not inf then return false end
    local data = inf:read("*a")
    inf:close()
    local outf = io.open(dst, "wb")
    if not outf then return false end
    outf:write(data)
    outf:close()
    return true
end

local function collectImageNames(html, article)
    local names = {}
    local function add(fname)
        if fname and fname ~= "" and not fname:match("^https?://") then
            names[fname] = true
        end
    end
    if article.image_path then
        add(article.image_path:match("([^/]+)$"))
    end
    if html then
        for fname in html:gmatch('[Ss][Rr][Cc]%s*=%s*"([^"/][^"]*)"') do add(fname) end
        for fname in html:gmatch("[Ss][Rr][Cc]%s*=%s*'([^'/][^']*)'") do add(fname) end
    end
    return names
end

local function buildDocument(article)
    local meta_parts = {}
    if article.source and article.source ~= "" then
        table.insert(meta_parts, escapeHtml(article.source))
    end
    local fmt_date = formatDate(article.date)
    if fmt_date then table.insert(meta_parts, escapeHtml(fmt_date)) end
    if article.link and article.link ~= "" then
        table.insert(meta_parts, '<a href="' .. escapeHtml(article.link) .. '">'
            .. escapeHtml(article.link) .. "</a>")
    end

    local body = article.content or ""
    if body == "" then
        body = "<p>" .. escapeHtml(article.full_text or "") .. "</p>"
    end
    body = HtmlCleanup.clean(body, { title = article.title })

    local banner = ""
    if article.image_path then
        local fname = article.image_path:match("([^/]+)$")
        if fname then
            banner = '<p><img src="' .. fname .. '" style="max-width:100%"></p>\n'
        end
    end

    local meta_html = ""
    if #meta_parts > 0 then
        meta_html = '<p class="meta">' .. table.concat(meta_parts, " &middot; ") .. "</p>\n"
    end

    local css = [[
body { font-family: Georgia, serif; font-size: 18px; line-height: 1.5;
       margin: 1.5em; max-width: 40em; }
h1 { font-size: 1.4em; line-height: 1.2; }
.meta { font-size: 0.85em; color: #555; }
img { max-width: 100%; height: auto; }
a { color: inherit; }
]]

    return string.format([[
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>%s</title>
<style>%s</style>
</head>
<body>
<h1>%s</h1>
%s
<hr>
%s
%s
</body>
</html>
]], escapeHtml(article.title or "Article"), css,
    escapeHtml(article.title or "Article"),
    meta_html, banner, body)
end

-- Save article HTML and images to dir_path (must end with /).
-- Returns (full_path_to_html, nil) or (nil, error_string).
function ArticleExport.save(article, dir_path)
    if not article then return nil, "no article" end
    if not dir_path or dir_path == "" then return nil, "no directory" end
    if dir_path:sub(-1) ~= "/" then dir_path = dir_path .. "/" end

    local attr = lfs.attributes(dir_path, "mode")
    if attr ~= "directory" then return nil, "not a directory" end

    local slug = ArticleExport.sanitizeFilename(article.title)
    local prefix = datePrefix(article.date)
    local base = prefix .. "_" .. slug
    local html_path = dir_path .. base .. ".html"

    local html = buildDocument(article)
    local images = collectImageNames(article.content, article)

    for fname in pairs(images) do
        local src = IMAGE_DIR .. "/" .. fname
        if lfs.attributes(src, "mode") == "file" then
            copyFile(src, dir_path .. fname)
        end
    end

    local f, err = io.open(html_path, "w")
    if not f then
        return nil, tostring(err)
    end
    f:write(html)
    f:close()

    -- Also keep a copy under plugin saved/ for easy USB retrieval.
    lfs.mkdir(DataStorage:getDataDir() .. "/quickrss")
    lfs.mkdir(SAVE_DIR)
    local internal = SAVE_DIR .. "/" .. base .. ".html"
    local ok = copyFile(html_path, internal)
    if ok then
        for fname in pairs(images) do
            copyFile(dir_path .. fname, SAVE_DIR .. "/" .. fname)
        end
    end

    logger.info("QuickRSS: saved article to", html_path)
    return html_path, nil
end

ArticleExport.SAVE_DIR = SAVE_DIR

return ArticleExport

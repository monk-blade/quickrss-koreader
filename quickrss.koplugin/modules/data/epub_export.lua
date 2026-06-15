-- QuickRSS: EPUB Export
-- Builds EPUB files from cached articles using KOReader's ffi/archiver.

local ArticleExport = require("modules/data/article_export")
local HtmlCleanup   = require("modules/data/html_cleanup")
local Images        = require("modules/data/images")
local TextUtil      = require("modules/lib/text_util")
local lfs           = require("libs/libkoreader-lfs")
local logger        = require("logger")

local IMAGE_DIR = Images.IMAGE_DIR

local EpubExport = {}

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

local function readFile(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local data = f:read("*a")
    f:close()
    return data
end

local EXT_MIME = {
    jpg = "image/jpeg", jpeg = "image/jpeg",
    png = "image/png", gif = "image/gif",
    webp = "image/webp", svg = "image/svg+xml",
}

local function buildHtml(article)
    local meta_parts = {}
    if article.source and article.source ~= "" then
        table.insert(meta_parts, escapeHtml(article.source))
    end
    local fmt_date = formatDate(article.date)
    if fmt_date then table.insert(meta_parts, escapeHtml(fmt_date)) end
    local rt = TextUtil.readingTime(TextUtil.articlePlainText(article), true)
    if rt then table.insert(meta_parts, rt) end

    local body = article.content or ""
    if body == "" then
        body = "<p>" .. escapeHtml(article.full_text or "") .. "</p>"
    end
    body = HtmlCleanup.clean(body, { title = article.title, headings = true })

    local banner = ""
    if article.image_path then
        local fname = article.image_path:match("([^/]+)$")
        if fname then
            banner = '<p><img src="images/' .. fname .. '" style="max-width:100%"></p>\n'
        end
    end

    local meta_html = ""
    if #meta_parts > 0 then
        meta_html = '<p class="meta">' .. table.concat(meta_parts, " &middot; ") .. "</p>\n"
    end

    local css = [[
body { font-family: Georgia, serif; font-size: 18px; line-height: 1.5; margin: 1em; }
h1 { font-size: 1.4em; }
.meta { font-size: 0.85em; color: #555; }
img { max-width: 100%; height: auto; }
figure { text-align: center; margin: 0.5em 0; }
]]

    return string.format([[
<?xml version="1.0" encoding="utf-8"?>
<!DOCTYPE html>
<html xmlns="http://www.w3.org/1999/xhtml">
<head>
<meta charset="utf-8"/>
<title>%s</title>
<style>%s</style>
</head>
<body>
<h1>%s</h1>
%s
<hr/>
%s
%s
</body>
</html>
]], escapeHtml(article.title or "Article"), css,
    escapeHtml(article.title or "Article"),
    meta_html, banner, body)
end

local function writeEpub(article, epub_path, html)
    local Archiver = require("ffi/archiver")
    local epub = Archiver.Writer:new{}
    local tmp_path = epub_path .. ".tmp"
    if not epub:open(tmp_path, "epub") then
        return false, "could not open epub writer"
    end

    local mtime = os.time()
    local title = article.title or "Article"
    local bookid = "quickrss-" .. (article.link or title):gsub("[^%w]", ""):sub(1, 32)

    epub:setZipCompression("store")
    epub:addFileFromMemory("mimetype", "application/epub+zip", mtime)
    epub:setZipCompression("deflate")

    epub:addFileFromMemory("META-INF/container.xml", [[<?xml version="1.0"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles>
    <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
  </rootfiles>
</container>]], mtime)

    local images = collectImageNames(article.content, article)
    local manifest = {}
    local manifest_lines = {}
    for fname in pairs(images) do
        local src = IMAGE_DIR .. "/" .. fname
        if lfs.attributes(src, "mode") == "file" then
            local ext = fname:match("%.([^.]+)$")
            local mime = EXT_MIME[(ext or ""):lower()] or "image/jpeg"
            local imgid = "img-" .. fname:gsub("[^%w]", "_")
            table.insert(manifest, { fname = fname, imgid = imgid, mime = mime })
            table.insert(manifest_lines, string.format(
                '    <item id="%s" href="images/%s" media-type="%s"/>',
                imgid, fname, mime))
        end
    end

    local opf = string.format([[
<?xml version="1.0" encoding="utf-8"?>
<package xmlns="http://www.idpf.org/2007/opf" version="2.0" unique-identifier="bookid">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
    <dc:title>%s</dc:title>
    <dc:identifier id="bookid">%s</dc:identifier>
    <dc:creator>QuickRSS</dc:creator>
  </metadata>
  <manifest>
    <item id="content" href="content.html" media-type="application/xhtml+xml"/>
    <item id="css" href="stylesheet.css" media-type="text/css"/>
    <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>
%s
  </manifest>
  <spine toc="ncx">
    <itemref idref="content"/>
  </spine>
</package>]], escapeHtml(title), bookid, table.concat(manifest_lines, "\n"))

    epub:addFileFromMemory("OEBPS/content.opf", opf, mtime)
    epub:addFileFromMemory("OEBPS/stylesheet.css", "/* QuickRSS */", mtime)

    local ncx = string.format([[
<?xml version="1.0" encoding="UTF-8"?>
<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
  <head>
    <meta name="dtb:uid" content="%s"/>
    <meta name="dtb:depth" content="1"/>
    <meta name="dtb:totalPageCount" content="0"/>
    <meta name="dtb:maxPageNumber" content="0"/>
  </head>
  <docTitle><text>%s</text></docTitle>
  <navMap>
    <navPoint id="navpoint-1" playOrder="1">
      <navLabel><text>%s</text></navLabel>
      <content src="content.html"/>
    </navPoint>
  </navMap>
</ncx>]], bookid, escapeHtml(title), escapeHtml(title))

    epub:addFileFromMemory("OEBPS/toc.ncx", ncx, mtime)
    epub:addFileFromMemory("OEBPS/content.html", html, mtime)

    for _, img in ipairs(manifest) do
        local data = readFile(IMAGE_DIR .. "/" .. img.fname)
        if data then
            local no_compress = img.mime ~= "image/svg+xml"
            epub:addFileFromMemory("OEBPS/images/" .. img.fname, data, no_compress, mtime)
        end
    end

    epub:close()
    os.remove(epub_path)
    local ok, err = os.rename(tmp_path, epub_path)
    if not ok then
        return false, tostring(err)
    end
    return true
end

-- Export one article to dir_path. Returns (epub_path, nil) or (nil, err).
function EpubExport.exportOne(article, dir_path)
    if not article then return nil, "no article" end
    if dir_path:sub(-1) ~= "/" then dir_path = dir_path .. "/" end
    if lfs.attributes(dir_path, "mode") ~= "directory" then
        return nil, "not a directory"
    end

    local slug = ArticleExport.sanitizeFilename(article.title)
    local epub_path = dir_path .. slug .. ".epub"
    local html = buildHtml(article)

    local ok, err = writeEpub(article, epub_path, html)
    if not ok then return nil, err end
    logger.info("QuickRSS: exported EPUB to", epub_path)
    return epub_path, nil
end

-- Export many articles sequentially. Returns ok_count, errors[], exported_links[].
function EpubExport.exportBatch(articles, dir_path, on_progress)
    local ok_count = 0
    local errors = {}
    local exported_links = {}
    for i, art in ipairs(articles or {}) do
        if on_progress then on_progress(i, #articles, art) end
        local path, err = EpubExport.exportOne(art, dir_path)
        if path then
            ok_count = ok_count + 1
            if art.link then table.insert(exported_links, art.link) end
        else
            table.insert(errors, (art.title or art.link or "?") .. ": " .. tostring(err))
        end
        collectgarbage("collect")
    end
    return ok_count, errors, exported_links
end

return EpubExport

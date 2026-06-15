-- QuickRSS: Parser Module
-- Async HTTP fetcher + XML parser that normalises RSS 2.0 and Atom feeds into
-- a flat article list.  For feeds that only publish summaries, full-text HTML
-- is fetched at fetch-time via the FiveFilters API so articles can be read
-- offline without a network connection.
--
-- Public API:
--   Parser.fetchAll(feeds, on_success, on_error, on_progress, on_status)
--     feeds       – array of { name, url } from Config.getFeeds()
--     on_success  – function(articles, errors)
--     on_error    – function(message) called only when ALL feeds fail
--     on_progress – function(name, i, total) called before each feed fetch
--     on_status   – function(message) called with a raw status string
--
--   Parser.parse(raw_xml)
--     Returns (result, nil) on success or (nil, error_string) on failure.
--     result = { feed_title = string, articles = { {title, link, snippet,
--                                                   content, image_url}, ... } }

local Config     = require("modules/data/config")
local HttpFetch  = require("modules/data/http_fetch")
local logger     = require("logger")
local NetworkMgr = require("ui/network/manager")
local util       = require("util")

local Parser = {}

-- ── Full-text helpers ─────────────────────────────────────────────────────────

-- Strip HTML tags and return the length of the remaining plain text.
local function _plainLength(html)
    if not html or html == "" then return 0 end
    local plain = html:gsub("<[^>]+>", ""):gsub("%s+", " ")
    return #(plain:match("^%s*(.-)%s*$") or "")
end

-- Return true when the HTML looks like a truncated summary – i.e. it ends with
-- a "Read full article / Read more / Continue reading" style link, which
-- publishers like Ars Technica inject to drive traffic back to their site.
local TRUNCATION_PATTERNS = {
    "read full article",
    "read the full article",
    "read more",
    "continue reading",
    "full story",
    "see full article",
}
local function _isTruncated(html)
    if not html or html == "" then return false end
    local lower = html:lower()
    for _, pat in ipairs(TRUNCATION_PATTERNS) do
        if lower:find(pat, 1, true) then return true end
    end
    return false
end

-- Extract a tag's inner content from an XML/HTML block.
-- Handles both CDATA-wrapped and plain text values.
-- Uses [%s%S] so the lazy match crosses newlines.
local function _extractXmlTag(block, tag)
    local value = block:match("<" .. tag .. "[^>]*>([%s%S]-)</" .. tag .. ">")
    if not value then return nil end
    value = value:match("^%s*(.-)%s*$")
    local cdata = value:match("^<!%[CDATA%[([%s%S]*)%]%]>$")
    return cdata or value
end

-- Remove unsafe HTML: block-level dangerous tags (script, iframe, …) and
-- inline event handlers / javascript: URLs.
local function _sanitizeHtml(html)
    if type(html) ~= "string" or html == "" then return html end
    for _, tag in ipairs({"script", "style", "iframe", "object", "embed", "noscript"}) do
        -- [%s%S]- crosses newlines inside block-tag content
        html = html:gsub("<" .. tag .. "[^>]*>[%s%S]-</" .. tag .. ">", "")
        html = html:gsub("<" .. tag .. "[^>]*/>", "")
    end
    -- Event handler attributes (onclick=, onload=, …)
    html = html:gsub("%s+on[%w_%-]+%s*=%s*\"[^\"]*\"", "")
    html = html:gsub("%s+on[%w_%-]+%s*=%s*'[^']*'", "")
    -- Neutralise javascript: href/src values
    html = html:gsub("(href%s*=%s*\")javascript:[^\"]*\"", "%1\"")
    html = html:gsub("(href%s*=%s*')javascript:[^']*'",    "%1'")
    html = html:gsub("(src%s*=%s*\")javascript:[^\"]*\"",  "%1\"")
    html = html:gsub("(src%s*=%s*')javascript:[^']*'",     "%1'")
    return html
end

-- ── Text helpers ─────────────────────────────────────────────────────────────

-- Encode a Unicode code point as a UTF-8 string.
local function utf8char(cp)
    if cp < 0x80 then
        return string.char(cp)
    elseif cp < 0x800 then
        return string.char(
            0xC0 + math.floor(cp / 0x40),
            0x80 + cp % 0x40)
    elseif cp < 0x10000 then
        return string.char(
            0xE0 + math.floor(cp / 0x1000),
            0x80 + math.floor(cp / 0x40) % 0x40,
            0x80 + cp % 0x40)
    elseif cp < 0x110000 then
        return string.char(
            0xF0 + math.floor(cp / 0x40000),
            0x80 + math.floor(cp / 0x1000) % 0x40,
            0x80 + math.floor(cp / 0x40) % 0x40,
            0x80 + cp % 0x40)
    end
    return ""
end

-- Decode HTML/XML numeric and named character entities.
local function decodeEntities(s)
    if not s or s == "" then return s end
    s = s:gsub("&#(%d+);", function(n)
        local cp = tonumber(n)
        return cp and cp >= 32 and utf8char(cp) or ""
    end)
    s = s:gsub("&#[xX](%x+);", function(h)
        local cp = tonumber(h, 16)
        return cp and cp >= 32 and utf8char(cp) or ""
    end)
    s = s:gsub("&nbsp;",  " ")
    s = s:gsub("&lt;",    "<")
    s = s:gsub("&gt;",    ">")
    s = s:gsub("&quot;",  '"')
    s = s:gsub("&apos;",  "'")
    s = s:gsub("&amp;",   "&")  -- must be last to avoid double-decoding
    return s
end

-- Convert HTML to plain text while preserving paragraph structure.
-- Block-level elements become blank lines; <br> becomes a single newline;
-- <li> items get a bullet prefix.  All remaining tags are stripped and
-- common HTML entities are decoded.
local function htmlToText(s)
    if not s or s == "" then return "" end
    -- Block-level elements → paragraph breaks
    s = s:gsub("<[hH][1-6][^>]*>",    "\n\n")   -- heading open
    s = s:gsub("</[hH][1-6]>",        "\n\n")   -- heading close
    s = s:gsub("<[pP][^>]*>",         "\n\n")   -- <p>
    s = s:gsub("</[pP]>",             "\n\n")   -- </p>
    s = s:gsub("<[dD][iI][vV][^>]*>", "\n\n")   -- <div>
    s = s:gsub("<[bB][rR]%s*/?>",     "\n")     -- <br> / <br/>
    s = s:gsub("<[lL][iI][^>]*>",     "\n\x95 ") -- <li>  (\x95 = bullet)
    -- Strip all remaining tags
    s = s:gsub("<[^>]+>", "")
    -- Decode HTML entities (numeric, hex, and named)
    s = decodeEntities(s)
    -- Normalise whitespace while preserving paragraph breaks
    s = s:gsub("[ \t\r]+", " ")    -- collapse horizontal whitespace
    s = s:gsub(" *\n *",    "\n")  -- trim spaces around newlines
    s = s:gsub("\n\n\n+",   "\n\n") -- at most one blank line between paragraphs
    s = s:match("^%s*(.-)%s*$")    -- trim leading/trailing whitespace
    return s
end

-- Parse a FiveFilters RSS response body into sanitized article HTML.
local function _parseFullTextResponse(body, article_url)
    if not body then return nil end
    if body:find("URL blocked", 1, true) then
        logger.warn("QuickRSS FiveFilters URL blocked:", article_url)
        return nil
    end

    local item_block = body:match("<item[^>]*>([%s%S]-)</item>")
    if not item_block then return nil end

    local desc = _extractXmlTag(item_block, "description")
    if not desc or desc == "" then return nil end

    desc = desc:gsub("&lt;", "<"):gsub("&gt;", ">"):gsub("&amp;", "&")

    if desc:lower():find("[unable to retrieve full-text content]", 1, true) then
        return nil
    end

    desc = desc:gsub(
        "%s*<p>%s*<strong>%s*<a%s+href=\"https://blockads%.fivefilters%.org\">Adblock%s+test</a>"
        .. "%s*</strong>%s*<a%s+href=\"https://blockads%.fivefilters%.org/acceptable%.html\">"
        .. "%(Why%?%)</a>%s*</p>%s*",
        ""
    )

    desc = _sanitizeHtml(desc)
    if _plainLength(desc) < 100 then return nil end
    return desc
end

-- Fetch the full-text HTML for a single article URL via the FiveFilters API.
local function _fetchFullText(article_url, base_url)
    if not article_url or article_url == "" then return nil end
    local encoded = util.urlEncode(article_url)
    if not encoded or encoded == "" then return nil end

    local ff_url = (base_url or "https://ftr.fivefilters.net/makefulltextfeed.php")
        .. "?step=3&fulltext=1&url=" .. encoded
        .. "&max=3&links=preserve&exc=1&submit=Create+Feed"

    local body, err = HttpFetch.fetchRaw(ff_url)
    if not body then
        logger.warn("QuickRSS FiveFilters fetch failed:", err)
        return nil
    end
    return _parseFullTextResponse(body, article_url)
end

-- ── fetchAll ──────────────────────────────────────────────────────────────────
-- Fetch every feed in `feeds` with bounded parallel HTTP (subprocess pool on
-- Linux/macOS), then enrich truncated articles via FiveFilters in parallel.
function Parser.fetchAll(feeds, on_success, on_error, on_progress, on_status, cached_by_link)
    local UIManager = require("ui/uimanager")

    local function _doFetch()
        local all_articles = {}
        local errors       = {}
        local concurrency  = Config.getFetchConcurrency()

        -- ── Phase 1: fetch all feeds in parallel ─────────────────────────────
        local feed_jobs = {}
        for i, feed in ipairs(feeds) do
            local url = feed.url:match("^https?://") and feed.url
                        or ("https://" .. feed.url)
            feed_jobs[i] = { id = "feed_" .. i, url = url, feed = feed }
        end

        local fetch_jobs = {}
        for _, fj in ipairs(feed_jobs) do
            table.insert(fetch_jobs, { id = fj.id, url = fj.url })
        end

        local feed_results = HttpFetch.fetchMany(fetch_jobs, {
            concurrency = concurrency,
            on_progress = function(done, total, id)
                local idx = tonumber(id:match("feed_(%d+)"))
                local feed = idx and feed_jobs[idx] and feed_jobs[idx].feed
                if feed and on_progress then
                    on_progress(feed.name, done, total)
                end
            end,
        })

        for _, fj in ipairs(feed_jobs) do
            local feed = fj.feed
            local res  = feed_results[fj.id]
            if not res or res.error then
                local err = res and res.error or "fetch failed"
                logger.warn("QuickRSS fetch failed for", feed.name, ":", err)
                table.insert(errors, feed.name .. ": " .. err)
            else
                local raw_xml = res.body
                logger.info("QuickRSS fetch OK:", feed.name, #raw_xml, "bytes")

                local result, parse_err = Parser.parse(raw_xml)
                if not result then
                    logger.warn("QuickRSS parse error for", feed.name, ":", parse_err)
                    table.insert(errors, feed.name .. ": " .. tostring(parse_err))
                else
                    local limit = Config.getArticleSettings().items_per_feed
                    while #result.articles > limit do
                        table.remove(result.articles)
                    end
                    for _, article in ipairs(result.articles) do
                        article.source = feed.name
                        table.insert(all_articles, article)
                    end
                end
            end
        end

        collectgarbage("collect")

        -- ── Phase 2: enrich thin articles with full text (parallel) ─────────
        local art_settings = Config.getArticleSettings()
        local needs_ft = {}
        if art_settings.fulltext_enabled then
            for _, art in ipairs(all_articles) do
                if art.link ~= ""
                and (_plainLength(art.content) < 2000 or _isTruncated(art.content))
                then
                    local cached = cached_by_link and cached_by_link[art.link]
                    if cached and _plainLength(cached.content) >= 2000 then
                        art.content   = cached.content
                        art.full_text = cached.full_text
                        art.snippet   = cached.snippet
                        if not art.image_url then art.image_url = cached.image_url end
                        logger.dbg("QuickRSS: reused cached full-text for", art.link)
                    else
                        table.insert(needs_ft, art)
                    end
                end
            end
        end

        if #needs_ft > 0 then
            local ft_url = art_settings.fulltext_url
            local ft_jobs = {}
            for j, art in ipairs(needs_ft) do
                local encoded = util.urlEncode(art.link)
                if encoded and encoded ~= "" then
                    local url = ft_url
                        .. "?step=3&fulltext=1&url=" .. encoded
                        .. "&max=3&links=preserve&exc=1&submit=Create+Feed"
                    table.insert(ft_jobs, {
                        id  = "ft_" .. j,
                        url = url,
                        art = art,
                    })
                end
            end

            local ft_concurrency = math.min(2, concurrency)
            local ft_results = HttpFetch.fetchMany(ft_jobs, {
                concurrency = ft_concurrency,
                on_progress = function(done, total, id)
                    local j = tonumber(id:match("ft_(%d+)"))
                    local art = j and ft_jobs[j] and ft_jobs[j].art
                    if art and on_status then
                        on_status("Fetching full text " .. done .. "/" .. total
                                  .. "\n(" .. art.source .. ")")
                    end
                end,
            })

            for _, job in ipairs(ft_jobs) do
                local art = job.art
                local res = ft_results[job.id]
                if res and res.body then
                    local full_html = _parseFullTextResponse(res.body, art.link)
                    if full_html then
                        art.content = full_html
                        local plain = htmlToText(full_html)
                        art.full_text = plain
                        art.snippet   = plain:gsub("\n+", " "):sub(1, 300)
                        if not art.image_url then
                            art.image_url = full_html:match('<img[^>]+src%s*=%s*"(https?://[^"]+)"')
                                or full_html:match("<img[^>]+src%s*=%s*'(https?://[^']+)'")
                        end
                    end
                end
            end
        end

        collectgarbage("collect")

        if #all_articles == 0 and #errors > 0 then
            if on_error then on_error(table.concat(errors, "\n")) end
        else
            if on_success then on_success(all_articles, errors) end
        end
    end  -- _doFetch

    if NetworkMgr:isConnected() then
        -- Already online — skip runWhenOnline entirely so no popup appears.
        _doFetch()
    else
        -- WiFi is off — let NetworkMgr prompt the user to connect.
        -- Once connected, close the "Connected" InfoMessage (tag = "NetworkMgr")
        -- before starting the blocking fetch, otherwise it covers our progress.
        NetworkMgr:runWhenOnline(function()
            UIManager:nextTick(function()
                for i = #UIManager._window_stack, 1, -1 do
                    local w = UIManager._window_stack[i]
                    if w and w.widget and w.widget.tag == "NetworkMgr" then
                        UIManager:close(w.widget)
                        break
                    end
                end
                _doFetch()
            end)
        end)
    end
end

-- ── parse helpers ─────────────────────────────────────────────────────────────

-- Extract the src URL of the first <img> element found in an HTML string.
local function firstImageUrl(html)
    if not html then return nil end
    return html:match('<img[^>]+src%s*=%s*"(https?://[^"]+)"')
        or html:match("<img[^>]+src%s*=%s*'(https?://[^']+)'")
end

-- Extract the best thumbnail URL for an item, preferring explicit media
-- namespace / enclosure declarations over scraping the HTML body.
local function extractThumbnailUrl(raw, content)
    -- <media:thumbnail url="..."/>
    local mt = raw["media:thumbnail"]
    if type(mt) == "table" and mt._attr and mt._attr.url then
        return mt._attr.url
    end
    -- <media:content url="..." medium="image"> or type="image/..."
    local mc = raw["media:content"]
    if type(mc) == "table" and mc._attr and mc._attr.url then
        local med  = mc._attr.medium or ""
        local mime = mc._attr.type   or ""
        if med == "image" or mime:match("^image/") then
            return mc._attr.url
        end
    end
    -- <enclosure url="..." type="image/..."/>  (RSS 2.0)
    local enc = raw.enclosure
    if type(enc) == "table" and enc._attr and enc._attr.url then
        if (enc._attr.type or ""):match("^image/") then
            return enc._attr.url
        end
    end
    -- Fall back to first remote <img> found in the HTML body
    return firstImageUrl(content)
end

-- Safely coerce a value that may be a string or a single-element table to a
-- string.  simpleTreeHandler sometimes wraps plain text in a 1-element table.
local function toStr(v)
    if type(v) == "string" then return v end
    if type(v) == "table"  then return toStr(v[1]) end
    return ""
end

-- Ensure a value that may be a table of items OR a single item is always
-- returned as an array.  simpleTreeHandler reduces 1-element vectors.
local function toArray(v)
    if type(v) ~= "table" then return {} end
    -- A vector has integer keys 1..n; a single reduced item has string keys.
    if v[1] ~= nil then return v end
    return { v }  -- wrap the single item so callers can always ipairs()
end

-- ── parse ─────────────────────────────────────────────────────────────────────
-- Convert a raw RSS 2.0 or Atom XML string into a normalised result table.
-- Returns (result_table, nil) on success, (nil, error_string) on failure.
function Parser.parse(raw_xml)
    local xmlParser     = require("modules/lib/xml").xmlParser
    local treeHandler   = require("modules/lib/handler").simpleTreeHandler

    -- Strip the UTF-8 BOM that some feeds prepend (xml.lua doesn't handle it)
    raw_xml = raw_xml:gsub("^\xef\xbb\xbf", "", 1)

    local handler = treeHandler()
    local ok, err = pcall(function()
        xmlParser(handler):parse(raw_xml)
    end)
    if not ok then
        logger.warn("QuickRSS XML parse error:", err)
        return nil, tostring(err)
    end

    local tree = handler.root
    local feed_title, raw_items, is_atom

    -- ── Detect feed format ──────────────────────────────────────────────────
    if tree.rss and tree.rss.channel then
        local ch  = tree.rss.channel
        feed_title = toStr(ch.title)
        raw_items  = toArray(ch.item)
    elseif tree.feed then
        is_atom    = true
        feed_title = toStr(tree.feed.title)
        raw_items  = toArray(tree.feed.entry)
    else
        return nil, "Unrecognised feed format"
    end

    logger.info("QuickRSS parsed feed:", feed_title, "items:", #raw_items)

    -- ── Normalise each item/entry ───────────────────────────────────────────
    local articles = {}
    for _, raw in ipairs(raw_items) do
        local title, link, content

        if is_atom then
            title   = toStr(raw.title)
            -- Atom <link> may be a single {_attr={href=…}} or an array of them
            -- when the entry has multiple <link> elements (e.g. alternate + self).
            if type(raw.link) == "table" then
                if raw.link._attr then
                    -- Single <link>
                    link = raw.link._attr.href or ""
                elseif raw.link[1] then
                    -- Multiple <link> elements: prefer rel="alternate"
                    link = ""
                    for _, l in ipairs(raw.link) do
                        if type(l) == "table" and l._attr then
                            if l._attr.rel == "alternate" or not l._attr.rel then
                                link = l._attr.href or ""
                                break
                            end
                        end
                    end
                    -- Fall back to first link if no alternate found
                    if link == "" and type(raw.link[1]) == "table"
                                  and raw.link[1]._attr then
                        link = raw.link[1]._attr.href or ""
                    end
                else
                    link = ""
                end
            else
                link = toStr(raw.link)
            end
            -- Atom full text may be in <content> or <summary>
            content = toStr(raw.content ~= nil and raw.content or raw.summary)
        else
            title   = toStr(raw.title)
            link    = toStr(raw.link)
            -- RSS full text is in <content:encoded>; fall back to <description>
            content = toStr(raw["content:encoded"] ~= nil
                            and raw["content:encoded"]
                            or  raw.description)
        end

        -- Publication date: pubDate (RSS) or published/updated (Atom)
        local date = is_atom
            and toStr(raw.published or raw.updated or "")
            or  toStr(raw.pubDate or "")

        -- Decode HTML entities in the title (e.g. &#8217; → ')
        title = decodeEntities(title)
        -- Cap title length to prevent memory issues with malformed feeds.
        if #title > 500 then title = title:sub(1, 499) .. "…" end

        local plain = htmlToText(content)
        table.insert(articles, {
            title     = title,
            link      = link,
            date      = date,
            -- Snippet is flattened (newlines → spaces) for single-block card display
            snippet   = plain:gsub("\n+", " "):sub(1, 300),
            full_text = plain,    -- paragraph-aware plain text (fallback)
            content   = content,  -- raw HTML for the article reader
            image_url = extractThumbnailUrl(raw, content),
        })
    end

    return { feed_title = feed_title, articles = articles }, nil
end

-- Ensure a feed URL has an http(s) scheme.
function Parser.normalizeUrl(url)
    url = (url or ""):match("^%s*(.-)%s*$") or ""
    if url == "" then return url end
    if url:match("^https?://") then return url end
    return "https://" .. url
end

-- Fetch and parse a feed URL. Returns (true, feed_title) or (false, error_string).
function Parser.validateFeed(url)
    url = Parser.normalizeUrl(url)
    if url == "" then return false, "Empty URL" end
    local raw_xml, err = HttpFetch.fetchRaw(url)
    if not raw_xml then return false, err end
    local result, parse_err = Parser.parse(raw_xml)
    if not result then return false, parse_err end
    return true, result.feed_title
end

return Parser

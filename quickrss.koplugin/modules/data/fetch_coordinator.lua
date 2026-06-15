-- QuickRSS: Fetch Coordinator
-- Shared fetch + image pipeline for UI and background scheduled fetch.

local Cache    = require("modules/data/cache")
local Config   = require("modules/data/config")
local Images   = require("modules/data/images")
local Parser   = require("modules/data/parser")
local lfs      = require("libs/libkoreader-lfs")
local logger   = require("logger")

local FetchCoordinator = {
    _in_progress = false,
}

local MONTHS = {
    Jan=1, Feb=2, Mar=3, Apr=4, May=5, Jun=6,
    Jul=7, Aug=8, Sep=9, Oct=10, Nov=11, Dec=12,
}

local function parseDate(raw)
    if not raw or raw == "" then return nil end
    local y, m, d, H, M, S = raw:match("(%d%d%d%d)%-(%d%d)%-(%d%d)T(%d%d):(%d%d):(%d%d)")
    if y then
        return os.time{ year=tonumber(y), month=tonumber(m), day=tonumber(d),
                         hour=tonumber(H), min=tonumber(M), sec=tonumber(S) }
    end
    d, m, y, H, M, S = raw:match("(%d+)%s+(%a+)%s+(%d%d%d%d)%s+(%d%d):(%d%d):(%d%d)")
    if d and MONTHS[m] then
        return os.time{ year=tonumber(y), month=MONTHS[m], day=tonumber(d),
                         hour=tonumber(H), min=tonumber(M), sec=tonumber(S) }
    end
    y, m, d = raw:match("(%d%d%d%d)%-(%d%d)%-(%d%d)")
    if y then
        return os.time{ year=tonumber(y), month=tonumber(m), day=tonumber(d),
                         hour=0, min=0, sec=0 }
    end
    return nil
end

function FetchCoordinator.sortArticles(articles, mode)
    for i, art in ipairs(articles) do
        art._sort_idx = i
        art._sort_ts  = parseDate(art.date)
    end
    if mode == "oldest" then
        table.sort(articles, function(a, b)
            if a._sort_ts and b._sort_ts then return a._sort_ts < b._sort_ts end
            if a._sort_ts and not b._sort_ts then return true end
            if not a._sort_ts and b._sort_ts then return false end
            return a._sort_idx < b._sort_idx
        end)
    elseif mode == "unread_first" then
        table.sort(articles, function(a, b)
            local ar, br = a.read and 1 or 0, b.read and 1 or 0
            if ar ~= br then return ar < br end
            if a._sort_ts and b._sort_ts then return a._sort_ts > b._sort_ts end
            if a._sort_ts and not b._sort_ts then return true end
            if not a._sort_ts and b._sort_ts then return false end
            return a._sort_idx < b._sort_idx
        end)
    else
        table.sort(articles, function(a, b)
            if a._sort_ts and b._sort_ts then return a._sort_ts > b._sort_ts end
            if a._sort_ts and not b._sort_ts then return true end
            if not a._sort_ts and b._sort_ts then return false end
            return a._sort_idx < b._sort_idx
        end)
    end
    for _, art in ipairs(articles) do
        art._sort_idx = nil
        art._sort_ts  = nil
    end
end

function FetchCoordinator.isInProgress()
    return FetchCoordinator._in_progress
end

-- opts:
--   on_progress(name, i, total)
--   on_status(message)
--   on_complete(articles, errors)  -- called after cache save
--   on_error(err)                  -- fatal fetch error
--   cancelled()                    -- optional; return true to stop UI updates
function FetchCoordinator.fetch(opts)
    opts = opts or {}
    if FetchCoordinator._in_progress then
        logger.dbg("QuickRSS: fetch already in progress, skipping")
        return false
    end
    FetchCoordinator._in_progress = true

    local feeds = Config.getFeeds()
    if #feeds == 0 then
        FetchCoordinator._in_progress = false
        if opts.on_error then opts.on_error("no feeds") end
        return false
    end

    local old_articles = Cache.loadArticles(999999)
    local cached_by_link = {}
    for _, art in ipairs(old_articles) do
        if art.link and art.link ~= "" then
            cached_by_link[art.link] = art
        end
    end

    Parser.fetchAll(
        feeds,
        function(articles, errors)
            local img_settings = Config.getArticleSettings()
            local AR = Images

            for _, art in ipairs(articles) do
                local cached = cached_by_link[art.link]
                if cached then
                    if cached.read then art.read = true end
                    if cached.starred then art.starred = true end
                    if cached.image_path
                    and lfs.attributes(cached.image_path, "mode") == "file" then
                        art.image_path = cached.image_path
                    end
                end
            end

            collectgarbage("collect")

            local concurrency = Config.getFetchConcurrency()
            local all_image_urls = {}
            local url_seen = {}

            local function queueUrl(url)
                if url and url ~= "" and not url_seen[url] then
                    url_seen[url] = true
                    table.insert(all_image_urls, url)
                end
            end

            if img_settings.thumbnails_enabled then
                for _, art in ipairs(articles) do
                    if art.image_url and not art.image_path then
                        queueUrl(art.image_url)
                    end
                end
            end

            if img_settings.article_images_enabled then
                for _, art in ipairs(articles) do
                    if art.content
                    and art.content:find("<[Ii][Mm][Gg]")
                    and art.content:find('src%s*=%s*["\']https?://') then
                        for _, url in ipairs(AR.collectRemoteUrls(art.content)) do
                            queueUrl(url)
                        end
                    end
                end
            end

            local image_cache = {}
            if #all_image_urls > 0 then
                image_cache = AR.downloadMany(all_image_urls, {
                    concurrency = concurrency,
                    on_progress = function(done, total)
                        if opts.cancelled and opts.cancelled() then return end
                        if opts.on_status then
                            opts.on_status(string.format(
                                "Downloading images… (%d/%d)", done, total))
                        end
                    end,
                })
            end

            if img_settings.thumbnails_enabled then
                for _, art in ipairs(articles) do
                    if art.image_url and not art.image_path then
                        local fname = image_cache[art.image_url]
                        if fname then
                            art.image_path = AR.IMAGE_DIR .. "/" .. fname
                        end
                    end
                end
            else
                for _, art in ipairs(articles) do
                    art.image_path = nil
                end
            end

            collectgarbage("collect")

            if img_settings.article_images_enabled then
                for _, art in ipairs(articles) do
                    if art.content
                    and art.content:find("<[Ii][Mm][Gg]")
                    and art.content:find('src%s*=%s*["\']https?://') then
                        art.content = AR.localizeImages(
                            AR.constrainImages(art.content),
                            image_cache)
                    end
                end
            end

            local sort_mode = Config.getArticleSettings().article_sort or "newest"
            FetchCoordinator.sortArticles(articles, sort_mode)
            Cache.cleanOrphanedImages(articles)
            Cache.saveArticles(articles)

            FetchCoordinator._in_progress = false
            if opts.on_complete then
                opts.on_complete(articles, errors or {})
            end
        end,
        function(err)
            FetchCoordinator._in_progress = false
            if opts.on_error then opts.on_error(err) end
        end,
        function(name, i, total)
            if opts.cancelled and opts.cancelled() then return end
            if opts.on_progress then opts.on_progress(name, i, total) end
        end,
        function(msg)
            if opts.cancelled and opts.cancelled() then return end
            if opts.on_status then opts.on_status(msg) end
        end,
        cached_by_link
    )
    return true
end

return FetchCoordinator

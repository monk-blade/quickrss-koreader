-- QuickRSS: Article Cache
-- Persists the last-fetched article list to disk so the plugin opens
-- instantly without a network round-trip.
--
-- Public API:
--   Cache.loadArticles(max_age_days)    → articles table (empty if stale or missing)
--   Cache.saveArticles(articles)        persists articles + last_fetched_at timestamp
--   Cache.getLastFetchedAt()            → Unix timestamp or nil
--   Cache.isStale(max_age_days)         → true when cache should be refreshed
--   Cache.markRead(link)                marks one article read by URL
--   Cache.clearCache()                  wipes articles, timestamp, and all images

local DataStorage = require("datastorage")
local Images      = require("modules/data/images")
local lfs         = require("libs/libkoreader-lfs")
local LuaSettings = require("luasettings")
local logger      = require("logger")

local CACHE_FILE = DataStorage:getDataDir() .. "/quickrss/cache.lua"
local IMAGE_DIR  = Images.IMAGE_DIR

local _settings
local function settings()
    if not _settings then
        _settings = LuaSettings:open(CACHE_FILE)
    end
    return _settings
end

local Cache = {}

function Cache.getLastFetchedAt()
    return settings():readSetting("last_fetched_at")
end

-- Returns true when max_age_days > 0 and the last fetch is older than that.
function Cache.isStale(max_age_days)
    if not max_age_days or max_age_days <= 0 then return false end
    local last = Cache.getLastFetchedAt()
    if not last then return true end
    return (os.time() - last) > max_age_days * 86400
end

-- Returns the cached article list, filtering out articles older than
-- max_age_days on a per-article basis.  Pass 0 or nil to skip age filtering.
function Cache.loadArticles(max_age_days)
    local all = settings():readSetting("articles") or {}
    if not max_age_days or max_age_days <= 0 then return all end

    local cutoff = os.time() - max_age_days * 86400
    local fresh  = {}
    for _, art in ipairs(all) do
        if (art.fetched_at or 0) >= cutoff then
            table.insert(fresh, art)
        end
    end
    return fresh
end

-- Persists articles to disk.  Stamps any article that lacks a fetched_at
-- timestamp with the current time (new articles from this fetch cycle).
function Cache.saveArticles(articles)
    local now = os.time()
    for _, art in ipairs(articles) do
        if not art.fetched_at then
            art.fetched_at = now
        end
    end
    settings()
        :saveSetting("articles", articles)
        :saveSetting("last_fetched_at", now)
        :flush()
end

-- Mark a single article as read by its canonical link URL.
function Cache.markRead(link)
    if not link or link == "" then return end
    local articles = settings():readSetting("articles") or {}
    local changed = false
    for _, art in ipairs(articles) do
        if art.link == link and not art.read then
            art.read = true
            changed = true
            break
        end
    end
    if changed then
        settings()
            :saveSetting("articles", articles)
            :flush()
    end
end

-- Mark a single article as starred (or unstarred) by link URL.
function Cache.markStarred(link, starred)
    if not link or link == "" then return end
    local articles = settings():readSetting("articles") or {}
    local changed = false
    for _, art in ipairs(articles) do
        if art.link == link then
            local want = starred and true or false
            if (art.starred and true or false) ~= want then
                art.starred = want or nil
                changed = true
            end
            break
        end
    end
    if changed then
        settings()
            :saveSetting("articles", articles)
            :flush()
    end
end

-- Remove articles whose links appear in the given set. Returns removed count.
function Cache.deleteByLinks(links)
    if not links or #links == 0 then return 0 end
    local remove = {}
    for _, link in ipairs(links) do remove[link] = true end
    local articles = settings():readSetting("articles") or {}
    local kept = {}
    local removed = 0
    for _, art in ipairs(articles) do
        if art.link and remove[art.link] then
            removed = removed + 1
        else
            table.insert(kept, art)
        end
    end
    if removed > 0 then
        settings()
            :saveSetting("articles", kept)
            :flush()
        Cache.cleanOrphanedImages(kept)
    end
    return removed
end

-- Wipes the entire article cache and all cached images.
-- After this call loadArticles() returns {} until the next fetch.
function Cache.clearCache()
    settings()
        :saveSetting("articles", nil)
        :saveSetting("last_fetched_at", nil)
        :flush()
    _settings = nil

    local ok = lfs.attributes(IMAGE_DIR, "mode") == "directory"
    if not ok then return end
    for fname in lfs.dir(IMAGE_DIR) do
        if fname ~= "." and fname ~= ".." then
            local path = IMAGE_DIR .. "/" .. fname
            local removed, err = os.remove(path)
            if not removed then
                logger.warn("QuickRSS: could not remove cached image:", path, err)
            end
        end
    end
end

-- Deletes image files in IMAGE_DIR that are not referenced by any article.
-- Called after every fetch so the image cache doesn't grow unboundedly.
function Cache.cleanOrphanedImages(articles)
    local live = {}
    for _, art in ipairs(articles) do
        if art.image_path then
            local fname = art.image_path:match("([^/]+)$")
            if fname then live[fname] = true end
        end
        if art.content then
            for fname in art.content:gmatch('[Ss][Rr][Cc]%s*=%s*"([^"/]+)"') do
                live[fname] = true
            end
            for fname in art.content:gmatch("[Ss][Rr][Cc]%s*=%s*'([^'/]+)'") do
                live[fname] = true
            end
        end
    end

    local ok = lfs.attributes(IMAGE_DIR, "mode") == "directory"
    if not ok then return end

    for fname in lfs.dir(IMAGE_DIR) do
        if fname ~= "." and fname ~= ".." and not live[fname] then
            local path = IMAGE_DIR .. "/" .. fname
            local removed, err = os.remove(path)
            if removed then
                logger.dbg("QuickRSS: removed orphan image:", fname)
            else
                logger.warn("QuickRSS: could not remove orphan image:", path, err)
            end
        end
    end
end

return Cache

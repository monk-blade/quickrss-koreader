-- QuickRSS: Config Module
-- Persists the user's feed list and article-limit settings to a dedicated
-- settings file.
--
-- Feed list is stored as a standard OPML file (feeds.opml) so it
-- can be edited on a computer or imported from another RSS reader.
-- All other settings (article limits, reader prefs) live in settings.lua.
--
-- All data lives under <koreader data dir>/quickrss/
--
-- Public API:
--   Config.getFeeds()                    → { { name, url }, … }
--   Config.saveFeeds(feeds)              saves and flushes to disk
--   Config.getArticleSettings()          → { items_per_feed, max_cache_age_days }
--   Config.saveArticleSettings(s)        saves and flushes to disk
--   Config.getReaderSettings()           → { font_face, font_size, line_spacing }
--   Config.saveReaderSettings(s)         saves and flushes to disk

local DataStorage = require("datastorage")
local lfs         = require("libs/libkoreader-lfs")
local LuaSettings = require("luasettings")
local OPML        = require("modules/data/opml")

local BASE_DIR      = DataStorage:getDataDir() .. "/quickrss"
lfs.mkdir(BASE_DIR)  -- no-op if already exists
local SETTINGS_FILE = BASE_DIR .. "/settings.lua"

-- Shown the first time the plugin is opened before the user adds their own feeds
local DEFAULT_FEEDS = {
    { name = "Ars Technica", url = "https://feeds.arstechnica.com/arstechnica/index" },
}

local DEFAULT_ARTICLE_SETTINGS = {
    items_per_feed         = 20,    -- most-recent articles to keep per feed
    max_cache_age_days     = 10,    -- treat cache as empty after this many days (0 = never)
    thumbnails_enabled     = true,  -- download and display feed-list thumbnails
    article_images_enabled = true,  -- download and display images inside articles
    card_font_size         = 14,    -- base font size for article cards in feed list
    fulltext_enabled       = true,  -- fetch full article text for truncated feeds
    fulltext_url           = "https://ftr.fivefilters.net/makefulltextfeed.php",
    auto_fetch_on_open     = false, -- fetch automatically when cache is stale
    fetch_concurrency      = nil,   -- parallel HTTP workers (nil = auto by device)
    article_sort           = "newest", -- newest | oldest | unread_first
    scheduled_fetch_enabled          = false,
    scheduled_fetch_requires_charging = true,
}

-- Lazily opened so require("modules/config") doesn't touch the filesystem
local _settings
local function settings()
    if not _settings then
        _settings = LuaSettings:open(SETTINGS_FILE)
    end
    return _settings
end

local Config = {}

function Config.getFeeds()
    -- Primary source: OPML file (editable on the computer)
    local feeds = OPML.read()
    if feeds and #feeds > 0 then return feeds end

    -- One-time migration: if the old quickrss.lua has feeds, move them to OPML
    -- and remove from the Lua settings so this path is never taken again.
    local old = settings():readSetting("feeds")
    if old and #old > 0 then
        OPML.write(nil, old)
        settings():saveSetting("feeds", nil):flush()
        return old
    end

    -- First-run defaults
    local copy = {}
    for _, f in ipairs(DEFAULT_FEEDS) do
        table.insert(copy, { name = f.name, url = f.url })
    end
    return copy
end

function Config.saveFeeds(feeds)
    OPML.write(nil, feeds)
end

function Config.getArticleSettings()
    local saved = settings():readSetting("article_settings")
    -- Merge with defaults so new keys always have a value even after upgrades.
    -- Booleans need explicit nil-check: `false or default` would use the default.
    local thumb = DEFAULT_ARTICLE_SETTINGS.thumbnails_enabled
    if saved and saved.thumbnails_enabled ~= nil then
        thumb = saved.thumbnails_enabled
    end
    local art_img = DEFAULT_ARTICLE_SETTINGS.article_images_enabled
    if saved and saved.article_images_enabled ~= nil then
        art_img = saved.article_images_enabled
    end
    local ft = DEFAULT_ARTICLE_SETTINGS.fulltext_enabled
    if saved and saved.fulltext_enabled ~= nil then
        ft = saved.fulltext_enabled
    end
    local auto_fetch = DEFAULT_ARTICLE_SETTINGS.auto_fetch_on_open
    if saved and saved.auto_fetch_on_open ~= nil then
        auto_fetch = saved.auto_fetch_on_open
    end
    local sched = DEFAULT_ARTICLE_SETTINGS.scheduled_fetch_enabled
    if saved and saved.scheduled_fetch_enabled ~= nil then
        sched = saved.scheduled_fetch_enabled
    end
    local sched_charge = DEFAULT_ARTICLE_SETTINGS.scheduled_fetch_requires_charging
    if saved and saved.scheduled_fetch_requires_charging ~= nil then
        sched_charge = saved.scheduled_fetch_requires_charging
    end
    local sort_mode = DEFAULT_ARTICLE_SETTINGS.article_sort
    if saved and saved.article_sort then
        sort_mode = saved.article_sort
    end
    -- Numeric fields also need nil-checks: `0 or default` would use the default,
    -- which silently breaks max_cache_age_days = 0 ("Never expire").
    local function num(key)
        if saved and saved[key] ~= nil then return saved[key] end
        return DEFAULT_ARTICLE_SETTINGS[key]
    end
    return {
        items_per_feed         = num("items_per_feed"),
        max_cache_age_days     = num("max_cache_age_days"),
        thumbnails_enabled     = thumb,
        article_images_enabled = art_img,
        card_font_size         = num("card_font_size"),
        fulltext_enabled       = ft,
        fulltext_url           = (saved and saved.fulltext_url)       or DEFAULT_ARTICLE_SETTINGS.fulltext_url,
        auto_fetch_on_open     = auto_fetch,
        fetch_concurrency      = num("fetch_concurrency"),
        article_sort           = sort_mode,
        scheduled_fetch_enabled = sched,
        scheduled_fetch_requires_charging = sched_charge,
    }
end

function Config.getFetchConcurrency()
    local saved = settings():readSetting("article_settings")
    local n = saved and saved.fetch_concurrency
    if n and n > 0 then return math.min(n, 8) end
    local Device = require("device")
    if Device.isEmulator then return 4 end
    return 2
end

-- Ensure feed URLs include a scheme (https by default).
function Config.normalizeFeedUrl(url)
    url = (url or ""):match("^%s*(.-)%s*$") or ""
    if url == "" then return url end
    if url:match("^https?://") then return url end
    return "https://" .. url
end

function Config.saveArticleSettings(s)
    settings():saveSetting("article_settings", s):flush()
end

local DEFAULT_READER_SETTINGS = {
    font_file    = "",   -- "" = let MuPDF use its default serif
    font_size    = 18,   -- pt
    line_spacing = 15,   -- x10 (15 → 1.5)
    text_align   = "justify", -- justify | left
    margin_scale = 1.0,
    theme        = "default", -- default | dark
}

function Config.getReaderSettings()
    local saved = settings():readSetting("reader_settings")
    local function val(key)
        if saved and saved[key] ~= nil then return saved[key] end
        return DEFAULT_READER_SETTINGS[key]
    end
    return {
        font_file    = val("font_file"),
        font_size    = val("font_size"),
        line_spacing = val("line_spacing"),
        text_align   = val("text_align"),
        margin_scale = val("margin_scale"),
        theme        = val("theme"),
    }
end

function Config.getExportQueue()
    return settings():readSetting("export_queue") or {}
end

function Config.saveExportQueue(queue)
    settings():saveSetting("export_queue", queue):flush()
end

function Config.isInExportQueue(link)
    if not link or link == "" then return false end
    for _, l in ipairs(Config.getExportQueue()) do
        if l == link then return true end
    end
    return false
end

function Config.addToExportQueue(link)
    if not link or link == "" then return end
    if Config.isInExportQueue(link) then return end
    local queue = Config.getExportQueue()
    table.insert(queue, link)
    Config.saveExportQueue(queue)
end

function Config.removeFromExportQueue(link)
    if not link or link == "" then return end
    local queue = Config.getExportQueue()
    local kept = {}
    for _, l in ipairs(queue) do
        if l ~= link then table.insert(kept, l) end
    end
    Config.saveExportQueue(kept)
end

function Config.clearExportQueueLinks(links)
    if not links or #links == 0 then return end
    local remove = {}
    for _, l in ipairs(links) do remove[l] = true end
    local kept = {}
    for _, l in ipairs(Config.getExportQueue()) do
        if not remove[l] then table.insert(kept, l) end
    end
    Config.saveExportQueue(kept)
end

function Config.saveReaderSettings(s)
    settings():saveSetting("reader_settings", s):flush()
end

return Config

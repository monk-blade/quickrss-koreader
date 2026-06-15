-- QuickRSS: UI Module
-- Fullscreen article-list overlay. Fetches all configured feeds on open and
-- merges their articles into a single paginated list.
-- Tapping the settings icon (top-left) opens the feed management popup.

local Button          = require("ui/widget/button")
local ButtonDialog    = require("ui/widget/buttondialog")
local CenterContainer = require("ui/widget/container/centercontainer")
local InfoMessage     = require("ui/widget/infomessage")
local Config          = require("modules/data/config")
local Icons           = require("modules/ui/icons")
local Device          = require("device")
local Font            = require("ui/font")
local FrameContainer  = require("ui/widget/container/framecontainer")
local Geom            = require("ui/geometry")
local GestureRange    = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan  = require("ui/widget/horizontalspan")
local InputContainer  = require("ui/widget/container/inputcontainer")
local LineWidget      = require("ui/widget/linewidget")
local Cache           = require("modules/data/cache")
local FetchCoordinator = require("modules/data/fetch_coordinator")
local EpubExport      = require("modules/data/epub_export")
local lfs             = require("libs/libkoreader-lfs")
local Size            = require("ui/size")
local T               = require("ffi/util").template
local TextBoxWidget   = require("ui/widget/textboxwidget")
local TextWidget      = require("ui/widget/textwidget")
local TitleBar        = require("ui/widget/titlebar")
local UIManager       = require("ui/uimanager")
local VerticalGroup   = require("ui/widget/verticalgroup")
local VerticalSpan    = require("ui/widget/verticalspan")
local _               = require("gettext")

-- Pull in the card widget and the geometry constants it computed
local ArticleItemModule = require("modules/ui/article_item")
local ArticleItem       = ArticleItemModule.ArticleItem
local ITEM_HEIGHT       = ArticleItemModule.ITEM_HEIGHT
local PAD               = ArticleItemModule.PAD

local Screen = Device.screen

-- ─────────────────────────────────────────────────────────────────────────────
-- QuickRSSUI: fullscreen overlay.
--
-- Structure (top → bottom):
--   TitleBar  ("QuickRSS" + hamburger menu (left) + close button (right))
--   article_list  ← VerticalGroup rebuilt on every page turn
--   list_spacer   ← absorbs leftover pixels so footer stays at screen bottom
--   footer        (prev chevron | "Page N of M" | next chevron)
-- ─────────────────────────────────────────────────────────────────────────────
local QuickRSSUI = InputContainer:extend{
    name               = "quickrss_ui",
    ui                 = nil,   -- KOReader app ui (dictionary / wikipedia)
    show_page          = 1,
    articles           = {},     -- all articles (unfiltered)
    filtered           = nil,    -- filtered subset, or nil when showing all
    filter_feed        = nil,    -- name of the active feed filter, or nil for all
    filter_unread_only = false,  -- when true, hide read articles
    filter_starred_only = false,
    filter_queue_only  = false,
    last_fetch_errors  = {},
}

function QuickRSSUI:init()
    local screen_w = Screen:getWidth()
    local screen_h = Screen:getHeight()

    -- Hardware buttons: Back closes, page-turn keys navigate pages.
    -- Each key must be its own sequence entry — Key:match() requires ALL
    -- keys in a single sequence to be pressed simultaneously.
    self.key_events = {
        Close    = { { "Back" }, doc = "close QuickRSS" },
        NextPage = { { "RPgFwd" }, { "LPgFwd" }, doc = "next page" },
        PrevPage = { { "RPgBack" }, { "LPgBack" }, doc = "prev page" },
    }

    -- Swipe left/right to flip pages
    self.ges_events.Swipe = {
        GestureRange:new{
            ges   = "swipe",
            range = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() },
        },
    }

    -- ── Title bar ─────────────────────────────────────────────────────────────
    self.title_bar = TitleBar:new{
        width                  = screen_w,
        title                  = Icons.FEEDS .. _(" QuickRSS"),
        with_bottom_line       = true,
        left_icon              = "appbar.menu",
        left_icon_tap_callback = function() self:_openMenu() end,
        close_callback         = function() self:onClose() end,
        show_parent            = self,
    }
    local title_h = self.title_bar:getSize().h

    -- ── Pagination footer ────────────────────────────────────────────────────
    self.filter_button = Button:new{
        text       = Icons.FILTER .. "  " .. _("All Feeds"),
        callback   = function() self:_openFilterDialog() end,
        hold_callback = function()
            -- Cycle: all → unread → starred → export queue → all
            if not self.filter_unread_only and not self.filter_starred_only
            and not self.filter_queue_only then
                self.filter_unread_only = true
            elseif self.filter_unread_only then
                self.filter_unread_only = false
                self.filter_starred_only = true
            elseif self.filter_starred_only then
                self.filter_starred_only = false
                self.filter_queue_only = true
            else
                self.filter_queue_only = false
            end
            self:_updateFilterButtonText()
            self:_applyFilter()
        end,
        bordersize = 0,
    }
    self.prev_button = Button:new{
        icon      = "chevron.left",
        callback  = function() self:prevPage() end,
        bordersize = 0,
    }
    self.next_button = Button:new{
        icon      = "chevron.right",
        callback  = function() self:nextPage() end,
        bordersize = 0,
    }
    self.page_label = TextWidget:new{
        text = _("Page – of –"),
        face = Font:getFace("cfont", 16),
    }

    local footer_h = self.prev_button:getSize().h + PAD * 2

    self.page_nav = HorizontalGroup:new{
        align = "center",
        self.prev_button,
        HorizontalSpan:new{ width = PAD * 3 },
        self.page_label,
        HorizontalSpan:new{ width = PAD * 3 },
        self.next_button,
    }

    -- Footer: filter button left-aligned, page nav right-aligned.
    -- A flexible spacer pushes them apart.
    local filter_pad = PAD
    local nav_w = self.page_nav:getSize().w
    local filter_w = self.filter_button:getSize().w
    local spacer_w = math.max(0, screen_w - filter_w - nav_w - filter_pad - PAD)
    self.footer_group = HorizontalGroup:new{
        align = "center",
        HorizontalSpan:new{ width = filter_pad },
        self.filter_button,
        HorizontalSpan:new{ width = spacer_w },
        self.page_nav,
    }
    local footer = CenterContainer:new{
        dimen = Geom:new{ w = screen_w, h = footer_h },
        self.footer_group,
    }

    -- ── Article list area ────────────────────────────────────────────────────
    self.list_h         = screen_h - title_h - footer_h
    self.items_per_page = math.max(1, math.floor(self.list_h / ITEM_HEIGHT))
    self.item_width     = screen_w

    -- Spacer height is recalculated on every page turn in _populateItems() so
    -- the footer is always flush with the screen bottom regardless of how many
    -- items appear on the current page (the last page is often a partial page).
    -- Initialise to a full-page height; _populateItems() will correct it.
    self.list_spacer = VerticalSpan:new{ width = 0 }

    -- Populated and cleared by _populateItems() on every page turn
    self.article_list = VerticalGroup:new{ align = "left" }

    -- ── Outer frame: white canvas covering the whole screen ──────────────────
    self.outer_group = VerticalGroup:new{
        align = "left",
        self.title_bar,
        self.article_list,
        self.list_spacer,
        footer,
    }
    self[1] = FrameContainer:new{
        width     = screen_w,
        height    = screen_h,
        padding   = 0,
        margin    = 0,
        bordersize = 0,
        background = require("ffi/blitbuffer").COLOR_WHITE,
        self.outer_group,
    }

    -- Load from cache immediately (non-blocking).  If the cache is empty the
    -- user will see a prompt to tap the refresh button.
    self:_loadFromCache()
    self:_maybeAutoFetch()
end

-- Auto-fetch when enabled and the on-disk cache is older than max_cache_age_days.
function QuickRSSUI:_maybeAutoFetch()
    local s = Config.getArticleSettings()
    if not s.auto_fetch_on_open then return end
    if not Cache.isStale(s.max_cache_age_days) then return end
    if #Config.getFeeds() == 0 then return end
    UIManager:nextTick(function() self:_fetch() end)
end

-- Load articles from the on-disk cache and display them immediately.
-- Shows a prompt if the cache is empty.
function QuickRSSUI:_loadFromCache()
    local max_age = Config.getArticleSettings().max_cache_age_days
    local articles = Cache.loadArticles(max_age)
    if #articles == 0 then
        self:_showStatus(_("No articles yet.\nOpen the menu to fetch."))
    else
        FetchCoordinator.sortArticles(articles, Config.getArticleSettings().article_sort)
        self.articles = articles
        self:_applyFilter()
    end
end

function QuickRSSUI:_sortCurrentArticles()
    FetchCoordinator.sortArticles(self.articles,
        Config.getArticleSettings().article_sort)
    if self.filtered then
        FetchCoordinator.sortArticles(self.filtered,
            Config.getArticleSettings().article_sort)
    end
end

-- Fetch all configured feeds, save to cache, and repopulate the list.
-- Triggered by the ↻ button in the title bar.
function QuickRSSUI:_fetch()
    self:_showStatus(_("Loading…"))
    UIManager:forceRePaint()

    FetchCoordinator.fetch({
        cancelled = function() return self._closed end,
        on_status = function(msg)
            if not self._closed then
                self:_showStatus(msg)
                UIManager:forceRePaint()
            end
        end,
        on_progress = function(name, i, total)
            if not self._closed then
                self:_showStatus(T(_("Fetching %1…\n(%2 of %3)"), name, i, total))
                UIManager:forceRePaint()
            end
        end,
        on_error = function(err)
            if not self._closed then
                self:_showStatus(T(_("Could not load feeds:\n%1"), err))
            end
        end,
        on_complete = function(articles, errors)
            self.last_fetch_errors = errors or {}

            if self._closed then return end

            if #articles == 0 then
                self:_showStatus(_("No articles found.\nCheck your feeds."))
            else
                self.articles = articles
                self:_applyFilter()

                if #self.last_fetch_errors > 0 then
                    local Notification = require("ui/widget/notification")
                    UIManager:show(Notification:new{
                        text = T(_("%1 feed(s) failed to load"), #self.last_fetch_errors),
                        tap_callback = function()
                            self:_showFetchErrors()
                        end,
                    })
                end
            end
        end,
    })
end

function QuickRSSUI:_showFetchErrors()
    if not self.last_fetch_errors or #self.last_fetch_errors == 0 then return end
    local TextViewer = require("ui/widget/textviewer")
    UIManager:show(TextViewer:new{
        title = _("Last fetch errors"),
        text  = table.concat(self.last_fetch_errors, "\n"),
    })
end

-- Show a centred status message (used for "Loading…" and error states).
-- Also disables the footer buttons since there are no pages to navigate.
function QuickRSSUI:_showStatus(message)
    self.article_list:clear()
    self.article_list:resetLayout()

    -- Use the full list area height so the placeholder is centred in the
    -- available space and the footer remains at the bottom of the screen.
    self.list_spacer.width = 0
    table.insert(self.article_list, CenterContainer:new{
        dimen = Geom:new{
            w = self.item_width,
            h = self.list_h,
        },
        TextBoxWidget:new{
            text      = message,
            face      = Font:getFace("cfont", 18),
            width     = self.item_width - Size.padding.large * 2,
            alignment = "center",
        },
    })

    self.page_label:setText("–")
    self.footer_group:resetLayout()
    self.prev_button:enableDisable(false)
    self.next_button:enableDisable(false)

    self.outer_group:resetLayout()

    UIManager:setDirty(self, function()
        return "ui", self.dimen
    end)
end

-- Show the hamburger dropdown menu.
function QuickRSSUI:_openMenu()
    local dialog
    dialog = ButtonDialog:new{
        buttons = {
            {{ text = Icons.FETCH .. "  " .. _("Fetch Articles"), callback = function()
                UIManager:close(dialog)
                local ConfirmBox = require("ui/widget/confirmbox")
                UIManager:show(ConfirmBox:new{
                    text = _("Fetch articles from all feeds?\nThis may take a moment."),
                    ok_text = _("Fetch"),
                    ok_callback = function()
                        -- Defer to next tick so the ConfirmBox visually
                        -- closes before the blocking fetch begins.
                        UIManager:nextTick(function() self:_fetch() end)
                    end,
                })
            end }},
            {{ text = _("Sort"), callback = function()
                UIManager:close(dialog)
                self:_openSortDialog()
            end }},
            {{ text = _("Export to EPUB"), callback = function()
                UIManager:close(dialog)
                self:_openBatchExportDialog()
            end }},
            {{ text = _("Last fetch errors"), callback = function()
                UIManager:close(dialog)
                if #self.last_fetch_errors == 0 then
                    UIManager:show(InfoMessage:new{ text = _("No fetch errors.") })
                else
                    self:_showFetchErrors()
                end
            end }},
            {
                { text = Icons.FEEDS    .. "  " .. _("Feeds"),    callback = function()
                    UIManager:close(dialog)
                    self:_openFeedList()
                end },
                { text = Icons.SETTINGS .. "  " .. _("Settings"), callback = function()
                    UIManager:close(dialog)
                    self:_openSettings()
                end },
            },
            -- Bottom row: destructive action + about
            {
                { text = Icons.CLEAR .. "  " .. _("Clear Cache"), callback = function()
                    UIManager:close(dialog)
                    self:_clearCache()
                end },
                { text = Icons.INFO .. "  " .. _("About"), callback = function()
                    UIManager:close(dialog)
                    self:_openAbout()
                end },
            },
        },
    }
    UIManager:show(dialog)
end

-- Ask for confirmation, then wipe the article cache and images.
function QuickRSSUI:_clearCache()
    local ConfirmBox = require("ui/widget/confirmbox")
    UIManager:show(ConfirmBox:new{
        text = _("Clear all cached articles and images?"),
        ok_text = _("Clear"),
        ok_callback = function()
            Cache.clearCache()
            self.articles    = {}
            self.filtered    = nil
            self.filter_feed = nil
            self.filter_unread_only = false
            self.filter_starred_only = false
            self.filter_queue_only = false
            self.last_fetch_errors = {}
            self.show_page   = 1
            self:_updateFilterButtonText()
            self:_rebuildFooter()
            self:_showStatus(_("Cache cleared.\nOpen the menu to fetch."))
        end,
    })
end

-- Open the settings popup.  When it closes, re-render the feed list so
-- toggling images takes effect immediately without a re-fetch.
function QuickRSSUI:_openSettings()
    local SettingsUI = require("modules/ui/settings")
    UIManager:show(SettingsUI:new{
        on_close = function()
            if #self.articles > 0 then
                self:_populateItems()
            end
        end,
    })
end

-- Open the feed management popup.
function QuickRSSUI:_openFeedList()
    local FeedListUI = require("modules/ui/feed_list")
    UIManager:show(FeedListUI:new{
        reload_callback = function() self:_loadFromCache() end,
    })
end

-- Show a brief about dialog.
function QuickRSSUI:_openAbout()
    local meta = require("_meta")
    UIManager:show(InfoMessage:new{
        text = "QuickRSS v" .. meta.version .. "\n"
            .. "by " .. meta.author .. "\n\n"
            .. "A fast, standalone RSS reader for KOReader.\n\n"
            .. "Feeds are stored in quickrss/feeds.opml in your KOReader "
            .. "data directory. Use Feeds → Import OPML to load subscriptions "
            .. "from another reader, or edit feeds.opml on your computer.\n\n"
            .. "In an article: menu (☰) → Save article exports HTML.",
    })
end

-- Apply the current feed and unread filters and rebuild the displayed list.
function QuickRSSUI:_applyFilter()
    local queue_links = {}
    if self.filter_queue_only then
        for _, link in ipairs(Config.getExportQueue()) do
            queue_links[link] = true
        end
    end

    if self.filter_feed or self.filter_unread_only or self.filter_starred_only
    or self.filter_queue_only then
        self.filtered = {}
        for _, art in ipairs(self.articles) do
            if (not self.filter_feed or art.source == self.filter_feed)
            and (not self.filter_unread_only or not art.read)
            and (not self.filter_starred_only or art.starred)
            and (not self.filter_queue_only or queue_links[art.link]) then
                table.insert(self.filtered, art)
            end
        end
    else
        self.filtered = nil
    end
    self.show_page = 1
    self:_updateFilterButtonText()
    self:_populateItems()
end

function QuickRSSUI:_updateFilterButtonText()
    local label
    if self.filter_feed then
        label = self.filter_feed
    else
        label = _("All Feeds")
    end
    if self.filter_unread_only then
        label = label .. " · " .. _("Unread")
    end
    if self.filter_starred_only then
        label = label .. " · ★"
    end
    if self.filter_queue_only then
        label = label .. " · " .. _("Queue")
    end
    self.filter_button:setText(Icons.FILTER .. "  " .. label, self.filter_button.width)
end

-- Open a dialog to pick which feed to show (or all).
function QuickRSSUI:_openFilterDialog()
    -- Collect unique feed names from articles
    local seen = {}
    local feed_names = {}
    for _, art in ipairs(self.articles) do
        if art.source and not seen[art.source] then
            seen[art.source] = true
            table.insert(feed_names, art.source)
        end
    end
    table.sort(feed_names)

    local RadioButtonWidget = require("ui/widget/radiobuttonwidget")
    local radio_buttons = {
        {{ text = _("All Feeds"), provider = "", checked = (self.filter_feed == nil) }},
    }
    for _, name in ipairs(feed_names) do
        table.insert(radio_buttons, {
            { text = name, provider = name, checked = (self.filter_feed == name) },
        })
    end
    table.insert(radio_buttons, {
        { text = _("Unread only"), provider = "__unread__",
          checked = self.filter_unread_only },
    })
    table.insert(radio_buttons, {
        { text = _("Starred only"), provider = "__starred__",
          checked = self.filter_starred_only },
    })
    table.insert(radio_buttons, {
        { text = _("Export queue only"), provider = "__queue__",
          checked = self.filter_queue_only },
    })

    UIManager:show(RadioButtonWidget:new{
        title_text = _("Filter Articles"),
        cancel_text = _("Close"),
        ok_text = _("Apply"),
        radio_buttons = radio_buttons,
        callback = function(radio)
            if radio.provider == "" then
                self.filter_feed = nil
            elseif radio.provider == "__unread__" then
                self.filter_unread_only = not self.filter_unread_only
            elseif radio.provider == "__starred__" then
                self.filter_starred_only = not self.filter_starred_only
            elseif radio.provider == "__queue__" then
                self.filter_queue_only = not self.filter_queue_only
            else
                self.filter_feed = radio.provider
            end
            self:_rebuildFooter()
            self:_applyFilter()
        end,
    })
end

function QuickRSSUI:_openSortDialog()
    local sort_mode = Config.getArticleSettings().article_sort or "newest"
    local RadioButtonWidget = require("ui/widget/radiobuttonwidget")
    UIManager:show(RadioButtonWidget:new{
        title_text = _("Sort Articles"),
        cancel_text = _("Close"),
        ok_text = _("Apply"),
        radio_buttons = {
            {{ text = _("Newest first"), provider = "newest",
               checked = sort_mode == "newest" }},
            {{ text = _("Oldest first"), provider = "oldest",
               checked = sort_mode == "oldest" }},
            {{ text = _("Unread first"), provider = "unread_first",
               checked = sort_mode == "unread_first" }},
        },
        callback = function(radio)
            local s = Config.getArticleSettings()
            s.article_sort = radio.provider
            Config.saveArticleSettings(s)
            FetchCoordinator.sortArticles(self.articles, s.article_sort)
            self:_applyFilter()
        end,
    })
end

function QuickRSSUI:_articlesForExportSource(source)
    if source == "queue" then
        local by_link = {}
        for _, art in ipairs(self.articles) do
            if art.link then by_link[art.link] = art end
        end
        local list = {}
        for _, link in ipairs(Config.getExportQueue()) do
            if by_link[link] then table.insert(list, by_link[link]) end
        end
        return list
    elseif source == "starred" then
        local list = {}
        for _, art in ipairs(self.articles) do
            if art.starred then table.insert(list, art) end
        end
        return list
    end
    return self.filtered or self.articles
end

function QuickRSSUI:_openBatchExportDialog()
    local export_source = "queue"
    local delete_after = false
    local dialog

    local function runExport(dir_path)
        local articles = self:_articlesForExportSource(export_source)
        if #articles == 0 then
            UIManager:show(InfoMessage:new{ text = _("No articles to export.") })
            return
        end
        if dir_path:sub(-1) ~= "/" then dir_path = dir_path .. "/" end
        lfs.mkdir(dir_path)

        local progress = InfoMessage:new{ text = _("Exporting…"), timeout = 3600 }
        UIManager:show(progress)

        local ok_count, errors, exported_links = EpubExport.exportBatch(articles, dir_path,
            function(i, total, art)
                progress.text = T(_("Exporting %1/%2:\n%3"), i, total,
                    art.title or "")
                UIManager:setDirty(progress, "ui")
                UIManager:forceRePaint()
            end)

        UIManager:close(progress)

        local msg = T(_("Exported %1 article(s) to:\n%2"), ok_count, dir_path)
        if #errors > 0 then
            msg = msg .. "\n\n" .. T(_("%1 failed"), #errors)
        end
        UIManager:show(InfoMessage:new{ text = msg })

        if delete_after and exported_links and #exported_links > 0 then
            Cache.deleteByLinks(exported_links)
            Config.clearExportQueueLinks(exported_links)
            self.articles = Cache.loadArticles(
                Config.getArticleSettings().max_cache_age_days)
            self:_applyFilter()
        end
    end

    dialog = ButtonDialog:new{
        title = _("Export to EPUB"),
        buttons = {
            {{ text = _("Source: Export queue"), callback = function()
                export_source = "queue"
            end }},
            {{ text = _("Source: Starred"), callback = function()
                export_source = "starred"
            end }},
            {{ text = _("Source: Current filter"), callback = function()
                export_source = "filter"
            end }},
            {{ text = delete_after and _("✓ Delete after export")
                or _("Delete exported articles after export"), callback = function()
                delete_after = not delete_after
                UIManager:close(dialog)
                self:_openBatchExportDialog()
            end }},
            {{ text = _("Choose folder…"), callback = function()
                UIManager:close(dialog)
                local default_dir = require("datastorage"):getDataDir()
                    .. "/quickrss-export-" .. os.date("%Y-%m-%d") .. "/"
                local PathChooser = require("ui/widget/pathchooser")
                UIManager:show(PathChooser:new{
                    path = default_dir,
                    select_directory = true,
                    select_file = false,
                    title = _("Export EPUB folder"),
                    onConfirm = function(dir_path) runExport(dir_path) end,
                })
            end }},
        },
    }
    UIManager:show(dialog)
end

-- Rebuild footer layout after filter button text changes.
function QuickRSSUI:_rebuildFooter()
    local screen_w = Screen:getWidth()
    local filter_pad = PAD
    local nav_w = self.page_nav:getSize().w
    local filter_w = self.filter_button:getSize().w
    local spacer_w = math.max(0, screen_w - filter_w - nav_w - filter_pad - PAD)

    self.footer_group:clear()
    self.footer_group:resetLayout()
    table.insert(self.footer_group, HorizontalSpan:new{ width = filter_pad })
    table.insert(self.footer_group, self.filter_button)
    table.insert(self.footer_group, HorizontalSpan:new{ width = spacer_w })
    table.insert(self.footer_group, self.page_nav)
end

-- Rebuild article_list for the current page and request a display refresh.
function QuickRSSUI:_populateItems()
    local articles = self.filtered or self.articles
    local total    = #articles

    self.pages     = math.max(1, math.ceil(total / self.items_per_page))
    self.show_page = math.min(self.show_page, self.pages)

    -- Clear stale widgets and invalidate the cached layout size
    self.article_list:clear()
    self.article_list:resetLayout()

    local start_idx   = (self.show_page - 1) * self.items_per_page + 1
    local end_idx     = math.min(start_idx + self.items_per_page - 1, total)
    local page_count  = end_idx - start_idx + 1
    local content_h   = page_count * ITEM_HEIGHT
                      + math.max(0, page_count - 1) * Size.line.thin
    self.list_spacer.width = math.max(0, self.list_h - content_h)

    local art_settings = require("modules/data/config").getArticleSettings()
    for i = start_idx, end_idx do
        local item = ArticleItem:new{
            width        = self.item_width,
            height       = ITEM_HEIGHT,
            article      = articles[i],
            art_settings = art_settings,
            callback = function(article)
                local InfoMessage = require("ui/widget/infomessage")
                local msg = InfoMessage:new{
                    text = _("Opening ") .. article.title,
                    timeout = 30,
                }
                UIManager:show(msg)
                UIManager:nextTick(function()
                    article.read = true
                    Cache.markRead(article.link)
                    local ArticleReader = require("modules/ui/article_reader")
                    UIManager:show(ArticleReader:new{
                        article       = article,
                        articles      = articles,
                        article_index = i,
                        ui            = self.ui,
                        on_read = function(art)
                            art.read = true
                            Cache.markRead(art.link)
                        end,
                    })
                    UIManager:close(msg)
                end)
            end,
            hold_callback = function(article)
                article.starred = not article.starred
                Cache.markStarred(article.link, article.starred)
                self:_populateItems()
            end,
        }
        table.insert(self.article_list, item)

        -- Thin grey separator between rows (omitted after the last item)
        if i < end_idx then
            table.insert(self.article_list, LineWidget:new{
                background = require("ffi/blitbuffer").COLOR_LIGHT_GRAY,
                dimen      = Geom:new{ w = self.item_width, h = Size.line.thin },
                style      = "solid",
            })
        end
    end

    -- Update footer controls
    self.page_label:setText(T(_("Page %1 of %2"), self.show_page, self.pages))
    self.footer_group:resetLayout()
    self.prev_button:enableDisable(self.show_page > 1)
    self.next_button:enableDisable(self.show_page < self.pages)

    self.outer_group:resetLayout()

    -- Full e-ink flash every 3 page turns to clear ghosting; fast partial
    -- update ("ui") on the others for snappy navigation.
    self._page_turn_count = (self._page_turn_count or 0) + 1
    local refresh_mode = (self._page_turn_count % 3 == 0) and "full" or "ui"
    UIManager:setDirty(self, function()
        return refresh_mode, self.dimen
    end)
end

function QuickRSSUI:nextPage()
    if self.show_page < self.pages then
        self.show_page = self.show_page + 1
        self:_populateItems()
    end
end

function QuickRSSUI:prevPage()
    if self.show_page > 1 then
        self.show_page = self.show_page - 1
        self:_populateItems()
    end
end

function QuickRSSUI:onSwipe(_, ges_ev)
    if ges_ev.direction == "west" then
        self:nextPage()
        return true
    elseif ges_ev.direction == "east" then
        self:prevPage()
        return true
    elseif ges_ev.direction == "northeast"
        or ges_ev.direction == "northwest"
        or ges_ev.direction == "southeast"
        or ges_ev.direction == "southwest" then
        UIManager:setDirty(nil, "full", nil, true)
        return false
    end
end

function QuickRSSUI:onNextPage()
    self:nextPage()
    return true
end

function QuickRSSUI:onPrevPage()
    self:prevPage()
    return true
end

function QuickRSSUI:onClose()
    self._closed = true
    UIManager:close(self)
end

return QuickRSSUI

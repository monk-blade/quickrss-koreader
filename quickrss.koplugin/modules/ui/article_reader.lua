-- QuickRSS: Article Reader
-- Full-screen HTML article viewer.  Uses ScrollHtmlWidget (KOReader's
-- built-in HTML/CSS engine) so paragraphs, bold, lists, and inline images
-- all render correctly.
--
-- Images referenced by remote URLs are downloaded on first open and cached
-- locally so they persist across sessions.  The resource directory is passed
-- to ScrollHtmlWidget so the engine resolves the local filenames correctly.
--
-- Constructor fields:
--   article  table  { title, content, full_text, … } from Parser

local Blitbuffer       = require("ffi/blitbuffer")
local Button           = require("ui/widget/button")
local Config           = require("modules/data/config")
local Device           = require("device")
local FrameContainer   = require("ui/widget/container/framecontainer")
local Geom             = require("ui/geometry")
local GestureRange     = require("ui/gesturerange")
local HorizontalGroup  = require("ui/widget/horizontalgroup")
local HorizontalSpan   = require("ui/widget/horizontalspan")
local Images           = require("modules/data/images")
local Icons            = require("modules/ui/icons")
local ArticleExport    = require("modules/data/article_export")
local HtmlCleanup      = require("modules/data/html_cleanup")
local TextUtil         = require("modules/lib/text_util")
local ButtonDialog     = require("ui/widget/buttondialog")
local InfoMessage      = require("ui/widget/infomessage")
local PathChooser      = require("ui/widget/pathchooser")
local T                = require("ffi/util").template
local InputContainer   = require("ui/widget/container/inputcontainer")
local LineWidget       = require("ui/widget/linewidget")
local ScrollHtmlWidget = require("ui/widget/scrollhtmlwidget")
local Size             = require("ui/size")
local TitleBar         = require("ui/widget/titlebar")
local UIManager        = require("ui/uimanager")
local VerticalGroup    = require("ui/widget/verticalgroup")
local Event              = require("ui/event")
local _                  = require("gettext")

local Screen    = Device.screen
local IMAGE_DIR = Images.IMAGE_DIR

-- Escape the five XML/HTML special characters.
local function escapeHtml(s)
    local r = (s or "")
        :gsub("&",  "&amp;")
        :gsub("<",  "&lt;")
        :gsub(">",  "&gt;")
        :gsub('"',  "&quot;")
        :gsub("'",  "&#39;")
    return r
end

-- Extract a human-readable date from a raw RSS pubDate or Atom ISO-8601 string.
local function formatDate(raw)
    if not raw or raw == "" then return nil end
    -- RSS pubDate: "Mon, 01 Jan 2024 00:00:00 +0000" → "01 Jan 2024"
    local d = raw:match("%a+,%s+(%d+%s+%a+%s+%d+)")
    if d then return d end
    -- Atom ISO-8601: "2024-01-01T00:00:00Z" → "2024-01-01"
    d = raw:match("(%d%d%d%d%-%d%d%-%d%d)")
    if d then return d end
    return raw  -- fallback: return as-is
end

-- Estimate reading time from plain text (~200 wpm).
local function readingTime(text)
    return TextUtil.readingTime(text, true)
end

-- Remove the first h1/h2/h3 whose plain text matches title.
local function stripLeadingTitle(html, title)
    return HtmlCleanup.stripLeadingTitle(html, title)
end

-- ── CSS ───────────────────────────────────────────────────────────────────────
-- MuPDF does not scale CSS pixel values, so font-size uses pt and spacing
-- uses unitless ratios.  line_spacing is stored as an integer x10 (15 = 1.5).
-- When the user picks a font file we load it via @font-face so MuPDF uses the
-- exact file rather than trying to match a family name.
local function makeCSS(prefs)
    local font_face_rule = ""
    local font_family    = "serif"
    if prefs.font_file and prefs.font_file ~= "" then
        font_face_rule = string.format(
            '@font-face { font-family: "UserFont"; src: url("%s"); }\n',
            prefs.font_file)
        font_family = '"UserFont", serif'
    end
    local align = (prefs.text_align == "left") and "left" or "justify"
    local margin = 1.5 * (prefs.margin_scale or 1.0)
    local bg = "#ffffff"
    local fg = "#000000"
    if prefs.theme == "dark" then
        bg = "#1a1a1a"
        fg = "#e8e8e8"
    end
    return font_face_rule .. string.format([[
@page { margin: 0; }
body {
    margin: 0;
    font-family: %s;
    font-size: %dpt;
    line-height: %.1f;
    text-align: %s;
    background: %s;
    color: %s;
}
.content             { margin: 0 %.1fem; padding-top: 0.5em; }
p                    { margin: 0.6em 0; }
h1, h2, h3, h4, h5  { font-weight: bold; margin: 0.8em 0 0.3em; }
img                  { max-width: 100%%; height: auto; display: block; margin: 0.5em auto; }
ol, ul               { margin: 0.5em 0; padding: 0 1.7em; }
li                   { margin: 0.2em 0; }
blockquote           { margin: 0.5em 1em; }
a                    { text-decoration: underline; color: %s; }
.meta                { font-size: 0.85em; margin: 0 0 0.8em; }
hr                   { border: none; border-top: 1px solid #999999; margin: 0.8em 0 1em; }
figure               { text-align: center; margin: 0.5em 0; }
]], font_family, prefs.font_size, prefs.line_spacing / 10,
    align, bg, fg, margin, fg)
end

-- ─────────────────────────────────────────────────────────────────────────────
local ArticleReader = InputContainer:extend{
    article       = nil,   -- populated by caller
    articles      = nil,   -- optional: full list for prev/next navigation
    article_index = 0,     -- position of `article` within `articles`
    on_read       = nil,   -- optional: function(article) when an article is opened
    ui            = nil,   -- KOReader app ui (dictionary lookups)
}

function ArticleReader:init()
    if self.on_read and self.article then
        self.on_read(self.article)
    end
    local screen_w = Screen:getWidth()
    local screen_h = Screen:getHeight()

    self.key_events = {
        Close = { { "Back" }, doc = "close article reader" },
    }

    -- Swipe left/right to navigate between articles
    self.ges_events.Swipe = {
        GestureRange:new{
            ges   = "swipe",
            range = Geom:new{ x = 0, y = 0, w = screen_w, h = screen_h },
        },
    }

    self.prefs = Config.getReaderSettings()

    local title_bar = TitleBar:new{
        width                  = screen_w,
        title                  = self.article.title or "",
        with_bottom_line       = true,
        left_icon              = "appbar.menu",
        left_icon_tap_callback = function() self:_openArticleMenu() end,
        close_callback         = function() self:onClose() end,
        show_parent            = self,
    }
    local title_h = title_bar:getSize().h

    -- ── Prev / Next navigation footer ─────────────────────────────────────────
    local nav_footer_widget = nil
    local footer_h          = 0

    local prev_art = (self.articles and self.article_index > 1)
        and self.articles[self.article_index - 1] or nil
    local next_art = (self.articles and self.article_index < #self.articles)
        and self.articles[self.article_index + 1] or nil

    if prev_art or next_art then
        local half_w = math.floor(screen_w / 2)
        local function trunc(s, n)
            s = s or ""
            -- Walk UTF-8 code points to avoid splitting multi-byte characters.
            local chars, pos = 0, 1
            while pos <= #s and chars < n do
                local b = s:byte(pos)
                if     b < 0x80  then pos = pos + 1
                elseif b < 0xE0 then pos = pos + 2
                elseif b < 0xF0 then pos = pos + 3
                else                  pos = pos + 4 end
                chars = chars + 1
            end
            if pos > #s then return s end
            return s:sub(1, pos - 1) .. "…"
        end

        local left_widget, right_widget
        if prev_art then
            left_widget = Button:new{
                text     = "◀  " .. trunc(prev_art.title, 25),
                width    = half_w,
                callback = function() self:_navigateTo(self.article_index - 1) end,
            }
        else
            left_widget = HorizontalSpan:new{ width = half_w }
        end

        if next_art then
            right_widget = Button:new{
                text     = trunc(next_art.title, 25) .. "  ▶",
                width    = half_w,
                callback = function() self:_navigateTo(self.article_index + 1) end,
            }
        else
            right_widget = HorizontalSpan:new{ width = half_w }
        end

        nav_footer_widget = VerticalGroup:new{
            align = "left",
            LineWidget:new{ dimen = Geom:new{ w = screen_w, h = Size.line.thin } },
            HorizontalGroup:new{ align = "center", left_widget, right_widget },
        }
        footer_h = nav_footer_widget:getSize().h
    end

    local article_images_enabled = Config.getArticleSettings().article_images_enabled
    local content_parts = {}

    -- Banner image rendered inside the HTML content
    if article_images_enabled and self.article.image_path then
        local fname = self.article.image_path:match("([^/]+)$")
        if fname then
            table.insert(content_parts,
                '<img src="' .. fname .. '" style="width:100%">')
        end
    end

    -- Title as H1
    table.insert(content_parts,
        '<h1>' .. escapeHtml(self.article.title) .. '</h1>')

    -- Meta line: "Source · Date · reading time" (omit empty parts)
    local meta_parts = {}
    if self.article.source and self.article.source ~= "" then
        table.insert(meta_parts, escapeHtml(self.article.source))
    end
    local fmt_date = formatDate(self.article.date)
    if fmt_date then
        table.insert(meta_parts, escapeHtml(fmt_date))
    end
    local rt = readingTime(TextUtil.articlePlainText(self.article))
    if rt then
        table.insert(meta_parts, rt)
    end
    if #meta_parts > 0 then
        table.insert(content_parts,
            '<p class="meta">' .. table.concat(meta_parts, " &middot; ") .. '</p>')
    end

    table.insert(content_parts, '<hr>')

    -- ── Body content ──────────────────────────────────────────────────────────
    -- Use raw HTML content; fall back to wrapping full_text if content is empty.
    local body = self.article.content or ""
    if body == "" then
        body = "<p>" .. (self.article.full_text or _("No content available.")) .. "</p>"
    end

    -- Remove any leading heading that duplicates the article title (we already
    -- render it as <h1> in the header above).
    body = stripLeadingTitle(body, self.article.title)
    body, self.headings = HtmlCleanup.clean(body, { headings = true })

    local function escPat(s)
        return s:gsub("([%(%)%.%%%+%-%*%?%[%^%$])", "%%%1")
    end
    -- Helper: remove <img> tags whose src starts with base_url.
    -- Always uses prefix matching so query strings / variant suffixes are accepted.
    -- max: maximum replacements (nil = unlimited).
    local function stripImgByBase(html, base_url, max)
        local ep = escPat(base_url)
        local r, n = html:gsub('<[Ii][Mm][Gg][^>]*[Ss][Rr][Cc]%s*=%s*"' .. ep .. '[^"]*"[^>]*/?>', "", max)
        if n > 0 then return r end
        r = html:gsub("<[Ii][Mm][Gg][^>]*[Ss][Rr][Cc]%s*=%s*'" .. ep .. "[^']*'[^>]*/?>", "", max)
        return r
    end

    if article_images_enabled then
        -- Pass 1 (pre-localization): remove all size variants of the banner image.
        -- Derives a URL stem by stripping the CDN dimension suffix ("-NNNxNNN") and
        -- file extension so variants like "squeak3-640x427.jpg" and
        -- "squeak3-1152x648.jpg" are both caught by the same prefix.
        if self.article.image_url then
            local base = self.article.image_url:match("^([^?#]+)") or self.article.image_url
            -- Try stripping "-NNNxNNN.ext" (e.g. Ars Technica CDN) first;
            -- fall back to just stripping ".ext" (e.g. Hackaday "?w=800" style).
            local stem = base:match("^(.-)%-%d+x%d+%.[^./]+$")
                         or base:match("^(.+)%.[^./]+$")
            if stem and stem ~= "" then base = stem end
            body = stripImgByBase(body, base)  -- no limit: removes all size variants
        end

        -- Strip explicit width/height/style attrs so CSS max-width takes effect,
        -- then download remote images and rewrite src to local filenames.
        body = Images.localizeImages(Images.constrainImages(body))

        -- Pass 2 (post-localization): strip by the local filename (safety net for
        -- any variant that survived Pass 1 after URL rewriting).
        if self.article.image_path then
            local fname = self.article.image_path:match("([^/]+)$")
            if fname then
                body = stripImgByBase(body, fname, 1)
            end
        end
    else
        -- Images disabled: strip all <img> tags (and stray </img> closers)
        -- so they don't show as broken placeholders.
        body = body:gsub("<[Ii][Mm][Gg][^>]*/?>", "")
        body = body:gsub("</[Ii][Mm][Gg]%s*>", "")
    end

    body = HtmlCleanup.stripEmptyParagraphs(body)
    body = HtmlCleanup.collapseBreaks(body)
    self._body_html = body

    self.html = '<div class="content">\n'
        .. table.concat(content_parts, "\n") .. "\n"
        .. body
        .. "\n</div>"
    self.scroll_w = screen_w
    self.scroll_h = screen_h - title_h - footer_h

    -- Build layout: title_bar → scroll → (optional footer).
    -- nav_footer_widget is optional; track scroll_idx so that _applyPrefs can
    -- replace the scroll widget regardless of what precedes it.
    self.layout_group = VerticalGroup:new{ align = "left", title_bar }
    self.scroll_idx = #self.layout_group + 1
    self.scroll_widget = self:_makeScrollWidget()
    table.insert(self.layout_group, self.scroll_widget)
    self:_registerTextSelectionGestures()
    if nav_footer_widget then
        table.insert(self.layout_group, nav_footer_widget)
    end

    self[1] = FrameContainer:new{
        width      = screen_w,
        height     = screen_h,
        padding    = 0,
        margin     = 0,
        bordersize = 0,
        background = Blitbuffer.COLOR_WHITE,
        self.layout_group,
    }
end

function ArticleReader:_makeScrollWidget()
    return ScrollHtmlWidget:new{
        html_body               = self.html,
        css                     = makeCSS(self.prefs),
        width                   = self.scroll_w,
        height                  = self.scroll_h,
        dialog                  = self,
        html_resource_directory = IMAGE_DIR,
    }
end

function ArticleReader:_htmlBox()
    return self.scroll_widget and self.scroll_widget.htmlbox_widget
end

-- Hold on a word (or drag to select) → dictionary lookup.
function ArticleReader:_registerTextSelectionGestures()
    if not Device:isTouchDevice() then return end

    local hold_pan_rate = G_reader_settings:readSetting("hold_pan_rate")
    if not hold_pan_rate then
        hold_pan_rate = Screen.low_pan_rate and 5.0 or 30.0
    end

    local range_fn = function()
        return self.scroll_widget and self.scroll_widget.dimen
    end

    self.ges_events.HoldStartText = {
        GestureRange:new{ ges = "hold", range = range_fn },
    }
    self.ges_events.HoldPanText = {
        GestureRange:new{
            ges  = "hold_pan",
            range = range_fn,
            rate = hold_pan_rate,
        },
    }
    self.ges_events.HoldReleaseText = {
        GestureRange:new{ ges = "hold_release", range = range_fn },
        args = function(text, _hold_duration)
            self:_onTextHoldRelease(text)
        end,
    }
end

function ArticleReader:onHoldStartText(arg, ges)
    local box = self:_htmlBox()
    if box then return box:onHoldStartText(arg, ges) end
end

function ArticleReader:onHoldPanText(arg, ges)
    local box = self:_htmlBox()
    if box then return box:onHoldPanText(arg, ges) end
end

function ArticleReader:onHoldReleaseText(callback, ges)
    local box = self:_htmlBox()
    if box then return box:onHoldReleaseText(callback, ges) end
end

function ArticleReader:_onTextHoldRelease(text)
    if not text or text == "" then return end

    local box = self:_htmlBox()
    local dict_close_callback
    if box then
        dict_close_callback = function()
            box:scheduleClearHighlightAndRedraw()
        end
    end

    if self.ui then
        self.ui:handleEvent(Event:new(
            "LookupWord", text, nil, nil, nil, nil, dict_close_callback))
    else
        local ReaderDictionary = require("apps/reader/modules/readerdictionary")
        ReaderDictionary:new{ ui = nil }
            :onLookupWord(text, false, nil, nil, nil, dict_close_callback)
    end
end

function ArticleReader:_openArticleMenu()
    local dialog
    local queue_label = Config.isInExportQueue(self.article.link)
        and _("Remove from export queue") or _("Add to export queue")
    local buttons = {
        {{
            text = Icons.SAVE .. "  " .. _("Save article"),
            callback = function()
                UIManager:close(dialog)
                self:_saveArticle()
            end,
        }},
        {{
            text = queue_label,
            callback = function()
                UIManager:close(dialog)
                if Config.isInExportQueue(self.article.link) then
                    Config.removeFromExportQueue(self.article.link)
                else
                    Config.addToExportQueue(self.article.link)
                end
                UIManager:show(InfoMessage:new{
                    text = Config.isInExportQueue(self.article.link)
                        and _("Added to export queue") or _("Removed from export queue"),
                    timeout = 2,
                })
            end,
        }},
        {{
            text = Icons.SETTINGS .. "  " .. _("Reader settings"),
            callback = function()
                UIManager:close(dialog)
                self:_openReaderSettings()
            end,
        }},
    }
    if self.headings and #self.headings > 0 then
        table.insert(buttons, {{
            text = _("Table of contents"),
            callback = function()
                UIManager:close(dialog)
                self:_openTocMenu()
            end,
        }})
    end
    dialog = ButtonDialog:new{ buttons = buttons }
    UIManager:show(dialog)
end

function ArticleReader:_openTocMenu()
    local RadioButtonWidget = require("ui/widget/radiobuttonwidget")
    local radio_buttons = {}
    for _, h in ipairs(self.headings) do
        local indent = string.rep("  ", math.max(0, h.level - 1))
        table.insert(radio_buttons, {{
            text = indent .. h.text,
            provider = h.id,
        }})
    end
    UIManager:show(RadioButtonWidget:new{
        title_text = _("Table of contents"),
        cancel_text = _("Close"),
        ok_text = _("Jump"),
        radio_buttons = radio_buttons,
        callback = function(radio)
            self:_jumpToHeading(radio.provider)
        end,
    })
end

function ArticleReader:_jumpToHeading(heading_id)
    local body = self._body_html or ""
    local start = body:find('id="' .. heading_id .. '"')
    if not start then return end
    local tag_start = body:reverse():find(">", #body - start + 1)
    if tag_start then
        start = #body - tag_start + 2
    else
        start = body:find("<[hH]", start - 5) or start
    end
    local sliced = body:sub(start)
    local header = self.html:match("(.-<hr>%s*)")
    if header then
        self.html = header .. "\n" .. sliced .. "\n</div>"
        self:_applyPrefs(self.prefs)
    end
end

function ArticleReader:_saveArticle()
    local path_chooser = PathChooser:new{
        select_directory = true,
        select_file        = false,
        title              = _("Save article to folder"),
        onConfirm = function(dir_path)
            local path, err = ArticleExport.save(self.article, dir_path)
            if not path then
                UIManager:show(InfoMessage:new{
                    text = T(_("Could not save article:\n%1"), tostring(err)),
                })
                return
            end
            UIManager:show(InfoMessage:new{
                text = T(_("Article saved to:\n%1"), path),
            })
        end,
    }
    UIManager:show(path_chooser)
end

function ArticleReader:_openReaderSettings()
    local ReaderSettingsUI = require("modules/ui/reader_settings")
    UIManager:show(ReaderSettingsUI:new{
        on_change = function(prefs)
            self:_applyPrefs(prefs)
        end,
    })
end

function ArticleReader:_applyPrefs(prefs)
    self.prefs = prefs
    self.scroll_widget = self:_makeScrollWidget()
    self.layout_group[self.scroll_idx] = self.scroll_widget
    self.layout_group:resetLayout()
    UIManager:setDirty(self, function() return "full", self.dimen end)
end

function ArticleReader:onClose()
    UIManager:close(self)
    -- Full e-ink flash so the feed list underneath redraws without ghosting.
    UIManager:setDirty(nil, "full")
end

-- Trigger a full e-ink flash on first display to clear ghosting.
function ArticleReader:onShow()
    UIManager:setDirty(self, function()
        return "full", self.dimen
    end)
end

function ArticleReader:onSwipe(_, ges_ev)
    if ges_ev.direction == "west" then
        self:_navigateTo(self.article_index + 1)
        return true
    elseif ges_ev.direction == "east" then
        self:_navigateTo(self.article_index - 1)
        return true
    elseif ges_ev.direction == "northeast"
        or ges_ev.direction == "northwest"
        or ges_ev.direction == "southeast"
        or ges_ev.direction == "southwest" then
        UIManager:setDirty(nil, "full", nil, true)
        return false
    end
end

-- Close the current reader and open the article at new_idx in the list.
function ArticleReader:_navigateTo(new_idx)
    if not self.articles
    or new_idx < 1 or new_idx > #self.articles then
        return
    end
    UIManager:close(self)
    UIManager:show(ArticleReader:new{
        article       = self.articles[new_idx],
        articles      = self.articles,
        article_index = new_idx,
        on_read       = self.on_read,
        ui            = self.ui,
    })
end

return ArticleReader

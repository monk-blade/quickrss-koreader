-- QuickRSS: Reader Settings UI
-- Popup for configuring article-reader appearance (font, size, line spacing).
-- Opened from the settings icon in ArticleReader's TitleBar.
-- Calls on_change(prefs) immediately on each change so the reader re-renders.

local Blitbuffer      = require("ffi/blitbuffer")
local ButtonDialog    = require("ui/widget/buttondialog")
local CenterContainer = require("ui/widget/container/centercontainer")
local Config          = require("modules/data/config")
local Icons           = require("modules/ui/icons")
local Device          = require("device")
local FrameContainer  = require("ui/widget/container/framecontainer")
local Geom            = require("ui/geometry")
local InputContainer  = require("ui/widget/container/inputcontainer")
local LineWidget      = require("ui/widget/linewidget")
local Size            = require("ui/size")
local SpinWidget      = require("ui/widget/spinwidget")
local SR              = require("modules/ui/settings_row")
local TextWidget      = require("ui/widget/textwidget")
local TitleBar        = require("ui/widget/titlebar")
local UIManager       = require("ui/uimanager")
local VerticalGroup   = require("ui/widget/verticalgroup")
local FontList        = require("fontlist")
local _               = require("gettext")

local Screen = Device.screen

local PAD        = SR.PAD
local ROW_H      = SR.ROW_H
local VALUE_FACE = SR.VALUE_FACE

-- ── Font list ─────────────────────────────────────────────────────────────────
-- Uses KOReader's own FontList module (the same source the built-in font picker
-- uses) so we see every font KOReader can see, including user-installed ones.
-- Bold/italic faces are filtered out to keep the list to one entry per family.
-- The first entry is always the "Default" option (path = "").
local function scanFonts()
    FontList:getFontList()  -- populates FontList.fontinfo (no-op if already cached)
    local fonts = {}
    for font_file, font_info_arr in pairs(FontList.fontinfo) do
        local info = font_info_arr and font_info_arr[1]
        if info and not info.bold and not info.italic then
            local name = FontList:getLocalizedFontName(font_file, 0) or info.name or font_file
            table.insert(fonts, { name = name, path = font_file })
        end
    end
    table.sort(fonts, function(a, b) return a.name < b.name end)
    table.insert(fonts, 1, { name = _("Default (Serif)"), path = "" })
    return fonts
end

-- Short display name for a stored font path.
local function fontDisplayName(font_file)
    if not font_file or font_file == "" then
        return _("Default (Serif)")
    end
    local arr = FontList.fontinfo and FontList.fontinfo[font_file]
    if arr and arr[1] then
        return FontList:getLocalizedFontName(font_file, 0) or arr[1].name or font_file
    end
    -- Fallback: derive from filename (used before getFontList() has been called)
    local base = font_file:match("([^/]+)$") or font_file
    return base:gsub("%-Regular", ""):gsub("%.[^%.]+$", ""):gsub("%-", " ")
end

-- ─────────────────────────────────────────────────────────────────────────────
local ReaderSettingsUI = InputContainer:extend{
    name      = "quickrss_reader_settings",
    on_change = nil,   -- function(prefs) – called when any setting changes
}

local function spacingText(v) return string.format("%.1f", v / 10) end

local READING_PRESETS = {
    compact = {
        name = _("Compact"),
        font_size = 14, line_spacing = 12, margin_scale = 0.8, text_align = "justify",
    },
    comfortable = {
        name = _("Comfortable"),
        font_size = 18, line_spacing = 15, margin_scale = 1.0, text_align = "justify",
    },
    newspaper = {
        name = _("Newspaper"),
        font_size = 16, line_spacing = 14, margin_scale = 1.2, text_align = "left",
    },
}

local function alignText(v)
    return v == "left" and _("Left") or _("Justify")
end

local function themeText(v)
    return v == "dark" and _("Dark") or _("Default")
end

function ReaderSettingsUI:init()
    local screen_w = Screen:getWidth()
    local screen_h = Screen:getHeight()

    self.key_events = {
        Close = { { "Back" }, doc = "close reader settings" },
    }

    self.s = Config.getReaderSettings()

    local popup_w = math.floor(screen_w * 0.9)
    local inner_w = popup_w - PAD * 2

    -- ── Title bar ─────────────────────────────────────────────────────────────
    local title_bar = TitleBar:new{
        width            = popup_w,
        title            = Icons.SETTINGS .. "  " .. _("Reader Settings"),
        with_bottom_line = true,
        close_callback   = function() self:onClose() end,
        show_parent      = self,
    }
    local title_bar_h = title_bar:getSize().h

    -- ── Value TextWidgets ──────────────────────────────────────────────────────
    self.font_val    = TextWidget:new{
        text = fontDisplayName(self.s.font_file),
        face = VALUE_FACE,
    }
    self.size_val    = TextWidget:new{
        text = tostring(self.s.font_size) .. " pt",
        face = VALUE_FACE,
    }
    self.spacing_val = TextWidget:new{
        text = spacingText(self.s.line_spacing),
        face = VALUE_FACE,
    }
    self.align_val = TextWidget:new{
        text = alignText(self.s.text_align),
        face = VALUE_FACE,
    }
    self.margin_val = TextWidget:new{
        text = string.format("%.1f", self.s.margin_scale or 1.0),
        face = VALUE_FACE,
    }
    self.theme_val = TextWidget:new{
        text = themeText(self.s.theme),
        face = VALUE_FACE,
    }

    -- ── Row builder (shared) ────────────────────────────────────────────────
    local function makeRow(label, val_widget, on_tap)
        return SR.makeRow(inner_w, label, val_widget, on_tap)
    end

    -- ── Three rows ────────────────────────────────────────────────────────────
    local row_font = makeRow(_("Font"), self.font_val, function()
        local fonts = scanFonts()
        local buttons = {}
        for _, font in ipairs(fonts) do
            local is_current = font.path == (self.s.font_file or "")
            local label = is_current and ("✓  " .. font.name) or font.name
            local path  = font.path   -- capture for closure
            local name  = font.name
            table.insert(buttons, {{ text = label, callback = function()
                UIManager:close(font_dialog)  -- luacheck: ignore (forward ref)
                self.s.font_file = path
                Config.saveReaderSettings(self.s)
                self.font_val:setText(name)
                self.rows_group:resetLayout()
                UIManager:setDirty(self, function() return "ui", self.dimen end)
                if self.on_change then self.on_change(self.s) end
            end }})
        end
        font_dialog = ButtonDialog:new{ buttons = buttons }
        UIManager:show(font_dialog)
    end)

    local row_size = makeRow(_("Font size"), self.size_val, function()
        UIManager:show(SpinWidget:new{
            title_text      = _("Font size"),
            value           = self.s.font_size,
            value_min       = 12,
            value_max       = 64,
            value_step      = 1,
            value_hold_step = 2,
            default_value   = 18,
            unit            = _("pt"),
            callback = function(spin)
                self.s.font_size = spin.value
                Config.saveReaderSettings(self.s)
                self.size_val:setText(spin.value .. " pt")
                self.rows_group:resetLayout()
                UIManager:setDirty(self, function() return "ui", self.dimen end)
                if self.on_change then self.on_change(self.s) end
            end,
        })
    end)

    local row_spacing = makeRow(_("Line spacing"), self.spacing_val, function()
        UIManager:show(SpinWidget:new{
            title_text      = _("Line spacing"),
            value           = self.s.line_spacing,
            value_min       = 10,
            value_max       = 25,
            value_step      = 1,
            value_hold_step = 5,
            default_value   = 15,
            callback = function(spin)
                self.s.line_spacing = spin.value
                Config.saveReaderSettings(self.s)
                self.spacing_val:setText(spacingText(spin.value))
                self.rows_group:resetLayout()
                UIManager:setDirty(self, function() return "ui", self.dimen end)
                if self.on_change then self.on_change(self.s) end
            end,
        })
    end)

    local row_align = makeRow(_("Text alignment"), self.align_val, function()
        local next_align = (self.s.text_align == "left") and "justify" or "left"
        self.s.text_align = next_align
        Config.saveReaderSettings(self.s)
        self.align_val:setText(alignText(next_align))
        self.rows_group:resetLayout()
        UIManager:setDirty(self, function() return "ui", self.dimen end)
        if self.on_change then self.on_change(self.s) end
    end)

    local row_margin = makeRow(_("Margin scale"), self.margin_val, function()
        UIManager:show(SpinWidget:new{
            title_text = _("Margin scale"),
            value = math.floor((self.s.margin_scale or 1.0) * 10),
            value_min = 5, value_max = 20, value_step = 1,
            default_value = 10,
            callback = function(spin)
                self.s.margin_scale = spin.value / 10
                Config.saveReaderSettings(self.s)
                self.margin_val:setText(string.format("%.1f", self.s.margin_scale))
                self.rows_group:resetLayout()
                UIManager:setDirty(self, function() return "ui", self.dimen end)
                if self.on_change then self.on_change(self.s) end
            end,
        })
    end)

    local row_theme = makeRow(_("Theme"), self.theme_val, function()
        self.s.theme = (self.s.theme == "dark") and "default" or "dark"
        Config.saveReaderSettings(self.s)
        self.theme_val:setText(themeText(self.s.theme))
        self.rows_group:resetLayout()
        UIManager:setDirty(self, function() return "ui", self.dimen end)
        if self.on_change then self.on_change(self.s) end
    end)

    local row_preset = makeRow(_("Preset"), TextWidget:new{
        text = _("Choose…"), face = VALUE_FACE,
    }, function()
        local preset_dialog
        local buttons = {}
        for key, preset in pairs(READING_PRESETS) do
            table.insert(buttons, {{ text = preset.name, callback = function()
                UIManager:close(preset_dialog)
                self.s.font_size = preset.font_size
                self.s.line_spacing = preset.line_spacing
                self.s.margin_scale = preset.margin_scale
                self.s.text_align = preset.text_align
                Config.saveReaderSettings(self.s)
                self.size_val:setText(self.s.font_size .. " pt")
                self.spacing_val:setText(spacingText(self.s.line_spacing))
                self.margin_val:setText(string.format("%.1f", self.s.margin_scale))
                self.align_val:setText(alignText(self.s.text_align))
                self.rows_group:resetLayout()
                UIManager:setDirty(self, function() return "ui", self.dimen end)
                if self.on_change then self.on_change(self.s) end
            end }})
        end
        preset_dialog = ButtonDialog:new{ buttons = buttons }
        UIManager:show(preset_dialog)
    end)

    local function sep()
        return LineWidget:new{
            background = Blitbuffer.COLOR_LIGHT_GRAY,
            dimen      = Geom:new{ w = inner_w, h = Size.line.thin },
            style      = "solid",
        }
    end

    self.rows_group = VerticalGroup:new{
        align = "left",
        CenterContainer:new{ dimen = Geom:new{ w = popup_w, h = ROW_H }, row_font },
        sep(),
        CenterContainer:new{ dimen = Geom:new{ w = popup_w, h = ROW_H }, row_size },
        sep(),
        CenterContainer:new{ dimen = Geom:new{ w = popup_w, h = ROW_H }, row_spacing },
        sep(),
        CenterContainer:new{ dimen = Geom:new{ w = popup_w, h = ROW_H }, row_align },
        sep(),
        CenterContainer:new{ dimen = Geom:new{ w = popup_w, h = ROW_H }, row_margin },
        sep(),
        CenterContainer:new{ dimen = Geom:new{ w = popup_w, h = ROW_H }, row_theme },
        sep(),
        CenterContainer:new{ dimen = Geom:new{ w = popup_w, h = ROW_H }, row_preset },
    }

    local rows_content_h = ROW_H * 7 + Size.line.thin * 6
    local popup_h        = title_bar_h + rows_content_h + 2 * Size.border.window

    local popup = FrameContainer:new{
        width      = popup_w,
        height     = popup_h,
        padding    = 0,
        margin     = 0,
        bordersize = Size.border.window,
        background = Blitbuffer.COLOR_WHITE,
        VerticalGroup:new{
            align = "left",
            title_bar,
            self.rows_group,
        },
    }

    self[1] = CenterContainer:new{
        dimen = Geom:new{ w = screen_w, h = screen_h },
        popup,
    }

    UIManager:setDirty(self, function()
        return "ui", self.dimen
    end)
end

function ReaderSettingsUI:onClose()
    UIManager:close(self)
end

function ReaderSettingsUI:onCloseWidget()
    UIManager:setDirty(nil, function()
        return "ui", self.dimen
    end)
end

return ReaderSettingsUI

local WidgetContainer = require("ui/widget/container/widgetcontainer")
local UIManager = require("ui/uimanager")
local Icons = require("modules/ui/icons")
local Config = require("modules/data/config")
local Cache = require("modules/data/cache")
local FetchCoordinator = require("modules/data/fetch_coordinator")
local NetworkMgr = require("ui/network/manager")
local Device = require("device")
local T = require("ffi/util").template
local _ = require("gettext")

local QuickRSS = WidgetContainer:extend{
    name = "quickrss",
    is_doc_only = false,
}

function QuickRSS:init()
    self.ui.menu:registerToMainMenu(self)
end

function QuickRSS:addToMainMenu(menu_items)
    menu_items.quickrss = {
        text = Icons.FEEDS .. " " .. _("QuickRSS"),
        sorting_hint = "search",
        callback = function()
            local QuickRSSUI = require("modules/ui/feed_view")
            UIManager:show(QuickRSSUI:new{})
        end,
    }
end

function QuickRSS:onResume()
    local s = Config.getArticleSettings()
    if not s.scheduled_fetch_enabled then return end
    if #Config.getFeeds() == 0 then return end
    if not Cache.isStale(s.max_cache_age_days) then return end
    if FetchCoordinator.isInProgress() then return end

    if not NetworkMgr:isConnected() then return end

    if s.scheduled_fetch_requires_charging then
        local power = Device:getPowerDevice()
        if power and not power:isCharging() then return end
    end

    FetchCoordinator.fetch({
        on_complete = function(_, errors)
            if errors and #errors > 0 then
                local Notification = require("ui/widget/notification")
                UIManager:show(Notification:new{
                    text = T(_("%1 feed(s) failed during background fetch"), #errors),
                })
            end
        end,
    })
end

return QuickRSS

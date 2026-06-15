-- QuickRSS: Text utilities
-- Shared plain-text helpers for cards and reader UI.

local TextUtil = {}

-- Estimate reading time from plain text (~200 wpm).
-- Returns "~N min" for cards or "~N min read" when long_form is true.
function TextUtil.readingTime(text, long_form)
    if not text or text == "" then return nil end
    local words = 0
    for _ in text:gmatch("%S+") do words = words + 1 end
    if words < 50 then return nil end
    local mins = math.max(1, math.ceil(words / 200))
    if long_form then
        return "~" .. mins .. " min read"
    end
    return "~" .. mins .. " min"
end

-- Plain text for read-time estimation: prefer full_text, then content sans tags.
function TextUtil.articlePlainText(article)
    if not article then return "" end
    if article.full_text and article.full_text ~= "" then
        return article.full_text
    end
    local html = article.content or ""
    return html:gsub("<[^>]+>", " "):gsub("%s+", " ")
end

return TextUtil

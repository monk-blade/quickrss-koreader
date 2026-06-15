return {
    getArticleSettings = function()
        return {
            items_per_feed     = 20,
            fulltext_enabled   = false,
            fulltext_url       = "https://example.com/",
        }
    end,
    normalizeFeedUrl = function(url)
        if url:match("^https?://") then return url end
        return "https://" .. url
    end,
}

-- QuickRSS: HTML cleanup
-- Shared sanitizer for article reader, HTML export, and EPUB export.

local HtmlCleanup = {}

local function normPlain(s)
    return (s or "")
        :gsub("<[^>]+>", "")
        :gsub("&amp;", "&"):gsub("&lt;", "<"):gsub("&gt;", ">")
        :gsub("&quot;", '"'):gsub("&#39;", "'"):gsub("&[^;]+;", "")
        :gsub("%s+", " "):match("^%s*(.-)%s*$") or ""
end

-- Remove the first h1/h2/h3 whose plain text matches title.
function HtmlCleanup.stripLeadingTitle(html, title)
    if not html or not title or title == "" then return html or "" end
    local title_norm = normPlain(title):lower()
    return (html or ""):gsub("<[hH][123][^>]*>([%s%S]-)</[hH][123]>",
        function(inner)
            if normPlain(inner):lower() == title_norm then return "" end
        end, 1)
end

-- Strip empty <p> tags and paragraphs with only whitespace / &nbsp;.
function HtmlCleanup.stripEmptyParagraphs(html)
    return (html or "")
        :gsub("<[pP][^>]*>%s*</[pP]>", "")
        :gsub("<[pP][^>]*>%s*&nbsp;%s*</[pP]>", "")
        :gsub("<[pP][^>]*>%s*<br%s*/?>%s*</[pP]>", "")
end

-- Collapse runs of three or more <br> into two.
function HtmlCleanup.collapseBreaks(html)
    local result = html or ""
    local pat = "<br%s*/?>%s*<br%s*/?>%s*<br%s*/?>"
    while result:find(pat) do
        result = result:gsub(pat, "<br><br>", 1)
    end
    return result
end

-- Normalize figure/picture wrappers to a simple centered figure block.
function HtmlCleanup.normalizeFigures(html)
    return (html or "")
        :gsub("<picture[^>]*>([%s%S]-)</picture>", "<figure>%1</figure>")
        :gsub("<figure([^>]*)>", '<figure%1 style="text-align:center;margin:0.5em 0;">')
end

-- Assign id="qrss-h-N" to h1–h3 and return heading list.
function HtmlCleanup.injectHeadingIds(html)
    local headings = {}
    local n = 0
    local result = (html or ""):gsub("<([hH])([123])([^>]*)>([%s%S]-)</%1%2>",
        function(h, level, attrs, inner)
            n = n + 1
            local id = "qrss-h-" .. n
            local text = normPlain(inner)
            if text ~= "" then
                table.insert(headings, { level = tonumber(level), text = text, id = id })
            end
            if attrs:match('id%s*=') then
                return string.format("<h%s%s>%s</h%s>", level, attrs, inner, level)
            end
            return string.format('<h%s id="%s"%s>%s</h%s>', level, id, attrs, inner, level)
        end)
    return result, headings
end

function HtmlCleanup.extractHeadings(html)
    local _, headings = HtmlCleanup.injectHeadingIds(html)
    return headings
end

-- Full cleanup pass used by reader, export, and EPUB.
function HtmlCleanup.clean(html, opts)
    opts = opts or {}
    local result = html or ""
    result = HtmlCleanup.stripEmptyParagraphs(result)
    result = HtmlCleanup.collapseBreaks(result)
    result = HtmlCleanup.normalizeFigures(result)
    if opts.title then
        result = HtmlCleanup.stripLeadingTitle(result, opts.title)
    end
    if opts.headings then
        local headings
        result, headings = HtmlCleanup.injectHeadingIds(result)
        return result, headings
    end
    return result
end

return HtmlCleanup

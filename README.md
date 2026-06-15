# QuickRSS

A fast, standalone RSS/Atom reader plugin for [KOReader](https://github.com/koreader/koreader). Read feeds offline on your e-reader, save articles as HTML, and manage subscriptions with OPML.

**Version:** see [`quickrss.koplugin/_meta.lua`](quickrss.koplugin/_meta.lua) (currently 0.3.x)

---

## Table of contents

1. [Install](#install)
2. [Quick start](#quick-start)
3. [Main screen](#main-screen)
4. [Fetching articles](#fetching-articles)
5. [Reading articles](#reading-articles)
6. [Saving articles](#saving-articles)
7. [Managing feeds](#managing-feeds)
8. [Filters](#filters)
9. [Settings](#settings)
10. [Data files and backup](#data-files-and-backup)
11. [Troubleshooting](#troubleshooting)
12. [Future improvements](#future-improvements)
13. [Development](#development)

---

## Install

1. Copy the entire `quickrss.koplugin` folder to your KOReader plugins directory:

   ```
   <device>/koreader/plugins/quickrss.koplugin/
   ```

   Common locations:
   - **Kobo / Kindle / etc.:** USB → `koreader/plugins/`
   - **Emulator:** `~/projects/koreader/plugins/` (use [`scripts/dev-link.sh`](scripts/dev-link.sh) for development)

2. Restart KOReader (or reload plugins if your build supports it).

3. Enable the plugin if needed: **Tools → More tools → Plugin management → User plugins → quickrss**.

4. Open **QuickRSS** from the KOReader main menu (look in the search/tools section).

---

## Quick start

1. Open **QuickRSS** from the main menu.
2. Tap the **menu icon** (top-left) → **Fetch Articles** → confirm.
3. Wait for feeds to load (Wi‑Fi must be on; KOReader will prompt you if it is off).
4. Tap any article card to read it.
5. Swipe left/right to move between articles.

On first launch, a default **Ars Technica** feed is available until you add your own.

---

## Main screen

The article list shows:

- **Title** (bold when unread)
- **Source · date** meta line (unread items show a **●** marker)
- **Snippet** from the feed or full-text extraction
- **Thumbnail** (if enabled and available)

**Controls:**

| Action | How |
|--------|-----|
| Open menu | Tap **☰** (top-left) |
| Close QuickRSS | Tap **✕** (top-right) or press **Back** |
| Next / previous page | Swipe left/right, or page-turn keys |
| Filter feeds | Tap **filter button** (bottom-left) |
| Unread-only filter | **Long-press** the filter button |

**Menu (☰):**

- **Fetch Articles** — download latest items from all feeds
- **Feeds** — add, remove, import/export OPML
- **Settings** — cache, images, full-text, parallelism
- **Clear Cache** — remove cached articles and images
- **About** — version and data paths

---

## Fetching articles

1. Menu → **Fetch Articles** → **Fetch**.
2. Progress appears on screen: per-feed status, full-text enrichment, then image downloads.
3. Articles are saved to the local cache automatically — next time you open QuickRSS, they load instantly without Wi‑Fi.

**Auto-fetch:** In **Settings**, enable **Auto-fetch on open**. When the cache is older than **Max cache age**, QuickRSS fetches automatically on open.

**Parallel downloads:** **Settings → Parallel downloads** controls how many HTTP requests run at once (default: 4 on emulator, 2 on device). Increase on fast Wi‑Fi; decrease if downloads fail on weak connections.

---

## Reading articles

Tap an article to open the full-screen reader.

| Action | How |
|--------|-----|
| Article menu | Tap **☰** (top-left) |
| Reader settings | Menu → **Reader settings** (font, size, line spacing) |
| Next / previous article | Swipe left/right, or footer buttons |
| Close reader | **Back** or **✕** |

Opening an article marks it **read**. Unread articles appear bolder in the list.

**Reader settings** (font, size, spacing) apply immediately and are remembered for future articles.

---

## Saving articles

Save an article as a standalone **HTML file** plus images for reading on a PC or archiving.

1. Open the article.
2. Tap **☰** (top-left) → **Save article**.
3. Choose a folder (e.g. USB storage, cloud sync folder, or `Documents`).
4. QuickRSS writes `YYYY-MM-DD_Article-Title.html` and copies any images into the same folder.

A duplicate is also kept under:

```
<KOReader data>/quickrss/saved/
```

Open the `.html` file in any browser. The original article URL is included in the header when available.

---

## Managing feeds

Menu → **Feeds**:

| Button | Action |
|--------|--------|
| **+ Add Feed** | Enter name and URL (validated over network before saving) |
| **Import OPML** | Pick a `.opml` / `.xml` file → merge or replace |
| **Export OPML** | Write `quickrss-feeds.opml` to a chosen folder |
| **×** on a row | Remove that feed |

**OPML on a computer:** Edit `<KOReader data>/quickrss/feeds.opml` directly, or export from another reader and import on the device.

Feed URLs without `https://` are normalized automatically.

---

## Filters

**Filter by feed:** Tap the filter button (bottom-left) → choose a feed or **All Feeds**.

**Unread only:** Long-press the filter button to toggle. The button label shows `· Unread` when active.

Filters combine: you can show unread items from one feed only.

---

## Settings

Open via menu → **Settings**.

| Setting | Description |
|---------|-------------|
| **Articles per feed** | Max recent items kept per feed after each fetch (5–100) |
| **Max cache age** | Days before cache is treated as stale; `0` = never expire |
| **Thumbnail images** | Show feed images on article cards |
| **Article images** | Download and show images inside articles |
| **Card font size** | Text size on the article list |
| **Full-text extraction** | Use FiveFilters for truncated feeds |
| **Extraction URL** | Custom FiveFilters endpoint (advanced) |
| **Auto-fetch on open** | Fetch when cache is stale |
| **Parallel downloads** | Concurrent HTTP workers (`Auto` = 2 on device, 4 on emulator) |

---

## Data files and backup

All plugin data lives under `<KOReader data>/quickrss/`:

| Path | Purpose |
|------|---------|
| `feeds.opml` | Subscription list (OPML 1.0) |
| `settings.lua` | Preferences |
| `cache.lua` | Cached articles, read flags, fetch time |
| `images/` | Thumbnails and inline images |
| `saved/` | Copies of exported HTML articles |

**Backup:** Copy the whole `quickrss/` folder to keep feeds, settings, cache, and saved articles.

**Reset:** Menu → **Clear Cache**, or delete `cache.lua` and `images/`. To remove all feeds, delete `feeds.opml` or use Feeds UI.

---

## Troubleshooting

| Problem | Try |
|---------|-----|
| No articles after fetch | Check Wi‑Fi; verify feed URLs in **Feeds**; some feeds block e-readers |
| Partial fetch failures | Notification shows count; remove or fix failing feeds |
| Full-text missing | Enable **Full-text extraction**; some sites block FiveFilters |
| Images missing | Enable **Thumbnail** / **Article images**; re-fetch after enabling |
| Slow fetch | Increase **Parallel downloads** on fast Wi‑Fi; disable full-text or images |
| Plugin not in menu | Enable under **Plugin management**; restart KOReader |
| Save fails | Pick a writable folder (not system paths); ensure storage is mounted |

---

## Future improvements

Ideas for reading experience, layout, and features — not all implemented yet.

### Reading and layout

- **Typography presets** — serif / sans / newspaper / compact modes beyond font picker
- **Dark mode / inverted** — match KOReader reader theme for night reading
- **Adjustable margins and column width** — especially on large screens
- **Justification toggle** — some users prefer ragged-right text on e-ink
- **Table of contents** — for long articles with many headings
- **Estimated read time on cards** — not only inside the article view
- **Open original URL** — menu item to copy or open in browser when online

### List and navigation

- **Search** — full-text search across cached articles
- **Sort options** — by date, source, unread first
- **Starred / favorites** — pin articles for later
- **Feed folders** — OPML categories as groups in the UI
- **Pull-to-refresh gesture** — alternative to menu fetch

### Content and formats

- **EPUB export** — single-article EPUB for KOReader library (like News Downloader)
- **Save from list** — long-press article card to save without opening
- **Batch save** — export all unread or all from one feed
- **Better HTML cleanup** — fewer broken layouts from publisher markup
- **Per-feed full-text toggle** — skip FiveFilters for feeds that already ship full content

### Sync and integration

- **Scheduled background fetch** — when device is charging and on Wi‑Fi
- **Wallabag / Instapaper** — send articles to read-later services
- **KOSync-style state** — sync read/unread across devices (ambitious)

### Technical

- **Translations** — Weblate / `locales/` for non-English UI
- **Per-feed error details** — tap failed-fetch notification to see which feed broke
- **Release zip** — one-click install package for the KOReader plugin forum

Contributions welcome for any of the above.

---

## Development

### Prerequisites (WSL2 / Linux)

```bash
./scripts/install-deps.sh
```

On Ubuntu 24.04, SDL3 is built from source; the script installs X11 dev headers automatically.

### Build KOReader emulator

```bash
./scripts/build-koreader.sh
./scripts/dev-link.sh
cd ~/projects/koreader && ./kodev run -s=kobo-aura-one
```

### Lint and test

```bash
luacheck quickrss.koplugin/
./tests/run.sh
```

See also [KOReader Building.md](https://github.com/koreader/koreader/blob/master/doc/Building.md).

---

## License

MIT — see [LICENSE](LICENSE).

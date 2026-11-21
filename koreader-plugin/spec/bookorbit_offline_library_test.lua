-- Proves the offline library answers like the server: a snapshot is saved
-- atomically for one account, book lists sort, filter, page and bucket as the
-- catalog routes ask, authors and series are drawn from the books, shelves and
-- their members come back as saved, search spans all three, and a summary
-- stands in for a detail page.

package.loaded["gettext"] = function(text)
    return text
end
package.loaded["ffi/util"] = {
    template = function(text, ...)
        local values = { ... }
        return (text:gsub("%%(%d+)", function(index)
            return tostring(values[tonumber(index)])
        end))
    end,
}
package.loaded["document/documentregistry"] = { hasProvider = function() return true end }
package.loaded["datetime"] = {
    shortDayOfWeekToLongTranslation = {},
    shortDayOfWeekTranslation = {},
    longMonthTranslation = {},
    shortMonthTranslation = {},
    secondsToHour = function() return "12:00" end,
    stringISO8601ToSeconds = function() return nil end,
}
package.loaded["device"] = { hasFrontlight = function() return false end }
package.loaded["ui/network/manager"] = { isConnected = function() return true end }
package.loaded["bookorbit_stats_reader"] = {
    getDailySeconds = function() return {} end,
    getBookPace = function() return nil end,
    getHourMinutes = function() return nil end,
    getSessionRecords = function() return nil end,
}
package.loaded["lua-ljsqlite3/init"] = false
package.loaded["datastorage"] = {
    getSettingsDir = function() return "/nonexistent" end,
    getDataDir = function() return "/data" end,
}
package.loaded["ffi/sha2"] = { md5 = function(value) return (value:gsub("[^%w]", "_")) end }

-- A fake filesystem for the snapshot files.
local files = {}
package.loaded["libs/libkoreader-lfs"] = {
    attributes = function(path, what)
        if not files[path] then return nil end
        if what == "mode" then return "file" end
        return { mode = "file" }
    end,
}
local made_paths = {}
package.loaded["util"] = {
    fixUtf8 = function(value) return value end,
    diskUsage = function() return { total = 1, available = 1 } end,
    makePath = function(path) table.insert(made_paths, path); return true end,
    trim = function(value) return tostring(value or ""):match("^%s*(.-)%s*$") end,
}
package.loaded["luasettings"] = {
    open = function(_, path)
        local data = files[path] or {}
        return {
            saveSetting = function(_, k, v) data[k] = v end,
            readSetting = function(_, k) return data[k] end,
            flush = function() files[path] = data end,
        }
    end,
}
local real_remove, real_rename = os.remove, os.rename
os.remove = function(path) files[path] = nil; return true end
os.rename = function(from, to)
    if not files[from] then return nil, "missing" end
    files[to] = files[from]
    files[from] = nil
    return true
end

G_reader_settings = { isTrue = function() return false end }

package.path = "koreader-plugin/bookorbit.koplugin/?.lua;" .. package.path

local OfflineLibrary = require("bookorbit_offline_library")

local function assertEqual(actual, expected, label)
    if actual ~= expected then
        error(string.format("%s: expected %s, got %s", label, tostring(expected), tostring(actual)))
    end
end

local function ids(items)
    local out = {}
    for _, item in ipairs(items or {}) do table.insert(out, tostring(item.id)) end
    return table.concat(out, ",")
end

local function titles(items)
    local out = {}
    for _, item in ipairs(items or {}) do table.insert(out, item.title) end
    return table.concat(out, ",")
end

-- ---------------------------------------------------------------- builder
local builder = OfflineLibrary.newBuilder(3)
local function book(id, extra)
    local b = { id = id, title = "Book " .. id, authors = { "Author" }, formats = { "epub" }, hasCover = true,
        addedAt = string.format("2026-01-%02dT00:00:00Z", id), updatedAt = "2026-01-01T00:00:00Z", detailUrl = "/x", thumbnailUrl = "/t" }
    for k, v in pairs(extra or {}) do b[k] = v end
    return b
end
assertEqual(builder:add(book(1), { libraryId = 7 }), true, "a book is added")
assertEqual(builder:add(book(1)), false, "the same book is not added twice")
assertEqual(builder:add(book(2)), true, "a second book is added")
assertEqual(builder:add(book(3)), true, "the third fills the limit")
assertEqual(builder:remaining(), 0, "nothing remains of the limit")
assertEqual(builder:add(book(4)), false, "the limit stops the walk")
assertEqual(builder:add(book(5), nil, true), true, "a forced book is kept past the limit")
assertEqual(builder:has(5), true, "the forced book is known")
assertEqual(builder.books[1].detailUrl, nil, "a summary drops what lists do not draw")
assertEqual(builder.books[1].libraryId, 7, "a summary keeps the library it was walked in")
builder:addTotal(10)
builder:addTotal(5)
builder:setShelf("libraries", { { id = "7", title = "Main" } })
builder:setMembers("collection:3", { 1, 5 })
builder:setCapabilities({ "catalogListsV2" })
local built = builder:finish(1000)
assertEqual(built.saved_at, 1000, "the snapshot records when it was saved")
assertEqual(built.total, 15, "the total is the libraries' total")
assertEqual(#built.books, 4, "the snapshot holds the walked and forced books")
assertEqual(built.capabilities[1], "catalogListsV2", "the capabilities ride along")

-- ---------------------------------------------------------------- storage
local account = "https://books.example/api/v1|reader"
assertEqual(OfflineLibrary.load(account), nil, "nothing is loaded before a save")
assertEqual(OfflineLibrary.save(account, built), true, "the snapshot saves")
local saved_path
for path in pairs(files) do saved_path = path end
assertEqual(saved_path:match("%.tmp$"), nil, "the temporary file was renamed into place")
assertEqual(made_paths[1], "/data/cache/bookorbit/offline", "the snapshot lives under the BookOrbit cache")
local loaded = OfflineLibrary.load(account)
assertEqual(loaded and #loaded.books, 4, "the snapshot loads again")
assertEqual(loaded.saved_at, 1000, "with when it was saved")
assertEqual(OfflineLibrary.load("https://books.example/api/v1|other"), nil, "another account has no snapshot")
files[saved_path].account = "someone else"
assertEqual(OfflineLibrary.load(account), nil, "a file holding another account's library is not served")
files[saved_path].account = account
local described = OfflineLibrary.describe(loaded)
assertEqual(described.count, 4, "describe counts the books")
assertEqual(described.total, 15, "describe carries the library total")
OfflineLibrary.clear(account)
assertEqual(OfflineLibrary.load(account), nil, "clear removes the snapshot")
assertEqual(OfflineLibrary.normalizeSize(999), OfflineLibrary.DEFAULT_SIZE, "an unknown size falls back to the default")
assertEqual(OfflineLibrary.normalizeSize(500), 500, "a known size is kept")

-- ----------------------------------------------------------------- books
local snapshot = {
    saved_at = 2000,
    total = 6,
    books = {
        { id = 1, title = "Zebra Tales", authors = { "Ann Brown" }, readStatus = "read", progressPercentage = 100, formats = { "epub" }, libraryId = 1, addedAt = "2026-01-01T00:00:00Z", lastReadAt = "2026-02-01T00:00:00Z", seriesId = 9, seriesName = "Safari", seriesIndex = 2 },
        { id = 2, title = "apple pie", authors = { "Bob Clark" }, readStatus = "reading", progressPercentage = 40, formats = { "epub" }, libraryId = 1, addedAt = "2026-01-03T00:00:00Z", lastReadAt = "2026-03-01T00:00:00Z" },
        { id = 3, title = "Éclair", authors = { "Ann Brown", "Cy Dole" }, readStatus = nil, formats = { "pdf" }, libraryId = 2, addedAt = "2026-01-02T00:00:00Z", seriesId = 9, seriesName = "Safari", seriesIndex = 1 },
        { id = 4, title = "42 Steps", authors = {}, readStatus = "want_to_read", formats = { "epub", "mobi" }, libraryId = 2, addedAt = "2026-01-04T00:00:00Z" },
        { id = 5, title = "Banana", authors = { "Bob Clark" }, readStatus = "reading", progressPercentage = 10, formats = { "epub" }, libraryId = 1, addedAt = "2026-01-05T00:00:00Z", lastReadAt = "2026-02-15T00:00:00Z" },
    },
    shelves = {
        libraries = { { id = "1", title = "Main" }, { id = "2", title = "Kids" } },
        collections = { { id = "3", title = "Favourites" } },
        ["smart-scopes"] = {},
    },
    members = { ["collection:3"] = { 1, 5 } },
}

local page = OfflineLibrary.books(snapshot, { sort = "title", page = 1, size = 3, buckets = 1 })
assertEqual(titles(page.items), "42 Steps,apple pie,Banana", "title sort ignores case and pages")
assertEqual(page.total, 5, "the total counts the whole list")
assertEqual(page.hasNext, true, "a second page follows")
assertEqual(page.hasPrevious, false, "the first page has none before it")
assertEqual(#page.buckets, 5, "buckets cover every letter group")
assertEqual(page.buckets[1].key .. page.buckets[1].index, "#0", "numbers bucket under #")
assertEqual(page.buckets[2].key .. page.buckets[2].index, "A1", "A starts at the second entry")
assertEqual(page.buckets[3].key, "B", "an accented letter folds into its base letter later on")
local second = OfflineLibrary.books(snapshot, { sort = "title", page = 2, size = 3 })
assertEqual(titles(second.items), "Éclair,Zebra Tales", "the second page holds the rest")
assertEqual(second.buckets, nil, "buckets come only when asked for")
local by_offset = OfflineLibrary.books(snapshot, { sort = "title", offset = 4, size = 3 })
assertEqual(titles(by_offset.items), "Zebra Tales", "an offset starts the page at that entry")
assertEqual(by_offset.offset, 4, "the offset is echoed")
assertEqual(by_offset.page, 2, "and the page is where the offset lies")

local newest = OfflineLibrary.books(snapshot, { sort = "recently_added", size = 10 })
assertEqual(ids(newest.items), "5,4,2,3,1", "recently added puts the newest first by default")
local oldest = OfflineLibrary.books(snapshot, { sort = "recently_added", order = "asc", size = 10 })
assertEqual(ids(oldest.items), "1,3,2,4,5", "an explicit order reverses it")
local last_read = OfflineLibrary.books(snapshot, { sort = "recently_read", readStatus = "reading", size = 10 })
assertEqual(ids(last_read.items), "2,5", "In progress is the reading books by last read")
local by_author = OfflineLibrary.books(snapshot, { sort = "author", size = 10, buckets = 1 })
assertEqual(ids(by_author.items), "4,3,1,2,5", "author sort puts books without an author first, then by author and title")
assertEqual(by_author.buckets[1].key, "#", "the author rail starts at the authorless books")

assertEqual(ids(OfflineLibrary.books(snapshot, { readStatus = "finished", size = 10 }).items), "1", "finished filters to read books")
assertEqual(ids(OfflineLibrary.books(snapshot, { readStatus = "unread", sort = "title", size = 10 }).items), "4,3", "unread is neither reading nor finished")
assertEqual(ids(OfflineLibrary.books(snapshot, { format = "PDF", size = 10 }).items), "3", "a format filter matches case-insensitively")
assertEqual(ids(OfflineLibrary.books(snapshot, { libraryId = 2, sort = "title", size = 10 }).items), "4,3", "a library filter uses the walked library")
assertEqual(ids(OfflineLibrary.books(snapshot, { ids = "5,1", sort = "title", size = 10 }).items), "5,1", "an ids filter takes a comma list")
assertEqual(ids(OfflineLibrary.books(snapshot, { ids = { 2, 3 }, sort = "title", size = 10 }).items), "2,3", "or a table of ids")
assertEqual(ids(OfflineLibrary.books(snapshot, { collectionId = 3, sort = "title", size = 10 }).items), "5,1", "a collection lists its saved members")
assertEqual(OfflineLibrary.books(snapshot, { collectionId = 4 }), nil, "a collection never walked cannot be answered")
assertEqual(OfflineLibrary.books(snapshot, { smartScopeId = 1 }), nil, "nor can a scope never walked")
local brown = OfflineLibrary.books(snapshot, { author = "ann brown", sort = "title", size = 10 })
assertEqual(ids(brown.items), "3,1", "an author filter matches any of a book's authors")
assertEqual(brown.authorSummary.name, "Ann Brown", "the author summary carries the name as written")
assertEqual(OfflineLibrary.books(snapshot, { author = "Nobody" }), nil, "an unknown author is unknown, not empty")
local safari = OfflineLibrary.books(snapshot, { seriesId = 9, sort = "series", size = 10 })
assertEqual(ids(safari.items), "3,1", "a series lists its books in series order")
assertEqual(safari.seriesSummary.total .. "/" .. safari.seriesSummary.finished, "2/1", "with how far it is read")
assertEqual(ids(OfflineLibrary.books(snapshot, { series = "safari", readStatus = "reading", size = 10 }).items), "", "a series by name honours the read filter")
assertEqual(OfflineLibrary.books(snapshot, { series = "safari", readStatus = "reading", size = 10 }).seriesSummary.total, 2, "while the summary counts the whole series")
assertEqual(ids(OfflineLibrary.books(snapshot, { q = "clark", sort = "title", size = 10 }).items), "2,5", "a search matches authors")
assertEqual(ids(OfflineLibrary.books(snapshot, { q = "SAFARI", sort = "title", size = 10 }).items), "3,1", "and series names, whatever the case")
local extra = { { id = 99, title = "Local only", authors = {}, formats = { "epub" } } }
assertEqual(ids(OfflineLibrary.books(snapshot, { ids = { 99, 2 }, sort = "title", size = 10 }, { extra = extra }).items), "2,99", "extra books join the answer")
assertEqual(ids(OfflineLibrary.books(snapshot, { sort = "title", size = 10 }, { exclude = function(b) return b.id ~= 4 end }).items), "4", "an exclude predicate drops books")
assertEqual(OfflineLibrary.find(snapshot, "5").title, "Banana", "find looks a book up by id")
assertEqual(OfflineLibrary.find(snapshot, 77), nil, "an unknown id is nil")

-- -------------------------------------------------------------- sections
local authors = OfflineLibrary.section(snapshot, "authors", { size = 60 })
assertEqual(titles(authors.items), "Ann Brown,Bob Clark,Cy Dole", "authors come from the books, by name")
assertEqual(authors.items[1].count, 2, "with how many books they wrote")
assertEqual(authors.items[1].finishedCount .. "/" .. authors.items[1].readingCount, "1/0", "and how many are finished or being read")
assertEqual(authors.items[1].letter, "A", "each carries its letter")
assertEqual(authors.items[1].id, "Ann Brown", "an author's id is its name, as the server's is")
assertEqual(#authors.items[2].previewBooks, 2, "with preview covers")
assertEqual(authors.items[2].previewBooks[1].id, 5, "the newest first")
assertEqual(authors.buckets[1].key .. authors.buckets[2].key .. authors.buckets[3].key, "ABC", "a name sort buckets by letter")
assertEqual(authors.total, 3, "the section counts its entries")
assertEqual(authors.section, "authors", "and names itself")
local by_books = OfflineLibrary.section(snapshot, "authors", { sort = "books", size = 60 })
assertEqual(titles(by_books.items), "Ann Brown,Bob Clark,Cy Dole", "most books first, names break ties")
assertEqual(by_books.buckets, nil, "the count sort has no letter rail")
assertEqual(titles(OfflineLibrary.section(snapshot, "authors", { sort = "name_desc", size = 60 }).items), "Cy Dole,Bob Clark,Ann Brown", "name_desc reverses the names")
assertEqual(titles(OfflineLibrary.section(snapshot, "authors", { filter = "reading", size = 60 }).items), "Bob Clark", "reading keeps authors with a book in progress")
assertEqual(titles(OfflineLibrary.section(snapshot, "authors", { filter = "finished", size = 60 }).items), "Ann Brown", "finished keeps authors with a finished book")
assertEqual(titles(OfflineLibrary.section(snapshot, "authors", { q = "do", size = 60 }).items), "Cy Dole", "a query filters by name")
local paged = OfflineLibrary.section(snapshot, "authors", { page = 2, size = 2 })
assertEqual(titles(paged.items), "Cy Dole", "sections page too")
assertEqual(paged.hasPrevious, true, "and know what came before")

local series = OfflineLibrary.section(snapshot, "series", { size = 60 })
assertEqual(#series.items, 1, "series come from the books' series names")
assertEqual(series.items[1].seriesId, 9, "with the series id")
assertEqual(series.items[1].count, 2, "and the member count")
assertEqual(table.concat(series.items[1].memberStates, ","), "unread,finished", "member states follow the series order")
assertEqual(series.items[1].authorNames[1], "Ann Brown", "and the authors are listed")

local libraries = OfflineLibrary.section(snapshot, "libraries")
assertEqual(titles(libraries.items), "Main,Kids", "shelf sections come back as saved")
assertEqual(OfflineLibrary.section(snapshot, "unknown"), nil, "an unknown section is nil")
assertEqual(OfflineLibrary.section({ books = {} }, "collections"), nil, "a snapshot without shelves has no shelf sections")

-- ----------------------------------------------------------------- search
local found = OfflineLibrary.search(snapshot, "br")
assertEqual(titles(found.authors), "Ann Brown", "search finds authors")
assertEqual(#found.series, 0, "and series")
assertEqual(ids(found.books), "3,1", "and books by their author")
assertEqual(found.books_total, 2, "with the book total")

-- ---------------------------------------------------------------- details
local detail = OfflineLibrary.detailFrom(OfflineLibrary.find(snapshot, 4))
assertEqual(#detail.files, 2, "a detail lists a file per format")
assertEqual(detail.files[1].format .. "/" .. detail.files[1].role, "epub/primary", "the first format is the primary file")
assertEqual(detail.files[1].id, nil, "an inferred file has no id to download by")
assertEqual(detail.offline_summary, true, "and the page knows it was built from a summary")
assertEqual(#detail.relatedSections, 0, "with nothing related to draw")
assertEqual(OfflineLibrary.detailFrom(nil), nil, "no summary, no detail")

os.remove, os.rename = real_remove, real_rename
print("bookorbit_offline_library_test.lua: ok")

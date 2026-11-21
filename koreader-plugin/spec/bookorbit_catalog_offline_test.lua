-- Proves the catalog's offline mixin: the library is saved behind a connected
-- Home in a bounded walk that stops at its limit and keeps every book on the
-- device, the lists, sections, shelves and search are served from it without
-- asking for a connection, a book opens from its saved summary, and books
-- chosen offline queue up for the next connected open.

local connected = true
local scheduled = {}
local toasts = {}
local confirms = {}

package.loaded["gettext"] = setmetatable({
    ngettext = function(one, many, count) return count == 1 and one or many end,
}, { __call = function(_, text) return text end })
package.loaded["ffi/util"] = {
    template = function(text, ...)
        local values = { ... }
        return (text:gsub("%%(%d+)", function(index) return tostring(values[tonumber(index)]) end))
    end,
}
package.loaded["ui/network/manager"] = { isConnected = function() return connected end }
package.loaded["ui/uimanager"] = {
    scheduleIn = function(_, delay, callback) table.insert(scheduled, { delay = delay, callback = callback }) end,
    nextTick = function(_, callback) table.insert(scheduled, { delay = 0, callback = callback }) end,
}
package.loaded["logger"] = { dbg = function() end, info = function() end, warn = function() end }
package.loaded["document/documentregistry"] = { hasProvider = function() return true end }
package.loaded["datetime"] = {
    shortDayOfWeekToLongTranslation = {}, shortDayOfWeekTranslation = {}, longMonthTranslation = {}, shortMonthTranslation = {},
    secondsToHour = function() return "12:00" end,
    stringISO8601ToSeconds = function() return nil end,
}
package.loaded["device"] = { hasFrontlight = function() return false end }
package.loaded["bookorbit_stats_reader"] = {
    getDailySeconds = function() return {} end, getBookPace = function() return nil end,
    getHourMinutes = function() return nil end, getSessionRecords = function() return nil end,
}
package.loaded["lua-ljsqlite3/init"] = false
package.loaded["datastorage"] = { getSettingsDir = function() return "/nonexistent" end, getDataDir = function() return "/data" end }
package.loaded["ffi/sha2"] = { md5 = function(value) return (value:gsub("[^%w]", "_")) end }
local files = {}
package.loaded["libs/libkoreader-lfs"] = {
    attributes = function(path, what)
        if not files[path] then return nil end
        if what == "mode" then return "file" end
        return { mode = "file" }
    end,
}
package.loaded["util"] = {
    fixUtf8 = function(value) return value end,
    diskUsage = function() return { total = 1, available = 1 } end,
    makePath = function() return true end,
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
os.rename = function(from, to) files[to] = files[from]; files[from] = nil; return true end
package.loaded["bookorbit_toast"] = {
    show = function(text) table.insert(toasts, text) end,
    error = function(text) table.insert(toasts, text) end,
}
package.loaded["bookorbit_dialog_ui"] = {
    confirm = function(o) table.insert(confirms, o) end,
}
-- The sidecar KOReader keeps for a file on the device.
package.loaded["docsettings"] = {
    open = function(_, path)
        return { readSetting = function(_, key)
            if key == "doc_props" and path == "/books/local.epub" then return { title = "Local Legend", authors = "Lee Local\nMo Local" } end
            return nil
        end }
    end,
}
G_reader_settings = { isTrue = function() return false end }

package.path = "koreader-plugin/bookorbit.koplugin/?.lua;" .. package.path

local CatalogOffline = require("bookorbit_catalog_offline")
local OfflineLibrary = require("bookorbit_offline_library")
local Capabilities = require("bookorbit_capabilities")

local function assertEqual(actual, expected, label)
    if actual ~= expected then
        error(string.format("%s: expected %s, got %s", label, tostring(expected), tostring(actual)))
    end
end

local function runScheduled()
    local pending = scheduled
    scheduled = {}
    for _, entry in ipairs(pending) do entry.callback() end
end

-- A server of two libraries: 7 books in Main, 2 in Kids, one collection.
local LIBRARY_BOOKS = {
    [1] = {}, [2] = {},
}
for id = 1, 7 do
    table.insert(LIBRARY_BOOKS[1], { id = id, title = "Main " .. id, authors = { "Ann" }, formats = { "epub" }, hasCover = true,
        addedAt = string.format("2026-01-%02dT00:00:00Z", 20 - id), updatedAt = "2026-01-01T00:00:00Z", readStatus = id == 2 and "reading" or nil, progressPercentage = id == 2 and 30 or nil })
end
for id = 8, 9 do
    table.insert(LIBRARY_BOOKS[2], { id = id, title = "Kids " .. id, authors = { "Bo" }, formats = { "epub" }, hasCover = true,
        addedAt = string.format("2026-01-%02dT00:00:00Z", 20 - id), updatedAt = "2026-01-01T00:00:00Z" })
end
local ALL_BOOKS = {}
for _, list in pairs(LIBRARY_BOOKS) do for _, b in ipairs(list) do ALL_BOOKS[b.id] = b end end
ALL_BOOKS[50] = { id = 50, title = "On device only", authors = { "Dee" }, formats = { "epub" }, hasCover = true, addedAt = "2025-01-01T00:00:00Z", updatedAt = "2025-01-01T00:00:00Z" }

local requests = {}
local fail_after
local client = {
    server_url = "https://books.example/api/v1",
    username = "reader",
    catalogSection = function(_, section)
        table.insert(requests, "section:" .. section)
        if section == "libraries" then return { items = { { id = "1", title = "Main" }, { id = "2", title = "Kids" } } } end
        if section == "collections" then return { items = { { id = "3", title = "Favourites" } } } end
        return { items = {} }
    end,
    catalogBooks = function(_, params)
        local key = {}
        for k, v in pairs(params) do table.insert(key, k .. "=" .. tostring(v)) end
        table.sort(key)
        table.insert(requests, "books:" .. table.concat(key, "&"))
        if fail_after and #requests > fail_after then return nil, "connection refused" end
        if params.ids then
            local items = {}
            for id in params.ids:gmatch("%d+") do if ALL_BOOKS[tonumber(id)] then table.insert(items, ALL_BOOKS[tonumber(id)]) end end
            return { items = items, total = #items, page = 1, size = #items, hasNext = false }
        end
        if params.collectionId then
            return { items = { ALL_BOOKS[1], ALL_BOOKS[9] }, total = 2, page = 1, size = 100, hasNext = false }
        end
        if params.readStatus == "reading" then
            return { items = { ALL_BOOKS[2] }, total = 1, page = 1, size = 100, hasNext = false }
        end
        local list = LIBRARY_BOOKS[params.libraryId] or {}
        local size = params.size
        local first = (params.page - 1) * size + 1
        local items = {}
        for i = first, math.min(#list, first + size - 1) do table.insert(items, list[i]) end
        return { items = items, total = #list, page = params.page, size = size, hasNext = first + size - 1 < #list }
    end,
}

local shown = {}
local function newCatalog(opts)
    opts = opts or {}
    local catalog = {
        settings = opts.settings or {},
        client = client,
        default_sort = "recently_added",
        catalog_closed = false,
        on_device = opts.on_device or {},
        current_context = { kind = "dashboard" },
    }
    CatalogOffline.install(catalog)
    -- The sizes offered are hundreds of books; the walk is proven with five.
    function catalog:offlineLimit() return 5 end
    function catalog:persistSetting(key, value) self.settings[key] = value end
    function catalog:fetch(_label, fn) return fn() end
    function catalog:runOffThread(fn) fn() end
    function catalog:refreshOnDevice() return true end
    function catalog:onDeviceBookPath(book) return book and self.on_device[book.id] or nil end
    function catalog:isOnDevice(book) return self:onDeviceBookPath(book) ~= nil end
    function catalog:effectiveOrder(query) return query.order or (query.sort == "recently_added" and "desc" or "asc") end
    function catalog:listBookPageSize() return 4 end
    function catalog:listDecorateBookQuery(query) query.buckets = 1; return query end
    function catalog:listSectionParams(_section, section_opts) return { page = section_opts.page, size = 3, sort = section_opts.sort, q = section_opts.q } end
    function catalog:listSavedPage() return nil end
    function catalog:errorText(err) return tostring(err) end
    function catalog:showBookPage(body, query, title, push, page_opts) shown = { kind = "books", body = body, query = query, title = title, push = push, opts = page_opts } end
    function catalog:showSectionPage(section, body, params, section_opts, extra) shown = { kind = "section", section = section, body = body, params = params, opts = section_opts, extra = extra } end
    function catalog:showShelvesPage(bodies, shelves_opts, extra) shown = { kind = "shelves", bodies = bodies, opts = shelves_opts, extra = extra } end
    function catalog:showSearchPage(q, results, search_opts, extra) shown = { kind = "search", q = q, results = results, opts = search_opts, extra = extra } end
    function catalog:confirmBulkBooks(books, label) shown = { kind = "bulk", books = books, label = label } end
    return catalog
end

-- ------------------------------------------------------------ the save
Capabilities.remember(client, { capabilities = { "catalogListsV2" } })
local catalog = newCatalog({ settings = {}, on_device = { [50] = "/books/fifty.epub", [3] = "/books/three.epub" } })
assertEqual(catalog:offlineSnapshotDue(os.time()), true, "a library never saved is due")
assertEqual(catalog:offlineSnapshotSchedule(1), true, "a connected catalog schedules the save")
assertEqual(catalog:offlineSnapshotSchedule(1), false, "only once")
assertEqual(#scheduled, 1, "behind the dashboard")
runScheduled()
assertEqual(catalog.offline_snapshot_running, false, "the save ran to its end")
local status = catalog.settings.offline_library_status
assertEqual(status and status.account, "https://books.example/api/v1|reader", "the status names the account")
assertEqual(status.count, 7, "five walked books plus the on-device one and the one in progress")
assertEqual(status.total, 9, "the total counts both libraries")
assertEqual(status.truncated, true, "and the walk knows it stopped short")
assertEqual(status.saved_to_disk, true, "the snapshot is on disk")
local walked = 0
for _, request in ipairs(requests) do
    if request:match("^books:libraryId=") then walked = walked + 1 end
end
assertEqual(walked, 2, "one page per library: the limit stopped Main, and Kids was asked for its total")
assertEqual(requests[1] .. "|" .. requests[2] .. "|" .. requests[3], "section:libraries|section:collections|section:smart-scopes", "the shelves come first")
local saw_ids, saw_reading, saw_collection = false, false, false
for _, request in ipairs(requests) do
    if request:match("^books:ids=50") then saw_ids = true end
    if request:match("readStatus=reading") then saw_reading = true end
    if request:match("collectionId=3") then saw_collection = true end
end
assertEqual(saw_ids, true, "the on-device book the walk missed is looked up by id")
assertEqual(saw_reading, true, "the books in progress are fetched")
assertEqual(saw_collection, true, "and the collection's members")
local snapshot = catalog:offlineSnapshot()
assertEqual(OfflineLibrary.find(snapshot, 50).title, "On device only", "the on-device book is in the library")
assertEqual(OfflineLibrary.find(snapshot, 1).libraryId, 1, "walked books remember their library")
assertEqual(#snapshot.members["collection:3"], 2, "the collection's members are remembered")
assertEqual(snapshot.capabilities[1], "catalogListsV2", "the server's capabilities are saved with it")
assertEqual(catalog:offlineSnapshotDue(os.time()), false, "a fresh library is not due")
assertEqual(catalog:offlineSnapshotDue(os.time() + CatalogOffline.REFRESH_INTERVAL), true, "until the interval passes")

-- A failing walk keeps the old library.
requests = {}
fail_after = 4
local done_ok, done_err
catalog:offlineSnapshotStart({ on_done = function(ok, err) done_ok, done_err = ok, err end })
assertEqual(done_ok, false, "a refused page fails the save")
assertEqual(done_err, "connection refused", "with the reason")
assertEqual(catalog.settings.offline_library_status.count, 7, "the previous status stands")
assertEqual(#catalog:offlineSnapshot().books, 7, "as does the previous library")
fail_after = nil

-- A closed catalog cancels between requests, without saving.
requests = {}
local closing = newCatalog({ settings = {} })
closing.client = setmetatable({
    catalogBooks = function(self_, params)
        closing.catalog_closed = true
        return client.catalogBooks(self_, params)
    end,
}, { __index = client })
local closed_ok, closed_err
closing:offlineSnapshotStart({ on_done = function(ok, err) closed_ok, closed_err = ok, err end })
assertEqual(closed_ok, false, "a closed catalog does not finish the save")
assertEqual(closed_err, "cancelled", "it is cancelled")
assertEqual(closing.settings.offline_library_status, nil, "and nothing is recorded")

-- Offline, with the library off, nothing is served and nothing scheduled.
connected = false
local off = newCatalog({ settings = { offline_library = false } })
assertEqual(off:offlineServeBooks({ sort = "title" }, "All books", true), false, "the library off serves nothing")
assertEqual(off:offlineSnapshotSchedule(0), false, "and schedules nothing")

-- --------------------------------------------------------------- serving
connected = true
assertEqual(catalog:offlineServeBooks({ sort = "title" }, "All books", true), false, "connected, the server is asked")
connected = false
Capabilities.reset()
assertEqual(catalog:offlineServeBooks({ sort = "title" }, "All books", true), true, "offline, the library answers")
assertEqual(shown.kind, "books", "with a book page")
assertEqual(shown.title, "All books", "under the list's title")
assertEqual(#shown.body.items, 4, "a screen of books")
assertEqual(shown.body.items[1].title, "Kids 9", "sorted by title")
assertEqual(shown.body.total, 7, "of everything saved")
assertEqual(shown.query.size, 4, "the query carries the page size")
assertEqual(shown.query.buckets, 1, "and the newer server's extras")
assertEqual(shown.opts.offline_saved_at, snapshot.saved_at, "the page says when the library was saved")
assertEqual(shown.opts.offline_library.truncated, true, "and that it is the newest part of a larger library")
assertEqual(Capabilities.cached(client).catalogListsV2, true, "the saved capabilities stand in for the version request")

assertEqual(catalog:offlineServeBooks({ sort = "title", on_device_filter = true }, "On device", true), true, "On device is served offline")
assertEqual(#shown.body.items, 2, "from the on-device map")
assertEqual(shown.body.items[1].title .. "," .. shown.body.items[2].title, "Main 3,On device only", "with the saved summaries")
catalog.on_device[51] = "/books/local.epub"
catalog.on_device[52] = "/books/Unknown Book.pdf"
catalog:offlineServeBooks({ sort = "title", on_device_filter = true }, "On device", true)
assertEqual(#shown.body.items, 4, "books the library never saw are still listed")
assertEqual(shown.body.items[1].title, "Local Legend", "named from KOReader's sidecar when it has one")
assertEqual(shown.body.items[1].authors[1] .. "," .. shown.body.items[1].authors[2], "Lee Local,Mo Local", "with its authors")
assertEqual(shown.body.items[4].title, "Unknown Book", "else from the file name")
assertEqual(shown.body.items[4].formats[1], "pdf", "with the file's format")
assertEqual(shown.body.items[4].offline_stub, true, "marked as a stand-in")

assertEqual(catalog:offlineServeBooks({ sort = "recently_added", not_on_device = true }, "Not on device", true), true, "Not on device is served offline")
assertEqual(#shown.body.items, 4, "a screen of the books not here")
for _, item in ipairs(shown.body.items) do
    assertEqual(catalog.on_device[item.id], nil, "none of them is on the device")
end

assertEqual(catalog:offlineServeBooks({ collectionId = 3, sort = "title" }, "Favourites", true), true, "a saved collection is served offline")
assertEqual(#shown.body.items, 2, "with its members")
assertEqual(catalog:offlineServeBooks({ collectionId = 99, sort = "title" }, "Other", true), false, "an unsaved collection is not, so a connection is asked for")
catalog.listSavedPage = function() return { body = { items = { { id = 1 } }, total = 1 }, saved_at = 123 } end
assertEqual(catalog:offlineServeBooks({ collectionId = 99, sort = "title" }, "Other", true), true, "unless this device saved that very page")
assertEqual(shown.opts.offline_saved_at, 123, "which is shown as the saved page")
assertEqual(shown.opts.offline_library, nil, "not as the library")
catalog.listSavedPage = function() return nil end

assertEqual(catalog:offlineServeSection("authors", { page = 1 }), true, "authors are served offline")
assertEqual(shown.kind .. "/" .. shown.section, "section/authors", "as a section page")
assertEqual(shown.body.items[1].title, "Ann", "from the saved books")
assertEqual(shown.extra.offline_library.count, 7, "with the library's size")
assertEqual(catalog:offlineServeSection("series", { page = 1 }), true, "series too")
assertEqual(#shown.body.items, 0, "none of these books belong to one")

assertEqual(catalog:offlineServeShelves({}), true, "the shelves are served offline")
assertEqual(shown.kind, "shelves", "as the shelves page")
assertEqual(shown.bodies.libraries[2].title, "Kids", "with the saved libraries")
assertEqual(#shown.bodies["smart-scopes"], 0, "and an empty scopes list")

assertEqual(catalog:offlineServeSearch("bo", { scope = "all" }), true, "search is served offline")
assertEqual(shown.kind .. ":" .. shown.q, "search:bo", "as a search page")
assertEqual(#shown.results.books, 1, "with the books that match")
assertEqual(shown.results.authors[1].title, "Bo", "and their authors")

local detail = catalog:offlineDetail(9)
assertEqual(detail.title, "Kids 9", "a saved book opens from its summary")
assertEqual(detail.files[1].format, "epub", "with files inferred from its formats")
assertEqual(catalog:offlineDetail(123, { id = 123, title = "From the list", formats = {} }).title, "From the list", "a book the library does not hold opens from the entry it was tapped in")
assertEqual(catalog:offlineDetail(51).title, "Local Legend", "a book only on the device opens from its sidecar")
assertEqual(catalog:offlineDetail(777), nil, "a book nothing is known about does not")

-- ------------------------------------------------------------------ queue
assertEqual(catalog:offlineIsQueued(8), false, "nothing is queued at first")
assertEqual(catalog:offlineToggleQueued({ id = 8, title = "Kids 8", authors = { "Bo" }, formats = { "epub" } }), true, "a tap queues a book")
assertEqual(catalog:offlineIsQueued(8), true, "and it is queued")
assertEqual(catalog:offlineToggleQueued({ id = 9, title = "Kids 9" }), true, "another joins it")
assertEqual(catalog.settings.offline_download_queue["https://books.example/api/v1|reader"][2].title, "Kids 9", "the queue is kept per account")
assertEqual(catalog:offlineToggleQueued({ id = 8 }), false, "a second tap takes it out")
assertEqual(catalog:offlineIsQueued(8), false, "so it is no longer queued")
assertEqual(catalog:offlineOfferQueuedDownloads(), false, "offline nothing is offered")
connected = true
assertEqual(catalog:offlineOfferQueuedDownloads(), true, "connected, the queue is offered")
assertEqual(#confirms, 1, "in a dialog")
assertEqual(confirms[1].title, "Download 1 book chosen offline?", "that counts the books")
assertEqual(catalog:offlineOfferQueuedDownloads(), false, "once per session")
confirms[1].on_ok()
assertEqual(shown.kind, "bulk", "accepting starts the bulk download")
assertEqual(shown.books[1].id, 9, "of the queued books")
assertEqual(catalog.settings.offline_download_queue, nil, "and the queue is emptied")
for id = 1, CatalogOffline.QUEUE_LIMIT do catalog:offlineToggleQueued({ id = 1000 + id, title = "Q" }) end
assertEqual(catalog:offlineToggleQueued({ id = 5000, title = "One too many" }), nil, "the queue has a limit")

-- ----------------------------------------------------------------- clear
catalog:offlineClear()
assertEqual(catalog:offlineSnapshot(), nil, "clear forgets the library")
assertEqual(catalog.settings.offline_library_status, nil, "and its status")
assertEqual(OfflineLibrary.load("https://books.example/api/v1|reader"), nil, "and removes the file")

os.remove, os.rename = real_remove, real_rename
print("bookorbit_catalog_offline_test.lua: ok")

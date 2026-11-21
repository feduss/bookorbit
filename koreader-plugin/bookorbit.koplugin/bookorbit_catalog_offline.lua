--[[--
Offline browsing for the BookOrbit catalog browser.

Without a connection the catalog answers from what this device saved rather
than asking for Wi-Fi: On device and In progress from the on-device map and
the offline library, every book list, the authors, series and shelves pages
and search from the offline library (bookorbit_offline_library), and book
details from the detail cache or the book's saved summary. A list served this
way wears the offline band, which reconnects on a tap.

The offline library is saved in the background after Home refreshes while
connected, at most every few hours, and from Settings > Offline on demand.
Books chosen while offline wait in a queue that is offered for download the
next time the catalog is online.

Installed onto the catalog controller as regular methods.
]]

local NetworkMgr = require("ui/network/manager")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local T = require("ffi/util").template
local _ = require("gettext")

local Capabilities = require("bookorbit_capabilities")
local CatalogUtil = require("bookorbit_catalog_util")
local OfflineLibrary = require("bookorbit_offline_library")

local CatalogOffline = {}

-- A saved library is refreshed behind Home this often, while connected.
CatalogOffline.REFRESH_INTERVAL = 6 * 3600
-- The server page size for the library walk; the server caps it at 100.
CatalogOffline.PAGE_SIZE = 100
-- How many collections and how many scopes have their books remembered, and
-- how many books each: enough for a reader's shelves, bounded for a server
-- with hundreds of them.
CatalogOffline.SHELF_LIMIT = 12
CatalogOffline.SHELF_PAGE = 100
-- The server's ids filter caps at 200, so on-device books are looked up in
-- chunks of that.
CatalogOffline.IDS_CHUNK = CatalogUtil.ON_DEVICE_MAX_IDS
-- The queue of books chosen while offline is capped so a tap-happy session
-- cannot queue a whole library.
CatalogOffline.QUEUE_LIMIT = 100

-- ----------------------------------------------------------------- state
function CatalogOffline:offlineAccount()
    return OfflineLibrary.accountKey(self.client)
end

function CatalogOffline:offlineEnabled()
    return self.settings.offline_library ~= false
end

function CatalogOffline:offlineLimit()
    return OfflineLibrary.normalizeSize(self.settings.offline_library_size)
end

function CatalogOffline:offlineMode()
    return not NetworkMgr:isConnected()
end

-- The saved library, loaded once per account for the catalog's lifetime.
function CatalogOffline:offlineSnapshot()
    local account = self:offlineAccount()
    if self.offline_snapshot_loaded and self.offline_snapshot_account == account then
        return self.offline_snapshot or nil
    end
    local snapshot = nil
    if self:offlineEnabled() then
        local ok, loaded = pcall(OfflineLibrary.load, account)
        if ok then snapshot = loaded else logger.warn("BookOrbit: loading the offline library failed", loaded) end
    end
    self.offline_snapshot = snapshot or false
    self.offline_snapshot_account = account
    self.offline_snapshot_loaded = true
    return snapshot
end

function CatalogOffline:offlineForget()
    self.offline_snapshot = nil
    self.offline_snapshot_account = nil
    self.offline_snapshot_loaded = false
    self.offline_queue_offered = nil
    self.offline_snapshot_generation = (self.offline_snapshot_generation or 0) + 1
    self.offline_snapshot_running = false
    self.offline_progress = nil
end

-- What Settings shows: { saved_at, count, total, truncated } for this
-- account, or nil before the first save.
function CatalogOffline:offlineStatus()
    local status = self.settings.offline_library_status
    if type(status) ~= "table" or status.account ~= self:offlineAccount() then return nil end
    return status
end

-- Removes the saved library and the queue for this account.
function CatalogOffline:offlineClear()
    local account = self:offlineAccount()
    pcall(OfflineLibrary.clear, account)
    self.offline_snapshot_generation = (self.offline_snapshot_generation or 0) + 1
    self.offline_snapshot_running = false
    self.offline_progress = nil
    self.offline_snapshot = false
    self.offline_snapshot_account = account
    self.offline_snapshot_loaded = true
    if type(self.settings.offline_library_status) == "table" and self.settings.offline_library_status.account == account then
        self:persistSetting("offline_library_status", nil)
    end
    self:offlineNotify()
end

-- Offline the server's capabilities are unknown for the session; the ones
-- the library was saved against keep the lists laid out the same way.
function CatalogOffline:offlineAdoptCapabilities()
    if Capabilities.cached(self.client) then return end
    local snapshot = self:offlineSnapshot()
    if snapshot and type(snapshot.capabilities) == "table" then
        Capabilities.remember(self.client, { capabilities = snapshot.capabilities })
    end
end

-- ------------------------------------------------------------- on device
local function titleFromPath(path)
    local name = tostring(path or ""):match("([^/]+)$") or ""
    name = name:gsub("%.[^%.]+$", "")
    return name ~= "" and name or _("Untitled")
end

local function formatFromPath(path)
    local ext = tostring(path or ""):match("%.([^%./]+)$")
    return ext and string.lower(ext) or nil
end

-- A list entry for a downloaded book the library never saw, from the
-- sidecar KOReader keeps for it, else its file name.
function CatalogOffline:offlineStubBook(book_id, path)
    local stub = { id = book_id, title = titleFromPath(path), authors = {}, hasCover = false, formats = {}, offline_stub = true }
    local format = formatFromPath(path)
    if format then stub.formats[1] = format end
    local ok, DocSettings = pcall(require, "docsettings")
    if ok and DocSettings and DocSettings.open then
        local loaded, doc_settings = pcall(DocSettings.open, DocSettings, path)
        local props = loaded and doc_settings and doc_settings.readSetting and doc_settings:readSetting("doc_props") or nil
        if type(props) == "table" then
            if type(props.title) == "string" and props.title ~= "" then stub.title = props.title end
            if type(props.authors) == "string" and props.authors ~= "" then
                for author in props.authors:gmatch("[^\n]+") do table.insert(stub.authors, author) end
            end
        end
    end
    return stub
end

-- Every book on this device: its ids, and a stub for each one the offline
-- library does not hold.
function CatalogOffline:offlineOnDeviceBooks(snapshot)
    self:refreshOnDevice()
    local ids, extra = {}, {}
    for book_id, path in pairs(self.on_device or {}) do
        if self:isOnDevice({ id = book_id }) then
            table.insert(ids, book_id)
            if not OfflineLibrary.find(snapshot, book_id) then
                table.insert(extra, self:offlineStubBook(book_id, path))
            end
        end
    end
    table.sort(ids, function(a, b) return tostring(a) < tostring(b) end)
    return ids, extra
end

-- ---------------------------------------------------------------- serving
local function libraryNote(snapshot)
    local status = OfflineLibrary.describe(snapshot)
    return status and { count = status.count, total = status.total, truncated = status.truncated } or nil
end

-- The query a book list would send, built as fetchBookPage builds it.
function CatalogOffline:offlineBookQuery(params)
    local query = CatalogUtil.cloneParams(params)
    query.page = query.page or 1
    query.sort = query.sort or self.default_sort or "recently_added"
    query.order = self:effectiveOrder(query)
    query.size = query.size or self:listBookPageSize(query, { offline = true })
    self:listDecorateBookQuery(query)
    return query
end

-- A page of books for the query from the offline library, with the snapshot
-- it came from, or nil.
function CatalogOffline:offlineBookBody(query, opts)
    local snapshot = self:offlineSnapshot()
    if not snapshot then return nil end
    local ok, body = pcall(OfflineLibrary.books, snapshot, query, opts)
    if not ok then
        logger.warn("BookOrbit: the offline library could not answer", body)
        return nil
    end
    if not body then return nil end
    return body, snapshot, libraryNote(snapshot)
end

-- Shows a book list without the network: from the offline library, else
-- from the page this device saved for the same request. Returns true when
-- it showed one; false leaves the caller to ask for a connection.
function CatalogOffline:offlineServeBooks(params, title, push)
    if not self:offlineMode() then return false end
    self:offlineAdoptCapabilities()
    local snapshot = self:offlineSnapshot()
    local query = self:offlineBookQuery(params)
    local opts = {}
    if query.on_device_filter then
        local ids, extra = self:offlineOnDeviceBooks(snapshot)
        if #ids == 0 then
            require("bookorbit_toast").show(_("No downloaded books are linked on this device yet"), { icon = "info", timeout = 3 })
            return true
        end
        -- A comma list like the server's, so the context can go online as is.
        query.ids = table.concat(ids, ",")
        opts.extra = extra
        if not snapshot then snapshot = { books = {}, saved_at = 0 } end
    elseif query.not_on_device then
        opts.exclude = function(book) return self:isOnDevice(book) end
    end
    local body, from
    if snapshot then
        local ok, answer = pcall(OfflineLibrary.books, snapshot, query, opts)
        if ok then body = answer else logger.warn("BookOrbit: the offline library could not answer", answer) end
        if body then from = snapshot end
    end
    local saved_at, library
    if body then
        saved_at = from.saved_at or 0
        library = libraryNote(from) or { count = #(from.books or {}), total = #(from.books or {}) }
    else
        local saved = self:listSavedPage(query, nil)
        if not saved then return false end
        body = saved.body
        saved_at = saved.saved_at or 0
    end
    self:showBookPage(body, query, title or _("Books"), push ~= false, { offline_saved_at = saved_at, offline_library = library })
    return true
end

-- Authors or series without the network. Returns true when shown.
function CatalogOffline:offlineServeSection(section, opts)
    if not self:offlineMode() then return false end
    local snapshot = self:offlineSnapshot()
    if not snapshot then return false end
    self:offlineAdoptCapabilities()
    local params = self:listSectionParams(section, opts, { offline = true })
    local ok, body = pcall(OfflineLibrary.section, snapshot, section, params)
    if not ok or not body then
        if not ok then logger.warn("BookOrbit: the offline library could not answer", body) end
        return false
    end
    self:showSectionPage(section, body, params, opts, { offline_saved_at = snapshot.saved_at or 0, offline_library = libraryNote(snapshot) })
    return true
end

-- The Shelves page without the network. Returns true when shown.
function CatalogOffline:offlineServeShelves(opts)
    if not self:offlineMode() then return false end
    local snapshot = self:offlineSnapshot()
    if not snapshot or type(snapshot.shelves) ~= "table" then return false end
    local bodies = {}
    for _i, section in ipairs({ "libraries", "collections", "smart-scopes" }) do
        bodies[section] = snapshot.shelves[section] or {}
    end
    self:showShelvesPage(bodies, opts, { offline_saved_at = snapshot.saved_at or 0, offline_library = libraryNote(snapshot) })
    return true
end

-- Search without the network. Returns true when shown.
function CatalogOffline:offlineServeSearch(q, opts)
    if not self:offlineMode() then return false end
    local snapshot = self:offlineSnapshot()
    if not snapshot then return false end
    local ok, results = pcall(OfflineLibrary.search, snapshot, q)
    if not ok or not results then
        if not ok then logger.warn("BookOrbit: the offline library could not answer", results) end
        return false
    end
    self:showSearchPage(q, results, opts, { offline_saved_at = snapshot.saved_at or 0, offline_library = libraryNote(snapshot) })
    return true
end

-- A detail page for a book whose details were never fetched: its saved
-- summary, the entry it was tapped in, or the file on this device. Nil when
-- nothing is known about it.
function CatalogOffline:offlineDetail(book_id, book)
    local snapshot = self:offlineSnapshot()
    local summary = snapshot and OfflineLibrary.find(snapshot, book_id) or nil
    if not summary and type(book) == "table" and book.id ~= nil then summary = book end
    if not summary then
        local path = self:onDeviceBookPath({ id = book_id })
        if path then summary = self:offlineStubBook(book_id, path) end
    end
    if not summary then return nil end
    return OfflineLibrary.detailFrom(summary)
end

-- ------------------------------------------------------------------ queue
-- Books chosen while offline, for this account.
function CatalogOffline:offlineQueue()
    local all = self.settings.offline_download_queue
    if type(all) ~= "table" then all = {} end
    local list = all[self:offlineAccount()]
    if type(list) ~= "table" then list = {} end
    return list, all
end

function CatalogOffline:offlineIsQueued(book_id)
    if book_id == nil then return false end
    for _, entry in ipairs(self:offlineQueue()) do
        if tostring(entry.id) == tostring(book_id) then return true end
    end
    return false
end

-- Adds the book to the queue, or takes it out again. Returns whether it is
-- queued afterwards, or nil when the queue is full.
function CatalogOffline:offlineToggleQueued(book)
    if type(book) ~= "table" or book.id == nil then return false end
    local list, all = self:offlineQueue()
    local kept = {}
    local was_queued = false
    for _, entry in ipairs(list) do
        if tostring(entry.id) == tostring(book.id) then was_queued = true else table.insert(kept, entry) end
    end
    if not was_queued then
        if #kept >= CatalogOffline.QUEUE_LIMIT then return nil end
        table.insert(kept, OfflineLibrary.summarize(book, { queued_at = os.time() }))
    end
    all[self:offlineAccount()] = #kept > 0 and kept or nil
    self:persistSetting("offline_download_queue", next(all) and all or nil)
    return not was_queued
end

function CatalogOffline:offlineClearQueue()
    local _list, all = self:offlineQueue()
    all[self:offlineAccount()] = nil
    self:persistSetting("offline_download_queue", next(all) and all or nil)
end

-- Once per catalog session while connected: offers to download the books
-- queued offline, through the ordinary bulk download.
function CatalogOffline:offlineOfferQueuedDownloads()
    if self.offline_queue_offered or not NetworkMgr:isConnected() then return false end
    local list = self:offlineQueue()
    if #list == 0 then return false end
    self.offline_queue_offered = true
    local books = {}
    for i, entry in ipairs(list) do books[i] = entry end
    local names = {}
    for i = 1, math.min(3, #books) do table.insert(names, books[i].title or _("Untitled")) end
    if #books > 3 then table.insert(names, T(_("and %1 more"), #books - 3)) end
    require("bookorbit_dialog_ui").confirm{
        title = T(_.ngettext("Download %1 book chosen offline?", "Download %1 books chosen offline?", #books), #books),
        text = table.concat(names, ", "),
        ok_label = _("Download"),
        ok_icon = "download",
        cancel_label = _("Keep waiting"),
        on_ok = function()
            self:offlineClearQueue()
            self:confirmBulkBooks(books, _("Chosen offline"))
        end,
    }
    return true
end

-- -------------------------------------------------------------- snapshot
function CatalogOffline:offlineNotify()
    local listener = self.offline_progress_listener
    if type(listener) == "function" then pcall(listener) end
end

-- Whether the saved library is old enough for a refresh.
function CatalogOffline:offlineSnapshotDue(now)
    if not self:offlineEnabled() then return false end
    local status = self:offlineStatus()
    if not status then return true end
    return (now or os.time()) - (tonumber(status.saved_at) or 0) >= CatalogOffline.REFRESH_INTERVAL
end

-- Queues a refresh behind a connected Home refresh, so the dashboard and
-- its covers come first. delay: seconds.
function CatalogOffline:offlineSnapshotSchedule(delay)
    if self.offline_snapshot_scheduled or self.offline_snapshot_running then return false end
    if not NetworkMgr:isConnected() or not self:offlineSnapshotDue(os.time()) then return false end
    self.offline_snapshot_scheduled = true
    UIManager:scheduleIn(delay or 3, function()
        self.offline_snapshot_scheduled = false
        if self.catalog_closed then return end
        self:offlineSnapshotStart()
    end)
    return true
end

-- Saves the library now. opts.on_done(ok, err) hears how it went; a manual
-- save also says so in a pill. Returns false when one is already running.
function CatalogOffline:offlineSnapshotStart(opts)
    opts = opts or {}
    if self.offline_snapshot_running then return false end
    self.offline_snapshot_running = true
    self.offline_snapshot_generation = (self.offline_snapshot_generation or 0) + 1
    local generation = self.offline_snapshot_generation
    self.offline_progress = { count = 0 }
    self:offlineNotify()
    self:runOffThread(function()
        local ok, snapshot, err = pcall(self.offlineSnapshotBuild, self, generation)
        if not ok then
            err = snapshot
            snapshot = nil
        end
        if generation ~= self.offline_snapshot_generation then return end
        self.offline_snapshot_running = false
        self.offline_progress = nil
        if snapshot then
            self:offlineSnapshotAdopt(snapshot)
            logger.info("BookOrbit: offline library saved", #snapshot.books, "books")
            if opts.manual then
                require("bookorbit_toast").show(T(_("Library saved for offline use: %1 books"), CatalogUtil.formatCount(#snapshot.books) or #snapshot.books))
            end
        elseif err ~= "cancelled" then
            logger.warn("BookOrbit: saving the offline library failed", err)
            if opts.manual then
                require("bookorbit_toast").error(T(_("Could not save the library: %1"), self:errorText(err)))
            end
        end
        self:offlineNotify()
        if opts.on_done then opts.on_done(snapshot ~= nil, err) end
    end)
    return true
end

function CatalogOffline:offlineSnapshotAdopt(snapshot)
    local account = self:offlineAccount()
    local saved = false
    local ok, result = pcall(OfflineLibrary.save, account, snapshot)
    if ok then saved = result == true else logger.warn("BookOrbit: writing the offline library failed", result) end
    self.offline_snapshot = snapshot
    self.offline_snapshot_account = account
    self.offline_snapshot_loaded = true
    local status = OfflineLibrary.describe(snapshot)
    status.account = account
    status.saved_to_disk = saved
    self:persistSetting("offline_library_status", status)
    return saved
end

-- The walk itself, inside a Trapper coroutine: shelves, the newest books of
-- each library up to the limit, every book on this device and in progress,
-- then the books of each collection and scope. Returns the snapshot, or nil
-- and why. A closed catalog or a newer save cancels it between requests.
function CatalogOffline:offlineSnapshotBuild(generation)
    local client = self.client
    local function current()
        return not self.catalog_closed and generation == self.offline_snapshot_generation
    end
    local function get(fn)
        if not current() then return nil, "cancelled" end
        local body, err = self:fetch(nil, fn, { invisible = true })
        if not current() then return nil, "cancelled" end
        if not body then return nil, err or "invalid response" end
        if type(body) ~= "table" then return nil, "invalid response" end
        return body
    end
    local progress = self.offline_progress or {}
    local function note(builder)
        progress.count = #builder.books
        self.offline_progress = progress
        self:offlineNotify()
    end

    local builder = OfflineLibrary.newBuilder(self:offlineLimit())
    for _i, section in ipairs({ "libraries", "collections", "smart-scopes" }) do
        local body, err = get(function() return client:catalogSection(section) end)
        if not body then return nil, err end
        builder:setShelf(section, body.items or {})
    end

    local scopes = {}
    for _i, library in ipairs(builder.shelves.libraries or {}) do
        if tonumber(library.id) then table.insert(scopes, { libraryId = tonumber(library.id) }) end
    end
    if #scopes == 0 then scopes = { {} } end
    -- The first page of every library is fetched even once the limit is
    -- reached, so the total counts the whole library.
    for _i, scope in ipairs(scopes) do
        local page = 1
        while true do
            local params = { sort = "recently_added", order = "desc", page = page, size = CatalogOffline.PAGE_SIZE, libraryId = scope.libraryId }
            local body, err = get(function() return client:catalogBooks(params) end)
            if not body then return nil, err end
            if page == 1 then builder:addTotal(body.total) end
            local items = body.items or {}
            local added = 0
            for _j, book in ipairs(items) do
                if builder:add(book, { libraryId = scope.libraryId }) then added = added + 1 end
            end
            note(builder)
            if builder:remaining() == 0 then
                if body.hasNext == true or added < #items then builder.truncated = true end
                break
            end
            if body.hasNext ~= true or #items == 0 then break end
            page = page + 1
        end
    end

    self:refreshOnDevice()
    local missing = {}
    for book_id in pairs(self.on_device or {}) do
        if not builder:has(book_id) then table.insert(missing, book_id) end
    end
    table.sort(missing, function(a, b) return tostring(a) < tostring(b) end)
    for start = 1, #missing, CatalogOffline.IDS_CHUNK do
        local chunk = {}
        for i = start, math.min(#missing, start + CatalogOffline.IDS_CHUNK - 1) do table.insert(chunk, missing[i]) end
        local body, err = get(function()
            return client:catalogBooks({ ids = table.concat(chunk, ","), sort = "title", page = 1, size = #chunk })
        end)
        if not body then return nil, err end
        for _j, book in ipairs(body.items or {}) do builder:add(book, nil, true) end
        note(builder)
    end

    local reading, reading_err = get(function()
        return client:catalogBooks({ readStatus = "reading", sort = "recently_read", page = 1, size = CatalogOffline.PAGE_SIZE })
    end)
    if not reading then return nil, reading_err end
    for _j, book in ipairs(reading.items or {}) do builder:add(book, nil, true) end
    note(builder)

    local SHELF_KEYS = { collections = { param = "collectionId", key = "collection:" }, ["smart-scopes"] = { param = "smartScopeId", key = "scope:" } }
    for section, spec in pairs(SHELF_KEYS) do
        local shelves = builder.shelves[section] or {}
        for index = 1, math.min(#shelves, CatalogOffline.SHELF_LIMIT) do
            local shelf = shelves[index]
            local id = tonumber(shelf.id)
            if id then
                local params = { sort = "title", page = 1, size = CatalogOffline.SHELF_PAGE }
                params[spec.param] = id
                local body, err = get(function() return client:catalogBooks(params) end)
                if err == "cancelled" then return nil, err end
                if body then
                    local ids = {}
                    for _j, book in ipairs(body.items or {}) do
                        table.insert(ids, book.id)
                        builder:add(book, nil, true)
                    end
                    builder:setMembers(spec.key .. tostring(id), ids)
                    note(builder)
                end
            end
        end
    end

    local known = Capabilities.cached(client)
    if known then
        local names = {}
        for name, supported in pairs(known) do
            if supported == true then table.insert(names, name) end
        end
        table.sort(names)
        builder:setCapabilities(names)
    end
    if not current() then return nil, "cancelled" end
    return builder:finish(os.time())
end

function CatalogOffline.install(Catalog)
    for name, fn in pairs(CatalogOffline) do
        if name ~= "install" and type(fn) == "function" then Catalog[name] = fn end
    end
end

return CatalogOffline

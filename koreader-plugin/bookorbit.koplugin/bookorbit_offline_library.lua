--[[--
The library this device keeps for when BookOrbit cannot be reached: a bounded
snapshot of the account's books, shelves and who is on them, saved under the
BookOrbit cache and answered the way the server answers.

bookorbit_catalog_offline builds the snapshot while the catalog is open and
connected, and serves the catalog's lists, sections, search and details from
it when there is no connection. This module holds no widgets and makes no
requests: it stores, loads and queries.

A snapshot is keyed by the account (server and user), so a sign-in elsewhere
never shows another account's library, and it is cleared on sign-out.
]]

local DataStorage = require("datastorage")
local LuaSettings = require("luasettings")
local lfs = require("libs/libkoreader-lfs")
local md5 = require("ffi/sha2").md5
local util = require("util")

local ListData = require("bookorbit_list_data")

local OfflineLibrary = {}

-- How many books a snapshot keeps: the newest of each library, plus every
-- book on this device and every book in progress, which are kept whatever
-- the limit. A library larger than the limit is marked truncated so the
-- lists can say so.
OfflineLibrary.SIZES = { 500, 2000, 5000 }
OfflineLibrary.DEFAULT_SIZE = 2000
-- The fields a list entry needs, so a snapshot stays small whatever the
-- server adds to a book.
local SUMMARY_FIELDS = {
    "id", "title", "authors", "seriesId", "seriesName", "seriesIndex", "progressPercentage",
    "lastReadAt", "readStatus", "formats", "hasCover", "updatedAt", "addedAt", "libraryId",
}
local PREVIEW_LIMIT = 4
local DEFAULT_PAGE_SIZE = 20
local MAX_PAGE_SIZE = 500

-- ---------------------------------------------------------------- storage
local function dir()
    return DataStorage:getDataDir() .. "/cache/bookorbit/offline"
end

function OfflineLibrary.accountKey(client)
    return tostring(client and client.server_url) .. "|" .. tostring(client and client.username)
end

function OfflineLibrary.normalizeSize(value)
    value = tonumber(value)
    for _, size in ipairs(OfflineLibrary.SIZES) do
        if value == size then return size end
    end
    return OfflineLibrary.DEFAULT_SIZE
end

local function pathOf(account)
    return dir() .. "/" .. md5(account) .. ".lua"
end

-- Writes the snapshot beside the old one and renames it into place, so an
-- interrupted save leaves the previous library readable.
function OfflineLibrary.save(account, snapshot)
    if type(snapshot) ~= "table" then return false end
    if not util.makePath(dir()) then return false end
    local path = pathOf(account)
    local temp = path .. ".tmp"
    os.remove(temp)
    local store = LuaSettings:open(temp)
    store:saveSetting("account", account)
    store:saveSetting("saved_at", snapshot.saved_at)
    store:saveSetting("snapshot", snapshot)
    store:flush()
    if not lfs.attributes(temp, "mode") then return false end
    local ok = os.rename(temp, path)
    if not ok then
        os.remove(temp)
        return false
    end
    return true
end

-- The saved snapshot for the account, or nil.
function OfflineLibrary.load(account)
    local path = pathOf(account)
    if not lfs.attributes(path, "mode") then return nil end
    local store = LuaSettings:open(path)
    if store:readSetting("account") ~= account then return nil end
    local snapshot = store:readSetting("snapshot")
    if type(snapshot) ~= "table" or type(snapshot.books) ~= "table" then return nil end
    snapshot.saved_at = tonumber(snapshot.saved_at) or tonumber(store:readSetting("saved_at")) or 0
    return snapshot
end

function OfflineLibrary.clear(account)
    local path = pathOf(account)
    os.remove(path .. ".tmp")
    os.remove(path)
end

-- { saved_at, count, total, truncated } for a status line.
function OfflineLibrary.describe(snapshot)
    if type(snapshot) ~= "table" then return nil end
    return {
        saved_at = tonumber(snapshot.saved_at) or 0,
        count = #(snapshot.books or {}),
        total = tonumber(snapshot.total) or #(snapshot.books or {}),
        truncated = snapshot.truncated == true,
    }
end

-- ---------------------------------------------------------------- summaries
local function copyList(list)
    if type(list) ~= "table" then return nil end
    local out = {}
    for i, value in ipairs(list) do out[i] = value end
    return out
end

-- The part of a book a list draws. extra: fields the server page did not
-- carry (libraryId).
function OfflineLibrary.summarize(book, extra)
    if type(book) ~= "table" or book.id == nil then return nil end
    local summary = {}
    for _, field in ipairs(SUMMARY_FIELDS) do
        local value = book[field]
        if type(value) == "table" then value = copyList(value) end
        summary[field] = value
    end
    for key, value in pairs(extra or {}) do summary[key] = value end
    return summary
end

local function previewOf(book)
    return {
        id = book.id,
        title = book.title,
        hasCover = book.hasCover,
        seriesIndex = book.seriesIndex,
        progressPercentage = book.progressPercentage,
        readStatus = book.readStatus,
        lastReadAt = book.lastReadAt,
        addedAt = book.addedAt,
        updatedAt = book.updatedAt,
    }
end

-- A detail page's worth of a summary, for a book whose details were never
-- fetched: the files are inferred from its formats, so Read works for a book
-- on this device and the page says what could be downloaded.
function OfflineLibrary.detailFrom(summary)
    if type(summary) ~= "table" or summary.id == nil then return nil end
    local detail = {}
    for key, value in pairs(summary) do
        detail[key] = type(value) == "table" and copyList(value) or value
    end
    detail.files = {}
    for index, format in ipairs(summary.formats or {}) do
        table.insert(detail.files, {
            format = format,
            role = index == 1 and "primary" or "secondary",
            downloadVariant = "original",
        })
    end
    detail.relatedSections = {}
    detail.collections = {}
    detail.genres = detail.genres or {}
    detail.tags = detail.tags or {}
    detail.offline_summary = true
    return detail
end

-- ------------------------------------------------------------------ builder
local Builder = {}
Builder.__index = Builder

-- limit: how many books the snapshot keeps from the library walk; books
-- added with force (on device, in progress, on a shelf) do not count.
function OfflineLibrary.newBuilder(limit)
    return setmetatable({
        limit = limit or OfflineLibrary.DEFAULT_SIZE,
        books = {},
        index = {},
        counted = 0,
        total = 0,
        truncated = false,
        shelves = {},
        members = {},
        capabilities = nil,
    }, Builder)
end

function Builder:has(id)
    return id ~= nil and self.index[tostring(id)] ~= nil
end

function Builder:remaining()
    return math.max(0, self.limit - self.counted)
end

-- Adds a book once. Returns true when it was added, false when it was known
-- already or the walk's limit is reached (force ignores the limit).
function Builder:add(book, extra, force)
    local summary = OfflineLibrary.summarize(book, extra)
    if not summary then return false end
    local key = tostring(summary.id)
    local existing = self.index[key]
    if existing then
        for field, value in pairs(extra or {}) do
            if existing[field] == nil then existing[field] = value end
        end
        return false
    end
    if not force and self.counted >= self.limit then return false end
    if not force then self.counted = self.counted + 1 end
    table.insert(self.books, summary)
    self.index[key] = summary
    return true
end

function Builder:setShelf(section, items)
    self.shelves[section] = items or {}
end

-- Which books a collection or scope holds, by id.
function Builder:setMembers(key, ids)
    self.members[key] = ids or {}
end

function Builder:addTotal(total)
    self.total = self.total + (tonumber(total) or 0)
end

function Builder:setCapabilities(names)
    self.capabilities = names
end

function Builder:finish(now)
    return {
        saved_at = now or os.time(),
        books = self.books,
        total = math.max(self.total, #self.books),
        truncated = self.truncated,
        shelves = self.shelves,
        members = self.members,
        capabilities = self.capabilities,
    }
end

-- ------------------------------------------------------------------ queries
-- Sorting and matching fold case and the common Latin accents, so "Éclair"
-- sorts under E as it does on the server rather than after Z.
local FOLD = {
    ["à"] = "a", ["á"] = "a", ["â"] = "a", ["ã"] = "a", ["ä"] = "a", ["å"] = "a", ["æ"] = "ae", ["ç"] = "c",
    ["è"] = "e", ["é"] = "e", ["ê"] = "e", ["ë"] = "e", ["ì"] = "i", ["í"] = "i", ["î"] = "i", ["ï"] = "i",
    ["ñ"] = "n", ["ò"] = "o", ["ó"] = "o", ["ô"] = "o", ["õ"] = "o", ["ö"] = "o", ["ø"] = "o", ["œ"] = "oe",
    ["ù"] = "u", ["ú"] = "u", ["û"] = "u", ["ü"] = "u", ["ý"] = "y", ["ÿ"] = "y", ["ß"] = "ss",
    ["À"] = "a", ["Á"] = "a", ["Â"] = "a", ["Ã"] = "a", ["Ä"] = "a", ["Å"] = "a", ["Æ"] = "ae", ["Ç"] = "c",
    ["È"] = "e", ["É"] = "e", ["Ê"] = "e", ["Ë"] = "e", ["Ì"] = "i", ["Í"] = "i", ["Î"] = "i", ["Ï"] = "i",
    ["Ñ"] = "n", ["Ò"] = "o", ["Ó"] = "o", ["Ô"] = "o", ["Õ"] = "o", ["Ö"] = "o", ["Ø"] = "o", ["Œ"] = "oe",
    ["Ù"] = "u", ["Ú"] = "u", ["Û"] = "u", ["Ü"] = "u", ["Ý"] = "y",
}
local function lowerText(value)
    if type(value) ~= "string" then return "" end
    return (string.lower(value):gsub("[\195][\128-\191]", FOLD))
end

local function firstAuthor(book)
    return type(book.authors) == "table" and book.authors[1] or nil
end

local function timeText(value)
    return type(value) == "string" and value or ""
end

local SORT_KEYS = {
    title = function(b) return lowerText(b.title) end,
    author = function(b) return lowerText(firstAuthor(b)) .. "\1" .. lowerText(b.title) end,
    series = function(b)
        local index = tonumber(b.seriesIndex) or 0
        return lowerText(b.seriesName) .. "\1" .. string.format("%012.3f", index) .. "\1" .. lowerText(b.title)
    end,
    recently_added = function(b) return timeText(b.addedAt) end,
    recently_updated = function(b) return timeText(b.updatedAt) end,
    recently_read = function(b) return timeText(b.lastReadAt) end,
}
local NATURAL_ORDER = { title = "asc", author = "asc", series = "asc", recently_added = "desc", recently_updated = "desc", recently_read = "desc" }
local LETTER_OF = {
    title = function(b) return ListData.letterOf(b.title) end,
    author = function(b) return ListData.letterOf(firstAuthor(b) or "") end,
}

local function sortBooks(list, sort, order)
    local key = SORT_KEYS[sort] or SORT_KEYS.title
    local desc = (order or NATURAL_ORDER[sort] or "asc") == "desc"
    local keyed = {}
    for i, book in ipairs(list) do keyed[i] = { k = key(book), t = lowerText(book.title), id = tostring(book.id), b = book } end
    table.sort(keyed, function(x, y)
        if x.k ~= y.k then
            if desc then return x.k > y.k end
            return x.k < y.k
        end
        if x.t ~= y.t then return x.t < y.t end
        return x.id < y.id
    end)
    for i, entry in ipairs(keyed) do list[i] = entry.b end
    return list
end

local function idSet(ids)
    if ids == nil then return nil end
    local set = {}
    if type(ids) == "table" then
        for _, id in ipairs(ids) do set[tostring(id)] = true end
    else
        for id in tostring(ids):gmatch("[^,%s]+") do set[id] = true end
    end
    return set
end

local function matchesText(book, needle)
    if lowerText(book.title):find(needle, 1, true) then return true end
    for _, author in ipairs(book.authors or {}) do
        if lowerText(author):find(needle, 1, true) then return true end
    end
    return lowerText(book.seriesName):find(needle, 1, true) ~= nil
end

local function hasFormat(book, format)
    for _, f in ipairs(book.formats or {}) do
        if lowerText(f) == format then return true end
    end
    return false
end

local function hasAuthor(book, name)
    for _, author in ipairs(book.authors or {}) do
        if lowerText(author) == name then return true end
    end
    return false
end

-- Buckets ({ key, index }) for a letter rail, from a sorted list.
local function bucketsOf(list, letter_of)
    local buckets, seen = {}, {}
    for index, book in ipairs(list) do
        local letter = letter_of(book)
        if not seen[letter] then
            seen[letter] = true
            table.insert(buckets, { key = letter, index = index - 1 })
        end
    end
    return buckets
end

local function pageOf(list, query)
    local total = #list
    local size = math.max(1, math.min(MAX_PAGE_SIZE, tonumber(query.size) or DEFAULT_PAGE_SIZE))
    local offset = tonumber(query.offset)
    local page = math.max(1, tonumber(query.page) or 1)
    local start
    if offset then
        start = math.max(0, math.min(offset, math.max(0, total - 1)))
        page = math.floor(start / size) + 1
    else
        start = (page - 1) * size
    end
    local items = {}
    for i = start + 1, math.min(total, start + size) do table.insert(items, list[i]) end
    return {
        items = items,
        total = total,
        page = page,
        size = size,
        offset = offset and start or nil,
        hasNext = start + size < total,
        hasPrevious = start > 0,
        nextUrl = nil,
        previousUrl = nil,
    }
end

-- The scope a query names, before its read-status filter and paging: the
-- books in it, or nil when the snapshot cannot answer (a collection it never
-- walked, an author it does not know).
local function scopedBooks(snapshot, query, opts)
    opts = opts or {}
    local books = snapshot.books or {}
    local wanted = idSet(query.ids)
    local members
    if query.collectionId ~= nil then
        members = (snapshot.members or {})["collection:" .. tostring(query.collectionId)]
        if not members then return nil end
        members = idSet(members)
    elseif query.smartScopeId ~= nil then
        members = (snapshot.members or {})["scope:" .. tostring(query.smartScopeId)]
        if not members then return nil end
        members = idSet(members)
    end
    local author = query.author ~= nil and lowerText(query.author) or nil
    local series = query.series ~= nil and lowerText(query.series) or nil
    local series_id = query.seriesId ~= nil and tostring(query.seriesId) or nil
    local library = query.libraryId ~= nil and tostring(query.libraryId) or nil
    local format = query.format and lowerText(query.format) or nil
    local needle = type(query.q) == "string" and lowerText(util.trim and util.trim(query.q) or query.q) or nil
    if needle == "" then needle = nil end

    local out, seen = {}, {}
    local function consider(book)
        if book.id == nil or seen[tostring(book.id)] then return end
        seen[tostring(book.id)] = true
        if wanted and not wanted[tostring(book.id)] then return end
        if members and not members[tostring(book.id)] then return end
        if library and tostring(book.libraryId) ~= library then return end
        if author and not hasAuthor(book, author) then return end
        if series_id and tostring(book.seriesId) ~= series_id then return end
        if series and lowerText(book.seriesName) ~= series then return end
        if format and not hasFormat(book, format) then return end
        if needle and not matchesText(book, needle) then return end
        if opts.exclude and opts.exclude(book) then return end
        table.insert(out, book)
    end
    for _, book in ipairs(books) do consider(book) end
    for _, book in ipairs(opts.extra or {}) do consider(book) end
    -- An author the snapshot holds no book of is unknown rather than empty,
    -- so the catalog can still ask for a connection.
    if author and #out == 0 and not wanted then return nil end
    return out
end

local function stateCounts(list)
    local finished, reading = 0, 0
    for _, book in ipairs(list) do
        local state = ListData.stateOf(book)
        if state == "finished" then finished = finished + 1 elseif state == "reading" then reading = reading + 1 end
    end
    return finished, reading
end

-- A page of books as GET /catalog/books returns it. query: the request's
-- parameters (ids, sort, order, readStatus, format, libraryId,
-- collectionId, smartScopeId, author, series, seriesId, q, page, size,
-- offset, buckets). opts.exclude(book) drops books; opts.extra lists books
-- the snapshot does not hold (books on this device it never saw). Returns
-- nil when the snapshot cannot answer the query.
function OfflineLibrary.books(snapshot, query, opts)
    if type(snapshot) ~= "table" then return nil end
    query = query or {}
    local scope = scopedBooks(snapshot, query, opts)
    if not scope then return nil end

    local list = {}
    local status = query.readStatus
    for _, book in ipairs(scope) do
        local keep = true
        if status == "reading" or status == "finished" then
            keep = ListData.stateOf(book) == status
        elseif status == "unread" then
            local state = ListData.stateOf(book)
            keep = state ~= "reading" and state ~= "finished"
        end
        if keep then table.insert(list, book) end
    end
    local sort = query.sort or "title"
    sortBooks(list, sort, query.order)

    local body = pageOf(list, query)
    if query.buckets and LETTER_OF[sort] then
        body.buckets = bucketsOf(list, LETTER_OF[sort])
    end
    if query.series ~= nil or query.seriesId ~= nil then
        local finished, reading = stateCounts(scope)
        body.seriesSummary = { total = #scope, finished = finished, reading = reading }
    end
    if query.author ~= nil then
        local name = query.author
        for _, book in ipairs(scope) do
            for _, candidate in ipairs(book.authors or {}) do
                if lowerText(candidate) == lowerText(query.author) then name = candidate end
            end
        end
        body.authorSummary = { name = name, hasPhoto = false }
    end
    return body
end

function OfflineLibrary.find(snapshot, id)
    if type(snapshot) ~= "table" or id == nil then return nil end
    local index = snapshot._index
    if not index then
        index = {}
        for _, book in ipairs(snapshot.books or {}) do
            if book.id ~= nil then index[tostring(book.id)] = book end
        end
        snapshot._index = index
    end
    return index[tostring(id)]
end

-- --------------------------------------------------------------- sections
local function previewsOf(list)
    local sorted = {}
    for i, book in ipairs(list) do sorted[i] = book end
    sortBooks(sorted, "recently_added", "desc")
    local previews = {}
    for i = 1, math.min(PREVIEW_LIMIT, #sorted) do table.insert(previews, previewOf(sorted[i])) end
    return previews
end

local function derivedAuthors(snapshot)
    local by_name, order = {}, {}
    for _, book in ipairs(snapshot.books or {}) do
        for _, author in ipairs(book.authors or {}) do
            local key = lowerText(author)
            if key ~= "" then
                local entry = by_name[key]
                if not entry then
                    entry = { id = author, title = author, section = "authors", books = {}, letter = ListData.letterOf(author) }
                    by_name[key] = entry
                    table.insert(order, entry)
                end
                table.insert(entry.books, book)
            end
        end
    end
    for _, entry in ipairs(order) do
        entry.count = #entry.books
        entry.finishedCount, entry.readingCount = stateCounts(entry.books)
        entry.previewBooks = previewsOf(entry.books)
        entry.books = nil
    end
    return order
end

local function derivedSeries(snapshot)
    local by_key, order = {}, {}
    for _, book in ipairs(snapshot.books or {}) do
        local name = type(book.seriesName) == "string" and book.seriesName or nil
        if name and name ~= "" then
            local key = book.seriesId ~= nil and ("id:" .. tostring(book.seriesId)) or ("name:" .. lowerText(name))
            local entry = by_key[key]
            if not entry then
                entry = { id = name, title = name, section = "series", seriesId = tonumber(book.seriesId), books = {}, letter = ListData.letterOf(name) }
                by_key[key] = entry
                table.insert(order, entry)
            end
            table.insert(entry.books, book)
        end
    end
    for _, entry in ipairs(order) do
        sortBooks(entry.books, "series", "asc")
        entry.count = #entry.books
        entry.finishedCount, entry.readingCount = stateCounts(entry.books)
        local names, seen_names, states = {}, {}, {}
        for _, book in ipairs(entry.books) do
            local author = firstAuthor(book)
            if author and not seen_names[author] and #names < 3 then
                seen_names[author] = true
                table.insert(names, author)
            end
            local state = ListData.stateOf(book)
            table.insert(states, state == "finished" and "finished" or state == "reading" and "reading" or "unread")
        end
        entry.authorNames = names
        entry.memberStates = states
        entry.previewBooks = previewsOf(entry.books)
        entry.books = nil
    end
    return order
end

local function derived(snapshot, section)
    snapshot._derived = snapshot._derived or {}
    local list = snapshot._derived[section]
    if not list then
        list = section == "authors" and derivedAuthors(snapshot) or derivedSeries(snapshot)
        snapshot._derived[section] = list
    end
    return list
end

local function sortEntries(list, sort)
    table.sort(list, function(a, b)
        if sort == "books" and a.count ~= b.count then return a.count > b.count end
        local ta, tb = lowerText(a.title), lowerText(b.title)
        if ta ~= tb then
            if sort == "name_desc" then return ta > tb end
            return ta < tb
        end
        return tostring(a.id) < tostring(b.id)
    end)
    return list
end

-- A section as GET /catalog/sections/:section returns it. Libraries,
-- collections and scopes come back as they were saved; authors and series
-- are drawn from the snapshot's books. params: page, offset, size, q, sort
-- ("name", "name_desc", "books"), filter ("reading", "finished").
function OfflineLibrary.section(snapshot, section, params)
    if type(snapshot) ~= "table" then return nil end
    params = params or {}
    if section == "libraries" or section == "collections" or section == "smart-scopes" then
        local items = type(snapshot.shelves) == "table" and snapshot.shelves[section] or nil
        if not items then return nil end
        return { section = section, items = items }
    end
    if section ~= "authors" and section ~= "series" then return nil end

    local needle = type(params.q) == "string" and lowerText(util.trim and util.trim(params.q) or params.q) or nil
    if needle == "" then needle = nil end
    local filter = params.filter
    local list = {}
    for _, entry in ipairs(derived(snapshot, section)) do
        local keep = true
        if needle and not lowerText(entry.title):find(needle, 1, true) then keep = false end
        if filter == "reading" and (entry.readingCount or 0) == 0 then keep = false end
        if filter == "finished" and (entry.finishedCount or 0) == 0 then keep = false end
        if keep then table.insert(list, entry) end
    end
    local sort = params.sort or "name"
    sortEntries(list, sort)

    local query = { page = params.page, offset = params.offset, size = params.size or 60 }
    local body = pageOf(list, query)
    body.section = section
    body.query = params.q
    body.sort = sort
    body.filter = filter
    if sort ~= "books" then
        body.buckets = bucketsOf(list, function(entry) return entry.letter or ListData.letterOf(entry.title) end)
    end
    return body
end

-- Authors, series and books for one query, the three lists a search page
-- shows. limits: { authors, series, books }.
function OfflineLibrary.search(snapshot, q, limits)
    if type(snapshot) ~= "table" then return nil end
    limits = limits or {}
    local authors = OfflineLibrary.section(snapshot, "authors", { q = q, size = limits.authors or 12 })
    local series = OfflineLibrary.section(snapshot, "series", { q = q, size = limits.series or 12 })
    local books = OfflineLibrary.books(snapshot, { q = q, sort = "title", page = 1, size = limits.books or 48 })
    if not authors or not series or not books then return nil end
    return {
        authors = authors.items,
        series = series.items,
        books = books.items,
        books_total = books.total,
    }
end

return OfflineLibrary

-- Issue 1965: past the dashboard, nothing that this device can answer asks
-- for a connection. Book lists, On device, Not on device, the shelves, search
-- and reloads go to the offline library first; only an explicit reconnect, a
-- refresh, or a list nothing saved answers goes through the connected gate.

package.path = "koreader-plugin/bookorbit.koplugin/?.lua;" .. package.path
package.loaded["gettext"] = function(text) return text end
package.loaded["ffi/util"] = {
    template = function(text, ...)
        local values = { ... }
        return (text:gsub("%%(%d+)", function(index) return tostring(values[tonumber(index)]) end))
    end,
}
package.loaded["document/documentregistry"] = {}
package.loaded["util"] = { trim = function(value) return tostring(value or ""):match("^%s*(.-)%s*$") end }
local connected = false
package.loaded["ui/network/manager"] = { isConnected = function() return connected end }
for _, name in ipairs({ "device", "ui/widget/infomessage", "ui/uimanager",
    "datetime", "logger", "bookorbit_board_data", "bookorbit_board_metrics",
    "bookorbit_capabilities", "bookorbit_list_cache", "bookorbit_list_data",
    "bookorbit_list_pages", "bookorbit_list_view" }) do package.loaded[name] = {} end
package.loaded["bookorbit_toast"] = { show = function() end, error = function() end }

local Lists = require("bookorbit_catalog_lists")

local function assertEqual(actual, expected, label)
    if actual ~= expected then
        error(string.format("%s: expected %s, got %s", label, tostring(expected), tostring(actual)))
    end
end

local function read(path)
    local file = assert(io.open(path, "rb"))
    local content = file:read("*a")
    file:close()
    return content
end

-- The book loaders live in bookorbit_catalog.lua, which cannot be loaded
-- whole outside KOReader, so each is lifted out and run against stubs.
local source = read("koreader-plugin/bookorbit.koplugin/bookorbit_catalog.lua")
local lifted = {}
local env = setmetatable({
    BookOrbitCatalog = lifted,
    cloneParams = function(params)
        local copy = {}
        for key, value in pairs(params or {}) do copy[key] = value end
        return copy
    end,
    Toast = package.loaded["bookorbit_toast"],
    ON_DEVICE_MAX_IDS = 3,
    _ = package.loaded["gettext"],
}, { __index = _G })
for _, name in ipairs({ "loadBooks", "onDeviceIdsParam", "loadOnDevice" }) do
    local chunk = assert(source:match("\n(function BookOrbitCatalog:" .. name .. "%(.-\nend)\n"), name .. " is defined in bookorbit_catalog.lua")
    local fn = assert(loadstring(chunk, name))
    setfenv(fn, env)
    fn()
end

local served, fetched, waited = {}, {}, 0
local catalog = setmetatable({
    on_device = { [5] = "/five.epub", [2] = "/two.epub", [9] = "/nine.epub", [7] = "/seven.epub" },
    current_context = {},
}, { __index = Lists })
for name, fn in pairs(lifted) do catalog[name] = fn end
function catalog:runConnected(fn) waited = waited + 1; fn() end
function catalog:refreshOnDevice() return true end
function catalog:isOnDevice(book) return self.on_device[book.id] ~= nil end
function catalog:fetchBookPage(params, title, push) table.insert(fetched, { params = params, title = title, push = push }) end
function catalog:persistSetting() end
local offline_answer = true
function catalog:offlineServeBooks(params, title, push)
    if not offline_answer then return false end
    table.insert(served, { kind = "books", params = params, title = title, push = push })
    return true
end
function catalog:offlineServeShelves(opts) table.insert(served, { kind = "shelves", opts = opts }); return offline_answer end
function catalog:offlineServeSearch(q, opts) table.insert(served, { kind = "search", q = q, opts = opts }); return offline_answer end
function catalog:recordRecentSearch() end
function catalog:fetch() return nil, "unreachable" end
function catalog:showRetry() end
function catalog:withLoading(_text, fn) fn() end
function catalog:listEnsureCapabilities() end

-- A book list offline is served and never waits for a connection.
catalog:loadBooks({ sort = "title" }, "All books", true)
assertEqual(#served, 1, "the offline library serves the list")
assertEqual(served[1].title, "All books", "under its title")
assertEqual(waited, 0, "without asking for a connection")
assertEqual(#fetched, 0, "and without a request")

-- On device offline is served from the map; online it is capped for the server.
catalog:loadOnDevice()
assertEqual(served[2].params.on_device_filter, true, "On device is asked of the offline library")
assertEqual(served[2].params.ids, nil, "which reads the map itself")
offline_answer = false
catalog:loadOnDevice()
assertEqual(#fetched, 1, "with nothing saved the server is asked")
assertEqual(fetched[1].params.ids, "2,5,7", "for the books on the device, within the server's cap")
assertEqual(waited, 1, "through the connected gate")

-- A list the device derived, reloaded online, is rebuilt rather than sent.
catalog:loadBooks({ sort = "recently_added", not_on_device_filter = true }, "Library", false, { online = true })
assertEqual(fetched[2].params.not_on_device_filter, true, "Not on this device keeps its filter; the exclusion is read at fetch time")
catalog:loadBooks({ sort = "title", on_device_filter = true, ids = { 2, 5, 7, 9 } }, "On device", false, { online = true })
assertEqual(fetched[3].params.ids, "2,5,7", "On device sends the capped ids, never the offline table")

-- An explicit reconnect skips the offline library.
offline_answer = true
served = {}
catalog:loadBooks({ sort = "title" }, "All books", false, { online = true })
assertEqual(#served, 0, "a reconnect does not ask the offline library")
assertEqual(#fetched, 4, "it goes to the server")

-- The list controller routes reloads, shelves and search the same way.
catalog.current_context = { kind = "books", params = { sort = "title" }, title = "All books", page = 2, list_offline = true }
catalog:listRun({ kind = "reconnect" })
assertEqual(#served, 0, "the offline band's tap reconnects")
assertEqual(fetched[5].params.page, 2, "on the same page")
catalog:listReload({ page = 3 })
assertEqual(served[1].params.page, 3, "an ordinary reload stays offline")
catalog:loadShelves({})
assertEqual(served[2].kind, "shelves", "the shelves are served offline")
catalog:loadShelves({ online = true, replace = true })
assertEqual(#served, 2, "unless reconnecting")
catalog:listSearch("dune", {})
assertEqual(served[3].q, "dune", "search is served offline")
assertEqual(waited, 6, "only the server-bound loads waited for a connection")

-- Applying the sort sheet offline reloads through the offline library.
catalog.current_context = { kind = "books", params = { sort = "title" }, title = "All books",
    list_sheet = { kind = "sort", staged = { sort = "recently_added", order = "desc", on_device = false } } }
function catalog:updateItems() end
catalog:listApplySheet()
assertEqual(served[4].params.sort, "recently_added", "the new sort is asked of the offline library")

-- Offline, a book on the device opens; any other opens its saved details.
local opened, detailed = {}, {}
function catalog:isBulkSelectionActive() return false end
function catalog:onDeviceBookPath(book) return self.on_device[book.id] end
function catalog:openDownloadedFile(path) table.insert(opened, path) end
function catalog:loadBookDetail(id, opts) table.insert(detailed, { id = id, book = opts and opts.book }) end
catalog.current_context = { kind = "books", list_offline = true, books = {} }
catalog:listRun({ kind = "open-book", book = { id = 5, title = "Five" } })
assertEqual(opened[1], "/five.epub", "a book on the device opens at once")
catalog:listRun({ kind = "open-book", book = { id = 6, title = "Six" } })
assertEqual(detailed[1].id, 6, "a book not on the device opens its details")
assertEqual(detailed[1].book.title, "Six", "from the entry it was tapped in")

-- The offline band says where the list came from, and the toolbar stays for
-- a library-served list.
package.loaded["bookorbit_board_data"].relativeDay = function() return "2 h ago" end
local band = catalog:listOfflineBand({ list_saved_at = 1000, list_offline_library = { count = 2000, total = 12345, truncated = true } })
assertEqual(band.note, "library saved 2 h ago · newest 2000 of 12345 books", "a truncated library says how much of it was saved")
assertEqual(band.action.kind, "reconnect", "and reconnects on a tap")
band = catalog:listOfflineBand({ list_saved_at = 1000, list_offline_library = { count = 40, total = 40 } })
assertEqual(band.note, "library saved 2 h ago", "a complete library only says when")
band = catalog:listOfflineBand({ list_saved_at = 1000, on_device_filter = true, list_offline_library = { count = 40, total = 40 } })
assertEqual(band.note, "books on this device · library saved 2 h ago", "On device says what it lists")
band = catalog:listOfflineBand({ list_saved_at = 1000 })
assertEqual(band.note, "saved list from 2 h ago. Books on this device open.", "a saved page keeps its note")
assertEqual(catalog:listOfflineLayout({ list_offline = true, list_offline_library = {} }).toolbar, true, "a library-served list keeps its toolbar")
assertEqual(catalog:listOfflineLayout({ list_offline = true }).toolbar, false, "a saved page loses it")
assertEqual(catalog:listOfflineLayout({}).offline, nil, "an online list has no band")

print("bookorbit_offline_navigation_test.lua: ok")

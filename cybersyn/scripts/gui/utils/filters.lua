-- The manager's filters: the station search, the item, network, surface and station chip a player sets, and the
-- predicates every tab applies them with.

local collector = require("scripts.gui.collector")
local util = require("scripts.gui.util")
local listing = require("scripts.gui.utils.listing")
local tabs = require("scripts.gui.utils.tabs")

local filters = {}

--- Whitespace-separated terms of a station-name query. Terms are matched as plain substrings (string.find with
--- plain = true), never as Lua patterns, so "[", "%" or "-" in a query match themselves. The query is lowercased the
--- way station names are (helpers.multilingual_to_lower), which leaves rich-text tags as they are, so a query that
--- contains an icon tag matches the names that show that icon.
--- @param text string?
--- @return string[]?
function filters.search_terms(text)
	if not text then return nil end
	local terms = {}
	for term in string.gmatch(helpers.multilingual_to_lower(text), "%S+") do
		terms[#terms + 1] = term
	end
	if #terms == 0 then return nil end
	return terms
end

--- True when every term occurs in `name_lower` (already normalised).
--- @param name_lower string
--- @param terms string[]
--- @return boolean
function filters.terms_match(name_lower, terms)
	for i = 1, #terms do
		if not string.find(name_lower, terms[i], 1, true) then return false end
	end
	return true
end

--- @class FilterState every filter the manager applies (player_data.filters); written through filters.set and
--- filters.clear, except the tab chips, which their own tab sets so that only its page resets
--- @field query string? raw text of the station-name search
--- @field terms string[]? lowercase terms of `query`
--- @field item string? item hash (name or name|quality)
--- @field station uint? station id of the station chip
--- @field train uint? train id of the train chip (a train panel's "Open in manager")
--- @field network string? network signal name
--- @field mask int? network ID; nil = any
--- @field surface uint? surface index
--- @field stations_chip string? the Stations flag chip, see stations.lua
--- @field problems_scope "errors"? with the Problems chip: only the stations with errors
--- @field trains_chip string? the Trains chip, see trains.lua

-- A stored id or name that no longer resolves (a removed stop, an uninstalled item, a deleted surface) is dropped
-- rather than kept as a filter nothing can pass.
local VALID = {
	item = function(hash) return util.signal_hash_valid(hash) end,
	network = function(name) return util.signal_hash_valid(name) end,
	station = function(id) return storage.stations[id] ~= nil end,
	train = function(id) return storage.trains[id] ~= nil end,
	surface = function(index) return game.get_surface(index) ~= nil end,
}

-- The filter row's own filters: any of them set opens the row, and closing the row clears them.
local ROW = { "item", "station", "train", "network", "mask", "surface" }
-- What a jump to a subject drops even when it keeps the row (manager.focus keep_row): the station and train chips
-- and the tabs' own chips.
local CHIPS = { "station", "train", "stations_chip", "problems_scope", "trains_chip" }
local IS_ROW = {}
for _, field in ipairs(ROW) do IS_ROW[field] = true end
local SCOPES = { chips = CHIPS, row = { "stations_chip", "problems_scope", "trains_chip" } }
for _, field in ipairs(ROW) do table.insert(SCOPES.row, field) end

--- Sets one filter: validates it, resets every tab's page and opens the filter row for a row filter, so no
--- filter is ever active with the row hidden. An empty query or a mask of -1 clears that filter.
--- @param player_data PlayerData
--- @param field string a FilterState field
--- @param value any
function filters.set(player_data, field, value)
	local fs = player_data.filters
	if field == "query" then
		if value == "" then value = nil end
		fs.terms = filters.search_terms(value)
	elseif field == "mask" then
		if value == -1 then value = nil end
	elseif value ~= nil and VALID[field] and not VALID[field](value) then
		value = nil
	end
	if fs[field] == value then return end
	fs[field] = value
	if value ~= nil and IS_ROW[field] then player_data.filter_row_open = true end
	listing.reset_pages(player_data)
end

--- Clears a scope of filters: "chips" (the station chip and the tab chips), "row" (those and the filter row's
--- filters) or "all" (also the station search).
--- @param player_data PlayerData
--- @param scope "chips"|"row"|"all"
function filters.clear(player_data, scope)
	if scope == "all" then
		player_data.filters = {}
	else
		local fs = player_data.filters
		for _, field in ipairs(SCOPES[scope]) do fs[field] = nil end
	end
	listing.reset_pages(player_data)
end

--- Whether any of the filter row's filters is set.
--- @param player_data PlayerData
--- @return boolean
function filters.active(player_data)
	local fs = player_data.filters
	for i = 1, #ROW do
		if fs[ROW[i]] ~= nil then return true end
	end
	return false
end

--- Drops every stored filter that no longer resolves; run before anything reads or shows the filters.
--- @param player_data PlayerData
function filters.validate(player_data)
	local fs = player_data.filters
	for field, valid in pairs(VALID) do
		local v = fs[field]
		if v ~= nil and not valid(v) then fs[field] = nil end
	end
	if fs.query and not fs.terms then fs.terms = filters.search_terms(fs.query) end
end

--- A plain string of every stored filter, to tell when the widgets showing them need writing.
--- @param player_data PlayerData
--- @return string
function filters.signature(player_data)
	local fs = player_data.filters
	return table.concat({ fs.query or "", fs.item or "", fs.station or "", fs.train or "", fs.network or "", fs.mask or "",
		fs.surface or "", fs.stations_chip or "", fs.problems_scope or "", fs.trains_chip or "" }, "\1")
end

--- @class ManagerFilters the filters one tab applies (filters.get)
--- @field terms string[]? lowercase, AND-ed plain substrings of the station name
--- @field item string? item hash
--- @field network string? network signal name
--- @field mask int -1 = any
--- @field surface uint? surface index
--- @field station uint? station id (the station chip): only that station's rows pass
--- @field train uint? train id (the train chip): only that train passes

--- The filters `tab` applies: the stored ones less those its tabs.lua entry does not apply, so a tab cannot filter
--- by something its chip tooltip says it ignores.
--- @param player_data PlayerData
--- @param tab string
--- @return ManagerFilters
function filters.get(player_data, tab)
	local fs = player_data.filters
	local t = tabs.by_name[tab]
	return {
		terms = t.search and fs.terms or nil,
		item = t.item and fs.item or nil,
		network = fs.network,
		mask = fs.mask or -1,
		surface = fs.surface,
		station = t.station and fs.station or nil,
		train = t.train and fs.train or nil,
	}
end

--- @param f ManagerFilters
--- @param ignore_item boolean?
--- @return boolean
function filters.filters_active(f, ignore_item)
	return f.terms ~= nil or f.network ~= nil or f.mask ~= -1 or f.surface ~= nil or f.station ~= nil
		or f.train ~= nil or (not ignore_item and f.item ~= nil)
end

local btest = bit32.btest

--- @param network_name string?
--- @param network_mask int|{[string]: int}?
--- @param f ManagerFilters
--- @return boolean
function filters.network_passes(network_name, network_mask, f)
	local want = f.network
	if want then
		if network_name == NETWORK_EACH then
			local mask = type(network_mask) == "table" and network_mask[want]
			return mask and btest(f.mask, mask) or false
		end
		if network_name ~= want then return false end
		return type(network_mask) == "number" and btest(f.mask, network_mask)
	elseif f.mask ~= -1 then
		if type(network_mask) == "table" then
			for _, mask in pairs(network_mask) do
				if btest(f.mask, mask) then return true end
			end
			return false
		end
		return type(network_mask) == "number" and btest(f.mask, network_mask)
	end
	return true
end

--- The row's own part of row_passes: its network and its item.
--- @param row SnapshotInventory
--- @param f ManagerFilters
--- @param ignore_item boolean?
--- @return boolean
local function row_own_passes(row, f, ignore_item)
	if not filters.network_passes(row.network_name, row.networks or row.mask, f) then return false end
	local item = f.item
	if item and not ignore_item then
		-- Deliveries belong to the station; they show on its first row.
		if not (row.provided[item] or row.requested[item] or (row.index == 0 and row.st.deliveries[item])) then
			return false
		end
	end
	return true
end

--- Whether one inventory row (collector.inventories) passes the filters: its station's surface, name terms and the
--- station chip, then the row's own network, mask and item.
--- @param row SnapshotInventory
--- @param f ManagerFilters
--- @param ignore_item boolean?
--- @return boolean
function filters.row_passes(row, f, ignore_item)
	local st = row.st
	if f.station and st.id ~= f.station then return false end
	if f.surface and st.surface_index ~= f.surface then return false end
	local terms = f.terms
	if terms and not filters.terms_match(st.name_lower, terms) then return false end
	return row_own_passes(row, f, ignore_item)
end

--- A station passes when any of its rows does. A record without rows (hand-built) is one row on its own lists.
--- @param st SnapshotStation
--- @param f ManagerFilters
--- @param ignore_item boolean?
--- @return boolean
function filters.station_passes(st, f, ignore_item)
	if f.station and st.id ~= f.station then return false end
	if f.surface and st.surface_index ~= f.surface then return false end
	local terms = f.terms
	if terms and not filters.terms_match(st.name_lower, terms) then return false end
	local rows = st.rows
	if rows == nil then
		if not filters.network_passes(st.network_name, st.network_mask, f) then return false end
		local item = f.item
		if item and not ignore_item then
			if not (st.provided[item] or st.requested[item] or st.deliveries[item]) then return false end
		end
		return true
	end
	for i = 1, #rows do
		if row_own_passes(rows[i], f, ignore_item) then return true end
	end
	return false
end

--- A plain string of every filter field, for caches keyed on the filters.
--- @param f ManagerFilters
--- @return string
function filters.filter_signature(f)
	return table.concat({
		f.terms and table.concat(f.terms, " ") or "", f.item or "", f.network or "", f.mask, f.surface or "",
		f.station or "", f.train or "",
	}, "\1")
end

--- Whether network name, network ID or surface is set: the filters that decide by a station's place, not its items.
--- @param f ManagerFilters
--- @return boolean
function filters.place_filters_active(f)
	return f.network ~= nil or f.mask ~= -1 or f.surface ~= nil
end

--- The locale-key suffix of the drill-down's empty texts: with a place filter or the station chip set, "No
--- station provides this item" would deny stations the filters merely hide, so the text names the filters.
--- Used as {"cybersyn-gui.item-empty-<table>" .. filters.empty_filter_suffix(f)}.
--- @param f ManagerFilters
--- @return string
function filters.empty_filter_suffix(f)
	if f.station ~= nil or filters.place_filters_active(f) then return "-filtered" end
	return ""
end

--- Whether requester `r_id` of an Unserved entry passes the network name, network ID and surface filters: read
--- from its snapshot record, or from the live station while the first pass is still collecting. A requester that is
--- gone passes only while none of those filters is set.
--- @param r_id uint
--- @param stations {[uint]: SnapshotStation}
--- @param f ManagerFilters
--- @return boolean
function filters.requester_passes(r_id, stations, f)
	if not filters.place_filters_active(f) then return true end
	local st = stations[r_id]
	if st then
		if f.surface and st.surface_index ~= f.surface then return false end
		return filters.network_passes(st.network_name, st.network_mask, f)
	end
	local station = storage.stations[r_id]
	local stop = station and station.entity_stop
	if not (stop and stop.valid) then return false end
	if f.surface and stop.surface_index ~= f.surface then return false end
	return filters.network_passes(station.network_name, station.network_mask, f)
end

--- Whether surface `surface_index` holds a Cybersyn station (the manager's surface default falls back to All without).
--- @param surface_index uint
--- @return boolean
function filters.surface_has_station(surface_index)
	for _, station in pairs(storage.stations) do
		local stop = station.entity_stop
		if stop and stop.valid and stop.surface_index == surface_index then return true end
	end
	return false
end

--- Station-name terms are not applied to trains.
--- @param tr SnapshotTrain
--- @param f ManagerFilters
--- @param ignore_item boolean?
--- @return boolean
function filters.train_passes(tr, f, ignore_item)
	if f.train and tr.id ~= f.train then return false end
	local station = f.station
	if station and tr.p_station_id ~= station and tr.r_station_id ~= station then return false end
	if f.surface and tr.surface_index ~= f.surface then return false end
	if not filters.network_passes(tr.network_name, tr.network_mask, f) then return false end
	if f.item and not ignore_item and not tr.manifest_hashes[f.item] then return false end
	if f.terms and not filters.train_terms_pass(tr, f.terms) then return false end
	return true
end

--- Text search on trains matches the names of the depot and of the current provider and requester, so searching
--- for a station also finds the trains serving it.
--- @param tr SnapshotTrain
--- @param terms string[] lowercase
--- @return boolean
function filters.train_terms_pass(tr, terms)
	local stations = collector.get().stations
	local depot = tr.depot_name and helpers.multilingual_to_lower(tr.depot_name)
	local p = tr.p_station_id and stations[tr.p_station_id]
	local r = tr.r_station_id and stations[tr.r_station_id]
	p = p and p.name_lower
	r = r and r.name_lower
	for i = 1, #terms do
		local term = terms[i]
		if not ((depot and string.find(depot, term, 1, true))
				or (p and string.find(p, term, 1, true))
				or (r and string.find(r, term, 1, true))) then
			return false
		end
	end
	return true
end

return filters

--By Mami
local min = math.min
local max = math.max
local abs = math.abs
local ceil = math.ceil
local INF = math.huge
local btest = bit32.btest
local band = bit32.band
local table_remove = table.remove
local table_insert = table.insert
local random = math.random

local analytics = require("scripts.analytics")
local stats = require("scripts.stats")
local diag = require("scripts.diag")
local diag_fail = diag.fail
-- tick_dispatch's per-evaluation rejection counters (diagnostics on only); zeroed before every evaluation.
local diag_rej = diag.rej
local REJ_P_LIMIT, REJ_P_REQUESTING, REJ_MASK, REJ_SURFACE, REJ_BELOW = REJ_P_AT_LIMIT, REJ_P_IS_REQUESTING,
	REJ_MASK_MISMATCH, REJ_NO_SURFACE_ROUTE, REJ_P_BELOW_THRESHOLD
local REJ_T_MASK, REJ_T_MANUAL, REJ_T_SURFACE = REJ_TRAIN_MASK, REJ_TRAIN_MANUAL, REJ_TRAIN_SURFACE
local REJ_N = REJ_COUNT

-- Diagnostics: the furthest provider check that rejected the current requester, with its provider and payload.
local rej_best = { site = 0, p = nil, a = 0, b = 0 }

--- Counts a provider rejection and keeps the furthest site; among below-threshold providers, the one holding most.
---@param site int REJ_P_*
---@param p_id uint
---@param a number
---@param b number
local function note_rej(site, p_id, a, b)
	diag_rej[site] = diag_rej[site] + 1
	local best = rej_best
	if best.site < site or (best.site == site and (site ~= REJ_BELOW or a > best.a)) then
		best.site, best.p, best.a, best.b = site, p_id, a, b
	end
end

local HASH_STRING = "|"

-- Request tracking functions
-- These functions manage tracking of when item requests started, allowing the GUI
-- to display how long items have been waiting to be delivered. The tracking is:
-- - Started when a station begins requesting an item
-- - Maintained while the request is active (even if deliveries fail)
-- - Cleared when a successful delivery is made or the request stops

---@param station Station
local function init_request_tracking(station)
	if not station.request_start_ticks then
		station.request_start_ticks = {}
	end
end

---@param station Station
---@param item_hash string
local function track_request_start(station, item_hash)
	init_request_tracking(station)
	if not station.request_start_ticks[item_hash] then
		station.request_start_ticks[item_hash] = game.tick
	end
end

---@param station Station
---@param item_hash string
local function clear_request_tracking(station, item_hash)
	if station.request_start_ticks then
		station.request_start_ticks[item_hash] = nil
	end
end

---@param station Station
function clear_all_request_tracking(station)
	station.request_start_ticks = nil
end

--- A request of `stop` went unserved. The station combinator's red S keeps its old meaning (some request of the
--- station failed, whichever combinator made it); an inventory's stop also lights that combinator's own red I.
---@param map_data MapData
---@param station Station
---@param stop StopInfo
local function mark_request_failed(map_data, station, stop)
	local unit = stop.unit
	if unit then
		local failed = station.inv_failed
		if not failed then
			failed = {}
			station.inv_failed = failed
		end
		if not failed[unit] then
			failed[unit] = true
			update_inv_display(map_data, station, unit)
		end
	end
	if band(station.display_state, 2) == 0 then
		station.display_state = station.display_state + 2
		update_display(map_data, station)
	end
end

---@param name string The name of the item
---@param quality string? The name of the quality of the item or nil if it is common
---@return string
function hash_item(name, quality)
	if quality == nil or quality == "normal" then
		return name
	else
		return name .. HASH_STRING .. quality
	end
end

---@param sig SignalID
---@return string
function hash_signal(sig)
	return hash_item(sig.name, sig.quality)
end

---@param hash string
---@return string name, string? quality
function unhash_signal(hash)
	local index = string.find(hash, HASH_STRING)
	if not index then
		return hash, nil
	end

	local name = string.sub(hash, 1, index - 1)
	local quality = string.sub(hash, index + string.len(HASH_STRING), string.len(hash))
	return name, quality
end

---Generate a `Cybersyn.Economy.ItemNetworkName` value.
---@param network_name string Name of the virutal signal prototype identifying the station's network.
---@param item_hash string
---@return Cybersyn.Economy.ItemNetworkName
function create_item_network_name(network_name, item_hash)
	return network_name .. ":" .. item_hash
end

---Extract the network name from an `Cybersyn.Economy.ItemNetworkName` value.
---@param item_network_name Cybersyn.Economy.ItemNetworkName
---@return string
local function get_network_name_from_item_network_name(item_network_name)
	local _, _, network_name = string.find(item_network_name, "^(.-):")
	return network_name
end

---@param item_network_name Cybersyn.Economy.ItemNetworkName
---@return string network_name
---@return string item_name
---@return string? item_quality
function parse_item_network_name(item_network_name)
	local s, e = string.find(item_network_name, ":", 1, true)
	if not (s and e) then
		error(item_network_name.." is no ItemNetworkName")
	end

	local network_name = string.sub(item_network_name, 1, s - 1)
	local item_hash = string.sub(item_network_name, e + 1)
	local item_name, item_quality = unhash_signal(item_hash)

	return network_name, item_name, item_quality
end

---Trains are not allowed to move further than one surface away from their home surface.
---This only checks if the train would be allowed to travel, not if travel is actually possible.
---@param train_surface uint surface index of the train
---@param stop_surface uint surface index of a destination
---@param home_surface uint surface index of the depot
---@return boolean
function is_train_allowed_to_travel(train_surface, stop_surface, home_surface)
	return train_surface == stop_surface
		or home_surface == stop_surface
		or train_surface == home_surface
end

---Deliveries must be on the home surface, from the home surface or to the home surface.
---This only checks if the delivery would be allowed, not if the surfaces are actually connected.
---@param train_surface uint surface index of the train
---@param provider_surface uint surface index of the provider stop
---@param requester_surface uint surface index of the requester stop
---@param home_surface uint surface index of the depot
---@return boolean
function is_delivery_allowed_for_train(train_surface, provider_surface, requester_surface, home_surface)
	if requester_surface == provider_surface then
		-- Same surface deliveries must be pure home surface deliveries.
		-- Otherwise surface_connections won't be calculated and the train would not know how to find home.
		-- This is not a problem because the train is still TO_D_BYPASS.
		-- The state just doesn't take effect for home surface deliveries until the train is back on the home surface.
		return train_surface == requester_surface and home_surface == requester_surface
	end

	if provider_surface == home_surface then -- from the home surface
		return train_surface == home_surface
	end
	if requester_surface == home_surface then -- to the home surface
		return train_surface == provider_surface or train_surface == home_surface
	end
	return false
end

---Checks that the train has a base schedule it can return to after a delivery.
---If it does not, the train is removed from Cybersyn and an alert is generated.
---@param train Train
---@return boolean base_schedule_valid
function validate_train_base_schedule(map_data, train_id, train)
	local schedule = train.entity.get_schedule()
	if schedule.get_record_count() > 0 then return true end

	remove_train(map_data, train_id, train)
	if schedule.group and schedule.group ~= "" then
		send_alert_train_group_base_schedule_broken(map_data, train.entity, schedule.group)
	else
		send_alert_train_base_schedule_broken(map_data, train.entity)
	end
	return false
end

---Move serviced stations to the end of the station polling list.
---@param map_data MapData
---@param p_station_id integer?
---@param r_station_id integer?
local function move_stations_to_end_of_polling_queue(map_data, p_station_id, r_station_id)
	if p_station_id == r_station_id then r_station_id = nil end
	local next_station_ids = {}
	for _, id in ipairs(map_data.active_station_ids) do
		if id ~= p_station_id and id ~= r_station_id then
			table_insert(next_station_ids, id)
		end
	end
	if p_station_id then table_insert(next_station_ids, p_station_id) end
	if r_station_id then table_insert(next_station_ids, r_station_id) end
	map_data.active_station_ids = next_station_ids
end

---@param map_data MapData
---@param station Station
---@param manifest Manifest
---@param sign -1|1
function remove_manifest(map_data, station, manifest, sign)
	local deliveries = station.deliveries
	for i, item in ipairs(manifest) do
		local item_hash = hash_item(item.name, item.quality)
		if deliveries[item_hash] then -- only updates deliveries the station still knows about
			deliveries[item_hash] = deliveries[item_hash] + sign * item.count
			if deliveries[item_hash] == 0 then
				deliveries[item_hash] = nil
			end
		end
	end
	station.deliveries_total = station.deliveries_total - 1
	set_comb2(map_data, station)
	if station.deliveries_total == 0 and band(station.display_state, 1) > 0 then
		station.display_state = station.display_state - 1
		update_display(map_data, station)
	end
end

---@param map_data MapData
---@param r_station_id uint
---@param p_station_id uint
---@param train_id uint
---@param manifest Manifest
---@param surface_connections Cybersyn.SurfaceConnection[]
---@param r_stop StopInfo? the matched requester stop; its networks can differ from the station's
---@param p_stop StopInfo? the matched provider stop
function create_delivery(map_data, r_station_id, p_station_id, train_id, manifest, surface_connections, r_stop, p_stop)
	local economy = map_data.economy
	local r_station = map_data.stations[r_station_id]
	local p_station = map_data.stations[p_station_id]
	local train = map_data.trains[train_id]
	local depot = map_data.depots[train.depot_id]

	if not train.entity.valid then
		on_train_broken(map_data, train_id, train)
		interface_raise_train_dispatch_failed(train_id)
		diag.dispatch_failed(DIAG_DISPATCH_TRAIN_INVALID, train_id, r_station_id, p_station_id, manifest)
		return
	end
	if not depot.entity_stop.valid then
		on_depot_broken(map_data, train.depot_id, depot)
		interface_raise_train_dispatch_failed(train_id)
		diag.dispatch_failed(DIAG_DISPATCH_DEPOT_INVALID, train_id, r_station_id, p_station_id, manifest)
		return
	end
	if not p_station.entity_stop.valid then
		on_station_broken(map_data, p_station_id, p_station)
		interface_raise_train_dispatch_failed(train_id)
		diag.dispatch_failed(DIAG_DISPATCH_PROVIDER_INVALID, train_id, r_station_id, p_station_id, manifest)
		return
	end
	if not r_station.entity_stop.valid then
		on_station_broken(map_data, r_station_id, r_station)
		interface_raise_train_dispatch_failed(train_id)
		diag.dispatch_failed(DIAG_DISPATCH_REQUESTER_INVALID, train_id, r_station_id, p_station_id, manifest)
		return
	end

	local is_at_depot = remove_available_train(map_data, train_id, train)
	--NOTE: we assume that the train is not being teleported at this time
	--NOTE: set_manifest_schedule is allowed to cancel the delivery at the last second if applying the schedule to the train makes it lost and is_at_depot == false
	local dispatched, why = set_manifest_schedule(map_data, train, depot.entity_stop, not train.use_any_depot, p_station.entity_stop, p_station, r_station.entity_stop, r_station, manifest, surface_connections, is_at_depot)
	if dispatched then
		local old_status = train.status
		train.status = STATUS_TO_P
		train.p_station_id = p_station_id
		train.r_station_id = r_station_id
		train.manifest = manifest
		train.last_manifest_tick = map_data.total_ticks
		stats.record_dispatch(train)
		local d = map_data.diag

		r_station.last_delivery_tick = map_data.total_ticks
		p_station.last_delivery_tick = map_data.total_ticks

		r_station.deliveries_total = r_station.deliveries_total + 1
		p_station.deliveries_total = p_station.deliveries_total + 1

		-- Reset request tracking times for delivered items
		-- Also record delivery start for analytics
		local request_start_ticks = r_station.request_start_ticks
		for i, item in ipairs(manifest) do
			local item_hash = hash_item(item.name, item.quality)
			local start_tick = request_start_ticks and request_start_ticks[item_hash]
			local fulfillment_time = start_tick and game.tick - start_tick or nil
			if fulfillment_time then
				stats.record_fulfilment(fulfillment_time, r_station_id, item_hash)
			end
			-- Record delivery start for analytics (only for first item to avoid duplicates)
			if i == 1 then
				analytics.record_delivery_start(map_data, train_id, item_hash, fulfillment_time)
				if d then diag.dispatched(d, train_id, train, r_station_id, p_station_id, manifest, item_hash) end
			end
			clear_request_tracking(r_station, item_hash)
			if d then diag.served(d, r_station_id, item_hash, p_station_id, train_id, train.delivery_id) end
		end

		-- A secondary inventory on a signal-each station carries its own networks, which are the ones it was listed under.
		local r_net = r_stop or r_station
		local p_net = p_stop or p_station
		local r_is_each = r_net.network_name == NETWORK_EACH
		local p_is_each = p_net.network_name == NETWORK_EACH
		for item_i, item in ipairs(manifest) do
			assert(item.count > 0, "main.lua error, transfer amount was not positive")

			local item_hash = hash_item(item.name, item.quality)

			r_station.deliveries[item_hash] = (r_station.deliveries[item_hash] or 0) + item.count
			p_station.deliveries[item_hash] = (p_station.deliveries[item_hash] or 0) - item.count

			if item_i > 1 or r_is_each or p_is_each then
				local f, a
				if r_is_each then
					f, a = pairs(r_net.network_mask --[[@as {[string]: int}]])
					if p_is_each then
						for network_name, _ in f, a do
							local item_network_name = network_name .. ":" .. item_hash
							economy.all_r_stops[item_network_name] = nil
							economy.all_p_stops[item_network_name] = nil
						end
						f, a = pairs(p_net.network_mask --[[@as {[string]: int}]])
					end
				elseif p_is_each then
					f, a = pairs(p_net.network_mask --[[@as {[string]: int}]])
				else
					f, a = once, r_net.network_name
				end
				--prevent deliveries from being processed for these items until their stations are re-polled
				--if we don't wait until they are repolled a duplicate delivery might be generated for stations that share inventories
				for network_name, _ in f, a do
					local item_network_name = network_name .. ":" .. item_hash
					economy.all_r_stops[item_network_name] = nil
					economy.all_p_stops[item_network_name] = nil
				end
			end
		end

		set_comb2(map_data, p_station)
		set_comb2(map_data, r_station)

		p_station.display_state = 1
		update_display(map_data, p_station)
		r_station.display_state = 1
		update_display(map_data, r_station)

		color_train_by_stop(train.entity, p_station.entity_stop)
		interface_raise_train_status_changed(train_id, old_status, STATUS_TO_P)
	else
		interface_raise_train_dispatch_failed(train_id)
		diag.dispatch_failed(why or DIAG_DISPATCH_SCHEDULE_REJECTED, train_id, r_station_id, p_station_id, manifest,
			train.entity.state)
	end
end
---@param map_data MapData
---@param r_stop StopInfo
---@param p_stop StopInfo
---@param train_id uint
---@param primary_item_name string?
function create_manifest(map_data, r_stop, p_stop, train_id, primary_item_name)
	--trains and stations expected to be of the same network
	local r_station = map_data.stations[r_stop.station_id]
	local p_station = map_data.stations[p_stop.station_id]
	local train = map_data.trains[train_id]

	if not train or not train.entity or not train.entity.valid then
		return {} -- train migrated to Factorio 2.0, create_delivery already produces an alert
	end

	---@type Manifest
	local manifest = {}

	local requested = r_stop.requested
	-- An inventory's stop offers every item it is short of; the station combinator's only what it registered.
	local inventory = r_stop.unit ~= nil
	local network_name = r_stop.network_name
	for _, v in pairs(r_stop.tick_signals) do
		---@type string
		local item_name = v.signal.name
		local item_type = v.signal.type or "item"
		local item_hash = item_name and hash_signal(v.signal)
		local wanted = item_hash and item_name ~= network_name and (item_type == "item" or item_type == "fluid")
			and (inventory or requested ~= nil and requested[item_hash] ~= nil)
		local r_item_count = v.count
		local r_effective_adjustment = r_station.enable_manual_inventory and 0 or (r_station.deliveries[item_hash] or 0)
		local r_effective_item_count = r_item_count + r_effective_adjustment
		if wanted and r_effective_item_count < 0 and r_item_count < 0 then
			local r_threshold = get_item_threshold(map_data, r_station, item_hash, item_name, item_type,
				r_stop.r_threshold, r_stop.r_fluid_threshold) --[[@as int]]

			local p_effective_item_count = p_stop.item_p_counts[item_hash]
			--could be an item that is not present at the station
			local effective_threshold
			local override_threshold = get_item_threshold(map_data, p_station, item_hash, item_name, item_type)
			if override_threshold and override_threshold <= r_threshold then
				effective_threshold = override_threshold
			else
				effective_threshold = r_threshold
			end
			if p_effective_item_count and p_effective_item_count >= effective_threshold then
				local item = {
					name = item_name,
					type = item_type,
					quality = v.signal.quality,
					count = min(-r_effective_item_count,
						p_effective_item_count),
				}
				if item_name == primary_item_name then
					manifest[#manifest + 1] = manifest[1]
					manifest[1] = item
				else
					manifest[#manifest + 1] = item
				end
			end
		end
	end

	--locked slots is only taken into account after the train is already approved for dispatch
	local locked_slots = p_station.locked_slots
	local total_item_slots = train.item_slot_capacity
	if locked_slots > 0 and total_item_slots > 0 then
		if mod_settings.locked_slots_per_item then
			-- Each item type loaded needs its own spare slots for surplus to transfer into.
			local item_types = 0
			for _, item in ipairs(manifest) do
				if item.type ~= "fluid" then item_types = item_types + 1 end
			end
			locked_slots = locked_slots * item_types
		end
		-- TODO: possible subtle bug here with modded wagons if locked_slots is
		-- bigger than the number of item slots in one wagon but not another. Might need to look
		-- at individual wagon capacities here.
		local total_cargo_wagons = #train.entity.cargo_wagons
		total_item_slots = max(total_item_slots - total_cargo_wagons * locked_slots, 1)
	end
	-- account for reserved fluid capacity; actual capacity of each wagon is reduced by reserved_fluid_capacity
	local total_liquid_left = train.fluid_capacity
	local reserved_fluid_capacity = p_stop.reserved_fluid_capacity or p_station.reserved_fluid_capacity or 0
	if reserved_fluid_capacity > 0 and total_liquid_left > 0 then
		local total_fluid_wagons = #train.entity.fluid_wagons
		total_liquid_left = max(total_liquid_left - total_fluid_wagons * reserved_fluid_capacity, 1)
	end

	local i = 1
	while i <= #manifest do
		local item = manifest[i]
		local keep_item = false
		if item.type == "fluid" then
			if total_liquid_left > 0 then
				if item.count > total_liquid_left then
					item.count = total_liquid_left
				end
				total_liquid_left = 0 --no liquid merging
				keep_item = true
			end
		elseif total_item_slots > 0 then
			local stack_size = get_stack_size(map_data, item.name)
			local slots = ceil(item.count / stack_size)
			if slots > total_item_slots then
				item.count = total_item_slots * stack_size
			end
			total_item_slots = total_item_slots - slots
			keep_item = true
		end
		if keep_item then
			i = i + 1
		else --swap remove
			manifest[i] = manifest[#manifest]
			manifest[#manifest] = nil
		end
	end

	return manifest
end

local REQUESTER_ALERT_MESSAGE = {
	[DIAG_ALERT_MISSING_TRAIN] = "cybersyn-messages.missing-train",
	[DIAG_ALERT_TRAINS_FILTERED] = "cybersyn-messages.trains-filtered",
	[DIAG_ALERT_NO_TRAIN_HAS_CAPACITY] = "cybersyn-messages.no-train-has-capacity",
	[DIAG_ALERT_NO_TRAIN_MATCHES_R_LAYOUT] = "cybersyn-messages.no-train-matches-r-layout",
	[DIAG_ALERT_NO_TRAIN_MATCHES_P_LAYOUT] = "cybersyn-messages.no-train-matches-p-layout",
}

-- The no-train alerts (NO_TRAINS_ON_NETWORK and TRAIN_FILTERED) are sent once per (item, network) per planner
-- cycle, on the stop of the requester that has waited longest, instead of once per failing requester evaluation:
-- a network short of trains fails every requester of an item on every pass, which flooded the alert list and paid
-- an API call each time. tick_dispatch only notes the evaluation (no API call, no storage.diag read); tick_init
-- sends what the cycle noted.
---@param map_data MapData
---@return {cycle: int, sent: int, keys: {[string]: NoTrainAlert}}
local function alert_dedupe(map_data)
	local ad = map_data.alert_dedupe
	if not ad then
		ad = { cycle = 0, sent = 0, keys = {} }
		map_data.alert_dedupe = ad
	end
	return ad
end

---@param ad {cycle: int, sent: int, keys: {[string]: NoTrainAlert}}
---@param key string item_network_name
---@param code DiagAlert DIAG_ALERT_MISSING_TRAIN or DIAG_ALERT_TRAINS_FILTERED
---@param wait number seconds the requester has waited
local function note_no_train_alert(ad, key, code, r_station_id, p_station_id, wait)
	local e = ad.keys[key]
	if not e then
		e = {}
		ad.keys[key] = e
	end
	if e.cycle ~= ad.cycle or wait > e.wait then
		e.cycle, e.code, e.r_id, e.p_id, e.wait = ad.cycle, code, r_station_id, p_station_id, wait
	end
end

---Sends the alerts the cycle that just ended noted, removing each key's previous alert first so it moves with the
---worst requester instead of piling up, and removes the alerts of keys that no longer fail.
---@param map_data MapData
---@param d DiagState?
local function flush_no_train_alerts(map_data, d)
	local ad = map_data.alert_dedupe
	if not ad then return end
	local cycle = ad.cycle
	local stations = map_data.stations
	-- Every removal comes before any send: an alert is matched by stop and text, and two keys can show the same
	-- text on the same stop, so a later removal would take down an alert just sent for another key.
	for key, e in pairs(ad.keys) do
		local shown = e.shown and stations[e.shown]
		local shown_stop = shown and shown.entity_stop
		if shown_stop and shown_stop.valid then remove_alert_about_missing_train(shown_stop, e.shown_text) end
		e.shown, e.shown_text = nil, nil
		if e.cycle ~= cycle then ad.keys[key] = nil end
	end
	for _, e in pairs(ad.keys) do
		local r, p = stations[e.r_id], stations[e.p_id]
		local r_stop, p_stop = r and r.entity_stop, p and p.entity_stop
		if r_stop and p_stop and r_stop.valid and p_stop.valid then
			e.shown_text = send_alert_about_missing_train(r_stop, p_stop, REQUESTER_ALERT_MESSAGE[e.code])
			e.shown = e.r_id
			e.sent = (e.sent or 0) + 1
			ad.sent = ad.sent + 1
			if d then diag.alert_ids(d, e.code, e.r_id, e.p_id) end
		end
	end
	ad.cycle = cycle + 1
end

---The other requester alerts stay one per failing evaluation; the planner logs them with the ids it holds.
---@param d DiagState?
local function requester_alert(d, code, r_station, p_station, r_station_id, p_station_id)
	send_alert_about_missing_train(r_station.entity_stop, p_station.entity_stop, REQUESTER_ALERT_MESSAGE[code])
	if d then diag.alert_ids(d, code, r_station_id, p_station_id) end
end

---@param map_data MapData
---@param mod_settings CybersynModSettings
local function tick_dispatch(map_data, mod_settings)
	--we do not dispatch more than one train per tick
	--psuedo-randomize what item (and what station) to check first so if trains available is low they choose orders psuedo-randomly
	--NOTE: this is an approximation algorithm for solving the assignment problem (bipartite graph weighted matching), the true solution would be to implement the simplex algorithm but I strongly believe most factorio players would prefer run-time efficiency over perfect train routing logic
	--NOTE: the above isn't even the full story, we can only use one edge per item per tick, which might break the assumptions of the simplex algorithm causing it to give imperfect solutions.

	local all_r_stops = map_data.economy.all_r_stops
	local all_p_stops = map_data.economy.all_p_stops
	local all_names = map_data.economy.all_names
	local stations = map_data.stations
	local d = map_data.diag
	-- The latest provider a requester's evaluation locked in this call (the P_BELOW_THRESHOLD table_remove), its stock
	-- and override threshold: a later requester that finds no provider left is tested against it (diagnostics on only).
	local lock_r, lock_p, lock_stop, lock_count, lock_override

	local r_stops
	local p_stops
	local item_name
	local item_hash
	local item_type
	local item_network_name

	-- Locate an `item_network_name` in the `Economy` that has both requesters and providers on network.
	while true do
		local size = #all_names
		if size == 0 then
			map_data.tick_state = STATE_INIT
			return true
		end

		--randomizing the ordering should only matter if we run out of available trains
		local name_i = size <= 2 and 2 or 2 * random(size / 2)

		item_network_name = all_names[name_i - 1] --[[@as Cybersyn.Economy.ItemNetworkName]]
		local signal = all_names[name_i] --[[@as SignalID]]

		--swap remove
		all_names[name_i - 1] = all_names[size - 1]
		all_names[name_i] = all_names[size]
		all_names[size] = nil
		all_names[size - 1] = nil

		-- Attempt to locate all possible matched pairs of requesters and providers for the given `item_network_name`.
		r_stops = all_r_stops[item_network_name]
		p_stops = all_p_stops[item_network_name]
		if r_stops then
			if p_stops then
				item_name = signal.name --[[@as string]]
				item_hash = hash_signal(signal) --[[@as string]]
				item_type = signal.type or "item"
				break
			else
				-- No matching pairs; update combinator display for all requesters to FAILED_REQUEST state.
				local no_provider_item_hash = hash_signal(signal)
				for i, stop in ipairs(r_stops) do
					local id = stop.station_id
					local station = stations[id]
					if station then
						mark_request_failed(map_data, station, stop)
						-- Record failed dispatch for analytics
						local wait_so_far = 0
						if station.request_start_ticks and station.request_start_ticks[no_provider_item_hash] then
							wait_so_far = (game.tick - station.request_start_ticks[no_provider_item_hash]) / 60
						end
						analytics.record_failed_dispatch(map_data, id, no_provider_item_hash, FAILURE_REASON_NO_PROVIDER_STOCK, wait_so_far, nil, REASON_NO_PROVIDER)
						if d then diag_fail(d, id, no_provider_item_hash, REASON_NO_PROVIDER, 0, 0, nil, nil, nil) end
					end
				end
			end
		end
	end

	while true do
		-- Locate the best matching requester amongst the possible requesters matching the `item_network_name`.
		local r_stop_i = nil
		local best_r_prior = -INF
		local best_timestamp = INF
		for i, stop in ipairs(r_stops) do
			local station = stations[stop.station_id]
			--NOTE: the station at r_station_id could have been deleted and reregistered since last poll, this check here prevents it from being processed for a delivery in that case
			if not station or station.deliveries_total >= station.trains_limit then
				goto continue
			end

			-- Verify station validity
			if (not station.entity_stop) or (not station.entity_stop.valid) then
				goto continue
			end

			--don't request when already providing
			local item_deliveries = station.deliveries[item_hash]
			if item_deliveries and item_deliveries < 0 then
				goto continue
			end

			local prior = stop.priority
			if station.item_priority and station.item_thresholds and station.item_thresholds[item_hash] then
				prior = station.item_priority --[[@as int]]
			end
			if prior < best_r_prior then
				goto continue
			end

			--prioritize by last delivery time if priorities are equal
			if prior == best_r_prior and station.last_delivery_tick > best_timestamp then
				goto continue
			end

			r_stop_i = i
			best_r_prior = prior
			best_timestamp = station.last_delivery_tick
			::continue::
		end

		-- No matching requester found; set all candidate request combinators to FAILED_REQUEST display state.
		if not r_stop_i then
			for _, stop in ipairs(r_stops) do
				local station = stations[stop.station_id]
				if station then mark_request_failed(map_data, station, stop) end
				-- Every requester still listed was skipped by the loop above (evaluated ones were removed).
				if d and station then diag.skipped(d, stop.station_id, station, item_hash) end
			end
			return false
		end

		local r_stop = r_stops[r_stop_i]
		local r_station_id = r_stop.station_id
		local r_station = stations[r_station_id]
		---@type string
		local network_name
		if r_stop.network_name == NETWORK_EACH then
			network_name = get_network_name_from_item_network_name(item_network_name)
		else
			network_name = r_stop.network_name --[[@as string]]
		end
		local trains = map_data.available_trains[network_name]
		local is_fluid = item_type == "fluid"
		local r_threshold = get_item_threshold(map_data, r_station, item_hash, item_name, item_type,
			r_stop.r_threshold, r_stop.r_fluid_threshold) --[[@as int]]
		--no train exists with layout accepted by both provide and request stations
		local correctness = 0
		local closest_to_correct_p_station = nil
		-- Diagnostics (on only): the largest capacity among trains rejected for capacity with the slots they lacked.
		local cap_need, cap_max = 0, -1
		if d then
			for k = 1, REJ_N do diag_rej[k] = 0 end
			rej_best.site, rej_best.p, rej_best.a, rej_best.b = 0, nil, 0, 0
		end

		local r_surface_id = r_station.entity_stop.surface_index

		---@type uint?
		local p_stop_i = nil
		local best_train_id = nil
		local best_p_prior = -INF
		local best_surface_connections = {}
		local best_dist = INF
		--if no available trains in the network, skip search
		---@type uint
		local j = 1
		while j <= #p_stops do
			local p_flag, r_flag, netand, best_p_train_id, best_t_prior, best_capacity, best_t_to_p_dist, effective_count, override_threshold, p_prior, best_p_to_r_dist, effective_threshold, slot_threshold, item_deliveries, surface_connections, p_surface_id

			local p_stop = p_stops[j]
			local p_station = stations[p_stop.station_id]
			if not p_station or p_station.deliveries_total >= p_station.trains_limit then
				if d and p_station then
					note_rej(REJ_P_LIMIT, p_stop.station_id, p_station.deliveries_total, p_station.trains_limit)
				end
				goto p_continue
			end

			--don't provide when already requesting
			item_deliveries = p_station.deliveries[item_hash]
			if item_deliveries and item_deliveries > 0 then
				if d then note_rej(REJ_P_REQUESTING, p_stop.station_id, item_deliveries, 0) end
				goto p_continue
			end

			p_flag = get_network_mask(p_stop, network_name)
			r_flag = get_network_mask(r_stop, network_name)
			netand = band(p_flag, r_flag)
			if netand == 0 then
				if d then note_rej(REJ_MASK, p_stop.station_id, r_flag, p_flag) end
				goto p_continue
			end

			-- Verify provider->requester routability. (NOTE: also check validity because station was just pulled from cache.)
			if not p_station.entity_stop.valid then
				goto p_continue
			end
			p_surface_id = p_station.entity_stop.surface_index

			surface_connections = Surfaces.find_surface_connections_masked(
				p_station.entity_stop.surface_index,
				r_station.entity_stop.surface_index,
				network_name, netand)
			if not surface_connections then
				if d then note_rej(REJ_SURFACE, p_stop.station_id, p_surface_id, r_surface_id) end
				goto p_continue
			end

			effective_count = p_stop.item_p_counts[item_hash] or 0
			override_threshold = get_item_threshold(map_data, p_station, item_hash, item_name, item_type)
			if override_threshold and override_threshold <= r_threshold then
				effective_threshold = override_threshold
			else
				effective_threshold = r_threshold
			end

			if effective_count < effective_threshold then
				--this p station should have serviced the current r station, lock it so it can't serve any others
				--this will lock stations even when the r station manages to find a p station, this not a problem because all stations will be unlocked before it could be an issue
				table_remove(p_stops, j)
				if band(p_station.display_state, 4) == 0 then
					p_station.display_state = p_station.display_state + 4
					update_display(map_data, p_station)
				end
				if d then
					note_rej(REJ_BELOW, p_stop.station_id, effective_count, effective_threshold)
					lock_r, lock_p, lock_stop, lock_count, lock_override =
						r_station_id, p_stop.station_id, p_stop, effective_count, override_threshold
				end
				goto p_continue_remove
			end

			p_prior = p_stop.priority
			if override_threshold and p_station.item_priority then
				p_prior = p_station.item_priority --[[@as int]]
			end
			if p_prior < best_p_prior then
				goto p_continue
			end

			-- get_dist() also handles cross-surface distance by penalizing it
			best_p_to_r_dist =
					p_station.entity_stop.valid and
					r_station.entity_stop.valid and
					(get_dist(p_station.entity_stop, r_station.entity_stop) or INF)
			if p_prior == best_p_prior and best_p_to_r_dist > best_dist then
				goto p_continue
			end

			if is_fluid then
				slot_threshold = effective_threshold
			else
				slot_threshold = ceil(effective_threshold / get_stack_size(map_data, item_name))
			end

			if correctness < 1 then
				correctness = 1
				closest_to_correct_p_station = p_station
			end
			----------------------------------------------------------------
			-- check for valid train
			----------------------------------------------------------------
			---@type uint?
			best_p_train_id = nil
			best_t_prior = -INF
			best_capacity = 0
			best_t_to_p_dist = INF
			best_t_to_r_is_return_home_surface = false
			if d then
				diag_rej[REJ_T_MASK], diag_rej[REJ_T_MANUAL], diag_rej[REJ_T_SURFACE] = 0, 0, 0
			end
			if trains then
				for train_id, _ in pairs(trains) do
					local train = map_data.trains[train_id]
					if not train then
						-- removed train needs cleanup in available_trains
						trains[train_id] = nil
						stats.available_changed(network_name, -1)
						if next(trains) == nil then map_data.available_trains[network_name] = nil end
						goto train_continue
					end

					-- Check if train is on same Cybersyn network.
					local train_flag = get_network_mask(train, network_name)
					if not btest(netand, train_flag) or train.se_is_being_teleported then
						if d then
							if btest(netand, train_flag) then
								diag_rej[REJ_T_SURFACE] = diag_rej[REJ_T_SURFACE] + 1
							else
								diag_rej[REJ_T_MASK] = diag_rej[REJ_T_MASK] + 1
							end
						end
						goto train_continue
					end

					-- Obtain a reference to the rolling stock of the train.
					local train_stock = get_any_train_entity(train.entity)
					if not train_stock or train.entity.manual_mode or not validate_train_base_schedule(map_data, train_id, train) then
						if d then diag_rej[REJ_T_MANUAL] = diag_rej[REJ_T_MANUAL] + 1 end
						goto train_continue
					end

					local t_surface_id = train_stock.surface_index
					if not is_delivery_allowed_for_train(t_surface_id, p_surface_id, r_surface_id, train.depot_surface_id) then
						if d then diag_rej[REJ_T_SURFACE] = diag_rej[REJ_T_SURFACE] + 1 end
						goto train_continue
					end

					if correctness < 2 then
						correctness = 2
						closest_to_correct_p_station = p_station
					end

					--check cargo capabilities
					local capacity = (is_fluid and train.fluid_capacity) or train.item_slot_capacity
					if capacity < slot_threshold then
						--no train with high enough capacity is available
						if d and capacity > cap_max then cap_max, cap_need = capacity, slot_threshold end
						goto train_continue
					end
					if correctness < 3 then
						correctness = 3
						closest_to_correct_p_station = p_station
					end

					--check layout validity for both stations
					local layout_id = train.layout_id
					if not (r_station.allows_all_trains or r_station.accepted_layouts[layout_id]) then
						goto train_continue
					end
					if correctness < 4 then
						correctness = 4
						closest_to_correct_p_station = p_station
					end

					if not (p_station.allows_all_trains or p_station.accepted_layouts[layout_id]) then
						goto train_continue
					end
					if correctness < 5 then
						correctness = 5
						closest_to_correct_p_station = p_station
					end

					if train.priority < best_t_prior then
						goto train_continue
					end

					if train.priority == best_t_prior and capacity < best_capacity then
						goto train_continue
					end

					-- favor trains for which this would be a trip back to their home surface
					local t_to_r_is_return_home_surface =
							r_surface_id ~= t_surface_id and
							r_surface_id == train.depot_surface_id
					if best_t_to_r_is_return_home_surface and not t_to_r_is_return_home_surface then
						goto train_continue
					end

					--check if path is shortest so we prioritize locality
					local t_to_p_dist =
							train_stock and p_station.entity_stop.valid and
							((get_dist(train_stock, p_station.entity_stop) - DEPOT_PRIORITY_MULT * train.priority) or INF)
					if capacity == best_capacity and t_to_p_dist > best_t_to_p_dist then
						goto train_continue
					end

					-- don't interrupt interrupts; the flag is kept by on_train_schedule_changed
					if train.in_interrupt then
						goto train_continue
					end

					best_p_train_id = train_id
					best_capacity = capacity
					best_t_prior = train.priority
					best_t_to_p_dist = t_to_p_dist
					best_t_to_r_is_return_home_surface = t_to_r_is_return_home_surface
					::train_continue::
				end
			end
			if not best_p_train_id then
				goto p_continue
			end

			p_stop_i = j
			best_train_id = best_p_train_id
			best_p_prior = p_prior
			best_surface_connections = surface_connections
			best_dist = best_p_to_r_dist
			::p_continue::
			j = j + 1
			::p_continue_remove::
		end

		if best_train_id then
			local p_stop = p_stops[p_stop_i] --[[@as StopInfo]]
			local p_station_id = p_stop.station_id
			move_stations_to_end_of_polling_queue(map_data, p_station_id, r_station_id)
			local manifest = create_manifest(map_data, r_stop, p_stop, best_train_id, item_name)
			create_delivery(map_data, r_station_id, p_station_id, best_train_id, manifest, best_surface_connections,
				r_stop, p_stop)
			return false
		else
			-- Record failed dispatch for analytics
			local wait_so_far = 0
			if r_station.request_start_ticks and r_station.request_start_ticks[item_hash] then
				wait_so_far = (game.tick - r_station.request_start_ticks[item_hash]) / 60
			end
			local closest_p_id = closest_to_correct_p_station and closest_to_correct_p_station.entity_stop.unit_number
			if closest_to_correct_p_station then
				local closest_id = closest_p_id
				if correctness == 1 then
					-- "Missing train" only when the network has none available; otherwise they were filtered.
					note_no_train_alert(alert_dedupe(map_data), item_network_name,
						trains and next(trains) and DIAG_ALERT_TRAINS_FILTERED or DIAG_ALERT_MISSING_TRAIN, r_station_id, closest_id,
						wait_so_far)
				elseif correctness == 2 then
					requester_alert(d, DIAG_ALERT_NO_TRAIN_HAS_CAPACITY,
						r_station, closest_to_correct_p_station, r_station_id, closest_id)
				elseif correctness == 3 then
					requester_alert(d, DIAG_ALERT_NO_TRAIN_MATCHES_R_LAYOUT,
						r_station, closest_to_correct_p_station, r_station_id, closest_id)
				elseif correctness == 4 then
					requester_alert(d, DIAG_ALERT_NO_TRAIN_MATCHES_P_LAYOUT,
						r_station, closest_to_correct_p_station, r_station_id, closest_id)
				end
			end
			-- The train-side reason is the furthest train check any train passed; correctness 0 means no provider got as
			-- far as the train checks, and only the diagnostics' site counters know which provider check stopped it.
			local failure_reason, reason
			local a, b, lost_to = 0, 0, nil
			local p_station_id = closest_p_id
			if correctness == 0 then
				failure_reason = FAILURE_REASON_NO_PROVIDER_STOCK
				if d then
					if rej_best.site > 0 then
						reason, a, b, p_station_id = REJ_REASON[rej_best.site], rej_best.a, rej_best.b, rej_best.p
					elseif lock_r then
						-- Every provider left was locked by an earlier requester of this call. The latest lock is tested
						-- against this requester's own mask and threshold: only a provider that would have served it was
						-- lost to the other requester. The surface route is not re-tested.
						local p_flag = get_network_mask(lock_stop, network_name)
						local r_flag = get_network_mask(r_stop, network_name)
						local threshold = (lock_override and lock_override <= r_threshold) and lock_override or r_threshold
						p_station_id = lock_p
						if band(p_flag, r_flag) == 0 then
							reason, a, b = REASON_MASK_MISMATCH, r_flag, p_flag
						elseif lock_count < threshold then
							reason, a, b = REASON_P_BELOW_THRESHOLD, lock_count, threshold
						else
							reason, a, b, lost_to = REASON_P_RESERVED, lock_count, threshold, lock_r
						end
					else
						reason = REASON_NO_PROVIDER
					end
				end
			elseif not trains or next(trains) == nil then
				failure_reason, reason = FAILURE_REASON_NO_TRAIN_AVAILABLE, REASON_NO_TRAINS_ON_NETWORK
			elseif correctness == 1 then
				failure_reason, reason = FAILURE_REASON_NO_TRAIN_AVAILABLE, REASON_TRAIN_FILTERED
			elseif correctness == 2 then
				failure_reason, reason = FAILURE_REASON_TRAIN_CAPACITY, REASON_CAPACITY
			elseif correctness == 3 then
				failure_reason, reason = FAILURE_REASON_LAYOUT_MISMATCH, REASON_R_LAYOUT
			elseif correctness == 4 then
				failure_reason, reason = FAILURE_REASON_LAYOUT_MISMATCH, REASON_P_LAYOUT
			else
				-- Every usable train is inside an interrupt, which is not a layout mismatch.
				failure_reason, reason = FAILURE_REASON_NO_TRAIN_AVAILABLE, REASON_ALL_IN_INTERRUPT
			end
			analytics.record_failed_dispatch(map_data, r_station_id, item_hash, failure_reason, wait_so_far, closest_p_id, reason)
			if d then
				if reason == REASON_NO_TRAINS_ON_NETWORK then
					b = diag.fleet_size(network_name)
				elseif reason == REASON_TRAIN_FILTERED then
					a = diag_rej[REJ_T_MASK] + diag_rej[REJ_T_MANUAL] + diag_rej[REJ_T_SURFACE]
				elseif reason == REASON_CAPACITY then
					a, b = cap_need, max(cap_max, 0)
				end
				diag_fail(d, r_station_id, item_hash, reason, a, b, p_station_id, diag_rej, lost_to)
			end
			mark_request_failed(map_data, r_station, r_stop)
		end

		table_remove(r_stops, r_stop_i)
	end
end
--- Reads a combinator's settings signals into `t`: the station for its station combinator, the stop for an inventory
--- combinator. Locked slots come from the station combinator only; on NETWORK_EACH every other virtual signal is a
--- network.
---@param t Station|StopInfo
---@param signals Signal[]
---@param is_each boolean
---@param primary boolean
local function read_settings(t, signals, is_each, primary)
	local network_name = t.network_name
	for _, v in pairs(signals) do
		local signal = v.signal
		local item_name = signal.name
		if item_name then
			local item_count = v.count
			if signal.type == "virtual" then
				if item_name == SIGNAL_PRIORITY then
					t.priority = item_count
				elseif item_name == REQUEST_THRESHOLD then
					--NOTE: thresholds must be >0 or they can cause a crash
					t.r_threshold = abs(item_count)
				elseif item_name == REQUEST_FLUID_THRESHOLD then
					t.r_fluid_threshold = abs(item_count)
				elseif item_name == LOCKED_SLOTS then
					if primary then t.locked_slots = max(item_count, 0) end
				elseif item_name == RESERVED_FLUID_CAPACITY then
					t.reserved_fluid_capacity = max(item_count, 0)
				elseif is_each then
					t.network_mask[item_name] = item_count
				end
			end
			if item_name == network_name then
				t.network_mask = item_count
			end
		end
	end
end

--- Registers a stop's items on its networks: requested when the count and the count after in-flight deliveries both
--- reach the threshold, else provided when both are positive. tick_signals stays as read: create_manifest and the
--- manager skip what the stop did not register.
---@param map_data MapData
---@param station Station
---@param stop StopInfo
---@param inv_requested {[string]: true}? station combinator's stop only: items an inventory requests, whose waits stay
---@return {[string]: int}? requested item hash -> threshold, also kept as stop.requested
local function register_items(map_data, station, stop, inv_requested)
	local economy = map_data.economy
	local all_r_stops, all_p_stops, all_names = economy.all_r_stops, economy.all_p_stops, economy.all_names
	local is_r, is_p = station.is_r, station.is_p
	local deliveries = not station.enable_manual_inventory and station.deliveries or nil
	local network_name, network_mask = stop.network_name, stop.network_mask
	local base_item, base_fluid = stop.r_threshold, stop.r_fluid_threshold
	local item_p_counts = stop.item_p_counts
	local primary = stop.unit == nil
	---@type {[string]: int}?
	local requested = nil
	for _, v in pairs(stop.tick_signals) do
		local signal = v.signal
		local item_name = signal.name
		local item_type = signal.type or "item"
		if item_name and item_name ~= network_name and (item_type == "item" or item_type == "fluid") then
			local item_hash = hash_signal(signal)
			local item_count = v.count
			local effective_item_count = item_count + (deliveries and deliveries[item_hash] or 0)
			-- Only a negative count can pass the threshold test, so a provided item skips the lookup.
			local r_threshold = is_r and item_count < 0 and get_item_threshold(map_data, station, item_hash, item_name,
				item_type, base_item, base_fluid)
			if r_threshold and -effective_item_count >= r_threshold and -item_count >= r_threshold then
				if not requested then requested = {} end
				requested[item_hash] = r_threshold
				track_request_start(station, item_hash)
				local f, a
				if network_name == NETWORK_EACH then
					f, a = pairs(network_mask --[[@as {[string]: int}]])
				else
					f, a = once, network_name
				end
				for net, _ in f, a do
					-- `item_hash` used here since matching algorithm should only match same quality.
					local item_network_name = create_item_network_name(net, item_hash)
					local stops = all_r_stops[item_network_name]
					if stops == nil then
						stops = {}
						all_r_stops[item_network_name] = stops
						all_names[#all_names + 1] = item_network_name
						all_names[#all_names + 1] = signal
					end
					stops[#stops + 1] = stop
				end
			else
				if is_r and primary and not (inv_requested and inv_requested[item_hash]) then
					clear_request_tracking(station, item_hash)
				end
				if is_p and effective_item_count > 0 and item_count > 0 then
					local f, a
					if network_name == NETWORK_EACH then
						f, a = pairs(network_mask --[[@as {[string]: int}]])
					else
						f, a = once, network_name
					end
					for net, _ in f, a do
						local item_network_name = create_item_network_name(net, item_hash)
						local stops = all_p_stops[item_network_name]
						if stops == nil then
							stops = {}
							all_p_stops[item_network_name] = stops
						end
						stops[#stops + 1] = stop
						item_p_counts[item_hash] = effective_item_count
					end
				end
			end
		end
	end
	if requested then stop.requested = requested end
	return requested
end

---@param map_data MapData
---@param mod_settings CybersynModSettings
local function tick_poll_station(map_data, mod_settings)
	local tick_data = map_data.tick_data
	local d = map_data.diag
	local all_r_stops = map_data.economy.all_r_stops
	local all_p_stops = map_data.economy.all_p_stops
	local all_names = map_data.economy.all_names

	local station_id
	local station
	while true do --choose a station
		tick_data.i = (tick_data.i or 0) + 1
		if tick_data.i > #map_data.active_station_ids then
			tick_data.i = nil
			-- For the manager, once per cycle: the economy is complete only now, and dispatch consumes all_names.
			local starved = {}
			for i = 1, #all_names, 2 do
				local key = all_names[i]
				if not all_p_stops[key] then starved[key] = true end
			end
			map_data.economy.starved = starved
			map_data.tick_state = STATE_DISPATCH
			return true
		end
		station_id = map_data.active_station_ids[tick_data.i]
		station = map_data.stations[station_id]
		if station and not station.is_warming_up then
			if station.network_name then
				break
			end
		else
			--lazy delete removed stations
			table_remove(map_data.active_station_ids, tick_data.i)
			tick_data.i = tick_data.i - 1
		end
	end
	if station.entity_stop.valid and station.entity_comb1.valid and (not station.entity_comb2 or station.entity_comb2.valid) then
		local old_limit = station.trains_limit
		station.trains_limit = station.entity_stop.trains_limit
		-- math.huge is the placeholder a station has until its first poll.
		if d and old_limit ~= station.trains_limit and old_limit ~= INF then
			diag.station_limit(d, station_id, old_limit, station.trains_limit)
		end
	else
		on_station_broken(map_data, station_id, station)
		return false
	end
	station.r_threshold = mod_settings.r_threshold
	if mod_settings.r_fluid_threshold > 0 then
		station.r_fluid_threshold = mod_settings.r_fluid_threshold
	else
		station.r_fluid_threshold = nil
	end
	station.priority = mod_settings.priority
	station.item_priority = nil
	station.locked_slots = mod_settings.locked_slots
	station.reserved_fluid_capacity = mod_settings.reserved_fluid_capacity
	local is_each = station.network_name == NETWORK_EACH
	if is_each then
		station.network_mask = {}
	else
		station.network_mask = mod_settings.network_mask
	end
	local comb1_signals, comb2_signals, secondary_inv_signals, comb1_working = get_signals(station)
	if d and (d.unpowered[station_id] == true) == comb1_working then
		diag.station_power(d, station_id, comb1_working)
	end
	station.primary_stop = nil
	station.inv_stops = nil
	-- Without station combinator input the poll ignores the control combinator and keeps stale item thresholds.
	station.comb2_signals = comb1_signals and comb2_signals

	-- The S clears when the whole station requests nothing; each inventory's I when that inventory does.
	local is_requesting_nothing = true
	---@type {[uint]: true}?
	local inv_requesting = nil
	if comb1_signals then
		if comb2_signals then
			station.item_thresholds = {}
			for k, v in pairs(comb2_signals) do
				local item_name = v.signal.name
				local item_hash = hash_signal(v.signal)
				local item_count = v.count
				local item_type = v.signal.type or "item"
				if item_name then
					if item_type == "virtual" then
						if item_name == SIGNAL_PRIORITY then
							station.item_priority = item_count
						end
					else
						station.item_thresholds[item_hash] = abs(item_count)
					end
				end
			end
		else
			station.item_thresholds = nil
		end
		read_settings(station, comb1_signals, is_each, true)

		-- Hashes an inventory combinator requests this poll. The station combinator's pass below and the cleanup after it
		-- must not clear their waits; nil at a station without inventory requests, so those poll exactly as before.
		---@type {[string]: true}?
		local inv_requested = nil

		if secondary_inv_signals then
			local inv_stops = {}
			station.inv_stops = inv_stops
			for unit_number, signals in pairs(secondary_inv_signals) do
				---@type StopInfo
				local stop = {
					station_id = station_id,
					unit = unit_number,
					tick_signals = signals,
					network_name = station.network_name,
					network_mask = is_each and {} or station.network_mask,
					priority = station.priority,
					r_threshold = station.r_threshold,
					r_fluid_threshold = station.r_fluid_threshold,
					reserved_fluid_capacity = station.reserved_fluid_capacity,
					item_p_counts = {},
				}
				read_settings(stop, signals, is_each, false)
				inv_stops[unit_number] = stop
				local requested = register_items(map_data, station, stop, nil)
				if requested then
					is_requesting_nothing = false
					if not inv_requesting then inv_requesting = {} end
					inv_requesting[unit_number] = true
					if not inv_requested then inv_requested = {} end
					for item_hash in pairs(requested) do inv_requested[item_hash] = true end
				end
			end
		end

		---@type StopInfo
		local stop = {
			station_id = station_id,
			tick_signals = comb1_signals,
			network_name = station.network_name,
			network_mask = station.network_mask,
			priority = station.priority,
			r_threshold = station.r_threshold,
			r_fluid_threshold = station.r_fluid_threshold,
			item_p_counts = {},
		}
		station.primary_stop = stop
		local requested = register_items(map_data, station, stop, inv_requested)
		if requested then is_requesting_nothing = false end

		local start_ticks = station.request_start_ticks
		if start_ticks and next(start_ticks) then
			local requested_items = inv_requested or {}
			if requested then
				for item_hash in pairs(requested) do requested_items[item_hash] = true end
			end
			for item_hash in pairs(start_ticks) do
				if not requested_items[item_hash] then
					clear_request_tracking(station, item_hash)
				end
			end
			if not next(requested_items) then
				clear_all_request_tracking(station)
			end
		end
	end
	local inv_failed = station.inv_failed
	if inv_failed then
		for unit in pairs(inv_failed) do
			if not (inv_requesting and inv_requesting[unit]) then
				inv_failed[unit] = nil
				update_inv_display(map_data, station, unit)
			end
		end
		if not next(inv_failed) then station.inv_failed = nil end
	end
	-- Update the graphic of the station combinator based on the result of polling the station.
	if station.display_state > 1 then
		if is_requesting_nothing and band(station.display_state, 2) > 0 then
			station.display_state = station.display_state - 2
			update_display(map_data, station)
		end
		if band(station.display_state, 8) > 0 then
			if band(station.display_state, 4) > 0 then
				station.display_state = station.display_state - 4
			else
				station.display_state = station.display_state - 8
				update_display(map_data, station)
			end
		elseif band(station.display_state, 4) > 0 then
			station.display_state = station.display_state + 4
		end
	end
	return false
end
---@param map_data MapData
---@param mod_settings CybersynModSettings
function tick_poll_entities(map_data, mod_settings)
	local tick_data = map_data.tick_data

	if map_data.total_ticks % 5 == 0 then
		local tick = game.tick
		if tick_data.last_train == nil or map_data.trains[tick_data.last_train] then
			local train_id, train = next(map_data.trains, tick_data.last_train)
			tick_data.last_train = train_id
			if train and not train.se_is_being_teleported then
				if (not train.entity or not train.entity.valid) then
					game.print(
						"Cybersyn: Lost track of invalid train after migration. You need to check for lost trains manually. You might get a few of these messages.")
					stats.train_networks_changed(train, -1)
					map_data.trains[train_id] = nil
					return
				end

				if train.manifest and not train.se_is_being_teleported and train.last_manifest_tick + mod_settings.stuck_train_time * mod_settings.tps < map_data.total_ticks then
					if mod_settings.stuck_train_alert_enabled then
						send_alert_stuck_train(map_data, train.entity)
					end
					interface_raise_train_stuck(train_id)
				elseif train.status == STATUS_TO_D_BYPASS and tick >= (train.skip_path_checks_until or 0) then
					add_available_train(map_data, train_id, train)
				end
			end
		else
			tick_data.last_train = nil
		end

		if tick_data.last_refueler == nil or map_data.each_refuelers[tick_data.last_refueler] then
			local refueler_id, _ = next(map_data.each_refuelers, tick_data.last_refueler)
			tick_data.last_refueler = refueler_id
			if refueler_id then
				local refueler = map_data.refuelers[refueler_id]
				if refueler.entity_stop.valid and refueler.entity_comb.valid then
					set_refueler_from_comb(map_data, mod_settings, refueler_id, refueler)
				else
					on_refueler_broken(map_data, refueler_id, refueler)
				end
			end
		else
			tick_data.last_refueler = nil
		end
	else
		if tick_data.last_comb == nil or map_data.to_comb[tick_data.last_comb] then
			local comb_id, comb = next(map_data.to_comb, tick_data.last_comb)
			tick_data.last_comb = comb_id
			if comb then
				if comb.valid then
					combinator_update(map_data, comb, true)
				else
					map_data.to_comb[comb_id] = nil
				end
			end
		else
			tick_data.last_comb = nil
		end
	end
end
---@param map_data MapData
---@param mod_settings CybersynModSettings
function tick_init(map_data, mod_settings)
	map_data.economy.all_p_stops = {}
	map_data.economy.all_r_stops = {}
	map_data.economy.all_names = {}
	local d = map_data.diag

	-- Finishing a warm-up raises events whose handlers may build stations, which would add keys to
	-- warmup_station_cycles while pairs() walks it; the finished ones are handled after the walk.
	local warmed_up = nil
	for id, cycles in pairs(map_data.warmup_station_cycles) do
		local station = map_data.stations[id]
		if station then
			--force a station to wait at least 1 cycle so we can be sure active_station_ids was flushed of duplicates
			if cycles > 0 then
				if station.entity_stop and station.entity_stop.valid and station.entity_stop.connected_rail == nil then
					goto warmup_continue -- Wait for station to be connected to a rail
				end

				if station.last_delivery_tick + mod_settings.warmup_time * mod_settings.tps < map_data.total_ticks then
					map_data.warmup_station_cycles[id] = nil
					if not warmed_up then warmed_up = {} end
					warmed_up[#warmed_up + 1] = id
				end
			else
				map_data.warmup_station_cycles[id] = cycles + 1
			end
		else
			map_data.warmup_station_cycles[id] = nil
		end
		::warmup_continue::
	end
	if warmed_up then
		for _, id in ipairs(warmed_up) do
			local station = map_data.stations[id]
			-- Skip one that an earlier station's events removed, or rebuilt into a fresh warm-up.
			if station and map_data.warmup_station_cycles[id] == nil then
				station.is_warming_up = nil
				map_data.active_station_ids[#map_data.active_station_ids + 1] = id
				if d then diag.station_warmup_done(d, id) end
				if station.entity_stop.valid and station.entity_comb1.valid then
					combinator_update(map_data, station.entity_comb1)
				else
					on_station_broken(map_data, id, station)
				end
			end
		end
	end

	if map_data.queue_station_update then
		for id, _ in pairs(map_data.queue_station_update) do
			local station = map_data.stations[id]
			if station then
				local pre = station.allows_all_trains
				if station.entity_comb1.valid then
					set_station_from_comb(station)
					if station.allows_all_trains ~= pre then
						update_stop_if_auto(map_data, station, true)
					end
				else
					on_station_broken(map_data, id, station)
				end
			end
		end
		map_data.queue_station_update = nil
	end

	flush_no_train_alerts(map_data, d)
	stats.cycle_start(game.tick)
	diag.cycle()
	map_data.tick_state = STATE_POLL_STATIONS
	interface_raise_tick_init()
end
---@param map_data MapData
---@param mod_settings CybersynModSettings
function tick(map_data, mod_settings)
	map_data.total_ticks = map_data.total_ticks + 1

	if map_data.active_alerts then
		if map_data.total_ticks % (8 * mod_settings.tps) < 1 then
			process_active_alerts(map_data)
		end
	end

	tick_poll_entities(map_data, mod_settings)

	if mod_settings.enable_planner then
		if map_data.tick_state == STATE_INIT then
			tick_init(map_data, mod_settings)
		end

		if map_data.tick_state == STATE_POLL_STATIONS then
			for i = 1, mod_settings.update_rate do
				if tick_poll_station(map_data, mod_settings) then break end
			end
		elseif map_data.tick_state == STATE_DISPATCH then
			local calls = 0
			for i = 1, mod_settings.update_rate do
				calls = i
				if tick_dispatch(map_data, mod_settings) then break end
			end
			stats.count_calls(calls)
		end
	else
		map_data.tick_state = STATE_INIT
	end
end

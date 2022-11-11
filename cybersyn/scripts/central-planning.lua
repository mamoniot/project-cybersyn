--By Mami
local get_distance = require("__flib__.misc").get_distance
local min = math.min
local max = math.max
local abs = math.abs
local ceil = math.ceil
local INF = math.huge
local btest = bit32.btest
local band = bit32.band
local table_remove = table.remove
local table_sort = table.sort
local random = math.random


---@param stop0 LuaEntity
---@param stop1 LuaEntity
local function get_stop_dist(stop0, stop1)
	return get_distance(stop0.position, stop1.position)
end


---@param map_data MapData
---@param station Station
---@param manifest Manifest
function remove_manifest(map_data, station, manifest, sign)
	local deliveries = station.deliveries
	for i, item in ipairs(manifest) do
		deliveries[item.name] = deliveries[item.name] + sign*item.count
		if deliveries[item.name] == 0 then
			deliveries[item.name] = nil
		end
	end
	set_comb2(map_data, station)
	station.deliveries_total = station.deliveries_total - 1
end

---@param map_data MapData
---@param r_station_id uint
---@param p_station_id uint
---@param item_type string
---@param min_slots_to_move int
local function get_valid_train(map_data, r_station_id, p_station_id, item_type, min_slots_to_move)
	--NOTE: this code is the critical section for run-time optimization
	local r_station = map_data.stations[r_station_id]
	local p_station = map_data.stations[p_station_id]
	---@type string
	local network_name = p_station.network_name

	local p_to_r_dist = get_stop_dist(p_station.entity_stop, r_station.entity_stop)
	local netand = band(p_station.network_flag, r_station.network_flag)
	if p_to_r_dist == INF or netand == 0 then
		return nil, INF
	end

	---@type Depot|nil
	local best_depot = nil
	local best_capacity = 0
	local best_dist = INF
	local valid_train_exists = false

	local is_fluid = item_type == "fluid"
	local trains = map_data.trains_available[network_name]
	if trains then
		for train_id, depot_id in pairs(trains) do
			local depot = map_data.depots[depot_id]
			local train = map_data.trains[train_id]
			local layout_id = train.layout_id
			--check cargo capabilities
			--check layout validity for both stations
			local capacity = (is_fluid and train.fluid_capacity) or train.item_slot_capacity
			if
			capacity >= min_slots_to_move and
			btest(netand, depot.network_flag) and
			(r_station.allows_all_trains or r_station.accepted_layouts[layout_id]) and
			(p_station.allows_all_trains or p_station.accepted_layouts[layout_id])
			then
				valid_train_exists = true
				--check if exists valid path
				--check if path is shortest so we prioritize locality
				local d_to_p_dist = get_stop_dist(depot.entity_stop, p_station.entity_stop) - DEPOT_PRIORITY_MULT*depot.priority

				local dist = d_to_p_dist
				if capacity > best_capacity or (capacity == best_capacity and dist < best_dist) then
					best_capacity = capacity
					best_dist = dist
					best_depot = depot
				end
			end
		end
	end

	if valid_train_exists then
		return best_depot, best_dist + p_to_r_dist
	else
		return nil, p_to_r_dist
	end
end


---@param map_data MapData
---@param r_station_id uint
---@param p_station_id uint
---@param depot Depot
---@param primary_item_name string
local function send_train_between(map_data, r_station_id, p_station_id, depot, primary_item_name)
	--trains and stations expected to be of the same network
	local economy = map_data.economy
	local r_station = map_data.stations[r_station_id]
	local p_station = map_data.stations[p_station_id]
	local train = map_data.trains[depot.available_train]
	---@type string
	local network_name = depot.network_name

	local manifest = {}

	for k, v in pairs(r_station.tick_signals) do
		---@type string
		local item_name = v.signal.name
		local item_type = v.signal.type
		local r_item_count = v.count
		local r_effective_item_count = r_item_count + (r_station.deliveries[item_name] or 0)
		if r_effective_item_count < 0 and r_item_count < 0 then
			local r_threshold = r_station.p_count_or_r_threshold_per_item[item_name]
			local p_effective_item_count = p_station.p_count_or_r_threshold_per_item[item_name]
			if p_effective_item_count and p_effective_item_count >= r_threshold then
				local item = {name = item_name, type = item_type, count = min(-r_effective_item_count, p_effective_item_count)}
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
	local total_slots_left = train.item_slot_capacity
	if locked_slots > 0 then
		local total_cw = #train.entity.cargo_wagons
		total_slots_left = min(total_slots_left, max(total_slots_left - total_cw*locked_slots, total_cw))
	end
	local total_liquid_left = train.fluid_capacity

	local i = 1
	while i <= #manifest do
		local item = manifest[i]
		local keep_item = false
		if item.type == "fluid" then
			if total_liquid_left > 0 then
				if item.count > total_liquid_left then
					item.count = total_liquid_left
				end
				total_liquid_left = 0--no liquid merging
				keep_item = true
			end
		elseif total_slots_left > 0 then
			local stack_size = get_stack_size(map_data, item.name)
			local slots = ceil(item.count/stack_size)
			if slots > total_slots_left then
				item.count = total_slots_left*stack_size
			end
			total_slots_left = total_slots_left - slots
			keep_item = true
		end
		if keep_item then
			i = i + 1
		else--swap remove
			manifest[i] = manifest[#manifest]
			manifest[#manifest] = nil
		end
	end

	r_station.last_delivery_tick = map_data.total_ticks
	p_station.last_delivery_tick = map_data.total_ticks

	r_station.deliveries_total = r_station.deliveries_total + 1
	p_station.deliveries_total = p_station.deliveries_total + 1

	for item_i, item in ipairs(manifest) do
		assert(item.count > 0, "main.lua error, transfer amount was not positive")

		r_station.deliveries[item.name] = (r_station.deliveries[item.name] or 0) + item.count
		p_station.deliveries[item.name] = (p_station.deliveries[item.name] or 0) - item.count

		if item_i > 1 then
			local item_network_name = network_name..":"..item.name
			local r_stations = economy.all_r_stations[item_network_name]
			local p_stations = economy.all_p_stations[item_network_name]
			if r_stations then
				for j, id in ipairs(r_stations) do
					if id == r_station_id then
						table_remove(r_stations, j)
						break
					end
				end
			end
			if p_stations then
				for j, id in ipairs(p_stations) do
					if id == p_station_id then
						table_remove(p_stations, j)
						break
					end
				end
			end
		end
	end

	remove_available_train(map_data, depot)
	train.status = STATUS_D_TO_P
	train.p_station_id = p_station_id
	train.r_station_id = r_station_id
	train.manifest = manifest

	train.entity.schedule = create_manifest_schedule(train.depot_name, p_station.entity_stop, r_station.entity_stop, manifest)
	set_comb2(map_data, p_station)
	set_comb2(map_data, r_station)
	if p_station.entity_comb1.valid then
		set_combinator_operation(p_station.entity_comb1, OPERATION_PRIMARY_IO_ACTIVE)
	end
	if r_station.entity_comb1.valid then
		set_combinator_operation(r_station.entity_comb1, OPERATION_PRIMARY_IO_ACTIVE)
	end
end


---@param map_data MapData
local function tick_poll_depot(map_data)
	local depot_id
	do--get next depot id
		local tick_data = map_data.tick_data
		while true do
			if tick_data.network == nil then
				tick_data.network_name, tick_data.network = next(map_data.trains_available, tick_data.network_name)
				if tick_data.network == nil then
					tick_data.train_id = nil
					map_data.tick_state = STATE_POLL_STATIONS
					return true
				end
			end

			tick_data.train_id, depot_id = next(tick_data.network, tick_data.train_id)
			if depot_id then
				break
			else
				tick_data.network = nil
			end
		end
	end

	local depot = map_data.depots[depot_id]
	local comb = depot.entity_comb
	if depot.network_name and comb.valid and (comb.status == defines.entity_status.working or comb.status == defines.entity_status.low_power) then
		depot.priority = 0
		depot.network_flag = 1
		local signals = comb.get_merged_signals(defines.circuit_connector_id.combinator_input)
		if signals then
			for k, v in pairs(signals) do
				local item_name = v.signal.name
				local item_count = v.count
				if item_name then
					if item_name == SIGNAL_PRIORITY then
						depot.priority = item_count
					end
					if item_name == depot.network_name then
						depot.network_flag = item_count
					end
				end
			end
		end
	else
		depot.priority = 0
		depot.network_flag = 0
	end
	return false
end
---@param map_data MapData
---@param mod_settings CybersynModSettings
local function tick_poll_station(map_data, mod_settings)
	local tick_data = map_data.tick_data
	local all_r_stations = map_data.economy.all_r_stations
	local all_p_stations = map_data.economy.all_p_stations
	local all_names = map_data.economy.all_names

	while true do
		local station_id, station = next(map_data.stations, tick_data.station_id)
		tick_data.station_id = station_id
		if station == nil then
			map_data.tick_state = STATE_DISPATCH
			return true
		end
		if station.display_update then
			update_combinator_display(station.entity_comb1, station.display_failed_request)
			station.display_update = station.display_failed_request
			station.display_failed_request = nil
		end

		if station.network_name and station.deliveries_total < station.entity_stop.trains_limit then
			station.r_threshold = mod_settings.r_threshold
			station.priority = 0
			station.locked_slots = 0
			station.network_flag = mod_settings.network_flag
			local signals = get_signals(station)
			station.tick_signals = signals
			table_clear(station.p_count_or_r_threshold_per_item)
			if signals then
				for k, v in pairs(signals) do
					local item_name = v.signal.name
					local item_count = v.count
					local item_type = v.signal.type
					if item_name then
						if item_type == "virtual" then
							if item_name == SIGNAL_PRIORITY then
								station.priority = item_count
							elseif item_name == REQUEST_THRESHOLD and item_count ~= 0 then
								--NOTE: thresholds must be >0 or they can cause a crash
								station.r_threshold = abs(item_count)
							elseif item_name == LOCKED_SLOTS then
								station.locked_slots = max(item_count, 0)
							end
							signals[k] = nil
						end
						if item_name == station.network_name then
							station.network_flag = item_count
						end
					else
						signals[k] = nil
					end
				end
				for k, v in pairs(signals) do
					---@type string
					local item_name = v.signal.name
					local item_count = v.count
					local effective_item_count = item_count + (station.deliveries[item_name] or 0)
					local r_threshold = get_threshold(map_data, station, v.signal)

					if station.is_r and -effective_item_count >= r_threshold and -item_count >= r_threshold then
						local item_network_name = station.network_name..":"..item_name
						local stations = all_r_stations[item_network_name]
						if stations == nil then
							stations = {}
							all_r_stations[item_network_name] = stations
							all_names[#all_names + 1] = item_network_name
							all_names[#all_names + 1] = v.signal
						end
						stations[#stations + 1] = station_id
						station.p_count_or_r_threshold_per_item[item_name] = r_threshold
					elseif station.is_p and effective_item_count > 0 and item_count > 0 then
						local item_network_name = station.network_name..":"..item_name
						local stations = all_p_stations[item_network_name]
						if stations == nil then
							stations = {}
							all_p_stations[item_network_name] = stations
						end
						stations[#stations + 1] = station_id
						station.p_count_or_r_threshold_per_item[item_name] = effective_item_count
					else
						signals[k] = nil
					end
				end
			end
			return false
		end
	end
end
---@param map_data MapData
---@param mod_settings CybersynModSettings
local function tick_dispatch(map_data, mod_settings)
	--we do not dispatch more than one train per tick
	--psuedo-randomize what item (and what station) to check first so if trains available is low they choose orders psuedo-randomly
	--NOTE: It may be better for performance to update stations one tick at a time rather than all at once, however this does mean more  redundant data will be generated and discarded each tick. Once we have a performance test-bed it will probably be worth checking.
	--NOTE: this is an approximation algorithm for solving the assignment problem (bipartite graph weighted matching), the true solution would be to implement the simplex algorithm but I strongly believe most factorio players would prefer run-time efficiency over perfect train routing logic
	local tick_data = map_data.tick_data
	local all_r_stations = map_data.economy.all_r_stations
	local all_p_stations = map_data.economy.all_p_stations
	local all_names = map_data.economy.all_names
	local stations = map_data.stations

	local r_stations = tick_data.r_stations
	local p_stations = tick_data.p_stations
	if not (p_stations and #r_stations > 0 and #p_stations > 0) then
		while true do
			local size = #all_names
			if size == 0 then
				tick_data.r_stations = nil
				tick_data.p_stations = nil
				tick_data.item_name = nil
				tick_data.item_type = nil
				map_data.tick_state = STATE_INIT
				return true
			end

			--randomizing the ordering should only matter if we run out of available trains
			local name_i = size <= 2 and 2 or 2*random(size/2)
			local item_network_name = all_names[name_i - 1]
			local signal = all_names[name_i]
			--swap remove
			all_names[name_i - 1] = all_names[size - 1]
			all_names[name_i] = all_names[size]
			all_names[size] = nil
			all_names[size - 1] = nil

			r_stations = all_r_stations[item_network_name]
			p_stations = all_p_stations[item_network_name]
			if p_stations then
				tick_data.r_stations = r_stations
				tick_data.p_stations = p_stations
				tick_data.item_name = signal.name
				tick_data.item_type = signal.type
				table_sort(r_stations, function(a_id, b_id)
					local a = stations[a_id]
					local b = stations[b_id]
					if a and b then
						if a.priority ~= b.priority then
							return a.priority < b.priority
						else
							return a.last_delivery_tick > b.last_delivery_tick
						end
					else
						return a == nil
					end
				end)
				break
			else
				for i, id in ipairs(r_stations) do
					local station = stations[id]
					if station then
						station.display_failed_request = true
						station.display_update = true
					end
				end
			end
		end
	end

	local r_station_id = table_remove(r_stations--[[@as uint[] ]])
	local r_station = stations[r_station_id]
	if r_station then
		local item_name = tick_data.item_name
		local item_type = tick_data.item_type
		local r_threshold = r_station.p_count_or_r_threshold_per_item[item_name]

		local best = 0
		local best_depot = nil
		local best_dist = INF
		local highest_prior = -INF
		local could_have_been_serviced = false
		for j, p_station_id in ipairs(p_stations) do
			local p_station = stations[p_station_id]
			if p_station and p_station.p_count_or_r_threshold_per_item[item_name] >= r_threshold then
				local prior = p_station.priority
				local slot_threshold = item_type == "fluid" and r_threshold or ceil(r_threshold/get_stack_size(map_data, item_name))
				local depot, d = get_valid_train(map_data, r_station_id, p_station_id, item_type, slot_threshold)
				if prior > highest_prior or (prior == highest_prior and d < best_dist) then
					if depot then
						best = j
						best_dist = d
						best_depot = depot
						highest_prior = prior
					elseif d < INF then
						could_have_been_serviced = true
						best = j
					end
				end
			end
		end
		if best_depot then
			send_train_between(map_data, r_station_id, table_remove(p_stations, best), best_depot, item_name)
		else
			if could_have_been_serviced then
				send_missing_train_alert_for_stops(r_station.entity_stop, stations[p_stations[best]].entity_stop)
			end
			r_station.display_failed_request = true
			r_station.display_update = true
		end
	end
	return false
end
---@param map_data MapData
---@param mod_settings CybersynModSettings
function tick(map_data, mod_settings)
	map_data.total_ticks = map_data.total_ticks + 1
	if map_data.tick_state == STATE_INIT then
		map_data.economy.all_p_stations = {}
		map_data.economy.all_r_stations = {}
		map_data.economy.all_names = {}
		map_data.tick_state = STATE_POLL_DEPOTS
	end

	if map_data.tick_state == STATE_POLL_DEPOTS then
		for i = 1, 3 do
			if tick_poll_depot(map_data) then break end
		end
	elseif map_data.tick_state == STATE_POLL_STATIONS then
		for i = 1, 2 do
			if tick_poll_station(map_data, mod_settings) then break end
		end
	elseif map_data.tick_state == STATE_DISPATCH then
		tick_dispatch(map_data, mod_settings)
	end
end

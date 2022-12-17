--By Mami
local min = math.min
local max = math.max
local abs = math.abs
local ceil = math.ceil
local INF = math.huge
local btest = bit32.btest
local band = bit32.band
local table_remove = table.remove
local random = math.random

---@param map_data MapData
---@param station Station
---@param manifest Manifest
---@param sign -1|1
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
	if station.deliveries_total == 0 and station.display_state >= 2 then
		station.display_state = station.display_state - 2
		update_display(map_data, station)
	end
end

---@param map_data MapData
---@param r_station_id uint
---@param p_station_id uint
---@param item_type string
---@param min_slots_to_move int
local function get_valid_train(map_data, r_station_id, p_station_id, item_type, min_slots_to_move)
	--NOTE: this code is the critical section for amortized run-time optimization
	local r_station = map_data.stations[r_station_id]
	local p_station = map_data.stations[p_station_id]
	---@type string
	local network_name = p_station.network_name

	local p_to_r_dist = get_stop_dist(p_station.entity_stop, r_station.entity_stop)
	local netand = band(p_station.network_flag, r_station.network_flag)
	if p_to_r_dist == INF or netand == 0 then
		return nil, INF
	end

	---@type uint?
	local best_train = nil
	local best_capacity = 0
	local best_dist = INF
	local valid_train_exists = false

	local is_fluid = item_type == "fluid"
	local trains = map_data.available_trains[network_name]
	if trains then
		for train_id, _ in pairs(trains) do
			local train = map_data.trains[train_id]
			local layout_id = train.layout_id
			--check cargo capabilities
			--check layout validity for both stations
			local capacity = (is_fluid and train.fluid_capacity) or train.item_slot_capacity
			if
			capacity >= min_slots_to_move and
			btest(netand, train.network_flag) and
			(r_station.allows_all_trains or r_station.accepted_layouts[layout_id]) and
			(p_station.allows_all_trains or p_station.accepted_layouts[layout_id]) and
			not train.se_is_being_teleported
			then
				valid_train_exists = true
				--check if exists valid path
				--check if path is shortest so we prioritize locality
				local t_to_p_dist = get_stop_dist(train.entity.front_stock, p_station.entity_stop) - DEPOT_PRIORITY_MULT*train.priority

				if capacity > best_capacity or (capacity == best_capacity and t_to_p_dist < best_dist) then
					best_capacity = capacity
					best_dist = t_to_p_dist
					best_train = train_id
				end
			end
		end
	end

	if valid_train_exists then
		return best_train, best_dist + p_to_r_dist
	else
		return nil, p_to_r_dist
	end
end


---@param map_data MapData
---@param r_station_id uint
---@param p_station_id uint
---@param train_id uint
---@param manifest Manifest
function create_delivery(map_data, r_station_id, p_station_id, train_id, manifest)
	local economy = map_data.economy
	local r_station = map_data.stations[r_station_id]
	local p_station = map_data.stations[p_station_id]
	local train = map_data.trains[train_id]
	---@type string
	local network_name = r_station.network_name

	remove_available_train(map_data, train_id, train)
	local depot_id = train.parked_at_depot_id
	if depot_id then
		map_data.depots[depot_id].available_train_id = nil
		train.parked_at_depot_id = nil
	end
	--NOTE: we assume that the train is not being teleported at this time
	if set_manifest_schedule(train.entity, train.depot_name, train.se_depot_surface_i, p_station.entity_stop, r_station.entity_stop, manifest, depot_id ~= nil) then
		local old_status = train.status
		train.status = STATUS_TO_P
		train.p_station_id = p_station_id
		train.r_station_id = r_station_id
		train.manifest = manifest
		train.last_manifest_tick = map_data.total_ticks

		r_station.last_delivery_tick = map_data.total_ticks
		p_station.last_delivery_tick = map_data.total_ticks

		r_station.deliveries_total = r_station.deliveries_total + 1
		p_station.deliveries_total = p_station.deliveries_total + 1

		for item_i, item in ipairs(manifest) do
			assert(item.count > 0, "main.lua error, transfer amount was not positive")

			r_station.deliveries[item.name] = (r_station.deliveries[item.name] or 0) + item.count
			p_station.deliveries[item.name] = (p_station.deliveries[item.name] or 0) - item.count

			if item_i > 1 then
				--prevent deliveries from being processed for these items until their stations are re-polled
				local item_network_name = network_name..":"..item.name
				economy.all_r_stations[item_network_name] = nil
				economy.all_p_stations[item_network_name] = nil
			end
		end

		set_comb2(map_data, p_station)
		set_comb2(map_data, r_station)

		if p_station.display_state < 2 then
			p_station.display_state = 2
			update_display(map_data, p_station)
		end
		if r_station.display_state < 2 then
			r_station.display_state = 2
			update_display(map_data, r_station)
		end
		interface_raise_train_status_changed(train_id, old_status, STATUS_TO_P)
	else
		interface_raise_train_dispatch_failed(train_id)
	end
end
---@param map_data MapData
---@param r_station_id uint
---@param p_station_id uint
---@param train_id uint
---@param primary_item_name string?
function create_manifest(map_data, r_station_id, p_station_id, train_id, primary_item_name)
	--trains and stations expected to be of the same network
	local r_station = map_data.stations[r_station_id]
	local p_station = map_data.stations[p_station_id]
	local train = map_data.trains[train_id]

	---@type Manifest
	local manifest = {}

	for k, v in pairs(r_station.tick_signals) do
		---@type string
		local item_name = v.signal.name
		local item_type = v.signal.type
		local r_item_count = v.count
		local r_effective_item_count = r_item_count + (r_station.deliveries[item_name] or 0)
		if r_effective_item_count < 0 and r_item_count < 0 then
			local r_threshold = r_station.item_thresholds and r_station.item_thresholds[item_name] or r_station.r_threshold
			local p_effective_item_count = p_station.item_p_counts[item_name]
			--could be an item that is not present at the station
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

	return manifest
end

---@param map_data MapData
---@param mod_settings CybersynModSettings
local function tick_dispatch(map_data, mod_settings)
	--we do not dispatch more than one train per tick
	--psuedo-randomize what item (and what station) to check first so if trains available is low they choose orders psuedo-randomly
	--NOTE: this is an approximation algorithm for solving the assignment problem (bipartite graph weighted matching), the true solution would be to implement the simplex algorithm but I strongly believe most factorio players would prefer run-time efficiency over perfect train routing logic
	--NOTE: the above isn't even the full story, we can only use one edge per item per tick, which might break the assumptions of the simplex algorithm causing it to give imperfect solutions.

	local all_r_stations = map_data.economy.all_r_stations
	local all_p_stations = map_data.economy.all_p_stations
	local all_names = map_data.economy.all_names
	local stations = map_data.stations

	local r_stations
	local p_stations
	local item_name
	local item_type
	while true do
		local size = #all_names
		if size == 0 then
			map_data.tick_state = STATE_INIT
			return true
		end

		--randomizing the ordering should only matter if we run out of available trains
		local name_i = size <= 2 and 2 or 2*random(size/2)

		local item_network_name = all_names[name_i - 1]--[[@as string]]
		local signal = all_names[name_i]--[[@as SignalID]]

		--swap remove
		all_names[name_i - 1] = all_names[size - 1]
		all_names[name_i] = all_names[size]
		all_names[size] = nil
		all_names[size - 1] = nil

		r_stations = all_r_stations[item_network_name]
		p_stations = all_p_stations[item_network_name]
		if r_stations then
			if p_stations then
				item_name = signal.name--[[@as string]]
				item_type = signal.type
				break
			else
				for i, id in ipairs(r_stations) do
					local station = stations[id]
					if station and station.display_state%2 == 0 then
						station.display_state = station.display_state + 1
						update_display(map_data, station)
					end
				end
			end
		end
	end
	local max_threshold = INF
	while true do
		local r_station_i = nil
		local r_threshold = nil
		local best_prior = -INF
		local best_lru = INF
		for i, id in ipairs(r_stations) do
			local station = stations[id]
			--NOTE: the station at r_station_id could have been deleted and reregistered since last poll, this check here prevents it from being processed for a delivery in that case
			if station and station.deliveries_total < station.entity_stop.trains_limit then
				local item_threshold = station.item_thresholds and station.item_thresholds[item_name] or nil
				local threshold = station.r_threshold
				local prior = station.priority
				if item_threshold then
					threshold = item_threshold
					if station.item_priority then
						prior = station.item_priority--[[@as int]]
					end
				end
				if threshold <= max_threshold and (prior > best_prior or (prior == best_prior and station.last_delivery_tick < best_lru)) then
					r_station_i = i
					r_threshold = threshold
					best_prior = prior
					best_lru = station.last_delivery_tick
				end
			end
		end
		if not r_station_i then
			for i, id in ipairs(r_stations) do
				local station = stations[id]
				if station and station.display_state%2 == 0 then
					station.display_state = station.display_state + 1
					update_display(map_data, station)
				end
			end
			return false
		end

		local r_station_id = r_stations[r_station_i]
		local r_station = stations[r_station_id]

		max_threshold = 0
		local best_i = 0
		local best_train = nil
		local best_dist = INF
		local best_prior = -INF
		local can_be_serviced = false
		for j, p_station_id in ipairs(p_stations) do
			local p_station = stations[p_station_id]
			if p_station and p_station.deliveries_total < p_station.entity_stop.trains_limit then
				local effective_count = p_station.item_p_counts[item_name]
				if effective_count >= r_threshold then
					local item_threshold = p_station.item_thresholds and p_station.item_thresholds[item_name] or nil
					local prior = p_station.priority
					if item_threshold and p_station.item_priority then
						prior = p_station.item_priority--[[@as int]]
					end
					local slot_threshold = item_type == "fluid" and r_threshold or ceil(r_threshold/get_stack_size(map_data, item_name))
					local train, d = get_valid_train(map_data, r_station_id, p_station_id, item_type, slot_threshold)
					if prior > best_prior or (prior == best_prior and d < best_dist) then
						if train then
							best_i = j
							best_dist = d
							best_train = train
							best_prior = prior
							can_be_serviced = true
						elseif d < INF then
							best_i = j
							can_be_serviced = true
						end
					end
				end
				if effective_count > max_threshold then
					max_threshold = effective_count
				end
			end
		end
		if best_train then
			local p_station_id = table_remove(p_stations, best_i)
			local manifest = create_manifest(map_data, r_station_id, p_station_id, best_train, item_name)
			create_delivery(map_data, r_station_id, p_station_id, best_train, manifest)
			return false
		else
			if can_be_serviced and mod_settings.missing_train_alert_enabled then
				send_missing_train_alert(r_station.entity_stop, stations[p_stations[best_i]].entity_stop)
			end
			if r_station.display_state%2 == 0 then
				r_station.display_state = r_station.display_state + 1
				update_display(map_data, r_station)
			end
		end

		table_remove(r_stations, r_station_i)
	end
end
---@param map_data MapData
---@param mod_settings CybersynModSettings
local function tick_poll_station(map_data, mod_settings)
	local tick_data = map_data.tick_data
	local all_r_stations = map_data.economy.all_r_stations
	local all_p_stations = map_data.economy.all_p_stations
	local all_names = map_data.economy.all_names

	local station_id
	local station
	while true do--choose a station
		tick_data.i = (tick_data.i or 0) + 1
		if tick_data.i > #map_data.active_station_ids then
			tick_data.i = nil
			map_data.tick_state = STATE_DISPATCH
			return true
		end
		station_id = map_data.active_station_ids[tick_data.i]
		station = map_data.stations[station_id]
		if station then
			--NOTE: polling trains_limit here is expensive and not strictly necessary but using it to early out saves more ups
			if station.network_name and station.deliveries_total < station.entity_stop.trains_limit then
				break
			end
		else
			--lazy delete removed stations
			table_remove(map_data.active_station_ids, tick_data.i)
			tick_data.i = tick_data.i - 1
		end
	end
	station.r_threshold = mod_settings.r_threshold
	station.priority = 0
	station.item_priority = nil
	station.locked_slots = 0
	station.network_flag = mod_settings.network_flag
	local comb1_signals, comb2_signals = get_signals(station)
	station.tick_signals = comb1_signals
	station.item_p_counts = {}

	if comb1_signals then
		if comb2_signals then
			station.item_thresholds = {}
			for k, v in pairs(comb2_signals) do
				local item_name = v.signal.name
				local item_count = v.count
				local item_type = v.signal.type
				if item_name then
					if item_type == "virtual" then
						if item_name == SIGNAL_PRIORITY then
							station.item_priority = item_count
						end
					else
						station.item_thresholds[item_name] = abs(item_count)
					end
				end
			end
		else
			station.item_thresholds = nil
		end
		for k, v in pairs(comb1_signals) do
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
					comb1_signals[k] = nil
				end
				if item_name == station.network_name then
					station.network_flag = item_count
					comb1_signals[k] = nil
				end
			else
				comb1_signals[k] = nil
			end
		end
		local is_requesting_nothing = true
		for k, v in pairs(comb1_signals) do
			---@type string
			local item_name = v.signal.name
			local item_count = v.count
			local effective_item_count = item_count + (station.deliveries[item_name] or 0)

			local is_not_requesting = true
			if station.is_r then
				local r_threshold = station.item_thresholds and station.item_thresholds[item_name] or station.r_threshold
				if -effective_item_count >= r_threshold and -item_count >= r_threshold then
					is_not_requesting = false
					is_requesting_nothing = false
					local item_network_name = station.network_name..":"..item_name
					local stations = all_r_stations[item_network_name]
					if stations == nil then
						stations = {}
						all_r_stations[item_network_name] = stations
						all_names[#all_names + 1] = item_network_name
						all_names[#all_names + 1] = v.signal
					end
					stations[#stations + 1] = station_id
				end
			end
			if is_not_requesting then
				if station.is_p and effective_item_count > 0 and item_count > 0 then
					local item_network_name = station.network_name..":"..item_name
					local stations = all_p_stations[item_network_name]
					if stations == nil then
						stations = {}
						all_p_stations[item_network_name] = stations
					end
					stations[#stations + 1] = station_id
					station.item_p_counts[item_name] = effective_item_count
				else
					comb1_signals[k] = nil
				end
			end
		end
		if is_requesting_nothing and station.display_state%2 == 1 then
			station.display_state = station.display_state - 1
			update_display(map_data, station)
		end
	end
	return false
end
---@param map_data MapData
---@param mod_settings CybersynModSettings
local function tick_poll_train(map_data, mod_settings)
	local tick_data = map_data.tick_data
	--NOTE: the following has undefined behavior if last_train is deleted, this should be ok since the following doesn't care how inconsistent our access pattern is
	local train_id, train = next(map_data.trains, tick_data.last_train)
	tick_data.last_train = train_id

	if train and train.manifest and not train.se_is_being_teleported and train.last_manifest_tick + mod_settings.stuck_train_time*mod_settings.tps < map_data.total_ticks then
		if mod_settings.stuck_train_alert_enabled then
			send_stuck_train_alert(train.entity, train.depot_name)
		end
		interface_raise_train_stuck(train_id)
	end
end
---@param map_data MapData
local function tick_poll_comb(map_data)
	local tick_data = map_data.tick_data
	--NOTE: the following has undefined behavior if last_comb is deleted
	local comb_id, comb = next(map_data.to_comb, tick_data.last_comb)
	tick_data.last_comb = comb_id

	if comb and comb.valid then
		combinator_update(map_data, comb, true)
	end
end
---@param map_data MapData
---@param mod_settings CybersynModSettings
function tick(map_data, mod_settings)
	map_data.total_ticks = map_data.total_ticks + 1
	if map_data.tick_state == STATE_INIT then
		map_data.economy.all_p_stations = {}
		map_data.economy.all_r_stations = {}
		map_data.economy.all_names = {}
		for i, id in pairs(map_data.warmup_station_ids) do
			local station = map_data.stations[id]
			if station then
				if station.last_delivery_tick + mod_settings.warmup_time*mod_settings.tps < map_data.total_ticks then
					map_data.active_station_ids[#map_data.active_station_ids + 1] = id
					map_data.warmup_station_ids[i] = nil
				end
			else
				map_data.warmup_station_ids[i] = nil
			end
		end
		map_data.tick_state = STATE_POLL_STATIONS
		interface_raise_tick_init()
		tick_poll_train(map_data, mod_settings)
		tick_poll_comb(map_data)
	end

	if map_data.tick_state == STATE_POLL_STATIONS then
		for i = 1, mod_settings.update_rate do
			if tick_poll_station(map_data, mod_settings) then break end
		end
	elseif map_data.tick_state == STATE_DISPATCH then
		for i = 1, mod_settings.update_rate do
			tick_dispatch(map_data, mod_settings)
		end
	end
end

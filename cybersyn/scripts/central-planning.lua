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
function create_delivery(map_data, r_station_id, p_station_id, train_id, manifest)
	local economy = map_data.economy
	local r_station = map_data.stations[r_station_id]
	local p_station = map_data.stations[p_station_id]
	local train = map_data.trains[train_id]
	local depot = map_data.depots[train.depot_id]


	if not train.entity.valid then
		on_train_broken(map_data, train_id, train)
		interface_raise_train_dispatch_failed(train_id)
		return
	end
	if not depot.entity_stop.valid then
		on_depot_broken(map_data, train.depot_id, depot)
		interface_raise_train_dispatch_failed(train_id)
		return
	end
	if not p_station.entity_stop.valid then
		on_station_broken(map_data, p_station_id, p_station)
		interface_raise_train_dispatch_failed(train_id)
		return
	end
	if not r_station.entity_stop.valid then
		on_station_broken(map_data, r_station_id, r_station)
		interface_raise_train_dispatch_failed(train_id)
		return
	end

	local is_at_depot = remove_available_train(map_data, train_id, train)
	--NOTE: we assume that the train is not being teleported at this time
	--NOTE: set_manifest_schedule is allowed to cancel the delivery at the last second if applying the schedule to the train makes it lost and is_at_depot == false
	local r_enable_inactive = mod_settings.allow_cargo_in_depot and r_station.enable_inactive--[[@as boolean]]
	if set_manifest_schedule(map_data, train.entity, depot.entity_stop, not train.use_any_depot, p_station.entity_stop, p_station.enable_inactive, r_station.entity_stop, r_enable_inactive, manifest, is_at_depot) then
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

		local r_is_each = r_station.network_name == NETWORK_EACH
		local p_is_each = p_station.network_name == NETWORK_EACH
		for item_i, item in ipairs(manifest) do
			assert(item.count > 0, "main.lua error, transfer amount was not positive")

			r_station.deliveries[item.name] = (r_station.deliveries[item.name] or 0) + item.count
			p_station.deliveries[item.name] = (p_station.deliveries[item.name] or 0) - item.count

			if item_i > 1 or r_is_each or p_is_each then
				local f, a
				if r_is_each then
					f, a = pairs(r_station.network_mask--[[@as {[string]: int}]])
					if p_is_each then
						for network_name, _ in f, a do
							local item_network_name = network_name..":"..item.name
							economy.all_r_stations[item_network_name] = nil
							economy.all_p_stations[item_network_name] = nil
						end
						f, a = pairs(p_station.network_mask--[[@as {[string]: int}]])
					end
				elseif p_is_each then
					f, a = pairs(p_station.network_mask--[[@as {[string]: int}]])
				else
					f, a = once, r_station.network_name
				end
				--prevent deliveries from being processed for these items until their stations are re-polled
				--if we don't wait until they are repolled a duplicate delivery might be generated for stations that share inventories
				for network_name, _ in f, a do
					local item_network_name = network_name..":"..item.name
					economy.all_r_stations[item_network_name] = nil
					economy.all_p_stations[item_network_name] = nil
				end
			end
		end

		set_comb2(map_data, p_station)
		set_comb2(map_data, r_station)

		p_station.display_state = 1
		update_display(map_data, p_station)
		r_station.display_state = 1
		update_display(map_data, r_station)

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
			if r_station.is_stack and item_type == "item" then
				r_threshold = r_threshold*get_stack_size(map_data, item_name)
			end
			local p_effective_item_count = p_station.item_p_counts[item_name]
			--could be an item that is not present at the station
			local effective_threshold
			local override_threshold = p_station.item_thresholds and p_station.item_thresholds[item_name]
			if override_threshold and p_station.is_stack and item_type == "item" then
				override_threshold = override_threshold*get_stack_size(map_data, item_name)
			end
			if override_threshold and override_threshold <= r_threshold then
				effective_threshold = override_threshold
			else
				effective_threshold = r_threshold
			end
			if p_effective_item_count and p_effective_item_count >= effective_threshold then
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
	local total_item_slots = train.item_slot_capacity
	if locked_slots > 0 and total_item_slots > 0 then
		local total_cargo_wagons = #train.entity.cargo_wagons
		total_item_slots = max(total_item_slots - total_cargo_wagons*locked_slots, 1)
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
		elseif total_item_slots > 0 then
			local stack_size = get_stack_size(map_data, item.name)
			local slots = ceil(item.count/stack_size)
			if slots > total_item_slots then
				item.count = total_item_slots*stack_size
			end
			total_item_slots = total_item_slots - slots
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
	local item_network_name
	while true do
		local size = #all_names
		if size == 0 then
			map_data.tick_state = STATE_INIT
			return true
		end

		--randomizing the ordering should only matter if we run out of available trains
		local name_i = size <= 2 and 2 or 2*random(size/2)

		item_network_name = all_names[name_i - 1]--[[@as string]]
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
					if station and band(station.display_state, 2) == 0 then
						station.display_state = station.display_state + 2
						update_display(map_data, station)
					end
				end
			end
		end
	end
	while true do
		local r_station_i = nil
		local r_threshold = nil
		local best_r_prior = -INF
		local best_timestamp = INF
		for i, id in ipairs(r_stations) do
			local station = stations[id]
			--NOTE: the station at r_station_id could have been deleted and reregistered since last poll, this check here prevents it from being processed for a delivery in that case
			if not station or station.deliveries_total >= station.trains_limit then
				goto continue
			end

			--don't request when already providing
			local item_deliveries = station.deliveries[item_name]
			if item_deliveries and item_deliveries < 0 then
				goto continue
			end

			local threshold = station.r_threshold
			local prior = station.priority
			local item_threshold = station.item_thresholds and station.item_thresholds[item_name] or nil
			if item_threshold then
				threshold = item_threshold
				if station.item_priority then
					prior = station.item_priority--[[@as int]]
				end
			end
			if prior < best_r_prior then
				goto continue
			end

			--prioritize by last delivery time if priorities are equal
			if prior == best_r_prior and station.last_delivery_tick > best_timestamp then
				goto continue
			end

			r_station_i = i
			r_threshold = threshold
			best_r_prior = prior
			best_timestamp = station.last_delivery_tick
			::continue::
		end
		if not r_station_i then
			for _, id in ipairs(r_stations) do
				local station = stations[id]
				if station and band(station.display_state, 2) == 0 then
					station.display_state = station.display_state + 2
					update_display(map_data, station)
				end
			end
			return false
		end

		local r_station_id = r_stations[r_station_i]
		local r_station = stations[r_station_id]
		---@type string
		local network_name
		if r_station.network_name == NETWORK_EACH then
			_, _, network_name = string.find(item_network_name, "^(.*):")
		else
			network_name = r_station.network_name
		end
		local trains = map_data.available_trains[network_name]
		local is_fluid = item_type == "fluid"
		if not is_fluid and r_station.is_stack then
			r_threshold = r_threshold*get_stack_size(map_data, item_name)
		end
		--no train exists with layout accepted by both provide and request stations
		local correctness = 0
		local closest_to_correct_p_station = nil

		---@type uint?
		local p_station_i = nil
		local best_train_id = nil
		local best_p_prior = -INF
		local best_dist = INF
		--if no available trains in the network, skip search
		---@type uint
		local j = 1
		while j <= #p_stations do
			local p_flag, r_flag, netand, best_p_train_id, best_t_prior, best_capacity, best_t_to_p_dist, effective_count, override_threshold, p_prior, best_p_to_r_dist, effective_threshold, slot_threshold, item_deliveries

			local p_station_id = p_stations[j]
			local p_station = stations[p_station_id]
			if not p_station or p_station.deliveries_total >= p_station.trains_limit then
				goto p_continue
			end

			--don't provide when already requesting
			item_deliveries = p_station.deliveries[item_name]
			if item_deliveries and item_deliveries > 0 then
				goto p_continue
			end

			p_flag = get_network_mask(p_station, network_name)
			r_flag = get_network_mask(r_station, network_name)
			netand = band(p_flag, r_flag)
			if netand == 0 then
				goto p_continue
			end

			effective_count = p_station.item_p_counts[item_name]
			override_threshold = p_station.item_thresholds and p_station.item_thresholds[item_name]
			if override_threshold and p_station.is_stack and not is_fluid then
				override_threshold = override_threshold*get_stack_size(map_data, item_name)
			end
			if override_threshold and override_threshold <= r_threshold then
				effective_threshold = override_threshold
			else
				effective_threshold = r_threshold
			end

			if effective_count < effective_threshold then
				--this p station should have serviced the current r station, lock it so it can't serve any others
				--this will lock stations even when the r station manages to find a p station, this not a problem because all stations will be unlocked before it could be an issue
				table_remove(p_stations, j)
				if band(p_station.display_state, 4) == 0 then
					p_station.display_state = p_station.display_state + 4
					update_display(map_data, p_station)
				end
				goto p_continue_remove
			end

			p_prior = p_station.priority
			if override_threshold and p_station.item_priority then
				p_prior = p_station.item_priority--[[@as int]]
			end
			if p_prior < best_p_prior then
				goto p_continue
			end

			best_p_to_r_dist = p_station.entity_stop.valid and r_station.entity_stop.valid and get_dist(p_station.entity_stop, r_station.entity_stop) or INF
			if p_prior == best_p_prior and best_p_to_r_dist > best_dist then
				goto p_continue
			end

			if is_fluid then
				slot_threshold = effective_threshold
			else
				slot_threshold = ceil(effective_threshold/get_stack_size(map_data, item_name))
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
			if trains then
				for train_id, _ in pairs(trains) do
					local train = map_data.trains[train_id]
					local train_flag = get_network_mask(train, network_name)
					if not btest(netand, train_flag) or train.se_is_being_teleported then
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

					--check if path is shortest so we prioritize locality
					local t = get_any_train_entity(train.entity)
					local t_to_p_dist = t and p_station.entity_stop.valid and (get_dist(t, p_station.entity_stop) - DEPOT_PRIORITY_MULT*train.priority) or INF
					if capacity == best_capacity and t_to_p_dist > best_t_to_p_dist then
						goto train_continue
					end

					best_p_train_id = train_id
					best_capacity = capacity
					best_t_prior = train.priority
					best_t_to_p_dist = t_to_p_dist
					::train_continue::
				end
			end
			if not best_p_train_id then
				goto p_continue
			end

			p_station_i = j
			best_train_id = best_p_train_id
			best_p_prior = p_prior
			best_dist = best_p_to_r_dist
			::p_continue::
			j = j + 1
			::p_continue_remove::
		end

		if best_train_id then
			local p_station_id = table_remove(p_stations, p_station_i)
			local manifest = create_manifest(map_data, r_station_id, p_station_id, best_train_id, item_name)
			create_delivery(map_data, r_station_id, p_station_id, best_train_id, manifest)
			return false
		else
			if closest_to_correct_p_station then
				if correctness == 1 then
					send_alert_missing_train(r_station.entity_stop, closest_to_correct_p_station.entity_stop)
				elseif correctness == 2 then
					send_alert_no_train_has_capacity(r_station.entity_stop, closest_to_correct_p_station.entity_stop)
				elseif correctness == 3 then
					send_alert_no_train_matches_r_layout(r_station.entity_stop, closest_to_correct_p_station.entity_stop)
				elseif correctness == 4 then
					send_alert_no_train_matches_p_layout(r_station.entity_stop, closest_to_correct_p_station.entity_stop)
				end
			end
			if band(r_station.display_state, 2) == 0 then
				r_station.display_state = r_station.display_state + 2
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
		station.trains_limit = station.entity_stop.trains_limit
	else
		on_station_broken(map_data, station_id, station)
		return false
	end
	station.r_threshold = mod_settings.r_threshold
	station.priority = mod_settings.priority
	station.item_priority = nil
	station.locked_slots = mod_settings.locked_slots
	local is_each = station.network_name == NETWORK_EACH
	if is_each then
		station.network_mask = {}
	else
		station.network_mask = mod_settings.network_mask
	end
	local comb1_signals, comb2_signals = get_signals(station)
	station.tick_signals = comb1_signals
	station.item_p_counts = {}

	local is_requesting_nothing = true
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
					elseif item_name == REQUEST_THRESHOLD then
						--NOTE: thresholds must be >0 or they can cause a crash
						station.r_threshold = abs(item_count)
					elseif item_name == LOCKED_SLOTS then
						station.locked_slots = max(item_count, 0)
					elseif is_each then
						station.network_mask[item_name] = item_count
					end
					comb1_signals[k] = nil
				end
				if item_name == station.network_name then
					station.network_mask = item_count
					comb1_signals[k] = nil
				end
			else
				comb1_signals[k] = nil
			end
		end
		for k, v in pairs(comb1_signals) do
			---@type string
			local item_name = v.signal.name
			local item_type = v.signal.type
			local item_count = v.count
			local effective_item_count = item_count + (station.deliveries[item_name] or 0)

			local is_not_requesting = true
			if station.is_r then
				local r_threshold = station.item_thresholds and station.item_thresholds[item_name] or station.r_threshold
				if station.is_stack and item_type == "item" then
					r_threshold = r_threshold*get_stack_size(map_data, item_name)
				end
				if -effective_item_count >= r_threshold and -item_count >= r_threshold then
					is_not_requesting = false
					is_requesting_nothing = false
					local f, a
					if station.network_name == NETWORK_EACH then
						f, a = pairs(station.network_mask--[[@as {[string]: int}]])
					else
						f, a = once, station.network_name
					end
					for network_name, _ in f, a do
						local item_network_name = network_name..":"..item_name
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
			end
			if is_not_requesting then
				if station.is_p and effective_item_count > 0 and item_count > 0 then
					local f, a
					if station.network_name == NETWORK_EACH then
						f, a = pairs(station.network_mask--[[@as {[string]: int}]])
					else
						f, a = once, station.network_name
					end
					for network_name, _ in f, a do
						local item_network_name = network_name..":"..item_name
						local stations = all_p_stations[item_network_name]
						if stations == nil then
							stations = {}
							all_p_stations[item_network_name] = stations
						end
						stations[#stations + 1] = station_id
						station.item_p_counts[item_name] = effective_item_count
					end
				else
					comb1_signals[k] = nil
				end
			end
		end
	end
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

	if map_data.total_ticks%5 == 0 then
		if tick_data.last_train == nil or map_data.trains[tick_data.last_train] then
			local train_id, train = next(map_data.trains, tick_data.last_train)
			tick_data.last_train = train_id
			if train then
				if train.manifest and not train.se_is_being_teleported and train.last_manifest_tick + mod_settings.stuck_train_time*mod_settings.tps < map_data.total_ticks then
					if mod_settings.stuck_train_alert_enabled then
						send_alert_stuck_train(map_data, train.entity)
					end
					interface_raise_train_stuck(train_id)
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

	map_data.economy.all_p_stations = {}
	map_data.economy.all_r_stations = {}
	map_data.economy.all_names = {}

	while #map_data.warmup_station_ids > 0 do
		local id = map_data.warmup_station_ids[1]
		local station = map_data.stations[id]
		if station then
			local cycles = map_data.warmup_station_cycles[id]
			--force a station to wait at least 1 cycle so we can be sure active_station_ids was flushed of duplicates
			if cycles > 0 then
				if station.last_delivery_tick + mod_settings.warmup_time*mod_settings.tps < map_data.total_ticks then
					station.is_warming_up = nil
					map_data.active_station_ids[#map_data.active_station_ids + 1] = id
					table_remove(map_data.warmup_station_ids, 1)
					map_data.warmup_station_cycles[id] = nil
					if station.entity_comb1.valid then
						combinator_update(map_data, station.entity_comb1)
					else
						on_station_broken(map_data, id, station)
					end
				else
					break
				end
			else
				map_data.warmup_station_cycles[id] = cycles + 1
				break
			end
		else
			table_remove(map_data.warmup_station_ids, 1)
			map_data.warmup_station_cycles[id] = nil
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

	map_data.tick_state = STATE_POLL_STATIONS
	interface_raise_tick_init()
end
---@param map_data MapData
---@param mod_settings CybersynModSettings
function tick(map_data, mod_settings)
	map_data.total_ticks = map_data.total_ticks + 1


	if map_data.active_alerts then
		if map_data.total_ticks%(8*mod_settings.tps) < 1 then
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
			for i = 1, mod_settings.update_rate do
				if tick_dispatch(map_data, mod_settings) then break end
			end
		end
	else
		map_data.tick_state = STATE_INIT
	end
end

--By Mami
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
	--local profiler = game.create_profiler()
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
			--profiler.stop()
			--game.write_file("cybersyn_profile.txt", {"", profiler, ""}, true)
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

	local _, _, network_name = string.find(item_network_name, "^(.*):")
	local is_fluid = item_type == "fluid"
	local stack_size = not is_fluid and get_stack_size(map_data, item_name) or nil

	local valid_requesters = {}
	for _, id in ipairs(r_stations) do
		local station = stations[id]
		if not station then
			goto valid_requesters_continue
		end
		local over_limit = station.deliveries_total >= station.trains_limit
		--don't request when already providing
		local item_deliveries = station.deliveries[item_name]
		if item_deliveries and item_deliveries < 0 then
			over_limit = true
		end
		if over_limit and station.disable_reservation then
			goto valid_requesters_continue
		end
		valid_requesters[#valid_requesters+1] = {
			station = station,
			over_limit = over_limit,
			priority = station.item_thresholds and station.item_thresholds[item_name] and station.item_priority or station.priority,
			timestamp = station.last_delivery_tick
		}
		::valid_requesters_continue::
	end
	table_sort(valid_requesters, function (a, b)
		if a.priority ~= b.priority then return a.priority > b.priority end
		--if a.over_limit ~= b.over_limit then return not a.over_limit end
		return a.timestamp < b.timestamp
	end )

	local valid_providers = {}
	for _, id in ipairs(p_stations) do
		local station = stations[id]
		if not station then
			goto valid_providers_continue
		end
		local over_limit = station.deliveries_total >= station.trains_limit
		--don't provide when already requesting
		local item_deliveries = station.deliveries[item_name]
		if item_deliveries and item_deliveries > 0 then
			over_limit = true
		end
		if over_limit and station.disable_reservation then
			goto valid_providers_continue
		end
		local priority = station.priority
		local threshold = station.item_thresholds and station.item_thresholds[item_name]
		if threshold then
			if station.item_priority then
				priority = station.item_priority
			end
			if not is_fluid and station.is_stack then
				threshold = threshold * stack_size
			end
		end
		valid_providers[#valid_providers+1] = {
			station = station,
			over_limit = over_limit,
			priority = priority,
			threshold = threshold,
			mask = get_network_mask(station, network_name),
			count = station.item_p_counts[item_name]
		}
		::valid_providers_continue::
	end

	--filled once a provider finds a requester
	local valid_trains = nil

	for _, r in ipairs(valid_requesters) do

		local r_station = r.station
		local r_threshold = (r_station.item_thresholds and r_station.item_thresholds[item_name]) or r_station.r_threshold
		if not is_fluid and r_station.is_stack then r_threshold = r_threshold * stack_size end
		local r_mask = get_network_mask(r_station, network_name)
		local r_stop = r_station.entity_stop

		local matching_providers = {}
		for p_i = #valid_providers, 1, -1 do
			local p = valid_providers[p_i]
			if btest(r_mask, p.mask) then
				local p_threshold = p.threshold
				if p.count >= (p_threshold and p_threshold < r_threshold and p_threshold or r_threshold) then
					--overwritten for next requester, only for sorting
					p.distance = get_dist_sq(r_stop, p.station.entity_stop)
					matching_providers[#matching_providers+1] = p
				else
					--prevent small threshold requesters from starving larger ones
					local p_station = p.station
					if band(p_station.display_state, 4) == 0 then
						p_station.display_state = p_station.display_state + 4
						update_display(map_data, p_station)
					end
					table_remove(valid_providers, p_i)
				end
			end
		end
		table_sort(matching_providers, function (a, b)
			if a.priority ~= b.priority then return a.priority > b.priority end
			if a.over_limit ~= b.over_limit then return not a.over_limit end
			return a.distance < b.distance
		end )

		local r_over_limit = r.over_limit
		local r_disable_reservation = r_station.disable_reservation
		local r_allows_all_trains = r_station.allows_all_trains
		local r_accepted_layouts = r_station.accepted_layouts

		local reserve_provider = nil
		local rp_priority = nil

		local best_p_station = nil
		local problem = 0

		for _, p in ipairs(matching_providers) do

			local p_station = p.station
			if not r_disable_reservation and not p_station.disable_reservation then
				if not reserve_provider then
					reserve_provider = p
					rp_priority = p.priority
					if r_over_limit or p.over_limit then
						goto r_continue
					end
				elseif r_over_limit or p.over_limit or rp_priority > p.priority then
					goto r_continue
				end
			elseif r_over_limit or p.over_limit then
				goto p_continue
			end

			local p_stop = p_station.entity_stop
			local p_matching_trains = p.matching_trains
			if not p_matching_trains then
				if not valid_trains then
					valid_trains = {}
					for id, _ in pairs(map_data.available_trains[network_name] or {}) do
						local train = map_data.trains[id]
						local capacity = is_fluid and train.fluid_capacity or train.item_slot_capacity
						if capacity == 0 or train.se_is_being_teleported then
							goto valid_trains_continue
						end
						local entity = get_any_train_entity(train.entity)
						if not entity then
							goto valid_trains_continue
						end
						valid_trains[#valid_trains+1] = {
							train = train,
							priority = train.priority,
							capacity = capacity,
							entity = entity,
							mask = get_network_mask(train, network_name)
						}
						::valid_trains_continue::
					end
				end
				p_matching_trains = {}
				p.matching_trains = p_matching_trains
				local p_mask = p.mask
				local p_allows_all_trains = p_station.allows_all_trains
				local p_accepted_layouts = p_station.accepted_layouts
				for _, t in ipairs(valid_trains) do
					if btest(p_mask, t.mask) and (p_allows_all_trains or p_accepted_layouts[t.train.layout_id]) then
						--overwritten for next provider, only for sorting
						t.distance = get_dist_sq(p_stop, t.entity)
						p_matching_trains[#p_matching_trains+1] = t
					end
				end
				table_sort(p_matching_trains, function (a, b)
					if a.priority ~= b.priority then return a.priority > b.priority end
					if a.capacity ~= b.capacity then return a.capacity > b.capacity end
					return a.distance < b.distance
				end )
			end

			if problem < 2 and next(p_matching_trains) == nil then
				if next(valid_trains--[[@as table]]) ~= nil then
					best_p_station = p_station
					problem = 2
				elseif problem < 1 then
					best_p_station = p_station
					problem = 1
				end
				goto p_continue
			end

			local p_threshold = p.threshold
			local slot_threshold = p_threshold and p_threshold < r_threshold and p_threshold or r_threshold
			if not is_fluid then
				slot_threshold = ceil(slot_threshold / stack_size)
			end

			for _, t in ipairs(p_matching_trains) do

				if not btest(r_mask, t.mask) or not (r_allows_all_trains or r_accepted_layouts[t.train.layout_id]) then
					if problem < 3 then
						best_p_station = p_station
						problem = 3
					end
					goto t_continue
				end
				if t.capacity < slot_threshold then
					if problem < 4 then
						best_p_station = p_station
						problem = 4
					end
					goto t_continue
				end

				local r_station_id = r_stop.unit_number
				local p_station_id = p_stop.unit_number
				local train_id = t.train.entity.id

				local manifest = create_manifest(map_data, r_station_id, p_station_id, train_id, item_name)
				create_delivery(map_data, r_station_id, p_station_id, train_id, manifest)
				--profiler.stop()
				--game.write_file("cybersyn_profile.txt", {"", profiler}, true)
				do return false end

				::t_continue::
			end

			::p_continue::
		end

		::r_continue::

		if band(r_station.display_state, 2) == 0 then
			r_station.display_state = r_station.display_state + 2
			update_display(map_data, r_station)
		end

		if reserve_provider then
			reserve_provider.count = reserve_provider.count - (reserve_provider.threshold or r_threshold)
		end

		if best_p_station then
			if problem == 1 then
				-- no train on the network with any capacity for this item_type
				send_alert_missing_train(r_station.entity_stop, best_p_station.entity_stop)
			elseif problem == 2 then
				-- no train matches the provider's mask and layout
				send_alert_no_train_matches_p_layout(r_station.entity_stop, best_p_station.entity_stop)
			elseif problem == 3 then
				-- no train matches the requester's mask and layout
				send_alert_no_train_matches_r_layout(r_station.entity_stop, best_p_station.entity_stop)
			elseif problem == 4 then
				-- no train has enough capacity to meet the threshold
				send_alert_no_train_has_capacity(r_station.entity_stop, best_p_station.entity_stop)
			end
		end
	end
	--profiler.stop()
	--game.write_file("cybersyn_profile.txt", {"", profiler}, true)
	return false
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
-- new_run = true
---@param map_data MapData
---@param mod_settings CybersynModSettings
function tick(map_data, mod_settings)
	-- if new_run then
	-- 	game.write_file("cybersyn_profile.txt", "\n", true)
	-- 	new_run = false
	-- end

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

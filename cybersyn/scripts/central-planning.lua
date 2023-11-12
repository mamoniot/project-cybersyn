--By Mami
local min = math.min
local max = math.max
local abs = math.abs
local ceil = math.ceil
local floor = math.floor
local sqrt = math.sqrt
local btest = bit32.btest
local table_insert = table.insert
local table_remove = table.remove
local table_sort = table.sort
local random = math.random
local string_match = string.match

local PROFILING_ENABLED = nil

local profiler = nil ---@type LuaProfiler?
local profiler_totals = nil ---@type {["item"|"fluid"|"train"]: uint}
local profiler_output_path = nil ---@type string

local function profiler_reset(output_path)
	if profiler then
		profiler_output_path = output_path
		profiler.reset()
	end
end

local function profiler_write()
	if profiler then
		profiler.stop()
		game.write_file(profiler_output_path, {"", profiler}, true)
		if global.tick_state == STATE_DISPATCH then
			game.write_file("cybersyn_totals.csv", string.format("items, %u\nfluids, %u\ntrains, %u", profiler_totals.item, profiler_totals.fluid, profiler_totals.train), false)
		end
	end
end

local function profiler_update_total(key, count)
	if profiler then
		profiler_totals[key] = profiler_totals[key] + count
	end
end

---@param r_station Station
---@param item_name string
local function requester_combine_priority(r_station, item_name)
	return (r_station.item_priorities[item_name] + 2^31) * 2^21 - r_station.r_item_timestamps[item_name] + (2^20-1)
end

---@param r_station Station
---@param p_station Station
---@param pf_trains {[string]: uint[]}?
---@param item_name string
---@param item_type string
local function provider_combine_priority(r_station, p_station, pf_trains, item_name, item_type)
	local combined_priority = (p_station.item_priorities[item_name] + 2^31) * 2^3
	if pf_trains and (pf_trains[item_name] or pf_trains[item_type]) then
		combined_priority = combined_priority + 2^2
	end
	if p_station.unused_trains_limit > 0 then
		combined_priority = combined_priority + 2^1
	end
	if r_station.surface_index == p_station.surface_index then
		local r_pos, p_pos = r_station.position, p_station.position
		local x, y = r_pos.x - p_pos.x, r_pos.y - p_pos.y
		--reciprocal of distance so there is no hard limit, instead accuracy just reduces further away
		combined_priority = combined_priority + (1.0 / sqrt(x * x + y * y))
	end
	return combined_priority
end

---@param map_data MapData
local function increment_dispatch_counter(map_data)
	--limited to 21 bits so it can be shoved into combined_priority (53 - 32 == 21)
	--this range is small enough that on huge worlds it might eventually overflow, so handle that gracefully
	local dispatch_count = map_data.dispatch_counter + 1
	if dispatch_count >= 2^21 then
		for station_id, station in pairs(map_data.stations) do
			for item_name, timestamp in pairs(station.r_item_timestamps) do
				station.r_item_timestamps[item_name] = max(timestamp - 2^20, 0)
				for network_name in iterate_network_names(station) do
					map_data.economy.combined_r_priorities[network_name..":"..item_name][station_id] = requester_combine_priority(station, item_name)
				end
			end
		end
		dispatch_count = 2^20+1
	end
	map_data.dispatch_counter = dispatch_count
	return dispatch_count
end

---@param r_station_id uint
---@param r_station Station
---@param p_station_id uint
---@param p_station Station
---@param train_id uint
---@param pf_keys {[string]: true}
---@param update_priorities boolean
---@param remove boolean
local function provider_update_pf_trains(r_station_id, r_station, p_station_id, p_station, train_id, pf_keys, update_priorities, remove)
	local pf_trains = p_station.p_pf_trains[r_station_id]
	if not pf_trains then
		if remove then return end
		pf_trains = {}
		p_station.p_pf_trains[r_station_id] = pf_trains
	end
	local pf_trains_totals = r_station.r_pf_trains_totals

	local changed_keys = {} ---@type {[string]: true}
	if remove then
		for name_or_type, _ in pairs(pf_keys) do
			local train_ids = pf_trains[name_or_type]
			for i = 1, #train_ids do
				if train_ids[i] == train_id then
					table_remove(train_ids, i)
					if not next(train_ids) then
						pf_trains[name_or_type] = nil
						pf_trains_totals[name_or_type] = pf_trains_totals[name_or_type] > 1 and pf_trains_totals[name_or_type] - 1 or nil
						changed_keys[name_or_type] = true
					end
					break
				end
			end
		end
	else
		for name_or_type, _ in pairs(pf_keys) do
			local train_ids = pf_trains[name_or_type]
			if not train_ids then
				train_ids = {}
				pf_trains[name_or_type] = train_ids
				pf_trains_totals[name_or_type] = (pf_trains_totals[name_or_type] or 0) + 1
				changed_keys[name_or_type] = true
			end
			train_ids[#train_ids+1] = train_id
		end
	end

	if update_priorities and next(changed_keys) then
		local item_prototypes = game.item_prototypes
		local r_item_counts = r_station.r_item_counts
		local r_combined_p_priorities = r_station.r_combined_p_priorities
		local f, a = iterate_common_network_names(r_station, p_station)
		for item_name, _ in pairs(p_station.p_item_counts) do
			if r_item_counts[item_name] then
				local item_type = item_prototypes[item_name] and "item" or "fluid"
				if not changed_keys[item_name] then
					if not changed_keys[item_type] or pf_trains[item_name] then
						goto continue
					end
				elseif not changed_keys[item_type] and pf_trains[item_type] then
					goto continue
				end
				local combined_priority = provider_combine_priority(r_station, p_station, pf_trains, item_name, item_type)
				for network_name in f, a do
					r_combined_p_priorities[network_name..":"..item_name][p_station_id] = combined_priority
				end
			end
			::continue::
		end
	end
end

---@param map_data MapData
---@param p_station_id uint
---@param p_station Station
local function provider_update_all_priorities(map_data, p_station_id, p_station)
	local item_prototypes = game.item_prototypes
	local stations = map_data.stations
	local all_r_stations = map_data.economy.sorted_r_stations
	local p_pf_trains = p_station.p_pf_trains
	local f, a = iterate_network_names(p_station)
	for item_name, _ in pairs(p_station.p_item_counts) do
		local item_type = item_prototypes[item_name] and "item" or "fluid"
		for network_name in f, a do
			local network_item = network_name..":"..item_name
			local r_stations = all_r_stations[network_item]
			if r_stations then
				for _, r_station_id in ipairs(r_stations) do
					local r_station = stations[r_station_id]
					r_station.r_combined_p_priorities[network_item][p_station_id] = provider_combine_priority(r_station, p_station, p_pf_trains[r_station_id], item_name, item_type)
				end
			end
		end
	end
end

---@param map_data MapData
---@param station_id uint
---@param station Station
---@param train_id uint
---@param train Train
---@param sign int
function remove_manifest(map_data, station_id, station, train_id, train, sign)
	local deliveries = station.deliveries
	for _, item in ipairs(train.manifest--[[@as Manifest]]) do
		local item_name = item.name
		local remaining_count = deliveries[item_name] + sign*item.count
		if remaining_count ~= 0 then
			deliveries[item_name] = remaining_count
		else
			deliveries[item_name] = nil
		end
	end
	set_comb2(map_data, station)

	station.deliveries_total = station.deliveries_total - 1
	station.unused_trains_limit = station.unused_trains_limit + 1

	if station.deliveries_total == 0 and btest(station.display_state, 1) then
		station.display_state = station.display_state - 1
		update_display(map_data, station)
	end

	if sign == 1 then
		local at_limit_changed = station.unused_trains_limit == 1
		local pf_keys = train.pf_keys
		if pf_keys then
			local r_station_id = train.r_station_id--[[@as uint]]
			provider_update_pf_trains(r_station_id, map_data.stations[r_station_id], station_id, station, train_id, pf_keys, not at_limit_changed, true)
			train.pf_keys = nil
		end
		if at_limit_changed then
			provider_update_all_priorities(map_data, station_id, station)
		end
	end
end

---@param map_data MapData
---@param r_station_id uint
---@param p_station_id uint
---@param train_id uint
---@param manifest Manifest
---@param pf_keys {[string]: true}?
function create_delivery(map_data, r_station_id, p_station_id, train_id, manifest, pf_keys)
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

		r_station.deliveries_total = r_station.deliveries_total + 1
		r_station.unused_trains_limit = r_station.unused_trains_limit - 1

		p_station.deliveries_total = p_station.deliveries_total + 1
		p_station.unused_trains_limit = p_station.unused_trains_limit - 1

		local r_deliveries, p_deliveries = r_station.deliveries, p_station.deliveries
		local f, a = iterate_all_network_names(r_station, p_station)
		for _, item in ipairs(manifest) do
			local item_name, item_count = item.name, item.count

			r_deliveries[item_name] = (r_deliveries[item_name] or 0) + item_count
			p_deliveries[item_name] = (p_deliveries[item_name] or 0) - item_count

			-- assert(r_station.r_item_counts[item_name] + item_count <= 0)
			-- assert(p_station.p_item_counts[item_name] - item_count >= 0)

			--prevent dispatches and delivery additions for these items until their stations are re-polled
			for network_name in f, a do
				economy.items_requested[network_name..":"..item_name] = 0
			end

			profiler_update_total(item.type, item_count)
		end
		profiler_update_total("train", 1)

		local at_limit_changed = p_station.unused_trains_limit == 0
		if pf_keys then
			provider_update_pf_trains(r_station_id, r_station, p_station_id, p_station, train_id, pf_keys, not at_limit_changed, false)
			train.pf_keys = pf_keys
		end
		if at_limit_changed then
			provider_update_all_priorities(map_data, p_station_id, p_station)
		end

		if r_station.is_p and r_station.unused_trains_limit == 0 then
			provider_update_all_priorities(map_data, r_station_id, r_station)
		end

		--only update the timestamp of the primary item, extra items are always below threshold
		local item_name = manifest[1].name
		r_station.r_item_timestamps[item_name] = increment_dispatch_counter(map_data)
		local combined_priority = requester_combine_priority(r_station, item_name)
		for network_name in iterate_network_names(r_station) do
			economy.combined_r_priorities[network_name..":"..item_name][r_station_id] = combined_priority
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
---@param network_name string
---@param primary_item_name string
function create_manifest(map_data, r_station_id, p_station_id, train_id, network_name, primary_item_name)
	--trains and stations expected to be of the same network
	local r_station = map_data.stations[r_station_id]
	local p_station = map_data.stations[p_station_id]
	local train = map_data.trains[train_id]

	local item_prototypes = game.item_prototypes
	local r_item_counts = r_station.r_item_counts
	local p_item_counts = p_station.p_item_counts
	local p_reserved_counts = p_station.p_reserved_counts

	local manifest = {} ---@type Manifest

	for item_name, r_item_count in pairs(r_item_counts) do
		local network_item = network_name..":"..item_name
		local p_item_count = p_reserved_counts[network_item] or p_item_counts[item_name]
		if p_item_count and p_item_count > 0 then
			local item = {name = item_name, type = item_prototypes[item_name] and "item" or "fluid", count = min(-r_item_count, p_item_count)}
			if item_name == primary_item_name then
				manifest[#manifest+1] = manifest[1]
				manifest[1] = item
			elseif not map_data.economy.items_requested[network_item] then
				manifest[#manifest+1] = item
			end
		end
	end

	--if there are multiple secondary items, shuffle them
	local num_entries = #manifest
	for i = 2, num_entries-1 do
		local j = random(i, num_entries)
		local temp = manifest[i]
		manifest[i] = manifest[j]
		manifest[j] = temp
	end

	--locked slots is only taken into account after the train is already approved for dispatch
	local free_item_slots = train.item_slot_capacity
	if free_item_slots > 0 then
		free_item_slots = max(free_item_slots - #train.entity.cargo_wagons * p_station.locked_slots, 1)
	end
	local free_fluid_capacity = train.fluid_capacity

	local pf_keys = {} ---@type {[string]: true}

	local i = 1
	repeat
		local item = manifest[i]

		if item.type == "fluid" then
			if free_fluid_capacity > 0 then
				if item.count < free_fluid_capacity then
					pf_keys[item.name] = true
				else
					item.count = free_fluid_capacity
				end
				free_fluid_capacity = 0 --one fluid per train
				i = i + 1
				goto keep_item
			end
		elseif free_item_slots > 0 then
			local stack_size = item_prototypes[item.name].stack_size
			local free_item_capacity = free_item_slots * stack_size
			if item.count < free_item_capacity then
				local slots = item.count / stack_size
				if item.count % stack_size > 0 then
					slots = ceil(slots)
					pf_keys[item.name] = true
				end
				free_item_slots = free_item_slots - slots
			else
				item.count = free_item_capacity
				free_item_slots = 0
			end
			i = i + 1
			goto keep_item
		end

		--swap remove
		manifest[i] = manifest[num_entries]
		manifest[num_entries] = nil
		num_entries = num_entries - 1

		::keep_item::
	until i > num_entries

	if free_item_slots > 0 then
		pf_keys["item"] = true
	end
	if free_fluid_capacity > 0 then
		pf_keys["fluid"] = true
	end

	return manifest, next(pf_keys) and pf_keys
end

---@param map_data MapData
---@param r_station_id uint
---@param p_station_id uint
---@param network_name string
---@param item_name string
local function add_item_to_deliveries(map_data, r_station_id, p_station_id, network_name, item_name)
	local economy = map_data.economy
	local r_station = map_data.stations[r_station_id]
	local p_station = map_data.stations[p_station_id]

	local item_prototypes = game.item_prototypes
	local item_prototype, item_type, stack_size = item_prototypes[item_name], nil, nil
	if item_prototype then
		item_type, stack_size = "item", item_prototype.stack_size
	else
		item_type = "fluid"
	end

	local r_item_counts, p_item_counts = r_station.r_item_counts, p_station.p_item_counts

	local original_deficit = min(-r_item_counts[item_name], p_station.p_reserved_counts[network_name..":"..item_name] or p_item_counts[item_name])
	assert(original_deficit > 0, "no items requested, or no items available")

	local pf_trains = p_station.p_pf_trains[r_station_id]

	local name_ids = pf_trains[item_name] ---@type uint[]?
	local type_ids = pf_trains[item_type] ---@type uint[]?
	assert(name_ids or type_ids, "no partly filled trains")

	local pf_trains_totals = r_station.r_pf_trains_totals

	local remaining_deficit = original_deficit
	local name_removed, type_removed = false, false

	repeat
		--pick trains first by name, then by type, from oldest to newest
		local train_id
		if name_ids then train_id = name_ids[1]
		elseif type_ids then train_id = type_ids[1]
		else break end

		local keep_name, keep_type = false, false

		local train = map_data.trains[train_id]
		local pf_keys = train.pf_keys--[[@as {[string]: true}]]

		if train.entity.valid then
			local manifest = train.manifest--[[@as Manifest]]

			local free_capacity, entry = nil, nil
			if stack_size then
				free_capacity = (train.item_slot_capacity - #train.entity.cargo_wagons * p_station.locked_slots) * stack_size
				for _, e in ipairs(manifest) do
					if e.name == item_name then
						free_capacity = free_capacity - e.count
						entry = e
					else
						free_capacity = free_capacity - ceil(e.count / item_prototypes[e.name].stack_size) * stack_size
					end
				end
			else
				free_capacity = train.fluid_capacity
				for _, e in ipairs(manifest) do
					if e.name == item_name then
						free_capacity = free_capacity - e.count
						entry = e
						break
					end
				end
			end

			--should always have capacity unless locked_slots changed since the train was dispatched
			if free_capacity > 0 then
				if not entry then
					entry = {name = item_name, type = item_type, count = 0}
					manifest[#manifest+1] = entry
				end

				local previous_deficit = remaining_deficit

				if remaining_deficit < free_capacity then
					entry.count = entry.count + remaining_deficit
					--check if train now has some capacity only usable by name
					if not name_ids and not (stack_size and entry.count < ceil(entry.count / stack_size) * stack_size) then
						name_ids = {train_id}
						pf_trains[item_name] = name_ids
						pf_trains_totals[item_name] = (pf_trains_totals[item_name] or 0) + 1
						name_removed = false
						pf_keys[item_name] = true
					end
					keep_name = true
					--check if train still has more capacity usable by type
					if type_ids and stack_size and floor((free_capacity - remaining_deficit) / stack_size) > 0 then
						keep_type = true
					end
					remaining_deficit = 0
				else
					entry.count = entry.count + free_capacity
					remaining_deficit = remaining_deficit - free_capacity
				end

				local schedule = train.entity.schedule
				assert(schedule, "train has no schedule")

				local record_index = schedule.current
				local record ---@type TrainScheduleRecord
				while true do
					record = schedule.records[record_index]
					if not record then
						error("could not find schedule record for provider")
					end
					if record.station == p_station.entity_stop.backer_name then
						break
					end
					record_index = record_index + 1
				end

				local condition_index = 1
				local condition ---@type CircuitCondition?
				while true do
					local wait_condition = record.wait_conditions[condition_index]
					if not wait_condition then
						condition = nil
						break
					end
					condition = wait_condition.condition
					if not condition or condition.first_signal.name == item_name then
						break
					end
					condition_index = condition_index + 1
				end

				local difference = previous_deficit - remaining_deficit
				if condition then
					condition.constant = condition.constant + difference
				else
					table_insert(record.wait_conditions, condition_index, {
						type = item_type.."_count", compare_type = "and",
						condition = {comparator = "≥", first_signal = {name = item_name, type = item_type}, constant = difference}
					})
				end
				train.entity.schedule = schedule

				if train.status == STATUS_P then
					set_comb1(map_data, p_station, manifest, -1)
				end
			end
		end

		if name_ids and not keep_name then
			table_remove(name_ids, 1)
			if not next(name_ids) then
				pf_trains[item_name], name_ids = nil, nil
				pf_trains_totals[item_name] = pf_trains_totals[item_name] > 1 and pf_trains_totals[item_name] - 1 or nil
				name_removed = true
			end
			pf_keys[item_name] = nil
		end
		if type_ids and not keep_type then
			for i = 1, #type_ids do
				if type_ids[i] == train_id then
					table_remove(type_ids, i)
					if not next(type_ids) then
						pf_trains[item_type], type_ids = nil, nil
						pf_trains_totals[item_type] = pf_trains_totals[item_type] > 1 and pf_trains_totals[item_type] - 1 or nil
						type_removed = true
					end
					pf_keys[item_type] = nil
					break
				end
			end
		end
		if not next(pf_keys) then train.pf_keys = nil end
	until remaining_deficit == 0

	if type_removed then
		local r_combined_p_priorities = r_station.r_combined_p_priorities
		local f, a = iterate_common_network_names(r_station, p_station)
		for other_name, _ in pairs(p_item_counts) do
			if r_item_counts[other_name] and not pf_trains[other_name] then
				local other_type = item_prototypes[other_name] and "item" or "fluid"
				if other_type == item_type then
					local combined_priority = provider_combine_priority(r_station, p_station, pf_trains, other_name, other_type)
					for other_network in f, a do
						r_combined_p_priorities[other_network..":"..other_name][p_station_id] = combined_priority
					end
				end
			end
		end
	elseif name_removed and not type_ids then
		local combined_priority = provider_combine_priority(r_station, p_station, pf_trains, item_name, item_type)
		for other_network in iterate_common_network_names(r_station, p_station) do
			r_station.r_combined_p_priorities[other_network..":"..item_name][p_station_id] = combined_priority
		end
	end

	local difference = original_deficit - remaining_deficit
	if difference == 0 then
		return --all trains became invalid or had extra slots locked
	end

	--only update the timestamp for additions at least as large as the threshold
	if difference >= (p_station.item_thresholds[item_name] or r_station.item_thresholds[item_name]) then
		r_station.r_item_timestamps[item_name] = increment_dispatch_counter(map_data)
		local combined_priority = requester_combine_priority(r_station, item_name)
		for other_network in iterate_network_names(r_station) do
			economy.combined_r_priorities[other_network..":"..item_name][r_station_id] = combined_priority
		end
	end

	r_station.deliveries[item_name] = (r_station.deliveries[item_name] or 0) + difference
	p_station.deliveries[item_name] = (p_station.deliveries[item_name] or 0) - difference

	-- assert(r_station.r_item_counts[item_name] + difference <= 0)
	-- assert(p_station.p_item_counts[item_name] - difference >= 0)

	profiler_update_total(item_type, difference)

	--prevent dispatches and delivery additions for these items until their stations are re-polled
	for other_network in iterate_all_network_names(r_station, p_station) do
		economy.items_requested[other_network..":"..item_name] = 0
	end

	set_comb2(map_data, r_station)
	set_comb2(map_data, p_station)
end

---@param map_data MapData
---@param mod_settings CybersynModSettings
local function tick_dispatch(map_data, mod_settings)
	--we do not dispatch more than one train per tick
	--psuedo-randomize what item (and what station) to check first so if trains available is low they choose orders psuedo-randomly
	--NOTE: this is an approximation algorithm for solving the assignment problem (bipartite graph weighted matching), the true solution would be to implement the simplex algorithm but I strongly believe most factorio players would prefer run-time efficiency over perfect train routing logic
	--NOTE: the above isn't even the full story, we can only use one edge per item per tick, which might break the assumptions of the simplex algorithm causing it to give imperfect solutions.
	profiler_reset("cybersyn_tick_dispatch.csv")

	local economy = map_data.economy
	local stations = map_data.stations
	local items_to_dispatch = economy.items_to_dispatch

	local network_item ---@type string
	local r_stations ---@type uint[]
	local p_stations ---@type uint[]
	while true do
		local size = #items_to_dispatch
		if size == 0 then
			map_data.tick_state = STATE_INIT
			profiler_write()
			return true
		end

		--randomizing the ordering should only matter if we run out of available trains
		local index = random(size)
		network_item = items_to_dispatch[index]

		--swap remove
		items_to_dispatch[index] = items_to_dispatch[size]
		items_to_dispatch[size] = nil

		--check that the item hasn't been disabled, and that there is at least one requester and one provider
		if economy.items_requested[network_item] == 1 then
			r_stations = economy.sorted_r_stations[network_item]
			if r_stations then
				p_stations = economy.sorted_p_stations[network_item]
				if p_stations then
					break
				end
				local item_name = string_match(network_item, ":(.*)")
				for _, station_id in ipairs(r_stations) do
					local station = stations[station_id]
					if -station.r_item_counts[item_name] >= station.item_thresholds[item_name] and not btest(station.display_state, 2) then
						station.display_state = station.display_state + 2
						update_display(map_data, station)
					end
				end
			end
		end
	end

	local network_name, item_name = string_match(network_item, "(.-):(.*)")
	local item_prototype, item_type, capacity_key, stack_size = game.item_prototypes[item_name], nil, nil, nil
	if item_prototype then
		item_type, capacity_key, stack_size = "item", "item_slot_capacity", item_prototype.stack_size
	else
		item_type, capacity_key = "fluid", "fluid_capacity"
	end

	local trains = map_data.trains
	local available_trains = map_data.available_trains[network_name]

	local matching_trains_cache = {}
	local p_train_distance_cache = {} --per provider but can reuse the table

	local add_item_r_station_id = nil ---@type uint?
	local add_item_p_station_id = nil ---@type uint?
	local add_item_count = nil ---@type int?

	local function sort_stations(sorted_stations, combined_priorities)
		table_sort(sorted_stations, function(id1, id2)
			return combined_priorities[id1] > combined_priorities[id2]
		end)
	end

	local function compare_trains(id1, id2)
		local train1, train2 = trains[id1], trains[id2]
		local val1, val2 = train1.priority, train2.priority
		if val1 == val2 then
			val1 = train1[capacity_key]; val2 = train2[capacity_key]
			if val1 == val2 then
				val1 = p_train_distance_cache[-id1]; val2 = p_train_distance_cache[-id2]
			end
		end
		return val1 > val2
	end

	sort_stations(r_stations, economy.combined_r_priorities[network_item])

	for _, r_station_id in ipairs(r_stations) do
		local r_station = stations[r_station_id]

		--extra block so goto can jump over local declarations
		do
			local r_threshold = r_station.item_thresholds[item_name]
			local r_below_threshold = -r_station.r_item_counts[item_name] < r_threshold

			if r_below_threshold then
				local pf_trains_totals = r_station.r_pf_trains_totals
				if not (pf_trains_totals[item_name] or pf_trains_totals[item_type]) or add_item_r_station_id then
					--no deliveries to update, or another requester already wants to update deliveries
					goto r_continue_below_threshold
				end
			end

			local r_mask = r_station.network_mask
			if r_station.network_name ~= network_name then
				r_mask = r_mask[network_name]
			end

			local r_over_limit = r_station.unused_trains_limit <= 0
			local r_disable_reservation = r_station.disable_reservation
			local r_allows_all_trains = r_station.allows_all_trains
			local r_accepted_layouts = r_station.accepted_layouts

			local reserve_station = nil ---@type Station?
			local reserve_threshold = nil ---@type int?
			local reserve_priority = nil ---@type int?

			local problem = 0
			local best_p_station = nil ---@type Station?

			sort_stations(p_stations, r_station.r_combined_p_priorities[network_item])

			for _, p_station_id in ipairs(p_stations) do
				local p_station = stations[p_station_id]

				local p_item_count = p_station.p_reserved_counts[network_item]
				if not p_item_count then
					p_item_count = p_station.p_item_counts[item_name]
				elseif p_item_count == 0 then
					--this provider was completely reserved by another requester
					goto p_continue
				end

				local p_mask = p_station.network_mask
				if p_station.network_name ~= network_name then
					p_mask = p_mask[network_name]
				end
				if not btest(r_mask, p_mask) then
					goto p_continue
				end

				if r_below_threshold then
					local pf_trains = p_station.p_pf_trains[r_station_id]
					if pf_trains and (pf_trains[item_name] or pf_trains[item_type]) then
						add_item_r_station_id, add_item_p_station_id, add_item_count = r_station_id, p_station_id, p_item_count
						goto r_continue_below_threshold
					end
					goto p_continue
				end

				local threshold = p_station.item_thresholds[item_name] or r_threshold
				local priority = p_station.item_priorities[item_name]

				if reserve_priority and (reserve_priority > priority or p_station.unused_trains_limit <= 0) then
					--we have a reservation, and have run out of same priority providers that aren't over limit
					goto r_continue
				end

				local pf_trains = p_station.p_pf_trains[r_station_id]
				if pf_trains and (pf_trains[item_name] or pf_trains[item_type]) then
					add_item_to_deliveries(map_data, r_station_id, p_station_id, network_name, item_name)
					profiler_write()
					return false
				end

				local disable_reservation = r_disable_reservation or p_station.disable_reservation
				if disable_reservation and (r_over_limit or p_station.unused_trains_limit <= 0) then
					--only needed to check for partly filled trains
					goto p_continue
				end

				if p_item_count < threshold then
					--prevent any other requesters from using this provider
					p_station.p_reserved_counts[network_item] = 0
					if not btest(p_station.display_state, 4) then
						p_station.display_state = p_station.display_state + 4
						update_display(map_data, p_station)
					end
					goto p_continue
				end

				if not reserve_station and not disable_reservation then
					reserve_station, reserve_threshold, reserve_priority = p_station, threshold, priority
					if r_over_limit or p_station.unused_trains_limit <= 0 then
						--requester is over limit, or there are no same priority providers that aren't over limit
						goto r_continue
					end
				end

				if not available_trains then
					if problem < 1 then
						problem = 1
						best_p_station = p_station
					end
					goto p_continue
				end

				--caching sorted trains like this is bad for cases where the first requester finds a train
				--however, it significantly helps when it doesn't, and those cases tend to be the slowest, thus the ones to optimise
				local p_matching_trains = matching_trains_cache[p_station_id]
				if not p_matching_trains then
					local p_allows_all_trains = p_station.allows_all_trains
					local p_accepted_layouts = p_station.accepted_layouts
					p_matching_trains = {}
					for train_id, _ in pairs(available_trains) do
						local train = trains[train_id]
						local t_mask = train.network_mask
						if train.network_name ~= network_name then
							t_mask = t_mask[network_name]
						end
						if not btest(p_mask, t_mask) or not (p_allows_all_trains or p_accepted_layouts[train.layout_id]) then
							goto t_continue
						end
						local t_entity = train.entity
						if not t_entity.valid or train.se_is_being_teleported then
							goto t_continue
						end
						--using indices from 1 to 1024 can cause expensive rehashes with factorio's table implementation
						--there was talk on discord of fixing this, but for now we avoid it here by negating the id
						--we also negate the distance so it has the same ordering as priority and capacity
						p_train_distance_cache[-train_id] = -get_distance_squared(p_station, t_entity.front_stock--[[@as LuaEntity]])
						p_matching_trains[#p_matching_trains+1] = train_id
						::t_continue::
					end
					table_sort(p_matching_trains, compare_trains)
					matching_trains_cache[p_station_id] = p_matching_trains
				end

				if stack_size then
					threshold = ceil(threshold / stack_size)
				end

				for _, train_id in ipairs(p_matching_trains) do
					local train = trains[train_id]

					local t_mask = train.network_mask
					if train.network_name ~= network_name then
						t_mask = t_mask[network_name]
					end
					if not btest(r_mask, t_mask) or not (r_allows_all_trains or r_accepted_layouts[train.layout_id]) then
						if problem < 3 then
							problem = 3
							best_p_station = p_station
						end
						goto t_continue
					end

					if train[capacity_key] < threshold then
						if problem < 4 then
							problem = 4
							best_p_station = p_station
						end
						goto t_continue
					end

					local manifest, pf_keys = create_manifest(map_data, r_station_id, p_station_id, train_id, network_name, item_name)
					create_delivery(map_data, r_station_id, p_station_id, train_id, manifest, pf_keys)
					profiler_write()
					do return false end

					::t_continue::
				end

				if problem < 2 then
					problem = 2
					best_p_station = p_station
				end

				::p_continue::
			end

			if r_below_threshold then
				goto r_continue_below_threshold
			end

			::r_continue::

			if reserve_station then
				local reserved_counts = reserve_station.p_reserved_counts
				reserved_counts[network_item] = (reserved_counts[network_item] or reserve_station.p_item_counts[item_name]) - reserve_threshold
			end

			--TODO: find a way to show more details about problems, probably in the manager or combinator gui
			if best_p_station then
				if problem == 1 then
					--no available trains on the network
					send_alert_missing_train(r_station.entity_stop, best_p_station.entity_stop)
				elseif problem == 2 then
					--no train matches the provider's mask and layout
					send_alert_no_train_matches_provider(r_station.entity_stop, best_p_station.entity_stop)
				elseif problem == 3 then
					--no train matches the requester's mask and layout
					send_alert_no_train_matches_requester(r_station.entity_stop, best_p_station.entity_stop)
				elseif problem == 4 then
					--no train has enough capacity to meet the threshold
					send_alert_no_train_has_capacity(r_station.entity_stop, best_p_station.entity_stop)
				end
			end

			if not btest(r_station.display_state, 2) then
				r_station.display_state = r_station.display_state + 2
				update_display(map_data, r_station)
			end
		end

		::r_continue_below_threshold::
	end

	if add_item_r_station_id then ---@cast add_item_p_station_id uint
		stations[add_item_p_station_id].p_reserved_counts[network_item] = add_item_count
		add_item_to_deliveries(map_data, add_item_r_station_id, add_item_p_station_id, network_name, item_name)
		profiler_write()
		return false
	end

	--allow adding as a secondary item to dispatches processed after this one
	economy.items_requested[network_item] = nil
	profiler_write()
	return false
end

---@param map_data MapData
---@param r_station_id uint
---@param item_name string
---@param item_type string
---@param network_item string
local function requester_add_to_economy(map_data, r_station_id, item_name, item_type, network_item)
	local economy = map_data.economy
	local stations = map_data.stations
	local r_station = stations[r_station_id]

	local r_stations, combined_r_priorities = economy.sorted_r_stations[network_item], nil
	if not r_stations then
		r_stations, combined_r_priorities = {}, {}
		economy.sorted_r_stations[network_item] = r_stations
		economy.combined_r_priorities[network_item] = combined_r_priorities
	else
		combined_r_priorities = economy.combined_r_priorities[network_item]
	end
	r_stations[#r_stations+1] = r_station_id
	combined_r_priorities[r_station_id] = requester_combine_priority(r_station, item_name)

	local combined_p_priorities = {}
	r_station.r_combined_p_priorities[network_item] = combined_p_priorities

	local p_stations = economy.sorted_p_stations[network_item]
	if p_stations then
		for _, p_station_id in ipairs(p_stations) do
			local p_station = stations[p_station_id]
			combined_p_priorities[p_station_id] = provider_combine_priority(r_station, p_station, p_station.p_pf_trains[r_station_id], item_name, item_type)
		end
	end
end

---@param map_data MapData
---@param r_station_id uint
---@param network_item string
function requester_remove_from_economy(map_data, r_station_id, network_item)
	local economy = map_data.economy

	local r_stations = economy.sorted_r_stations[network_item]
	local num_stations = #r_stations
	if num_stations > 1 then
		for i = 1, num_stations do
			if r_stations[i] == r_station_id then
				r_stations[i] = r_stations[num_stations]
				r_stations[num_stations] = nil
				break
			end
		end
		economy.combined_r_priorities[network_item][r_station_id] = nil
	else
		economy.sorted_r_stations[network_item] = nil
		economy.combined_r_priorities[network_item] = nil
	end

	map_data.stations[r_station_id].r_combined_p_priorities[network_item] = nil
end

---@param map_data MapData
---@param p_station_id uint
---@param item_name string
---@param item_type string
---@param network_item string
local function provider_add_to_economy(map_data, p_station_id, item_name, item_type, network_item)
	local economy = map_data.economy

	local p_stations = economy.sorted_p_stations[network_item]
	if not p_stations then
		p_stations = {}
		economy.sorted_p_stations[network_item] = p_stations
	end
	p_stations[#p_stations+1] = p_station_id

	local r_stations = economy.sorted_r_stations[network_item]
	if r_stations then
		local stations = map_data.stations
		local p_station = stations[p_station_id]
		local p_pf_trains = p_station.p_pf_trains
		for _, r_station_id in ipairs(r_stations) do
			local r_station = stations[r_station_id]
			r_station.r_combined_p_priorities[network_item][p_station_id] = provider_combine_priority(r_station, p_station, p_pf_trains[r_station_id], item_name, item_type)
		end
	end
end

---@param map_data MapData
---@param p_station_id uint
---@param network_item string
function provider_remove_from_economy(map_data, p_station_id, network_item)
	local economy = map_data.economy

	local r_stations = economy.sorted_r_stations[network_item]
	if r_stations then
		local stations = map_data.stations
		for _, r_station_id in ipairs(r_stations) do
			stations[r_station_id].r_combined_p_priorities[network_item][p_station_id] = nil
		end
	end

	local p_stations = economy.sorted_p_stations[network_item]
	local num_stations = #p_stations
	if num_stations > 1 then
		for i = 1, num_stations do
			if p_stations[i] == p_station_id then
				p_stations[i] = p_stations[num_stations]
				p_stations[num_stations] = nil
				break
			end
		end
	else
		economy.sorted_p_stations[network_item] = nil
	end
end

---@param map_data MapData
---@param mod_settings CybersynModSettings
local function tick_poll_station(map_data, mod_settings)
	profiler_reset("cybersyn_tick_poll_station.csv")

	local tick_data = map_data.tick_data
	local economy = map_data.economy
	local stations = map_data.stations

	local station_id
	local station
	while true do--choose a station
		tick_data.i = (tick_data.i or 0) + 1
		if tick_data.i > #map_data.active_station_ids then
			tick_data.i = nil
			map_data.tick_state = STATE_DISPATCH
			profiler_write()
			return true
		end
		station_id = map_data.active_station_ids[tick_data.i]
		station = stations[station_id]
		if station and not station.warmup_start_time then
			if station.network_name then
				break
			end
		else
			--lazy delete removed stations
			table_remove(map_data.active_station_ids, tick_data.i)
			tick_data.i = tick_data.i - 1
		end
	end

	if not station.entity_stop.valid or not station.entity_comb1.valid or (station.entity_comb2 and not station.entity_comb2.valid) then
		on_station_broken(map_data, station_id, station)
		profiler_write()
		return false
	end

	local was_under_limit = station.unused_trains_limit > 0
	station.unused_trains_limit = station.entity_stop.trains_limit - station.deliveries_total
	station.locked_slots = mod_settings.locked_slots
	local is_under_limit = station.unused_trains_limit > 0

	local is_network_each = station.network_name == NETWORK_EACH
	local f, a
	if is_network_each then
		f, a = next, {}--[[@as {[string]: int}]]
		station.network_mask = a
	else
		f, a = once, station.network_name--[[@as string]]
		station.network_mask = mod_settings.network_mask
	end

	local comb2_thresholds, comb2_priority = nil, nil
	local comb2_signals = get_comb2_signals(station)
	if comb2_signals then
		comb2_thresholds = {}
		for _, v in pairs(comb2_signals) do
			local item_name, item_type, item_count = v.signal.name, v.signal.type, v.count
			if item_name then
				if item_type ~= "virtual" then
					comb2_thresholds[item_name] = abs(item_count)
				elseif item_name == SIGNAL_PRIORITY then
					comb2_priority = item_count
				end
			end
		end
	end

	local comb1_threshold, comb1_priority = mod_settings.r_threshold, mod_settings.priority
	local comb1_signals = get_comb1_signals(station)
	for k, v in pairs(comb1_signals) do
		local item_name, item_type, item_count = v.signal.name, v.signal.type, v.count
		if item_name then
			if item_name == station.network_name then
				station.network_mask = item_count
				comb1_signals[k] = nil
			elseif item_type == "virtual" then
				if item_name == REQUEST_THRESHOLD then
					comb1_threshold = abs(item_count)
				elseif item_name == SIGNAL_PRIORITY then
					comb1_priority = item_count
				elseif item_name == LOCKED_SLOTS then
					station.locked_slots = max(item_count, 0)
				elseif is_network_each then
					station.network_mask[item_name] = item_count
				end
				comb1_signals[k] = nil
			end
		else
			comb1_signals[k] = nil
		end
	end

	local poll_values, item_thresholds, r_item_counts, p_item_counts = {}, {}, {}, {}
	local old_poll_values, item_priorities = station.poll_values, station.item_priorities

	station.poll_values = poll_values
	station.item_thresholds = item_thresholds
	station.r_item_counts = r_item_counts
	station.p_item_counts = p_item_counts
	station.p_reserved_counts = {}

	local item_prototypes_if_stack = (station.is_stack or nil) and game.item_prototypes
	local is_requesting_nothing = true

	for _, v in pairs(comb1_signals) do
		local item_name, item_type, item_count = v.signal.name--[[@as string]], v.signal.type, v.count
		local deliveries = station.deliveries[item_name] or 0
		item_count = item_count + deliveries

		local item_threshold = comb2_thresholds and comb2_thresholds[item_name]
		local item_priority = item_threshold and comb2_priority or comb1_priority

		local old_item_priority = item_priorities[item_name]
		item_priorities[item_name] = item_priority

		if station.is_r and deliveries >= 0 and item_count < 0 then
			r_item_counts[item_name] = item_count
			if not item_threshold then
				item_threshold = comb1_threshold
			end
			if item_prototypes_if_stack and item_type == "item" then
				item_threshold = item_threshold * item_prototypes_if_stack[item_name].stack_size
			end
			item_thresholds[item_name] = item_threshold
			for network_name in f, a do
				local network_item = network_name..":"..item_name
				local old_poll_value = old_poll_values[network_item]
				if old_poll_value ~= -1 then
					if old_poll_value then
						provider_remove_from_economy(map_data, station_id, network_item)
						old_poll_values[network_item] = nil
					end
					if not station.r_item_timestamps[item_name] then
						station.r_item_timestamps[item_name] = increment_dispatch_counter(map_data)
					end
					requester_add_to_economy(map_data, station_id, item_name, item_type, network_item)
				elseif old_item_priority ~= item_priority then
					economy.combined_r_priorities[network_item][station_id] = requester_combine_priority(station, item_name)
				end
				if not economy.items_requested[network_item] and (-item_count >= item_threshold or station.r_pf_trains_totals[item_name] or station.r_pf_trains_totals[item_type]) then
					economy.items_requested[network_item] = 1
					economy.items_to_dispatch[#economy.items_to_dispatch+1] = network_item
				end
				poll_values[network_item] = -1
			end
			is_requesting_nothing = false
		elseif station.is_p and deliveries <= 0 and item_count > 0 then
			p_item_counts[item_name] = item_count
			if item_threshold then
				if item_prototypes_if_stack and item_type == "item" then
					item_threshold = item_threshold * item_prototypes_if_stack[item_name].stack_size
				end
				item_thresholds[item_name] = item_threshold
			end
			for network_name in f, a do
				local network_item = network_name..":"..item_name
				local old_poll_value = old_poll_values[network_item]
				if old_poll_value ~= 1 then
					if old_poll_value then
						requester_remove_from_economy(map_data, station_id, network_item)
						old_poll_values[network_item] = nil
						station.r_item_timestamps[item_name] = nil
					end
					provider_add_to_economy(map_data, station_id, item_name, item_type, network_item)
				elseif old_item_priority ~= item_priority or was_under_limit ~= is_under_limit then
					local r_stations = economy.sorted_r_stations[network_item]
					if r_stations then
						local p_pf_trains = station.p_pf_trains
						for _, r_station_id in ipairs(r_stations) do
							local r_station = stations[r_station_id]
							r_station.r_combined_p_priorities[network_item][station_id] = provider_combine_priority(r_station, station, p_pf_trains[r_station_id], item_name, item_type)
						end
					end
				end
				poll_values[network_item] = 1
			end
		end
	end

	for network_item, old_poll_value in pairs(old_poll_values) do
		if not poll_values[network_item] then
			local item_name = string_match(network_item, ":(.*)")
			if old_poll_value == -1 then
				requester_remove_from_economy(map_data, station_id, network_item)
				if station.r_item_counts[item_name] then
					goto keep_item
				end
				station.r_item_timestamps[item_name] = nil
			else
				provider_remove_from_economy(map_data, station_id, network_item)
				if station.p_item_counts[item_name] then
					goto keep_item
				end
			end
			station.item_priorities[item_name] = nil
		end
		::keep_item:: --item remains on other networks
	end

	if station.display_state > 1 then
		if is_requesting_nothing and btest(station.display_state, 2) then
			station.display_state = station.display_state - 2
			update_display(map_data, station)
		end
		if btest(station.display_state, 8) then
			if btest(station.display_state, 4) then
				station.display_state = station.display_state - 4
			else
				station.display_state = station.display_state - 8
				update_display(map_data, station)
			end
		elseif btest(station.display_state, 4) then
			station.display_state = station.display_state + 4
		end
	end

	profiler_write()
	return false
end

---@param map_data MapData
---@param mod_settings CybersynModSettings
local function tick_poll_entities(map_data, mod_settings)
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
local function tick_init(map_data, mod_settings)
	map_data.economy.items_requested = {}
	map_data.economy.items_to_dispatch = {}

	while #map_data.warmup_station_ids > 0 do
		local id = map_data.warmup_station_ids[1]
		local station = map_data.stations[id]
		if station then
			local cycles = map_data.warmup_station_cycles[id]
			--force a station to wait at least 1 cycle so we can be sure active_station_ids was flushed of duplicates
			if cycles > 0 then
				if station.warmup_start_time + mod_settings.warmup_time*mod_settings.tps < map_data.total_ticks then
					station.warmup_start_time = nil
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
	if PROFILING_ENABLED and not profiler then
		game.write_file("cybersyn_tick_poll_station.csv", "\n", true)
		game.write_file("cybersyn_tick_dispatch.csv", "\n", true)
		profiler = game.create_profiler(true)
		profiler_totals = {item = 0, fluid = 0, train = 0}
	end

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

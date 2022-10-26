--By Mami
local get_distance = require("__flib__.misc").get_distance
local math = math
local INF = math.huge

local create_loading_order_condition = {type = "inactivity", compare_type = "and", ticks = 120}
---@param stop LuaEntity
---@param manifest Manifest
function create_loading_order(stop, manifest)
	local condition = {}
	for _, item in ipairs(manifest) do
		local cond_type
		if item.type == "fluid" then
			cond_type = "fluid_count"
		else
			cond_type = "item_count"
		end

		condition[#condition + 1] = {
			type = cond_type,
			compare_type = "and",
			condition = {comparator = "≥", first_signal = {type = item.type, name = item.name}, constant = item.count}
		}
	end
	condition[#condition + 1] = create_loading_order_condition
	return {station = stop.backer_name, wait_conditions = condition}
end

local create_unloading_order_condition = {{type = "empty", compare_type = "and"}}
---@param stop LuaEntity
function create_unloading_order(stop)
	return {station = stop.backer_name, wait_conditions = create_unloading_order_condition}
end

local create_inactivity_order_condition = {{type = "inactivity", compare_type = "and", ticks = 120}}
---@param depot_name string
function create_inactivity_order(depot_name)
	return {station = depot_name, wait_conditions = create_inactivity_order_condition}
end

---@param stop LuaEntity
local function create_direct_to_station_order(stop)
	return {rail = stop.connected_rail, rail_direction = stop.connected_rail_direction}
end

---@param depot_name string
function create_depot_schedule(depot_name)
	return {current = 1, records = {create_inactivity_order(depot_name)}}
end

---@param depot_name string
---@param p_stop LuaEntity
---@param r_stop LuaEntity
---@param manifest Manifest
function create_manifest_schedule(depot_name, p_stop, r_stop, manifest)
	return {current = 1, records = {
		create_inactivity_order(depot_name),
		create_direct_to_station_order(p_stop),
		create_loading_order(p_stop, manifest),
		create_direct_to_station_order(r_stop),
		create_unloading_order(r_stop),
	}}
end

---@param station Station
local function get_signals(station)
	if station.entity_comb1.valid then
		local signals = station.entity_comb1.get_merged_signals(defines.circuit_connector_id.combinator_input)
		return signals
	else
		return nil
	end
end

---@param map_data MapData
---@param comb LuaEntity
---@param signals ConstantCombinatorParameters[]?
function set_combinator_output(map_data, comb, signals)
	if comb.valid then
		local out = map_data.to_output[comb.unit_number]
		if out.valid then
			out.get_or_create_control_behavior().parameters = signals
		else
			--TODO: error logging?
		end
	else
		--TODO: error logging?
	end
end

---@param map_data MapData
---@param station Station
local function set_comb2(map_data, station)
	if station.entity_comb2 then
		local deliveries = station.deliveries
		local signals = {}
		for item_name, count in pairs(deliveries) do
			local i = #signals + 1
			local item_type = game.item_prototypes[item_name].type
			signals[i] = {index = i, signal = {type = item_type, name = item_name}, count = count}
		end
		set_combinator_output(map_data, station.entity_comb2, signals)
	end
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
---@param station Station
---@param signal SignalID
local function get_thresholds(map_data, station, signal)
	local comb2 = station.entity_comb2
	if comb2 and comb2.valid then
		local count = comb2.get_merged_signal(signal, defines.circuit_connector_id.combinator_input)
		if count > 0 then
			return station.r_threshold, count
		elseif count < 0 then
			return -count, station.p_threshold
		end
	end
	return station.r_threshold, station.p_threshold
end

---@param stop0 LuaEntity
---@param stop1 LuaEntity
local function get_stop_dist(stop0, stop1)
	return get_distance(stop0.position, stop1.position)
end


---@param station Station
---@param layout_id uint
local function station_accepts_layout(station, layout_id)
	return true
end



---@param map_data MapData
---@param r_station_id uint
---@param p_station_id uint
---@param item_type string
local function get_valid_train(map_data, r_station_id, p_station_id, item_type)
	--NOTE: this code is the critical section for run-time optimization
	local r_station = map_data.stations[r_station_id]
	local p_station = map_data.stations[p_station_id]

	local p_to_r_dist = get_stop_dist(p_station.entity_stop, r_station.entity_stop)
	if p_to_r_dist == INF then
		return nil, INF
	end

	local best_train = nil
	local best_dist = INF
	local valid_train_exists = false

	local is_fluid = item_type == "fluid"
	for train_id, _ in pairs(map_data.trains_available) do
		local train = map_data.trains[train_id]
		--check cargo capabilities
		--check layout validity for both stations
		if
		((is_fluid and train.fluid_capacity > 0) or (not is_fluid and train.item_slot_capacity > 0))
		and station_accepts_layout(r_station, train.layout_id)
		and station_accepts_layout(p_station, train.layout_id)
		and train.entity.station
		then
			valid_train_exists = true
			--check if exists valid path
			--check if path is shortest so we prioritize locality
			local d_to_p_dist = get_stop_dist(train.entity.station, p_station.entity_stop)

			local dist = d_to_p_dist
			if dist < best_dist then
				best_dist = dist
				best_train = train
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
---@param train Train
---@param primary_item_name string
---@param economy Economy
local function send_train_between(map_data, r_station_id, p_station_id, train, primary_item_name, economy)
	local r_station = map_data.stations[r_station_id]
	local p_station = map_data.stations[p_station_id]

	local requests = {}
	local manifest = {}

	local r_signals = get_signals(r_station)
	if r_signals then
		for k, v in pairs(r_signals) do
			local item_name = v.signal.name
			local item_count = v.count
			local item_type = v.signal.type
			if item_name and item_type and item_type ~= "virtual" then
				local effective_item_count = item_count + (r_station.deliveries[item_name] or 0)
				local r_threshold, p_threshold = get_thresholds(map_data, r_station, v.signal)
				if -effective_item_count >= r_threshold then
					requests[item_name] = -effective_item_count
				end
			end
		end
	end

	local p_signals = get_signals(p_station)
	if p_signals then
		for k, v in pairs(p_signals) do
			local item_name = v.signal.name
			local item_count = v.count
			local item_type = v.signal.type
			if item_name and item_type and item_type ~= "virtual" then
				local effective_item_count = item_count + (p_station.deliveries[item_name] or 0)
				local r_threshold, p_threshold = get_thresholds(map_data, r_station, v.signal)
				if effective_item_count >= p_threshold then
					local r = requests[item_name]
					if r then
						local item = {name = item_name, count = math.min(r, effective_item_count), type = item_type}
						if item_name == primary_item_name then
							manifest[#manifest + 1] = manifest[1]
							manifest[1] = item
						else
							manifest[#manifest + 1] = item
						end
					end
				end
			end
		end
	end

	local locked_slots = math.max(p_station.locked_slots, r_station.locked_slots)
	local total_slots_left = train.item_slot_capacity
	if locked_slots > 0 then
		total_slots_left = math.max(total_slots_left - #train.entity.cargo_wagons*locked_slots, math.min(total_slots_left, #train.entity.cargo_wagons))
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
			local stack_size = game.item_prototypes[item.name].stack_size
			local slots = math.ceil(item.count/stack_size)
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

	r_station.last_delivery_tick = economy.total_ticks
	p_station.last_delivery_tick = economy.total_ticks

	r_station.deliveries_total = r_station.deliveries_total + 1
	p_station.deliveries_total = p_station.deliveries_total + 1

	for _, item in ipairs(manifest) do
		assert(item.count > 0, "main.lua error, transfer amount was not positive")

		r_station.deliveries[item.name] = (r_station.deliveries[item.name] or 0) + item.count
		p_station.deliveries[item.name] = (p_station.deliveries[item.name] or 0) - item.count

		local r_stations = economy.r_stations_all[item.name]
		local p_stations = economy.p_stations_all[item.name]
		for i, id in ipairs(r_stations) do
			if id == r_station_id then
				table.remove(r_stations, i)
				break
			end
		end
		for i, id in ipairs(p_stations) do
			if id == p_station_id then
				table.remove(p_stations, i)
				break
			end
		end
	end

	map_data.trains_available[train.entity.id] = nil
	train.status = STATUS_D_TO_P
	train.p_station_id = p_station_id
	train.r_station_id = r_station_id
	train.manifest = manifest

	train.entity.schedule = create_manifest_schedule(train.depot_name, p_station.entity_stop, r_station.entity_stop, manifest)
	set_comb2(map_data, p_station)
	set_comb2(map_data, r_station)
end

---@param map_data MapData
function tick(map_data, mod_settings)
	local total_ticks = map_data.total_ticks
	local stations = map_data.stations
	local economy = {
		r_stations_all = {},
		p_stations_all = {},
		all_items = {},
		total_ticks = total_ticks,
	}
	local r_stations_all = economy.r_stations_all
	local p_stations_all = economy.p_stations_all
	local all_items = economy.all_items

	for station_id, station in pairs(stations) do
		if station.deliveries_total < station.entity_stop.trains_limit then
			station.r_threshold = mod_settings.r_threshold
			station.p_threshold = mod_settings.p_threshold
			station.priority = 0
			station.locked_slots = 0
			local signals = get_signals(station)
			if signals then
				for k, v in pairs(signals) do
					local item_name = v.signal.name
					local item_count = v.count
					local item_type = v.signal.type
					if item_name and item_type then
						if item_type == "virtual" then
							if item_name == SIGNAL_PRIORITY then
								station.priority = item_count
							elseif item_name == REQUEST_THRESHOLD then
								station.r_threshold = math.abs(item_count)
							elseif item_name == PROVIDE_THRESHOLD then
								station.p_threshold = math.abs(item_count)
							elseif item_name == LOCKED_SLOTS then
								station.locked_slots = math.max(item_count, 0)
							end
							signals[k] = nil
						end
					else
						signals[k] = nil
					end
				end
				for k, v in pairs(signals) do
					local item_name = v.signal.name
					local item_count = v.count
					local effective_item_count = item_count + (station.deliveries[item_name] or 0)
					local r_threshold, p_threshold = get_thresholds(map_data, station, v.signal)

					if item_name then
						if -effective_item_count >= r_threshold then
							if r_stations_all[item_name] == nil then
								r_stations_all[item_name] = {}
								p_stations_all[item_name] = {}
								all_items[#all_items + 1] = item_name
								all_items[#all_items + 1] = v.signal.type
							end
							table.insert(r_stations_all[item_name], station_id)
						elseif effective_item_count >= p_threshold then
							if r_stations_all[item_name] == nil then
								r_stations_all[item_name] = {}
								p_stations_all[item_name] = {}
								all_items[#all_items + 1] = item_name
								all_items[#all_items + 1] = v.signal.type
							end
							table.insert(p_stations_all[item_name], station_id)
						end
					end
				end
			end
		end
	end

	local failed_because_missing_trains = {}
	--we do not dispatch more than one train per station per tick
	--psuedo-randomize what item (and what station) to check first so if trains available is low they choose orders psuedo-randomly
	local start_i = 2*(total_ticks%(#all_items/2)) + 1
	for item_i = 0, #all_items - 1, 2 do
		local item_name = all_items[(start_i + item_i - 1)%#all_items + 1]
		local item_type = all_items[(start_i + item_i)%#all_items + 1]
		local r_stations = r_stations_all[item_name]
		local p_stations = p_stations_all[item_name]

		--NOTE: this is an approximation algorithm for solving the assignment problem (bipartite graph weighted matching), the true solution would be to implement the simplex algorithm (and run it twice to compare the locality solution to the round-robin solution) but I strongly believe most factorio players would prefer run-time efficiency over perfect train routing logic
		if #r_stations > 0 and #p_stations > 0 then
			if #r_stations <= #p_stations then
				--probably backpressure, prioritize locality
				repeat
					local i = total_ticks%#r_stations + 1
					local r_station_id = table.remove(r_stations, i)

					local best = 0
					local best_train = nil
					local best_dist = INF
					local highest_prior = -INF
					local could_have_been_serviced = false
					for j, p_station_id in ipairs(p_stations) do
						local train, d = get_valid_train(map_data, r_station_id, p_station_id, item_type)
						local prior = stations[p_station_id].priority
						if prior > highest_prior or (prior == highest_prior and d < best_dist) then
							if train then
								best = j
								best_dist = d
								best_train = train
								highest_prior = prior
							elseif d < INF then
								could_have_been_serviced = true
								best = j
							end
						end
					end
					if best_train then
						send_train_between(map_data, r_station_id, p_stations[best], best_train, item_name, economy)
					elseif could_have_been_serviced then
						send_missing_train_alert_for_stops(stations[r_station_id].entity_stop, p_stations[best].entity_stop)
					end
				until #r_stations == 0
			else
				--prioritize round robin
				repeat
					local j = total_ticks%#p_stations + 1
					local p_station_id = table.remove(p_stations, j)

					local best = 0
					local best_train = nil
					local lowest_tick = INF
					local highest_prior = -INF
					local could_have_been_serviced = false
					for i, r_station_id in ipairs(r_stations) do
						local r_station = stations[r_station_id]
						local prior = r_station.priority
						if prior > highest_prior or (prior == highest_prior and r_station.last_delivery_tick < lowest_tick) then
							local train, d = get_valid_train(map_data, r_station_id, p_station_id, item_type)
							if train then
								best = i
								best_train = train
								lowest_tick = r_station.last_delivery_tick
								highest_prior = prior
							elseif d < INF then
								could_have_been_serviced = true
								best = i
							end
						end
					end
					if best_train then
						send_train_between(map_data, r_stations[best], p_station_id, best_train, item_name, economy)
					elseif could_have_been_serviced then
						send_missing_train_alert_for_stops(stations[best].entity_stop, p_stations[p_station_id].entity_stop)
					end
				until #p_stations == 0
			end
		end
	end
end

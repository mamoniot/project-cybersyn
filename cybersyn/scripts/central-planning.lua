--By Mami
local get_distance = require("__flib__.misc").get_distance
local min = math.min
local max = math.max
local abs = math.abs
local ceil = math.ceil
local INF = math.huge
local btest = bit32.btest
local band = bit32.band

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
	local comb = station.entity_comb1
	if comb.valid and (comb.status == defines.entity_status.working or comb.status == defines.entity_status.low_power) then
		return comb.get_merged_signals(defines.circuit_connector_id.combinator_input)
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
		end
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
			local item_type = game.item_prototypes[item_name].type--NOTE: this is expensive
			signals[i] = {index = i, signal = {type = item_type, name = item_name}, count = -count}
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



---@param map_data MapData
---@param r_station_id uint
---@param p_station_id uint
---@param item_type string
local function get_valid_train(map_data, r_station_id, p_station_id, item_type)
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
			if
			btest(netand, depot.network_flag) and
			((is_fluid and train.fluid_capacity > 0) or (not is_fluid and train.item_slot_capacity > 0)) and
			(r_station.is_all or r_station.accepted_layouts[layout_id]) and
			(p_station.is_all or p_station.accepted_layouts[layout_id])
			then
				valid_train_exists = true
				--check if exists valid path
				--check if path is shortest so we prioritize locality
				local d_to_p_dist = get_stop_dist(depot.entity_stop, p_station.entity_stop) - DEPOT_PRIORITY_MULT*depot.priority

				local dist = d_to_p_dist
				if dist < best_dist then
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

	local requests = {}
	local manifest = {}

	local r_signals = r_station.tick_signals
	if r_signals then
		for k, v in pairs(r_signals) do
			---@type string
			local item_name = v.signal.name
			local item_count = v.count
			local effective_item_count = item_count + (r_station.deliveries[item_name] or 0)
			if effective_item_count < 0 and item_count < 0 then
				requests[item_name] = -effective_item_count
			end
		end
	end

	local p_signals = p_station.tick_signals
	if p_signals then
		for k, v in pairs(p_signals) do
			local item_name = v.signal.name
			local item_count = v.count
			local item_type = v.signal.type
			local effective_item_count = item_count + (p_station.deliveries[item_name] or 0)
			if effective_item_count > 0 and item_count > 0 then
				local r = requests[item_name]
				if r then
					local item = {name = item_name, type = item_type, count = min(r, effective_item_count)}
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

	local locked_slots = max(p_station.locked_slots, r_station.locked_slots)
	local total_slots_left = train.item_slot_capacity
	if locked_slots > 0 then
		total_slots_left = max(total_slots_left - #train.entity.cargo_wagons*locked_slots, min(total_slots_left, #train.entity.cargo_wagons))
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

	for _, item in ipairs(manifest) do
		assert(item.count > 0, "main.lua error, transfer amount was not positive")

		r_station.deliveries[item.name] = (r_station.deliveries[item.name] or 0) + item.count
		p_station.deliveries[item.name] = (p_station.deliveries[item.name] or 0) - item.count

		local item_network_name = network_name..":"..item.name
		local r_stations = economy.all_r_stations[item_network_name]
		local p_stations = economy.all_p_stations[item_network_name]
		--NOTE: one of these will be redundant
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

	remove_available_train(map_data, depot)
	train.status = STATUS_D_TO_P
	train.p_station_id = p_station_id
	train.r_station_id = r_station_id
	train.manifest = manifest

	train.entity.schedule = create_manifest_schedule(train.depot_name, p_station.entity_stop, r_station.entity_stop, manifest)
	set_comb2(map_data, p_station)
	set_comb2(map_data, r_station)
end



---@param map_data MapData
local function tick_poll_depot(map_data)
	local depot_id
	do--get next depot id
		local tick_data = map_data.tick_data
		while true do
			if tick_data.network == nil then
				tick_data.network_name, tick_data.network = next(map_data.trains_available)
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

		if station.network_name and station.deliveries_total < station.entity_stop.trains_limit then
			station.r_threshold = mod_settings.r_threshold
			station.p_threshold = mod_settings.p_threshold
			station.priority = 0
			station.locked_slots = 0
			station.network_flag = mod_settings.network_flag
			local signals = get_signals(station)
			station.tick_signals = signals
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
								--NOTE: thresholds must be >0 or they will cause a crash
								station.r_threshold = abs(item_count)
							elseif item_name == PROVIDE_THRESHOLD and item_count ~= 0 then
								station.p_threshold = abs(item_count)
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
					local item_name = v.signal.name
					local item_count = v.count
					local effective_item_count = item_count + (station.deliveries[item_name] or 0)
					local r_threshold, p_threshold = get_thresholds(map_data, station, v.signal)

					if -effective_item_count >= r_threshold and -item_count >= r_threshold then
						local item_network_name = station.network_name..":"..item_name
						local stations = all_r_stations[item_network_name]
						if stations == nil then
							stations = {}
							all_r_stations[item_network_name] = stations
							all_names[#all_names + 1] = item_network_name
							all_names[#all_names + 1] = v.signal
						end
						stations[#stations + 1] = station_id
					elseif effective_item_count >= p_threshold and item_count >= p_threshold then
						local item_network_name = station.network_name..":"..item_name
						local stations = all_p_stations[item_network_name]
						if stations == nil then
							stations = {}
							all_p_stations[item_network_name] = stations
						end
						stations[#stations + 1] = station_id
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
	--we do not dispatch more than one train per station per tick
	--psuedo-randomize what item (and what station) to check first so if trains available is low they choose orders psuedo-randomly
	--NOTE: It may be better for performance to update stations one tick at a time rather than all at once, however this does mean more  redundant data will be generated and discarded each tick. Once we have a performance test-bed it will probably be worth checking.
	local tick_data = map_data.tick_data
	local all_r_stations = map_data.economy.all_r_stations
	local all_p_stations = map_data.economy.all_p_stations
	local all_names = map_data.economy.all_names
	local stations = map_data.stations

	local size = #all_names
	if tick_data.start_i == nil and size > 0 then
		--semi-randomized starting item
		tick_data.start_i = 2*(map_data.total_ticks%(size/2)) + 1
		tick_data.offset_i = 0
	elseif size == 0 or tick_data.offset_i >= size then
		tick_data.start_i = nil
		tick_data.offset_i = nil
		map_data.tick_state = STATE_INIT
		return true
	end
	local name_i = tick_data.start_i + tick_data.offset_i
	tick_data.offset_i = tick_data.offset_i + 2

	local item_network_name = all_names[(name_i - 1)%size + 1]
	local signal = all_names[(name_i)%size + 1]
	local item_name = signal.name
	local item_type = signal.type
	local r_stations = all_r_stations[item_network_name]
	local p_stations = all_p_stations[item_network_name]

	--NOTE: this is an approximation algorithm for solving the assignment problem (bipartite graph weighted matching), the true solution would be to implement the simplex algorithm but I strongly believe most factorio players would prefer run-time efficiency over perfect train routing logic
	if p_stations and #r_stations > 0 and #p_stations > 0 then
		if #r_stations <= #p_stations then
			--probably backpressure, prioritize locality
			repeat
				local i = map_data.total_ticks%#r_stations + 1
				local r_station_id = table.remove(r_stations, i)

				local best = 0
				local best_depot = nil
				local best_dist = INF
				local highest_prior = -INF
				local could_have_been_serviced = false
				for j, p_station_id in ipairs(p_stations) do
					local depot, d = get_valid_train(map_data, r_station_id, p_station_id, item_type)
					local prior = stations[p_station_id].priority
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
				if best_depot then
					send_train_between(map_data, r_station_id, p_stations[best], best_depot, item_name)
				elseif could_have_been_serviced then
					send_missing_train_alert_for_stops(stations[r_station_id].entity_stop, stations[p_stations[best]].entity_stop)
				end
			until #r_stations == 0
		else
			--prioritize round robin
			repeat
				local j = map_data.total_ticks%#p_stations + 1
				local p_station_id = table.remove(p_stations, j)

				local best = 0
				local best_depot = nil
				local lowest_tick = INF
				local highest_prior = -INF
				local could_have_been_serviced = false
				for i, r_station_id in ipairs(r_stations) do
					local r_station = stations[r_station_id]
					local prior = r_station.priority
					if prior > highest_prior or (prior == highest_prior and r_station.last_delivery_tick < lowest_tick) then
						local depot, d = get_valid_train(map_data, r_station_id, p_station_id, item_type)
						if depot then
							best = i
							best_depot = depot
							lowest_tick = r_station.last_delivery_tick
							highest_prior = prior
						elseif d < INF then
							could_have_been_serviced = true
							best = i
						end
					end
				end
				if best_depot then
					send_train_between(map_data, r_stations[best], p_station_id, best_depot, item_name)
				elseif could_have_been_serviced then
					send_missing_train_alert_for_stops(stations[r_stations[best]].entity_stop, stations[p_station_id].entity_stop)
				end
			until #p_stations == 0
		end
	end
	return false
end
---@param map_data MapData
---@param mod_settings CybersynModSettings
function tick(map_data, mod_settings)
	if map_data.tick_state == STATE_INIT then
		map_data.total_ticks = map_data.total_ticks + 1
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

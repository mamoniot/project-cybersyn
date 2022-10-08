--By Monica Moniot
local get_distance = require("__flib__.misc").get_distance
local math = math
local INF = math.huge

local function icpairs(a, start_i)
	if #a == 0 then
		return nil
	end
	start_i = start_i%#a + 1
	local i = start_i - 1
	local flag = true
	return function()
		i = i%#a + 1
		if i ~= start_i or flag then
			flag = false
			local v = a[i]
			if v then
				return i, v
			end
		end
	end
end

--[[
station: {
	deliveries_total: int
	train_limit: int
	priority: int
	last_delivery_tick: int
	r_threshold: int >= 0
	p_threshold: int >= 0
	entity: FactorioStop
	train_layout: [ [ {
		[car_type]: true|nil
	} ] ]
	accepted_layouts: {
		[layout_id]: true|nil
	}
}
train: {
	layout_id: int
	depot_id: int
	depot_name: string
	item_slot_capacity: int
	fluid_capacity: int
}
available_trains: [{
	layout_id: int
	capacity: int
	all: [train]
}]
]]

local function create_loading_order(stop, manifest)
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
	return {station = stop.backer_name, wait_conditions = condition}
end

local create_unloading_order_condition = {type = "empty", compare_type = "and"}
local function create_unloading_order(stop, manifest)
	return {station = stop.backer_name, wait_conditions = create_unloading_order_condition}
end

local create_inactivity_order_condition = {type = "inactivity", compare_type = "and", ticks = 3}
local function create_inactivity_order(stop)
	return {station = stop.backer_name, wait_conditions = create_inactivity_order_condition}
end

local create_direct_to_station_order_condition = {{type = "time", compare_type = "and", ticks = 0}}
local function create_direct_to_station_order(stop)
	return {wait_conditions = create_direct_to_station_order_condition, rail = stop.connected_rail, rail_direction = stop.connected_rail_direction}
end



local function get_signals(stations, station_id)
	return {}
end

local function get_stop_dist(stop0, stop1)
	return get_distance(stop0.position, stop1.position)
end

local function get_valid_train(stations, r_station_id, p_station_id, available_trains, item_type)
	--NOTE: this code is the critical section for run-time optimization
	local r_station = stations[r_station_id]
	local p_station = stations[p_station_id]

	local p_to_r_dist = get_stop_dist(p_station.entity, r_station.entity)
	if p_to_r_dist == INF then
		return nil, INF
	end

	local best_train = nil
	local best_dist = INF
	local valid_train_exists = false

	local is_fluid = item_type == "fluid"
	for k, train in pairs(available_trains.all) do
		--check cargo capabilities
		--check layout validity for both stations
		if
			((is_fluid and train.fluid_capacity > 0) or (not is_fluid and train.item_slot_capacity > 0))
			and r_station.accepted_layouts[train.layout_id] and p_station.accepted_layouts[train.layout_id]
			and train.entity.station
		then
			valid_train_exists = true
			--check if exists valid path
			--check if path is shortest so we prioritize locality
			local d_to_p_dist = get_stop_dist(train.entity.station, p_station.entity)

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

local function send_train_between(stations, r_station_id, p_station_id, train, primary_item_name, economy)
	local r_station = stations[r_station_id]
	local p_station = stations[p_station_id]

	local requests = {}
	local manifest = {}

	local r_signals = get_signals(r_station_id)
	for k, v in pairs(r_signals) do
		local item_name = v.signal.name
		local item_count = v.count
		local item_type = v.signal.type
		if item_name and item_type and item_type ~= "virtual" then
			local effective_item_count = item_count + r_station.delivery_amount[item_name]
			if -effective_item_count >= r_station.r_threshold then
				requests[item_name] = -effective_item_count
			end
		end
	end

	local p_signals = get_signals(r_station_id)
	for k, v in pairs(p_signals) do
		local item_name = v.signal.name
		local item_count = v.count
		local item_type = v.signal.type
		if item_name and item_type and item_type ~= "virtual" then
			local effective_item_count = item_count + p_station.delivery_amount[item_name]
			if effective_item_count >= p_station.p_threshold then
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

	local total_slots_left = train.item_slot_capacity
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

	r_station.last_delivery_tick = economy.ticks_total
	p_station.last_delivery_tick = economy.ticks_total

	r_station.deliveries_total = r_station.deliveries_total + 1
	p_station.deliveries_total = p_station.deliveries_total + 1

	for _, item in ipairs(manifest) do
		assert(item.count > 0, "main.lua error, transfer amount was not positive")

		r_station.delivery_amount[item.name] = r_station.delivery_amount[item.name] + item.count
		p_station.delivery_amount[item.name] = p_station.delivery_amount[item.name] - item.count

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

	do
		local records = {}
		records[#records + 1] = create_inactivity_order(train.depot_name)

		records[#records + 1] = create_direct_to_station_order(p_station.entity)
		records[#records + 1] = create_loading_order(p_station.entity, manifest)

		records[#records + 1] = create_direct_to_station_order(p_station.entity)
		records[#records + 1] = create_unloading_order(p_station.entity, manifest)

		local schedule = {current = 1, records = records}

		train.entity.schedule = schedule
	end
end


function tick(stations, available_trains, ticks_total)
	local economy = {
		r_stations_all = {},
		p_stations_all = {},
		all_items = {},
		ticks_total = ticks_total,
	}
	local r_stations_all = economy.r_stations_all
	local p_stations_all = economy.p_stations_all
	local all_items = economy.all_items

	for station_id, station in pairs(stations) do
		if station.deliveries_total < station.train_limit then
			station.r_threshold = 0
			station.p_threshold = 0
			station.priority = 0
			local signals = get_signals(station_id)
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
				local effective_item_count = item_count + station.delivery_amount[item_name]

				if -effective_item_count >= station.r_threshold then
					if r_stations_all[item_name] == nil then
						r_stations_all[item_name] = {}
						p_stations_all[item_name] = {}
						all_items[#all_items + 1] = item_name
					end
					table.insert(r_stations_all[item_name], station_id)
				elseif effective_item_count >= station.p_threshold then
					if r_stations_all[item_name] == nil then
						r_stations_all[item_name] = {}
						p_stations_all[item_name] = {}
						all_items[#all_items + 1] = item_name
					end
					table.insert(p_stations_all[item_name], station_id)
				end
			end
		end
	end

	local failed_because_missing_trains_total = 0
	--we do not dispatch more than one train per station per tick
	--psuedo-randomize what item (and what station) to check first so if trains available is low they choose orders psuedo-randomly
	for _, item_name in icpairs(all_items, ticks_total) do
		local r_stations = r_stations_all[item_name]
		local p_stations = p_stations_all[item_name]

		--NOTE: this is an approximation algorithm for solving the assignment problem (bipartite graph weighted matching), the true solution would be to implement the simplex algorithm (and run it twice to compare the locality solution to the round-robin solution) but I strongly believe most factorio players would prefer run-time efficiency over perfect train routing logic
		if #r_stations > 0 and #p_stations > 0 then
			if #r_stations <= #p_stations then
				--probably backpressure, prioritize locality
				repeat
					local i = ticks_total%#r_stations + 1
					local r_station_id = table.remove(r_stations, i)

					local best = 0
					local best_train = nil
					local best_dist = INF
					local highest_prior = -INF
					local could_have_been_serviced = false
					for j, p_station_id in ipairs(p_stations) do
						local train, d = get_valid_train(stations, r_station_id, p_station_id, available_trains)
						local prior = stations[p_station_id].priority
						if prior > highest_prior or (prior == highest_prior and d < best_dist) then
							if train then
								best = j
								best_dist = d
								best_train = train
								highest_prior = prior
							elseif d < INF then
								could_have_been_serviced = true
							end
						end
					end
					if best > 0 then
						send_train_between(stations, r_station_id, p_stations[best], best_train, item_name, economy)
					elseif could_have_been_serviced then
						failed_because_missing_trains_total = failed_because_missing_trains_total + 1
					end
				until #r_stations == 0
			else
				--prioritize round robin
				repeat
					local j = ticks_total%#p_stations + 1
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
							local train, d = get_valid_train(stations, r_station_id, p_station_id, available_trains)
							if train then
								best = i
								best_train = train
								lowest_tick = r_station.last_delivery_tick
								highest_prior = prior
							elseif d < INF then
								could_have_been_serviced = true
							end
						end
					end
					if best > 0 then
						send_train_between(stations, r_stations[best], p_station_id, best_train, item_name, economy)
					elseif could_have_been_serviced then
						failed_because_missing_trains_total = failed_because_missing_trains_total + 1
					end
				until #p_stations == 0
			end
		end
	end
end

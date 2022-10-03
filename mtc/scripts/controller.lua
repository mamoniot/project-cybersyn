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
}
available_trains: [{
	layout_id: int
	capacity: int
}]
]]


local function get_signals(stations, station_id)
	return {}
end

local function get_station_dist(stations, id0, id1)
	return INF
end

local function get_valid_train(stations, r_station_id, p_station_id, available_trains)
	--NOTE: this code is the critical section for run-time optimization
	local r_station = stations[r_station_id]
	local p_station = stations[p_station_id]

	local p_to_r_dist = get_station_dist(stations, p_station_id, r_station_id)
	if p_to_r_dist == INF then
		return nil, p_to_r_dist
	end

	local best_train = nil
	local best_dist = INF

	for k, train in pairs(available_trains.all) do
		--check cargo capabilities
		--check layout validity for both stations
		--TODO: add check for correct cargo type
		if r_station.accepted_layouts[train.layout_id] and p_station.accepted_layouts[train.layout_id] then
			--check if exists valid path
			--check if path is shortest so we prioritize locality
			local d_to_p_dist = get_station_dist(stations, train.depot_id, p_station_id)

			local dist = d_to_p_dist + p_to_r_dist
			if dist < best_dist then
				best_dist = dist
				best_train = train
			end
		end
	end

	return best_train, best_dist
end

local function send_train_between(stations, r_station_id, p_station_id, train, ticks_total)
	local r_station = stations[r_station_id]
	local p_station = stations[p_station_id]

	local requests = {}
	local orders = {}
	local has_liquid = false
	local has_solid = false

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
					orders[item_name] = math.min(r, effective_item_count)
					if item_type == "liquid" then--TODO: here add liquid detection
						has_liquid = true
					else
						has_solid = true
					end
				end
			end
		end
	end

	r_station.last_delivery_tick = ticks_total
	p_station.last_delivery_tick = ticks_total

	r_station.deliveries_total = r_station.deliveries_total + 1
	p_station.deliveries_total = p_station.deliveries_total + 1

	for item_name, item_count in pairs(orders) do
		assert(item_count > 0, "main.lua error, transfer amount was not positive")

		r_station.delivery_amount[item_name] = r_station.delivery_amount[item_name] + item_count
		p_station.delivery_amount[item_name] = p_station.delivery_amount[item_name] - item_count
		--set train orders

	end

end


function tick(stations, available_trains, ticks_total)
	local r_stations_all = {}
	local p_stations_all = {}
	local all_items = {}

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
	--psuedo-randomize what item (and what station) to check first so if trains available is low they choose orders psuedo-randomly
	for _, item_name in icpairs(all_items, ticks_total) do
		--we do not dispatch more than one train per station per tick
		local r_stations = r_stations_all[item_name]
		local p_stations = p_stations_all[item_name]

		--NOTE: this is an approximation algorithm for solving the assignment problem (bipartite graph weighted matching), the true solution would be to implement the simplex algorithm (and run it twice to compare the locality solution to the round-robin solution) but I strongly believe most factorio players would prefer run-time efficiency over perfect train routing logic
		if #r_stations > 0 and #p_stations > 0 then
			if #r_stations <= #p_stations then
				--probably backpressure, prioritize locality
				for i, r_station_id in icpairs(r_stations, ticks_total) do
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
						send_train_between(stations, r_station_id, p_stations[best], best_train)
						table.remove(p_stations, best)
					elseif could_have_been_serviced then
						failed_because_missing_trains_total = failed_because_missing_trains_total + 1
					end
				end
			else
				--prioritize round robin
				for j, p_station_id in icpairs(p_stations, ticks_total) do
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
						send_train_between(stations, r_stations[best], p_station_id, best_train)
						table.remove(r_stations, best)
					elseif could_have_been_serviced then
						failed_because_missing_trains_total = failed_because_missing_trains_total + 1
					end
				end
			end
		end
	end
end

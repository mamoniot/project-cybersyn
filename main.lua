local function get_item_amount(station, item_id)
	return 0
end

local function get_valid_train(stations, r_station_i, p_station_i, available_trains)
	return 0
end

local function get_distance(stations, r_station_i, p_station_i)
	return 0
end

local function send_train_between(stations, r_station_i, p_station_i, train)
	local r_station = stations[r_station_i]
	local p_station = stations[p_station_i]
	r_station.last_p_station_i = p_station_i
	p_station.last_r_station_i = r_station_i

	r_station.deliveries_total = r_station.deliveries_total + 1
	p_station.deliveries_total = p_station.deliveries_total + 1

	local r_amount = get_item_amount(r_station, item_id) + r_station.delivery_amount[item_id]
	local p_amount = get_item_amount(p_station, item_id) + p_station.delivery_amount[item_id]
	local transfer_amount = math.min(train.capacity, -r_amount, p_amount)
	assert(transfer_amount > 0, "main.lua error, transfer amount was not positive")

	r_station.delivery_amount[item_id] = r_station.delivery_amount[item_id] + transfer_amount
	p_station.delivery_amount[item_id] = p_station.delivery_amount[item_id] - transfer_amount
end

--[[
	station: {
		deliveries_total: int
		train_limit: int
		requester_limit: int > 0
		provider_limit: int > 0
		priority: int
		last_delivery_tick: int
		train_layout: [ [ {
			[car_type]: true|nil
		} ] ]
		accepted_layouts: {
			[layout_id]: true|nil
		}
	}
	available_trains: [{
		layout_id: int
		capacity: int
	}]
]]

--local function check_train_layouts(station, available_layouts)
--	for _, layout_id in ipairs(available_layouts) do
--		if station.accepted_layouts[layout_id] then
--			return true
--		end
--	end
--	return false
--end

local function icpairs(a, start_i)
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


local function tick(stations, all_items, available_trains, ticks_total)
	if #all_items == 0 then
		return
	end
	local failed_because_missing_trains_total = 0
	--psuedo-randomize what item (and what station) to check first so if trains available is low they choose orders psuedo-randomly
	for _, item_id in icpairs(all_items, ticks_total) do
		local r_stations = {}
		local p_stations = {}

		for station_i, station in pairs(stations) do
			if station.deliveries_total < station.train_limit then
				local item_amount = get_item_amount(station, item_id) + station.delivery_amount[item_id]

				if -item_amount >= station.requester_limit then
					table.insert(r_stations, station_i)
				elseif item_amount >= station.provider_limit then
					table.insert(p_stations, station_i)
				end
			end
		end

		--we do not dispatch more than one train per station per tick

		if #r_stations > 0 and #p_stations > 0 then
			if #r_stations <= #p_stations then
				--backpressure, prioritize locality
				for i, r_station_i in icpairs(r_stations, ticks_total) do

					local best = 0
					local best_train = nil
					local best_dist = math.huge
					local highest_prior = -math.huge
					local could_have_been_serviced = false
					for j, p_station_i in ipairs(p_stations) do
						local d = get_distance(stations, r_station_i, p_station_i)
						local prior = stations[p_station_i].priority
						if prior > highest_prior or (prior == highest_prior and d < best_dist) then
							local train, is_possible = get_valid_train(stations, r_station_i, p_station_i, available_trains)
							if train then
								best = j
								best_dist = d
								best_train = train
								highest_prior = prior
							elseif is_possible then
								could_have_been_serviced = true
							end
						end
					end
					if best > 0 then
						send_train_between(stations, r_station_i, p_stations[best], best_train)
						table.remove(p_stations, best)
					elseif could_have_been_serviced then
						failed_because_missing_trains_total = failed_because_missing_trains_total + 1
					end
				end
			else
				--prioritize round robin
				for j, p_station_i in icpairs(p_stations, ticks_total) do

					local best = 0
					local best_train = nil
					local lowest_tick = math.huge
					local highest_prior = -math.huge
					local could_have_been_serviced = false
					for i, r_station_i in ipairs(r_stations) do
						local r_station = stations[r_station_i]
						local prior = r_station.priority
						if prior > highest_prior or (prior == highest_prior and r_station.last_delivery_tick < lowest_tick) then
							local train, is_possible = get_valid_train(stations, r_station_i, p_station_i, available_trains)
							if train then
								best = i
								best_train = train
								lowest_tick = r_station.last_delivery_tick
								highest_prior = prior
							elseif is_possible then
								could_have_been_serviced = true
							end
						end
					end
					if best > 0 then
						send_train_between(stations, r_stations[best], p_station_i, best_train)
						table.remove(r_stations, best)
					elseif could_have_been_serviced then
						failed_because_missing_trains_total = failed_because_missing_trains_total + 1
					end
				end
			end
		end
	end
end


tick()

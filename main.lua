local function get_item_amount(station, item_id)
	return 0
end

local function get_distance(stations, r_station_i, p_station_i)
	return 0
end

local function send_train_between(stations, r_station_i, p_station_i)
	stations[r_station_i].last_p_station_i = p_station_i
	stations[p_station_i].last_r_station_i = r_station_i
end

--[[
	station:
		deliveries_total: int
		train_limit: int
		requester_limit: int
		provider_limit: int
		priority: int
]]

local function tick(stations, all_items)
	for _, item_id in pairs(all_items) do
		local r_stations = {}
		local p_stations = {}

		for station_i, station in pairs(stations) do
			if station.deliveries_total < station.train_limit then
				local item_amount = get_item_amount(station, item_id)
				local delivery_amount = station.delivery_amount

				if -(item_amount + delivery_amount) >= station.requester_limit then
					table.insert(r_stations, station_i)
				elseif item_amount + delivery_amount >= station.provider_limit then
					table.insert(p_stations, station_i)
				end
			end
		end

		--we do not dispatch more than one train per station per tick

		if #r_stations > 0 and #p_stations > 0 then
			if #r_stations <= #p_stations then
				--backpressure, prioritize locality
				for i, r_station_i in ipairs(r_stations) do
					local best = 1
					local best_dist = math.huge
					local highest_prior = -math.huge
					for j, p_station_i in ipairs(p_stations) do
						local d = get_distance(stations, r_station_i, p_station_i)
						local prior = stations[p_station_i].priority
						if prior > highest_prior then
							best = j
							best_dist = d
							highest_prior = prior
						elseif prior == highest_prior and d < best_dist then
							best = j
							best_dist = d
						end
					end
					send_train_between(stations, r_station_i, p_stations[best])
					table.remove(p_stations, best)
				end
			else
				--prioritize round robin
				for j, p_station_i in ipairs(p_stations) do
					local best = 1
					local highest_prior = -math.huge
					local last_r_station_i = stations[p_station_i].last_r_station_i
					for i, r_station_i in ipairs(r_stations) do
						local prior = stations[r_station_i].priority
						if r_stations[i] > last_r_station_i then
							prior = prior + .5
						end
						if prior > highest_prior then
							best = i
							highest_prior = prior
						end
					end
					send_train_between(stations, r_stations[best], p_station_i)
					table.remove(r_stations, best)
				end
			end
		end
	end
end


tick()

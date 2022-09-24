

local function send_train_between(stations, r_station_i, p_station_i)
	stations[r_station_i].last_p_station_i = p_station_i
	stations[p_station_i].last_r_station_i = r_station_i
end


local function tick(stations)
	--psuedocode

	local r_stations = {}

	for station_i, station in ipairs(stations) do
		local r_item = station.item
		if -r_item.amount >= station.requester_limit then
			r_stations[#r_stations + 1] = station_i
		end
	end

	local p_stations = {}

	for station_i, station in ipairs(stations) do
		local p_item = station.item
		if p_item.amount >= station.provider_limit then
			p_stations[#p_stations + 1] = station_i
		end
	end

	--we do not dispatch more than one train per station per tick
	if #r_stations > 0 and #p_stations > 0 then
		if #r_stations <= #p_stations then
			local last_p_station_i = stations[r_stations[1]].last_p_station_i
			local i = 1
			while true do
				if i > #p_stations then
					i = 1
					break
				elseif p_stations[i] > last_p_station_i then
					break
				else
					i = i + 1
				end
			end
			for j = 1, #r_stations do
				send_train_between(stations, r_stations[j], p_stations[i])

				i = i%#p_stations + 1
			end
		else
			local last_r_station_i = stations[p_stations[1]].last_r_station_i
			local i = 1
			while true do
				if i > #r_stations then
					i = 1
					break
				elseif r_stations[i] > last_r_station_i then
					break
				else
					i = i + 1
				end
			end
			for j = 1, #p_stations do
				send_train_between(stations, r_stations[i], p_stations[j])

				i = i%#p_stations + 1
			end

		end
	end
end


tick()

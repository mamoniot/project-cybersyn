
--- @param stop LuaEntity
--- @param message LocalisedString
local function report_print(stop, message)
	if stop and stop.valid then
		local stop_info = string.format("[train-stop=%d]", stop.unit_number)
		game.print({"cybersyn-problems.message-wrapper", stop_info, message})
	else
		game.print(message)
	end
end

local function report_noop(stop, message)
end

--- Find the names of all Cybersyn stations in the game.
--- @param report function(LuaEntity, LocalisedString)
--- 
--- @return {[integer]: string} station_types maps from train-stop unit_number to cybersyn station type (MODE_PRIMARY_IO | MODE_DEPOT | MODE_REFUELER | nil)
--- @return {[string]: boolean} station_names set of station names (requester/provider)
--- @return {[string]: boolean} depot_names set of depot names
--- @return {[string]: boolean} refueler_names set of refueler names
local function check_single_stations_and_collect_data(report)
	local station_names = {}
	local depot_names = {}
	local refueler_names = {}
	local station_types = {}

	for _,s in pairs(game.surfaces) do
		for _,ts in pairs(s.find_entities_filtered {name="train-stop"}) do
			local comb_1 = nil
			local comb_2 = nil
			local depot  = nil
			local refuel = nil

			for _,c in pairs(s.find_entities_filtered {name="cybersyn-combinator", position=ts.position, radius=3}) do
				local op = c.get_control_behavior()
				op = op and op.parameters.operation

				if op == MODE_PRIMARY_IO or op == MODE_PRIMARY_IO_ACTIVE or op == MODE_PRIMARY_IO_FAILED_REQUEST then
					if not comb_1 then comb_1 = c else report(ts, {"cybersyn-problems.double-station"}) end
				elseif op == MODE_SECONDARY_IO then
					if not comb_2 then comb_2 = c else report(ts, {"cybersyn-problems.double-station-control"}) end
				elseif op == MODE_DEPOT then
					if not depot  then depot  = c else report(ts, {"cybersyn-problems.double-depot"}) end
				elseif op == MODE_REFUELER then
					if not refuel then refuel = c else report(ts, {"cybersyn-problems.double-refueler"}) end
				end
			end

			if comb_1 and depot  then report(ts, {"cybersyn-problems.station-and-depot"}) end
			if comb_1 and refuel then report(ts, {"cybersyn-problems.station-and-refueler"}) end
			if depot  and refuel then report(ts, {"cybersyn-problems.depot-and-refueler"}) end

			if comb_1 then -- station mode takes precedence
				station_types [ts.unit_number] = MODE_PRIMARY_IO
				station_names [ts.backer_name] = true
			elseif depot then
				station_types [ts.unit_number] = MODE_DEPOT
				depot_names   [ts.backer_name] = true
			elseif refuel then
				station_types [ts.unit_number] = MODE_REFUELER
				refueler_names[ts.backer_name] = true
			end
		end
	end

	return station_types, station_names, depot_names, refueler_names
end

--- @param report function(LuaEntity, LocalisedString)
local function find_problems(report)
	local problem_counter = 0

	local counting_report = function(stop, message)
		problem_counter = problem_counter + 1
		report(stop, message)
	end

	local types, stations, depots, refuelers = check_single_stations_and_collect_data(counting_report)

	-- global checks 
	for _,s in pairs(game.surfaces) do
		for _,ts in pairs(s.find_entities_filtered {name="train-stop"}) do
			-- priority is only problematic when a station is named the same as a Cybersyn requester/provider
			local name = ts.backer_name
			if ts.train_stop_priority ~= 50 and (stations[name] or depots[name] or refuelers[name]) then
				counting_report(ts, {"cybersyn-problems.non-default-priority"})
			end

			local type = types[ts.unit_number]
			if type ~= MODE_DEPOT and depots[ts.backer_name] then
				counting_report(ts, {"cybersyn-problems.name-overlap-with-depot"})
			end

			-- TODO decide if this is actually a problem
			-- if type ~= MODE_REFUELER and refuelers[ts.backer_name] then
			--	report(ts, {"cybersyn-problems.name-overlap-with-refueler"})
			-- end
		end
	end

	if problem_counter == 0 then
		report(nil, {"cybersyn-problems.no-problems-found"})
	end
end

local function fix_priorities_command()
	-- don't depend on any 'storage' data for a repair command
	local _, stations, depots, refuelers = check_single_stations_and_collect_data(report_noop)

	for _,s in pairs(game.surfaces) do
		for _,ts in pairs(s.find_entities_filtered {name="train-stop"}) do
			local name = ts.backer_name
			if ts.train_stop_priority ~= 50 and (stations[name] or depots[name] or refuelers[name]) then
				report_print(ts, {"cybersyn-problems.priority-was-reset"})
			end
		end
	end
end

commands.add_command("cybersyn-find-problems", {"cybersyn-messages.find-problems-command-help"}, function() find_problems(report_print) end)
commands.add_command("cybersyn-fix-priorities", {"cybersyn-messages.fix-priorities-command-help"}, fix_priorities_command)

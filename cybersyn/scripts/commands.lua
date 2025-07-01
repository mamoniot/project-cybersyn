--- @param entity LuaEntity
local function gps_text(entity)
	local pos = entity.position
	return string.format("[gps=%f,%f,%s]", pos.x, pos.y, entity.surface.name)
end

---@param train LuaTrain
function train_richtext(train)
	local _, loco = next(train.locomotives.front_movers)
	if loco then
		return "[train="..loco.unit_number.."]"
	end
	return "train "..train.id
end

local function stop_richtext(stop)
	return "[train-stop="..stop.unit_number.."]"
end

--- @param entity LuaEntity
--- @param message LocalisedString
local function report_print(entity, message)
	local location_info = nil

	if entity and entity.valid then
		if entity.name == "train-stop" then
			location_info = stop_richtext(entity)
		else
			location_info = { "", gps_text(entity), " ", entity.localised_name }
		end
	end

	if location_info then
		game.print({ "", location_info, " ", message })
	else
		game.print(message)
	end
end

local function report_noop(stop, message)
end

local NORTH = defines.direction.north
local SOUTH = defines.direction.south

---@param comb LuaEntity
local function combinator_search_area(comb)
	local pos = comb.position
	local dir = comb.direction

	-- see on_combinator_built
	if dir == NORTH or dir == SOUTH then
		return {
			{ pos.x - 1.5, pos.y - 2 },
			{ pos.x + 1.5, pos.y + 2 },
		}
	else
		return {
			{ pos.x - 2, pos.y - 1.5 },
			{ pos.x + 2, pos.y + 1.5 },
		}
	end
end

---@param station LuaEntity
local function station_search_area(station)
	local pos = station.position

	-- see search_for_station_combinator
	return {
		{ pos.x - 2, pos.y - 2 },
		{ pos.x + 2, pos.y + 2 },
	}
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

	for _, s in pairs(game.surfaces) do
		for _, ts in pairs(s.find_entities_filtered { name = "train-stop" }) do
			local comb_1 = nil
			local comb_2 = nil
			local depot = nil
			local refuel = nil

			for _, c in pairs(s.find_entities_filtered { name = "cybersyn-combinator", area = station_search_area(ts) }) do
				local op = c.get_control_behavior()
				op = op and op.parameters.operation

				if op == MODE_PRIMARY_IO or op == MODE_PRIMARY_IO_ACTIVE or op == MODE_PRIMARY_IO_FAILED_REQUEST then
					if not comb_1 then comb_1 = c else report(ts, { "cybersyn-problems.double-station" }) end
				elseif op == MODE_SECONDARY_IO then
					if not comb_2 then comb_2 = c else report(ts, { "cybersyn-problems.double-station-control" }) end
				elseif op == MODE_DEPOT then
					if not depot then depot = c else report(ts, { "cybersyn-problems.double-depot" }) end
				elseif op == MODE_REFUELER then
					if not refuel then refuel = c else report(ts, { "cybersyn-problems.double-refueler" }) end
				end
			end

			if comb_1 and depot then report(ts, { "cybersyn-problems.station-and-depot" }) end
			if comb_1 and refuel then report(ts, { "cybersyn-problems.station-and-refueler" }) end
			if depot and refuel then report(ts, { "cybersyn-problems.depot-and-refueler" }) end

			if comb_1 then -- station mode takes precedence
				station_types[ts.unit_number] = MODE_PRIMARY_IO
				station_names[ts.backer_name] = true
			elseif depot then
				station_types[ts.unit_number] = MODE_DEPOT
				depot_names[ts.backer_name] = true
			elseif refuel then
				station_types[ts.unit_number] = MODE_REFUELER
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
	for _, s in pairs(game.surfaces) do
		for _, ts in pairs(s.find_entities_filtered { name = "train-stop" }) do
			-- priority is only problematic when a station is named the same as a Cybersyn requester/provider
			local name = ts.backer_name
			if ts.train_stop_priority ~= 50 and (stations[name] or depots[name] or refuelers[name]) then
				counting_report(ts, { "cybersyn-problems.non-default-priority" })
			end

			local type = types[ts.unit_number]
			if type ~= MODE_DEPOT and depots[ts.backer_name] then
				counting_report(ts, { "cybersyn-problems.name-overlap-with-depot" })
			end

			-- TODO decide if this is actually a problem
			-- if type ~= MODE_REFUELER and refuelers[ts.backer_name] then
			--	report(ts, {"cybersyn-problems.name-overlap-with-refueler"})
			-- end
		end
	end

	for _, s in pairs(game.surfaces) do
		for _, c in pairs(s.find_entities_filtered { name = "cybersyn-combinator" }) do
			if not next(s.find_entities_filtered { name = "train-stop", area = combinator_search_area(c), limit = 1 }) then
				local op = c.get_control_behavior()
				op = op and op.parameters.operation
				if op ~= MODE_WAGON then
					counting_report(c, { "cybersyn-problems.derelict-combinator" })
				end
			end
		end
	end

	if problem_counter == 0 then
		report(nil, { "cybersyn-problems.no-problems-found" })
	end
end

local function fix_priorities_command()
	-- don't depend on any 'storage' data for a repair command
	local _, stations, depots, refuelers = check_single_stations_and_collect_data(report_noop)

	for _, s in pairs(game.surfaces) do
		for _, ts in pairs(s.find_entities_filtered { name = "train-stop" }) do
			local name = ts.backer_name
			if ts.train_stop_priority ~= 50 and (stations[name] or depots[name] or refuelers[name]) then
				ts.train_stop_priority = 50
				report_print(ts, { "cybersyn-problems.priority-was-reset" })
			end
		end
	end
end

function retrigger_train_calculation(print_message)
	---@type MapData
	local map_data = storage
	log("Recalculating all train capacities")
	local nbtrains = 0
	for _,train in pairs(map_data.trains) do
		if train.entity and train.entity.valid then
			set_train_layout(map_data, train)
			nbtrains = nbtrains+1
		end
	end
	if print_message then
		game.print("All ".. nbtrains .. " train capacities recalculated.")
	end
	log("Recalculated "..nbtrains.." trains")
end

local function abolish_same_depot()
	local map_data = storage --[[@as MapData]]
	local num_depots, num_trains = 0, 0

	log("Disabling Require same depot")

	for _, depot in pairs(map_data.depots) do
		local stop = depot.entity_stop
		if stop and stop.valid and depot.entity_comb and depot.entity_comb.valid then
			local bits = get_comb_params(depot.entity_comb).second_constant or 0
			if bit32.extract(bits, SETTING_USE_ANY_DEPOT) == 0 then
				set_comb_setting(depot.entity_comb, SETTING_USE_ANY_DEPOT, true)
				num_depots = num_depots + 1

				function log_depot(detail)
					log(string.format("%s adjusted, %s", stop_richtext(stop), detail))
				end

				if stop.trains_limit > 2100000000 then -- no limit = uint_max, ~int_max is good enough here
					log_depot("train limit set to 1")
					stop.trains_limit = 1
				else
					log_depot("current train limit retained")
				end
			end
		end
	end

	for _, train in pairs(map_data.trains) do
		if not train.use_any_depot and train.entity and train.entity.valid then
			train.use_any_depot = true
			num_trains = num_trains + 1

			function log_train(detail)
				log(string.format("%s adjusted, %s", train_richtext(train.entity), detail))
			end

			if train.status == STATUS_D then
				log_train("at depot")
			else
				local depot = map_data.depots[train.depot_id] --[[@as Depot?]]
				if not (depot and depot.entity_stop and depot.entity_stop.valid) then
					log_train("schedule not touched, depot invalid")
					goto train_any_depot_done
				end

				local depot_name = depot.entity_stop.backer_name
				local schedule = train.entity.get_schedule()
				local records = schedule.get_records() --[[@as ScheduleRecord[] ]]
				for i = #records, 2, -1 do
					if records[i].temporary then break end
					if records[i].station == depot_name and records[i-1].rail then
						schedule.remove_record({ schedule_index = i-1 })
						log_train("depot coordinate entry removed from schedule")
						goto train_any_depot_done
					end
				end

				log_train("schedule not touched but not at depot, schedule:")
				local current = schedule.current
				for i, record in ipairs(records) do
					log(string.format("%s%d: %s", current == i and ">" or "#", i, serpent.line(record)))
				end
			end

			::train_any_depot_done::
		end
	end

	log("Finished disabling Require same depot")
	game.print({ "cybersyn-messages.abolish-same-depot-command-result", num_depots, num_trains })
end

commands.add_command("cybersyn-recalculate-train-size", { "cybersyn-messages.recalculate-train-size-command-help" },
	function() retrigger_train_calculation(true) end)
commands.add_command("cybersyn-find-problems", { "cybersyn-messages.find-problems-command-help" },
	function() find_problems(report_print) end)
commands.add_command("cybersyn-fix-priorities", { "cybersyn-messages.fix-priorities-command-help" },
	fix_priorities_command)
commands.add_command("cybersyn-abolish-same-depot", { "cybersyn-messages.abolish-same-depot-command-help" },
	abolish_same_depot)

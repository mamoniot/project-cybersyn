local actions = require("scripts.actions")
local lint = require("scripts.lint")

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
		location_info = entity_richtext(entity)
	end

	if location_info then
		game.print({ "", location_info, " ", message })
	else
		game.print(message)
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

local NAMED_MODES = {
	[MODE_PRIMARY_IO] = true,
	[MODE_PRIMARY_IO_ACTIVE] = true,
	[MODE_PRIMARY_IO_FAILED_REQUEST] = true,
	[MODE_DEPOT] = true,
	[MODE_REFUELER] = true,
}

--- The names of every train stop that a station, depot or refueler combinator serves, found from the entities
--- alone so a repair command does not depend on storage.
--- @return {[string]: true}
local function collect_cybersyn_stop_names()
	local names = {}
	for _, s in pairs(game.surfaces) do
		for _, ts in pairs(s.find_entities_filtered { name = "train-stop" }) do
			for _, c in pairs(s.find_entities_filtered { name = "cybersyn-combinator", area = station_search_area(ts) }) do
				local op = c.get_control_behavior()
				op = op and op.parameters.operation
				if NAMED_MODES[op] then
					names[ts.backer_name] = true
					break
				end
			end
		end
	end
	return names
end

local function fix_priorities_command()
	local names = collect_cybersyn_stop_names()

	for _, s in pairs(game.surfaces) do
		for _, ts in pairs(s.find_entities_filtered { name = "train-stop" }) do
			if ts.train_stop_priority ~= 50 and names[ts.backer_name] then
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
	-- set_train_layout counts the train into its layout, so the counts start from 0 and every layout no train
	-- re-derives is dropped afterwards; otherwise each run would add every train a second time.
	local counts = map_data.layout_train_count
	for id in pairs(map_data.layouts) do counts[id] = 0 end
	for _,train in pairs(map_data.trains) do
		if train.entity and train.entity.valid then
			set_train_layout(map_data, train)
			nbtrains = nbtrains+1
		elseif counts[train.layout_id] then
			counts[train.layout_id] = counts[train.layout_id] + 1
		end
	end
	local orphans = {}
	for id in pairs(map_data.layouts) do
		if counts[id] == 0 then orphans[#orphans + 1] = id end
	end
	if #orphans > 0 then
		for _, id in ipairs(orphans) do
			counts[id] = nil
			map_data.layouts[id] = nil
		end
		for _, stop in pairs(map_data.stations) do
			for _, id in ipairs(orphans) do stop.accepted_layouts[id] = nil end
		end
		for _, stop in pairs(map_data.refuelers) do
			for _, id in ipairs(orphans) do stop.accepted_layouts[id] = nil end
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

				if stop.trains_limit > TRAIN_LIMIT_UNLIMITED then
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

--- A command that changes game state: refused without the right, audited when it ran.
--- @param action DiagAction
--- @param fn fun()
--- @return fun(command: CustomCommandData)
local function gated(action, fn)
	return function(command)
		local player = command.player_index and game.get_player(command.player_index) or nil
		local what = "/" .. command.name
		if not actions.check(player, what) then return end
		fn()
		actions.audit(action, nil, player, what)
	end
end

--- Prints the setup registry (combinators and stops that keep a station from registering or misroute trains, kept
--- up to date by the build handlers, scripts/lint.lua) and the registered stops at a non-default priority. Nothing
--- is scanned: the command reads what the handlers recorded.
--- @param command CustomCommandData
local function find_problems_command(command)
	local player = command.player_index and game.get_player(command.player_index) or nil
	lint.report(player)
end

commands.add_command("cybersyn-recalculate-train-size", { "cybersyn-messages.recalculate-train-size-command-help" },
	gated(ACTION_RECALCULATE_TRAIN_SIZE, function() retrigger_train_calculation(true) end))
commands.add_command("cybersyn-find-problems", { "cybersyn-messages.find-problems-command-help" }, find_problems_command)
commands.add_command("cybersyn-fix-priorities", { "cybersyn-messages.fix-priorities-command-help" },
	gated(ACTION_FIX_PRIORITIES, fix_priorities_command))
commands.add_command("cybersyn-abolish-same-depot", { "cybersyn-messages.abolish-same-depot-command-help" },
	gated(ACTION_ABOLISH_SAME_DEPOT, abolish_same_depot))

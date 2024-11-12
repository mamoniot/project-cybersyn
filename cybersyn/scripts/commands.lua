--- Find the names of all Cybersyn stations in the game.
---@return {[string]: true} cybersyn_names Hash of all Cybersyn station names mapped to `true`
local function find_cybersyn_station_names()
	local cybersyn_names = {}
	for _,s in pairs(game.surfaces) do
		for _,ts in pairs(s.find_entities_filtered {name="train-stop"}) do
			if next(s.find_entities_filtered {name="cybersyn-combinator", position=ts.position, radius=3}) then
				cybersyn_names[ts.backer_name] = true
			end
		end
	end
	return cybersyn_names
end

--- Run a function on each stop with non-default priority
---@param callback fun(train_stop: LuaEntity) 
local function for_each_stop_with_invalid_priority(callback)
	-- Priority is only problematic when a station is named the same as a
	-- Cybersyn station.
	local cybersyn_names = find_cybersyn_station_names()
	for _,s in pairs(game.surfaces) do
		for _,ts in pairs(s.find_entities_filtered {name="train-stop"}) do
			if ts.train_stop_priority ~= 50 and cybersyn_names[ts.backer_name] then
				callback(ts)
			end
		end
	end
end

local function fix_priorities_command()
	-- don't depend on any 'storage' data for a repair command

	for_each_stop_with_invalid_priority(function(ts)
		ts.train_stop_priority = 50
		game.print("Reset [train-stop="..ts.unit_number.."] to priority 50")
	end)
end

local function find_priorities_command()
	for_each_stop_with_invalid_priority(function(ts)
		game.print("[train-stop="..ts.unit_number.."] has priority "..ts.train_stop_priority .. " and will cause Project Cybersyn trains to be misdirected.")
	end)
end

commands.add_command("cybersyn-fix-priorities", {"cybersyn-messages.fix-priorities-command-help"}, fix_priorities_command)

commands.add_command("cybersyn-find-priorities", {"cybersyn-messages.find-priorities-command-help"}, find_priorities_command)

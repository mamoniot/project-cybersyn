--By Mami
local se_compat = require("scripts.mod-compatibility.space-exploration")
local get_distance = require("__flib__.position").distance
local table_insert = table.insert
local bit_extract = bit32.extract
local bit_replace = bit32.replace
local max = math.max

local DEFINES_WORKING = defines.entity_status.working
local DEFINES_LOW_POWER = defines.entity_status.low_power
--local DEFINES_COMBINATOR_INPUT = defines.circuit_connector_id.combinator_input

local stack_size_cache = {}

for name, prototype in pairs(prototypes.item) do
	stack_size_cache[name] = prototype.stack_size
end

function get_stack_size(map_data, item_name)
	return stack_size_cache[item_name]
end

---@param item_order table<string, int>
---@param item1_name string
---@param item2_name string
function item_lt(item_order, item1_name, item2_name)
	return item_order[item1_name] < item_order[item2_name]
end

---NOTE: does not check .valid
---@param entity0 LuaEntity
---@param entity1 LuaEntity
function get_dist(entity0, entity1)
	local surface0 = entity0.surface.index
	local surface1 = entity1.surface.index
	return (surface0 == surface1 and get_distance(entity0.position, entity1.position) or DIFFERENT_SURFACE_DISTANCE)
end

---Get a rolling stock entity associated to the train. Attempts to get
---the front stock if possible.
---@param train LuaTrain
---@return LuaEntity?
function get_any_train_entity(train)
	return train.valid and (train.front_stock or train.back_stock or train.carriages[1]) or nil
end

---@param e Station|Refueler|Train|StopInfo
---@param network_name string
---@return int
function get_network_mask(e, network_name)
	return e.network_name == NETWORK_EACH and (e.network_mask[network_name] or 0) or e.network_mask --[[@as int]]
end

--- Sets colors of all locomotives of the train to the color of the given station.
--- Respects the copy_color_from_train_stop user setting.
---@param train LuaTrain
---@param station LuaEntity
function color_train_by_stop(train, station)
	for _, locomotive in ipairs(train.locomotives.front_movers) do
		if locomotive.copy_color_from_train_stop then
			locomotive.color = station.color
		end
	end
	for _, locomotive in ipairs(train.locomotives.back_movers) do
		if locomotive.copy_color_from_train_stop then
			locomotive.color = station.color
		end
	end
end

------------------------------------------------------------------------------
--[[train schedules]] --
------------------------------------------------------------------------------

---@type WaitCondition
local condition_wait_inactive = { type = "inactivity", compare_type = "and", ticks = INACTIVITY_TIME }
---@type WaitCondition
local condition_empty = { type = "empty", compare_type = "and" }
---@type WaitCondition
local condition_circuit = {
	type = "circuit",
	compare_type = "and",
	condition = {
		comparator = ">",
		first_signal = { type = "virtual", name = "signal-check" },
		constant = 0,
	},
}
---@type WaitCondition[]
local conditions_only_inactive = { condition_wait_inactive }
---@type WaitCondition[]
local conditions_direct_to_station = { { type = "time", compare_type = "and", ticks = 1 } }

---@param stop LuaEntity
---@param manifest Manifest
---@param schedule_settings Cybersyn.StationScheduleSettings
---@return AddRecordData
function create_loading_order(stop, manifest, schedule_settings)
	---@type WaitCondition[]
	local conditions = {}
	for _, item in ipairs(manifest) do
		local cond_type
		if item.type == "fluid" then
			cond_type = "fluid_count"
		else
			cond_type = "item_count"
		end

		if not (schedule_settings.disable_manifest_condition and
			-- one other wait condition is required without manifest loading conditions
			(schedule_settings.enable_inactive or
			schedule_settings.enable_circuit_condition))
		then
			conditions[#conditions + 1] = {
				type = cond_type,
				compare_type = "and",
				condition = {
					comparator = "≥",
					first_signal = { type = item.type, name = item.name, quality = item.quality },
					constant = item.count,
				},
			}
		end
	end
	if schedule_settings.enable_inactive then
		conditions[#conditions + 1] = condition_wait_inactive
	end
	if schedule_settings.enable_circuit_condition then
		conditions[#conditions + 1] = condition_circuit
	end
	return {
		station = stop.backer_name,
		wait_conditions = conditions,
		temporary = true, -- avoids modifying a potential train group
	}
end

---@param stop LuaEntity
---@param schedule_settings Cybersyn.StationScheduleSettings
---@return AddRecordData
function create_unloading_order(stop, schedule_settings)
	---@type WaitCondition[]
	local conditions = {}

	if schedule_settings.enable_inactive then
		conditions[#conditions + 1] = condition_wait_inactive
		if not mod_settings.allow_cargo_in_depot then
			-- This implements the behavior specified in the documentation for
			-- allow_cargo_in_depot. When enabled, trains only wait for inactivity
			-- when unloading at requesters.
			conditions[#conditions + 1] = condition_empty
		end
	else
		-- No inactivity condition = always wait for empty
		conditions[#conditions + 1] = condition_empty
	end

	if schedule_settings.enable_circuit_condition then
		conditions[#conditions + 1] = condition_circuit
	end

	return {
		station = stop.backer_name,
		wait_conditions = conditions,
		temporary = true,
	}
end

---@param depot_name string
---@return AddRecordData
function create_inactivity_order(depot_name)
	return {
		station = depot_name,
		wait_conditions = conditions_only_inactive,
		temporary = true,
	}
end

---@param stop LuaEntity
---@return AddRecordData
function create_direct_to_station_order(stop)
	return {
		rail = stop.connected_rail,
		rail_direction = stop.connected_rail_direction,
		wait_conditions = conditions_direct_to_station,
		temporary = true,
	}
end

---@param train LuaTrain
---@param depot_name string
function set_depot_schedule(train, depot_name)
	if not train.valid then return end

	local schedule = train.get_schedule()
	local count = schedule.get_record_count()
	if count > 0 then
		local record = schedule.get_record({ schedule_index = count }) --[[@as ScheduleRecord ]]
		local is_depot = record.station == depot_name
			and record.wait_conditions
			and #record.wait_conditions == 1
			and record.wait_conditions[1].type == "inactivity"

		if is_depot then
			for i=count-1, 1, -1 do
				schedule.remove_record({ schedule_index = i })
			end
		else
			schedule.clear_records()
		end
	end

	if schedule.get_record_count() == 0 then
		local depot_record = {
			station = depot_name,
			wait_conditions = conditions_only_inactive,
			-- the only schedule entry that is not temporary
		}
		schedule.add_record(depot_record)
		if train.group and train.group ~= "" then
			game.print({ "cybersyn-messages.control-train-group", train.group, depot_name })
		end
	end
end

---@param train LuaTrain
function lock_train(train)
	if train.valid then
		train.manual_mode = true
	end
end
---@param train LuaTrain
---@param depot_name string
function lock_train_to_depot(train, depot_name)
	if not train.valid then return end

	local schedule = train.get_schedule()
	if schedule.get_record_count() == 0 then
		train.manual_mode = true
		return
	end

	local current = schedule.current
	schedule.add_record({
		station = depot_name,
		wait_conditions = { { type = "inactivity", compare_type = "and", ticks = LOCK_TRAIN_TIME } },
		temporary = true,
		index = { schedule_index = current },
	})
	schedule.go_to_station(current)
end

---@param train LuaTrain
---@param stop LuaEntity
---@param old_name string
function rename_manifest_schedule(train, stop, old_name)
	if train.valid then
		local new_name = stop.backer_name
		local schedule = train.get_schedule()
		local records = schedule.get_records()
		if not records then return end

		for i, record in ipairs(records) do
			if record.temporary and record.station == old_name then
				local new_record = record --[[@as AddRecordData]]
				new_record.station = new_name
				new_record.index = { schedule_index = i }
				-- replace the record in the schedule
				local is_current = schedule.current == i
				schedule.remove_record(new_record.index)
				schedule.add_record(new_record)
				if is_current and schedule.current ~= i then
					schedule.go_to_station(i)
				end
			end
		end
	end
end

---clean slate; remove all temporary, non-interrupt records from the schedule, including a direct-to-depot record
---@param schedule LuaSchedule
function clean_temporary_records(schedule)
	local current_records = schedule.get_records() --[[@as ScheduleRecord[] ]]
	for i = schedule.get_record_count(), 1, -1 do
		local current_record = current_records[i]
		if current_record.temporary and not current_record.created_by_interrupt then
			schedule.remove_record({ schedule_index = i })
		end
	end
end

---Inserts the given records before the first non-interrupt record in the schedule
---@param schedule LuaSchedule
---@param records AddRecordData[] supports optional entries by skipping falsy ones
---@return int insert_index the index of the first inserted record
---@return int insert_count the number of records that were truthy and thus inserted
function add_records_after_interrupt(schedule, records)
	local last_interrupt = 0
	for i = 1, schedule.get_record_count() do
		-- read single records to optimize under the assumption there is no interrupt
		-- (tick_dispatch won't schedule deliveries if there is one)
		local record = schedule.get_record({ schedule_index = i }) --[[@as ScheduleRecord]]
		if not record.created_by_interrupt then break end
		last_interrupt = i
	end

	local i = 1
	for _, record in pairs(records) do
		if record then
			record.index = { schedule_index = last_interrupt + i }
			schedule.add_record(record)
			i = i + 1
		end
	end

	return last_interrupt + 1, i - 1
end

---NOTE: does not check .valid
---@param map_data MapData
---@param train LuaTrain
---@param depot_stop LuaEntity
---@param same_depot boolean
---@param p_stop LuaEntity
---@param p_schedule_settings Cybersyn.StationScheduleSettings
---@param r_stop LuaEntity
---@param r_schedule_settings Cybersyn.StationScheduleSettings
---@param manifest Manifest
---@param start_at_depot boolean?
function set_manifest_schedule(
		map_data,
		train,
		depot_stop,
		same_depot,
		p_stop,
		p_schedule_settings,
		r_stop,
		r_schedule_settings,
		manifest,
		start_at_depot)
	--NOTE: can only return false if start_at_depot is false, it should be incredibly rare that this function returns false

	local schedule = train.get_schedule()
	clean_temporary_records(schedule)

	-- creates a schedule that cannot be fulfilled, the train will be stuck but it will give the player information what went wrong
	function train_stuck()
		add_records_after_interrupt(schedule, {
			create_loading_order(p_stop, manifest, p_schedule_settings),
			create_unloading_order(r_stop, r_schedule_settings),
		})
		lock_train(train)
	end

	if not p_stop.connected_rail or not r_stop.connected_rail then
		train_stuck()
		send_alert_station_of_train_broken(map_data, train)
		return true
	end
	if same_depot and not depot_stop.connected_rail then
		train_stuck()
		send_alert_depot_of_train_broken(map_data, train)
		return true
	end

	local t_surface = train.front_stock.surface
	local p_surface = p_stop.surface
	local r_surface = r_stop.surface
	local d_surface_i = depot_stop.surface.index
	local t_surface_i = t_surface.index
	local p_surface_i = p_surface.index
	local r_surface_i = r_surface.index
	local is_p_on_t = t_surface_i == p_surface_i
	local is_r_on_t = t_surface_i == r_surface_i
	local is_d_on_t = t_surface_i == d_surface_i
	local records = nil
	if is_p_on_t and is_r_on_t and is_d_on_t then
		records = {
			create_direct_to_station_order(p_stop),
			create_loading_order(p_stop, manifest, p_schedule_settings),
			create_direct_to_station_order(r_stop),
			create_unloading_order(r_stop, r_schedule_settings),
			same_depot and create_direct_to_station_order(depot_stop),
		}
	elseif IS_SE_PRESENT then
		game.print("Compatibility with Space Exploration is broken.")
		-- records = se_compat.se_set_manifest_schedule(
		-- 	map_data.perf_cache,
		-- 	train,
		-- 	depot_stop,
		-- 	same_depot,
		-- 	p_stop,
		-- 	p_schedule_settings,
		-- 	r_stop,
		-- 	r_schedule_settings,
		-- 	manifest,
		-- 	start_at_depot
		-- )
	end

	if records and next(records) then
		local insert_index = add_records_after_interrupt(schedule, records)
		if start_at_depot then
			schedule.go_to_station(schedule.get_record_count() --[[@as int]])
		elseif schedule.current > insert_index then
			schedule.go_to_station(insert_index)
		end
		return train.has_path
	end

	train_stuck()
	send_alert_cannot_path_between_surfaces(map_data, train)
	return true
end

---NOTE: does not check .valid
---@param map_data MapData
---@param train LuaTrain
---@param stop LuaEntity
function add_refueler_schedule(map_data, train, stop)
	if not stop.connected_rail then
		send_alert_refueler_of_train_broken(map_data, train)
		return false
	end

	local schedule = train.get_schedule()

	local t_surface = train.front_stock.surface
	local f_surface = stop.surface
	local t_surface_i = t_surface.index
	local f_surface_i = f_surface.index
	if t_surface_i == f_surface_i then
		local refueler_index = add_records_after_interrupt(schedule, {
			create_direct_to_station_order(stop),
			create_inactivity_order(stop.backer_name),
		})
		if schedule.current >= refueler_index then
			schedule.go_to_station(refueler_index)
		end
		return true
	elseif IS_SE_PRESENT then
		game.print("Compatibility with Space Exploration is broken.")
		-- if se_compat.se_add_refueler_schedule(map_data.perf_cache, train, stop, schedule) then
		-- 	train.schedule = schedule
		-- 	return true
		-- end
	end
	--create an order that probably cannot be fulfilled and alert the player
	add_records_after_interrupt(schedule, { create_inactivity_order(stop.backer_name) })
	lock_train(train)
	send_alert_cannot_path_between_surfaces(map_data, train)
	return false
end

------------------------------------------------------------------------------
--[[combinators]] --
------------------------------------------------------------------------------

---@param comb LuaEntity
function get_comb_control(comb)
	--NOTE: using this as opposed to get_comb_params gives you R/W access
	return comb.get_or_create_control_behavior() --[[@as LuaArithmeticCombinatorControlBehavior]]
end
---@param comb LuaEntity
function get_comb_params(comb)
	return comb.get_or_create_control_behavior().parameters --[[@as ArithmeticCombinatorParameters]]
end

---NOTE: does not check .valid
---@param station Station
function set_station_from_comb(station)
	--NOTE: this does nothing to update currently active deliveries
	--NOTE: this can only be called at the tick init boundary

	-- Extract settings from station combinator
	local params = get_comb_params(station.entity_comb1)
	local signal = params.first_signal

	local bits = params.second_constant or 0
	local is_pr_state = bit_extract(bits, 0, 2)
	local allows_all_trains = bit_extract(bits, SETTING_DISABLE_ALLOW_LIST) > 0
	local is_stack = bit_extract(bits, SETTING_IS_STACK) > 0
	local enable_inactive = bit_extract(bits, SETTING_ENABLE_INACTIVE) > 0
	local enable_circuit_condition = bit_extract(bits, SETTING_ENABLE_CIRCUIT_CONDITION) > 0
	local disable_manifest_condition = bit_extract(bits, SETTING_DISABLE_MANIFEST_CONDITION) > 0

	station.allows_all_trains = allows_all_trains
	station.is_stack = is_stack
	station.enable_inactive = enable_inactive
	station.is_p = (is_pr_state == 0 or is_pr_state == 1) or nil
	station.is_r = (is_pr_state == 0 or is_pr_state == 2) or nil
	station.enable_circuit_condition = enable_circuit_condition
	station.disable_manifest_condition = disable_manifest_condition

	-- Extract settings from station control combinator, if it exists
	local enable_train_count = nil
	local enable_manual_inventory = nil

	if station.entity_comb2 and station.entity_comb2.valid then
		local params2 = get_comb_params(station.entity_comb2)
		local bits2 = params2.second_constant or 0
		enable_train_count = bit_extract(bits2, SETTING_ENABLE_TRAIN_COUNT) > 0
		enable_manual_inventory = bit_extract(bits2, SETTING_ENABLE_MANUAL_INVENTORY) > 0
	end

	station.enable_train_count = enable_train_count
	station.enable_manual_inventory = enable_manual_inventory

	local new_name = signal and signal.name or nil
	if station.network_name ~= new_name then
		station.network_name = new_name
		if station.network_name == NETWORK_EACH then
			station.network_mask = {}
		else
			station.network_mask = 0
		end
	end
end
---NOTE: does not check .valid
---@param mod_settings CybersynModSettings
---@param train Train
---@param comb LuaEntity
function set_train_from_comb(mod_settings, train, comb)
	--NOTE: this does nothing to update currently active deliveries
	local params = get_comb_params(comb)
	local signal = params.first_signal
	local network_name = signal and signal.name or nil

	local bits = params.second_constant or 0
	local disable_bypass = bit_extract(bits, SETTING_DISABLE_DEPOT_BYPASS) > 0
	local use_any_depot = bit_extract(bits, SETTING_USE_ANY_DEPOT) > 0

	train.network_name = network_name
	train.disable_bypass = disable_bypass
	train.use_any_depot = use_any_depot

	local is_each = train.network_name == NETWORK_EACH
	if is_each then
		train.network_mask = {}
	else
		train.network_mask = mod_settings.network_mask
	end
	train.priority = mod_settings.priority
	local signals = comb.get_signals(defines.wire_connector_id.circuit_red, defines.wire_connector_id.circuit_green)
	if signals then
		for k, v in pairs(signals) do
			local item_name = v.signal.name
			local item_type = v.signal.type or "item"
			local item_count = v.count
			if item_name then
				if item_type == "virtual" then
					if item_name == SIGNAL_PRIORITY then
						train.priority = item_count
					elseif is_each then
						if item_name ~= REQUEST_THRESHOLD and item_name ~= REQUEST_FLUID_THRESHOLD and  item_name ~= LOCKED_SLOTS then
							train.network_mask[item_name] = item_count
						end
					end
				end
				if item_name == network_name then
					train.network_mask = item_count
				end
			end
		end
	end
end
---@param map_data MapData
---@param mod_settings CybersynModSettings
---@param id uint
---@param refueler Refueler
function set_refueler_from_comb(map_data, mod_settings, id, refueler)
	--NOTE: this does nothing to update currently active deliveries
	local params = get_comb_params(refueler.entity_comb)
	local bits = params.second_constant or 0
	local signal = params.first_signal
	local old_network = refueler.network_name
	local old_network_mask = refueler.network_mask

	refueler.network_name = signal and signal.name or nil
	refueler.allows_all_trains = bit_extract(bits, SETTING_DISABLE_ALLOW_LIST) > 0
	refueler.priority = mod_settings.priority

	local is_each = refueler.network_name == NETWORK_EACH
	if is_each then
		map_data.each_refuelers[id] = true
		refueler.network_mask = {}
	else
		map_data.each_refuelers[id] = nil
		refueler.network_mask = mod_settings.network_mask
	end

	local signals = refueler.entity_comb.get_signals(defines.wire_connector_id.circuit_red,
		defines.wire_connector_id.circuit_green)
	if signals then
		for k, v in pairs(signals) do
			local item_name = v.signal.name
			local item_type = v.signal.type or "item"
			local item_count = v.count
			if item_name then
				if item_type == "virtual" then
					if item_name == SIGNAL_PRIORITY then
						refueler.priority = item_count
					elseif is_each then
						if item_name ~= REQUEST_THRESHOLD and item_name ~= REQUEST_FLUID_THRESHOLD and  item_name ~= LOCKED_SLOTS then
							refueler.network_mask[item_name] = item_count
						end
					end
				end
				if item_name == refueler.network_name then
					refueler.network_mask = item_count
				end
			end
		end
	end

	local f, a
	if old_network == NETWORK_EACH then
		f, a = pairs(old_network_mask --[[@as {[string]: int}]])
	elseif old_network ~= refueler.network_name then
		f, a = once, old_network
	else
		f, a = once, nil
	end
	for network_name, _ in f, a do
		local network = map_data.to_refuelers[network_name]
		if network then
			network[id] = nil
			if next(network) == nil then
				map_data.to_refuelers[network_name] = nil
			end
		end
	end

	if refueler.network_name == NETWORK_EACH then
		f, a = pairs(refueler.network_mask --[[@as {[string]: int}]])
	elseif old_network ~= refueler.network_name then
		f, a = once, refueler.network_name
	else
		f, a = once, nil
	end
	for network_name, _ in f, a do
		local network = map_data.to_refuelers[network_name]
		if not network then
			network = {}
			map_data.to_refuelers[network_name] = network
		end
		network[id] = true
	end
end

---@param map_data MapData
---@param station Station
function update_display(map_data, station)
	local comb = station.entity_comb1
	if not comb.valid then return end
	
	local control = get_comb_control(comb)
	local params = control.parameters
	local current_op = params.operation
	
	if current_op ~= MODE_PRIMARY_IO and 
	   current_op ~= MODE_PRIMARY_IO_ACTIVE and 
	   current_op ~= MODE_PRIMARY_IO_FAILED_REQUEST then
		return
	end
	
	local new_op
	if station.display_state == 0 then
		new_op = MODE_PRIMARY_IO
	elseif station.display_state % 2 == 1 then
		new_op = MODE_PRIMARY_IO_ACTIVE
	else
		new_op = MODE_PRIMARY_IO_FAILED_REQUEST
	end
	
	if new_op ~= current_op then
		params.operation = new_op
		control.parameters = params
	end
end

---@param comb LuaEntity
function get_comb_gui_settings(comb)
	local params = get_comb_params(comb)
	local op = params.operation

	local selected_index = 0
	local switch_state = "none"
	local bits = params.second_constant or 0
	local is_pr_state = bit_extract(bits, 0, 2)
	if is_pr_state == 0 then
		switch_state = "none"
	elseif is_pr_state == 1 then
		switch_state = "left"
	elseif is_pr_state == 2 then
		switch_state = "right"
	end

	if op == MODE_PRIMARY_IO or op == MODE_PRIMARY_IO_ACTIVE or op == MODE_PRIMARY_IO_FAILED_REQUEST then
		selected_index = 1
	elseif op == MODE_DEPOT then
		selected_index = 2
	elseif op == MODE_REFUELER then
		selected_index = 3
	elseif op == MODE_SECONDARY_IO then
		selected_index = 4
	elseif op == MODE_SECONDARY_INVENTORY then
		selected_index = 5
	elseif op == MODE_WAGON then
		selected_index = 6
	end
	return selected_index --[[@as uint]], params.first_signal, switch_state, bits
end
---@param comb LuaEntity
---@param is_pr_state 0|1|2
function set_comb_is_pr_state(comb, is_pr_state)
	local control = get_comb_control(comb)
	local param = control.parameters
	local bits = param.second_constant or 0

	param.second_constant = bit_replace(bits, is_pr_state, 0, 2)
	control.parameters = param
end
---@param comb LuaEntity
---@param n int
---@param bit boolean
function set_comb_setting(comb, n, bit)
	local control = get_comb_control(comb)
	local param = control.parameters
	local bits = param.second_constant or 0

	param.second_constant = bit_replace(bits, bit and 1 or 0, n)
	control.parameters = param
end
---@param comb LuaEntity
---@param signal SignalID?
function set_comb_network_name(comb, signal)
	local control = get_comb_control(comb)
	local param = control.parameters

	param.first_signal = signal
	control.parameters = param
end
---@param comb LuaEntity
---@param op ArithmeticCombinatorParameterOperation
function set_comb_operation(comb, op)
	local control = get_comb_control(comb)
	local params = control.parameters
	params.operation = op
	control.parameters = params
end

--- Set the output signals of a Cybersyn combinator.
---@param map_data MapData Cybersyn stored data.
---@param comb LuaEntity Factorio combinator entity.
---@param signals LogisticFilter[]?
function set_combinator_output(map_data, comb, signals)
	local out = map_data.to_output[comb.unit_number]
	if out.valid then
		-- out is a non-interactable, invisible combinator which means players cannot change the number of sections
		out.get_or_create_control_behavior().get_section(1).filters = signals or {}
	end
end

---@param station Station
function get_signals(station)
	local comb1 = station.entity_comb1
	local status1 = comb1.status
	---@type Signal[]?
	local comb1_signals = nil
	---@type Signal[]?
	local comb2_signals = nil
	---@type table<string, Signal[]>
	local secondary_inv_signals = {}
	
	if status1 == DEFINES_WORKING or status1 == DEFINES_LOW_POWER then
		comb1_signals = comb1.get_signals(defines.wire_connector_id.circuit_red, defines.wire_connector_id.circuit_green)
	end
	
	local comb2 = station.entity_comb2
	if comb2 then
		local status2 = comb2.status
		if status2 == DEFINES_WORKING or status2 == DEFINES_LOW_POWER then
			comb2_signals = comb2.get_signals(defines.wire_connector_id.circuit_red, defines.wire_connector_id.circuit_green)
		end
	end
	
	-- Read signals from secondary inventory combinators
	if station.secondary_inv_combs then
		for _, sec_comb in pairs(station.secondary_inv_combs) do
			if sec_comb and sec_comb.valid then
				local status = sec_comb.status
				if status == DEFINES_WORKING or status == DEFINES_LOW_POWER then
					secondary_inv_signals[sec_comb.unit_number] = sec_comb.get_signals(defines.wire_connector_id.circuit_red, defines.wire_connector_id.circuit_green)
				end
			end
		end
	end
	
	return comb1_signals, comb2_signals, secondary_inv_signals
end

--- Update the station control combinator at the given station if it exists.
---@param map_data MapData
---@param station Station
function set_comb2(map_data, station)
	if station.entity_comb2 then
		local deliveries = station.deliveries
		---@type LogisticFilter[]
		local signals = {}
		for item_hash, count in pairs(deliveries) do
			local item_name, item_quality = unhash_signal(item_hash)
			local i = #signals + 1
			local is_fluid = prototypes.item[item_name] == nil --NOTE: this is expensive
			signals[i] = {
				value = {
					type = is_fluid and "fluid" or "item",
					name = item_name,
					quality = item_quality or "normal",
					comparator = "=",
				},
				min = count,
			} -- constant combinator cannot have quality = nil (any)
		end

		-- Add train count virtual signal if enabled
		if station.enable_train_count then
			local train_count = station.deliveries_total
			if train_count > 0 then
				local i = #signals + 1
				signals[i] = {
					value = "signal-T",
					min = train_count,
				}
			end
		end

		set_combinator_output(map_data, station.entity_comb2, signals)
	end
end

------------------------------------------------------------------------------
--[[alerts]] --
------------------------------------------------------------------------------

---@param train LuaTrain
---@param icon {}
---@param message string
local function send_alert_for_train(train, icon, message, ...)
	local loco = train.front_stock or train.back_stock
	if loco then
		for _, player in pairs(loco.force.players) do
			player.add_custom_alert(
				loco,
				icon,
				{ message, ... },
				true)
		end
	end
end

--- Send an alert about a particular train station.
---@param station LuaEntity Must be a train stop.
---@param icon {}
---@param message string
local function send_alert_for_station(station, icon, message)
	for _, player in pairs(station.force.players) do
		player.add_custom_alert(
			station,
			icon,
			{ message },
			true)
		player.play_sound({ path = ALERT_SOUND })
	end
end


local send_alert_about_missing_train_icon = { name = MISSING_TRAIN_NAME, type = "fluid" }
---@param r_stop LuaEntity
---@param p_stop LuaEntity
---@param message string
function send_alert_about_missing_train(r_stop, p_stop, message)
	for _, player in pairs(r_stop.force.players) do
		player.add_custom_alert(
			r_stop,
			send_alert_about_missing_train_icon,
			{ message, r_stop.backer_name, p_stop.backer_name },
			true)
	end
end

---@param train LuaTrain
function send_alert_sounds(train)
	local loco = get_any_train_entity(train)
	if loco then
		for _, player in pairs(loco.force.players) do
			player.play_sound({ path = ALERT_SOUND })
		end
	end
end

---@param r_stop LuaEntity
---@param p_stop LuaEntity
function send_alert_missing_train(r_stop, p_stop)
	send_alert_about_missing_train(r_stop, p_stop, "cybersyn-messages.missing-train")
end
---@param r_stop LuaEntity
---@param p_stop LuaEntity
function send_alert_no_train_has_capacity(r_stop, p_stop)
	send_alert_about_missing_train(r_stop, p_stop, "cybersyn-messages.no-train-has-capacity")
end
---@param r_stop LuaEntity
---@param p_stop LuaEntity
function send_alert_no_train_matches_r_layout(r_stop, p_stop)
	send_alert_about_missing_train(r_stop, p_stop, "cybersyn-messages.no-train-matches-r-layout")
end
---@param r_stop LuaEntity
---@param p_stop LuaEntity
function send_alert_no_train_matches_p_layout(r_stop, p_stop)
	send_alert_about_missing_train(r_stop, p_stop, "cybersyn-messages.no-train-matches-p-layout")
end

local send_stuck_train_alert_icon = { name = LOST_TRAIN_NAME, type = "fluid" }
---@param map_data MapData
---@param train LuaTrain
function send_alert_stuck_train(map_data, train)
	send_alert_for_train(train, send_stuck_train_alert_icon, "cybersyn-messages.stuck-train")
	map_data.active_alerts = map_data.active_alerts or {}
	map_data.active_alerts[train.id] = { train, 1, map_data.total_ticks }
end

local send_nonempty_train_in_depot_alert_icon = { name = NONEMPTY_TRAIN_NAME, type = "fluid" }
---@param map_data MapData
---@param train LuaTrain
function send_alert_nonempty_train_in_depot(map_data, train)
	send_alert_for_train(train, send_nonempty_train_in_depot_alert_icon, "cybersyn-messages.nonempty-train")
	send_alert_sounds(train)
	map_data.active_alerts = map_data.active_alerts or {}
	map_data.active_alerts[train.id] = { train, 2, map_data.total_ticks }
end

local send_lost_train_alert_icon = { name = LOST_TRAIN_NAME, type = "fluid" }
---@param map_data MapData
---@param train LuaTrain
function send_alert_depot_of_train_broken(map_data, train)
	send_alert_for_train(train, send_lost_train_alert_icon, "cybersyn-messages.depot-broken")
	send_alert_sounds(train)
	map_data.active_alerts = map_data.active_alerts or {}
	map_data.active_alerts[train.id] = { train, 3, map_data.total_ticks }
end
---@param map_data MapData
---@param train LuaTrain
function send_alert_station_of_train_broken(map_data, train)
	send_alert_for_train(train, send_lost_train_alert_icon, "cybersyn-messages.station-broken")
	send_alert_sounds(train)
	map_data.active_alerts = map_data.active_alerts or {}
	map_data.active_alerts[train.id] = { train, 4, map_data.total_ticks }
end
---@param map_data MapData
---@param train LuaTrain
function send_alert_refueler_of_train_broken(map_data, train)
	send_alert_for_train(train, send_lost_train_alert_icon, "cybersyn-messages.refueler-broken")
	send_alert_sounds(train)
	map_data.active_alerts = map_data.active_alerts or {}
	map_data.active_alerts[train.id] = { train, 5, map_data.total_ticks }
end
---@param map_data MapData
---@param train LuaTrain
function send_alert_train_at_incorrect_station(map_data, train)
	send_alert_for_train(train, send_lost_train_alert_icon, "cybersyn-messages.train-at-incorrect")
	send_alert_sounds(train)
	map_data.active_alerts = map_data.active_alerts or {}
	map_data.active_alerts[train.id] = { train, 6, map_data.total_ticks }
end
---@param map_data MapData
---@param train LuaTrain
function send_alert_cannot_path_between_surfaces(map_data, train)
	send_alert_for_train(train, send_lost_train_alert_icon, "cybersyn-messages.cannot-path-between-surfaces")
	send_alert_sounds(train)
	map_data.active_alerts = map_data.active_alerts or {}
	map_data.active_alerts[train.id] = { train, 7, map_data.total_ticks }
end
---@param map_data MapData
---@param train LuaTrain
---@param group string
function send_alert_train_group_base_schedule_broken(map_data, train, group)
	send_alert_for_train(train, send_lost_train_alert_icon, "cybersyn-messages.train-group-schedule-broken", group)
	send_alert_sounds(train)
	map_data.active_alerts = map_data.active_alerts or {}
	map_data.active_alerts[train.id] = { train, 8, map_data.total_ticks }
end
---@param map_data MapData
---@param train LuaTrain
function send_alert_train_base_schedule_broken(map_data, train)
	send_alert_for_train(train, send_lost_train_alert_icon, "cybersyn-messages.train-schedule-broken")
	send_alert_sounds(train)
	map_data.active_alerts = map_data.active_alerts or {}
	map_data.active_alerts[train.id] = { train, 9, map_data.total_ticks }
end

--- Alert user when a Cybersyn train arrives at a station with non-default
--- vanilla priority. This usually means a missed delivery.
---@param station LuaEntity Must be a train stop.
function send_alert_station_non_default_priority(station)
	send_alert_for_station(station, send_lost_train_alert_icon, "cybersyn-messages.station-non-default-priority")
end

---@param train LuaTrain
function send_alert_unexpected_train(train)
	send_alert_for_train(train, send_lost_train_alert_icon, "cybersyn-messages.unexpected-train")
end

---@param map_data MapData
function process_active_alerts(map_data)
	for train_id, data in pairs(map_data.active_alerts) do
		local train = data[1]
		if train.valid then
			local id = data[2]
			if id == 1 then
				send_alert_for_train(train, send_stuck_train_alert_icon, "cybersyn-messages.stuck-train")
			elseif id == 2 then
				--this is an alert that we have to actively check if we can clear
				local is_train_empty = next(train.get_contents()) == nil and next(train.get_fluid_contents()) == nil
				if is_train_empty then
					--NOTE: this function could get confused being called internally, be sure it can handle that
					on_train_changed({ train = train })
				else
					send_alert_for_train(train, send_nonempty_train_in_depot_alert_icon, "cybersyn-messages.nonempty-train")
				end
			elseif id == 3 then
				send_alert_for_train(train, send_lost_train_alert_icon, "cybersyn-messages.depot-broken")
			elseif id == 4 then
				send_alert_for_train(train, send_lost_train_alert_icon, "cybersyn-messages.station-broken")
			elseif id == 5 then
				send_alert_for_train(train, send_lost_train_alert_icon, "cybersyn-messages.refueler-broken")
			elseif id == 6 then
				send_alert_for_train(train, send_lost_train_alert_icon, "cybersyn-messages.train-at-incorrect")
			elseif id == 7 then
				send_alert_for_train(train, send_lost_train_alert_icon, "cybersyn-messages.cannot-path-between-surfaces")
			end
		else
			map_data.active_alerts[train_id] = nil
		end
	end
end

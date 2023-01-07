--By Mami
local min = math.min
local INF = math.huge
local btest = bit32.btest

---@param map_data MapData
---@param station Station
---@param manifest Manifest?
---@param sign int?
local function set_comb1(map_data, station, manifest, sign)
	local comb = station.entity_comb1
	if comb.valid then
		if manifest then
			local signals = {}
			for i, item in ipairs(manifest) do
				signals[i] = {index = i, signal = {type = item.type, name = item.name}, count = sign*item.count}
			end
			set_combinator_output(map_data, comb, signals)
		else
			set_combinator_output(map_data, comb, nil)
		end
	end
end

---@param map_data MapData
---@param train_id uint
---@param train Train
function on_failed_delivery(map_data, train_id, train)
	--NOTE: must either change this train's status or remove it after this call
	local p_station_id = train.p_station_id--[[@as uint]]
	local r_station_id = train.r_station_id--[[@as uint]]
	local manifest = train.manifest--[[@as Manifest]]
	local is_p_in_progress = train.status == STATUS_TO_P or train.status == STATUS_P
	local is_r_in_progress = is_p_in_progress or train.status == STATUS_TO_R or train.status == STATUS_R
	if is_p_in_progress then
		local station = map_data.stations[p_station_id]
		remove_manifest(map_data, station, manifest, 1)
		if train.status == STATUS_P then
			set_comb1(map_data, station, nil)
			unset_wagon_combs(map_data, station)
		end
	end
	if is_r_in_progress then
		local station = map_data.stations[r_station_id]
		remove_manifest(map_data, station, manifest, -1)
		if train.status == STATUS_R then
			set_comb1(map_data, station, nil)
			unset_wagon_combs(map_data, station)
		end
	end
	if train.has_filtered_wagon then
		train.has_filtered_wagon = nil
		for carriage_i, carriage in ipairs(train.entity.cargo_wagons) do
			local inv = carriage.get_inventory(defines.inventory.cargo_wagon)
			if inv then
				---@type uint
				for i = 1, inv.get_bar() - 1 do
					inv.set_filter(i, nil)
				end
				inv.set_bar()
			end
		end
	end
	train.r_station_id = nil
	train.p_station_id = nil
	train.manifest = nil
	interface_raise_train_failed_delivery(train_id, is_p_in_progress, p_station_id, is_r_in_progress, r_station_id, manifest)
end



---@param map_data MapData
---@param train_id uint
---@param train Train
function add_available_train(map_data, train_id, train)
	if train.network_name then
		local f, a
		if train.network_name == NETWORK_EACH then
			f, a = next, train.network_flag
		else
			f, a = once, train.network_name
		end
		for network_name in f, a do
			local network = map_data.available_trains[network_name]
			if not network then
				network = {}
				map_data.available_trains[network_name] = network
			end
			network[train_id] = true
		end
		train.is_available = true
		interface_raise_train_available(train_id)
	end
end
---@param map_data MapData
---@param mod_settings CybersynModSettings
---@param depot_id uint
---@param depot Depot
---@param train_id uint
---@param train Train
function add_available_train_to_depot(map_data, mod_settings, train_id, train, depot_id, depot)
	local comb = depot.entity_comb
	set_train_from_comb(mod_settings, train, comb)
	depot.available_train_id = train_id
	train.depot_id = depot_id
	train.status = STATUS_D

	add_available_train(map_data, train_id, train)
end
---@param map_data MapData
---@param train_id uint
---@param train Train
function remove_available_train(map_data, train_id, train)
	if train.is_available then
		train.is_available = nil
		local f, a
		if train.network_name == NETWORK_EACH then
			f, a = next, train.network_flag
		else
			f, a = once, train.network_name
		end
		for network_name in f, a do
			local network = map_data.available_trains[network_name]
			if network then
				network[train_id] = nil
				if next(network) == nil then
					map_data.available_trains[network_name] = nil
				end
			end
		end
		local depot = map_data.depots[train.depot_id]
		if depot.available_train_id == train_id then
			depot.available_train_id = nil
			return true
		end
	end
	return false
end



---@param map_data MapData
---@param depot_id uint
---@param train_entity LuaTrain
local function on_train_arrives_depot(map_data, depot_id, train_entity)
	local is_train_empty = next(train_entity.get_contents()) == nil and next(train_entity.get_fluid_contents()) == nil
	local train_id = train_entity.id
	local train = map_data.trains[train_id]
	if train then
		if train.status == STATUS_TO_D then
			--shouldn't be possible to get train.status == STATUS_D
		elseif train.status == STATUS_TO_D_BYPASS or train.status == STATUS_D then
			remove_available_train(map_data, train_id, train)
		elseif mod_settings.react_to_train_early_to_depot then
			if train.manifest then
				on_failed_delivery(map_data, train_id, train)
			end
			send_alert_unexpected_train(train.entity)
		else
			return
		end
		if is_train_empty or mod_settings.allow_cargo_in_depot then
			local old_status = train.status
			local depot = map_data.depots[depot_id]
			add_available_train_to_depot(map_data, mod_settings, train_id, train, depot_id, depot)
			set_depot_schedule(train_entity, depot.entity_stop.backer_name)
			interface_raise_train_status_changed(train_id, old_status, STATUS_D)
		else
			--train still has cargo
			lock_train_to_depot(train_entity)
			remove_train(map_data, train_id, train)
			send_alert_nonempty_train_in_depot(map_data, train_entity)
		end
	elseif is_train_empty or mod_settings.allow_cargo_in_depot then
		--NOTE: only place where new Train
		train = {
			entity = train_entity,
			--layout_id = set_train_layout,
			--item_slot_capacity = set_train_layout,
			--fluid_capacity = set_train_layout,
			--status = add_available_train_to_depot,
			p_station_id = 0,
			r_station_id = 0,
			manifest = nil,
			last_manifest_tick = map_data.total_ticks,
			has_filtered_wagon = nil,
			--is_available = add_available_train_to_depot,
			--depot_id = add_available_train_to_depot,
			--use_any_depot = add_available_train_to_depot,
			--disable_bypass = add_available_train_to_depot,
			--network_name = add_available_train_to_depot,
			--network_flag = add_available_train_to_depot,
			--priority = add_available_train_to_depot,
		}--[[@as Train]]
		set_train_layout(map_data, train)
		map_data.trains[train_id] = train
		local depot = map_data.depots[depot_id]
		add_available_train_to_depot(map_data, mod_settings, train_id, train, depot_id, depot)

		set_depot_schedule(train_entity, depot.entity_stop.backer_name)
		interface_raise_train_created(train_id, depot_id)
	else
		lock_train_to_depot(train_entity)
		send_alert_nonempty_train_in_depot(map_data, train_entity)
	end
	if not is_train_empty then
		interface_raise_train_nonempty_in_depot(depot_id, train_entity)
	end
end
---@param map_data MapData
---@param station_id uint
---@param train_id uint
---@param train Train
local function on_train_arrives_station(map_data, station_id, train_id, train)
	---@type uint
	if train.status == STATUS_TO_P then
		train.status = STATUS_P
		local station = map_data.stations[station_id]
		set_comb1(map_data, station, train.manifest, mod_settings.invert_sign and 1 or -1)
		set_p_wagon_combs(map_data, station, train)
		interface_raise_train_status_changed(train_id, STATUS_TO_P, STATUS_P)
	elseif train.status == STATUS_TO_R then
		train.status = STATUS_R
		local station = map_data.stations[station_id]
		set_comb1(map_data, station, train.manifest, mod_settings.invert_sign and -1 or 1)
		set_r_wagon_combs(map_data, station, train)
		interface_raise_train_status_changed(train_id, STATUS_TO_R, STATUS_R)
	end
end

---@param map_data MapData
---@param refueler_id uint
---@param train_id uint
---@param train Train
local function on_train_arrives_refueler(map_data, refueler_id, train_id, train)
	if train.status == STATUS_TO_F then
		local refueler = map_data.refuelers[refueler_id]
		train.status = STATUS_F
		set_refueler_combs(map_data, refueler, train)
		interface_raise_train_status_changed(train_id, STATUS_TO_F, STATUS_F)
	end
end

---@param map_data MapData
---@param mod_settings CybersynModSettings
---@param train_id uint
---@param train Train
local function on_train_leaves_stop(map_data, mod_settings, train_id, train)
	if train.status == STATUS_P then
		train.status = STATUS_TO_R
		local station = map_data.stations[train.p_station_id]
		remove_manifest(map_data, station, train.manifest, 1)
		set_comb1(map_data, station, nil)
		unset_wagon_combs(map_data, station)
		if train.has_filtered_wagon then
			train.has_filtered_wagon = nil
			for carriage_i, carriage in ipairs(train.entity.cargo_wagons) do
				local inv = carriage.get_inventory(defines.inventory.cargo_wagon)
				if inv then
					---@type uint
					for i = 1, inv.get_bar() - 1 do
						inv.set_filter(i, nil)
					end
					inv.set_bar()
				end
			end
		end
		interface_raise_train_status_changed(train_id, STATUS_P, STATUS_TO_R)
	elseif train.status == STATUS_R then
		local station = map_data.stations[train.r_station_id]
		remove_manifest(map_data, station, train.manifest, -1)
		set_comb1(map_data, station, nil)
		unset_wagon_combs(map_data, station)
		--complete delivery
		train.p_station_id = nil
		train.r_station_id = nil
		train.manifest = nil
		--add to available trains for depot bypass
		local fuel_fill = INF
		for _, v in pairs(train.entity.locomotives) do
			for _, loco in pairs(v) do
				local inv = loco.get_fuel_inventory()
				if inv then
					local inv_size = #inv
					if inv_size > 0 then
						local fuel_total = 0
						---@type uint
						for i = 1, inv_size do
							local item = inv[i]
							if item.valid_for_read then
								fuel_total = fuel_total + item.count/get_stack_size(map_data, item.name)
							end
						end
						fuel_fill = min(fuel_fill, fuel_total/inv_size)
					end
				end
			end
		end
		if fuel_fill > mod_settings.fuel_threshold then
			--if fuel_fill == INF, it's probably a modded electric train
			if not train.disable_bypass then
				train.status = STATUS_TO_D_BYPASS
				add_available_train(map_data, train_id, train)
				interface_raise_train_status_changed(train_id, STATUS_R, STATUS_TO_D_BYPASS)
				return
			end
		else
			local f, a
			if train.network_name == NETWORK_EACH then
				f, a = next, train.network_flag
			else
				f, a = once, train.network_name
			end
			for network_name in f, a do
				local refuelers = map_data.to_refuelers[network_name]
				if refuelers then
					local best_refueler_id = nil
					local best_dist = INF
					local best_prior = -INF
					for id, _ in pairs(refuelers) do
						local refueler = map_data.refuelers[id]
						set_refueler_from_comb(map_data, mod_settings, id)

						local refueler_network_flag = get_network_flag(refueler, network_name)
						local train_network_flag = get_network_flag(train, network_name)
						if btest(train_network_flag, refueler_network_flag) and (refueler.allows_all_trains or refueler.accepted_layouts[train.layout_id]) and refueler.trains_total < refueler.entity_stop.trains_limit then
							local accepted = false
							local dist = nil
							if refueler.priority == best_prior then
								dist = get_stop_dist(train.entity.front_stock, refueler.entity_stop)
								accepted = dist < best_dist
							end
							if accepted or refueler.priority > best_prior then
								best_refueler_id = id
								best_dist = dist or get_stop_dist(train.entity.front_stock, refueler.entity_stop)
								best_prior = refueler.priority
							end
						end
					end
					if best_refueler_id then
						local refueler = map_data.refuelers[best_refueler_id]
						if add_refueler_schedule(map_data, train.entity, refueler.entity_stop) then
							train.status = STATUS_TO_F
							train.refueler_id = best_refueler_id
							refueler.trains_total = refueler.trains_total + 1
							interface_raise_train_status_changed(train_id, STATUS_R, STATUS_TO_F)
							return
						end
					end
				end
			end
		end
		--the train has not qualified for depot bypass nor refueling
		train.status = STATUS_TO_D
		interface_raise_train_status_changed(train_id, STATUS_R, STATUS_TO_D)
	elseif train.status == STATUS_F then
		local refueler = map_data.refuelers[train.refueler_id]
		train.refueler_id = nil
		refueler.trains_total = refueler.trains_total - 1
		unset_wagon_combs(map_data, refueler)
		set_combinator_output(map_data, refueler.entity_comb, nil)
		if not train.disable_bypass then
			train.status = STATUS_TO_D_BYPASS
			add_available_train(map_data, train_id, train)
		else
			train.status = STATUS_TO_D
		end
		interface_raise_train_status_changed(train_id, STATUS_F, train.status)
	elseif train.status == STATUS_D then
		--The train is leaving the depot without a manifest, the player likely intervened
		remove_train(map_data, train_id, train)
	end
end


---@param map_data MapData
---@param train_id uint
---@param train Train
function on_train_broken(map_data, train_id, train)
	--NOTE: train.entity is only absent if the train is climbing a space elevator as of 0.5.0
	if not train.se_is_being_teleported then
		remove_train(map_data, train_id, train)
	end
end
---@param map_data MapData
---@param pre_train_id uint
local function on_train_modified(map_data, pre_train_id)
	local train = map_data.trains[pre_train_id]
	--NOTE: train.entity is only absent if the train is climbing a space elevator as of 0.5.0
	if train and not train.se_is_being_teleported then
		remove_train(map_data, pre_train_id, train)
	end
end


function on_train_built(event)
	local train_e = event.train
	if event.old_train_id_1 then
		on_train_modified(global, event.old_train_id_1)
	end
	if event.old_train_id_2 then
		on_train_modified(global, event.old_train_id_2)
	end
end
function on_train_changed(event)
	---@type MapData
	local map_data = global
	local train_e = event.train--[[@as LuaTrain]]
	if not train_e.valid then return end
	local train_id = train_e.id

	if map_data.active_alerts then
		--remove the alert if the train is interacted with at all
		local data = map_data.active_alerts[train_id]
		if data then
			--we need to wait for the train to come to a stop from being locked
			if data[3] + 10*mod_settings.tps < map_data.total_ticks then
				map_data.active_alerts[train_id] = nil
				if next(map_data.active_alerts) == nil then
					map_data.active_alerts = nil
				end
			end
		end
	end

	if train_e.state == defines.train_state.wait_station then
		local stop = train_e.station
		if stop and stop.valid and stop.name == "train-stop" then
			local id = stop.unit_number--[[@as uint]]
			if map_data.depots[id] then
				on_train_arrives_depot(map_data, id, train_e)
			end
		else
			local train = map_data.trains[train_id]
			if train then
				local schedule = train_e.schedule
				if schedule then
					local rail = schedule.records[schedule.current].rail
					if rail then
						local id, station, is_station
						if train.status == STATUS_TO_P then
							id = train.p_station_id
							station = map_data.stations[id]
							is_station = true
						elseif train.status == STATUS_TO_R then
							id = train.r_station_id
							station = map_data.stations[id]
							is_station = true
						elseif train.status == STATUS_TO_F then
							id = train.refueler_id
							station = map_data.refuelers[id]
							is_station = false
						end
						if id and station.entity_stop.connected_rail == rail then
							if is_station then
								on_train_arrives_station(map_data, id, train_id, train)
							else
								on_train_arrives_refueler(map_data, id, train_id, train)
							end
						end
					end
				end
			end
		end
	elseif event.old_state == defines.train_state.wait_station then
		local path = train_e.path
		if path and path.total_distance > 4 then
			local train = map_data.trains[train_id]
			if train then
				on_train_leaves_stop(map_data, mod_settings, train_id, train)
			end
		end
	end
end

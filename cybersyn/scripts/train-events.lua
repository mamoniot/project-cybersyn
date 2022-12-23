--By Mami
local min = math.min
local INF = math.huge

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
	train.r_station_id = nil
	train.p_station_id = nil
	train.manifest = nil
	interface_raise_train_failed_delivery(train_id, is_p_in_progress, p_station_id, is_r_in_progress, r_station_id, manifest)
end



---@param map_data MapData
---@param train_id uint
---@param train Train
function add_available_train(map_data, train_id, train)
	local network_name = train.network_name
	if network_name then
		local network = map_data.available_trains[network_name]
		if not network then
			network = {}
			map_data.available_trains[network_name] = network
		end
		network[train_id] = true
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
	local network_name = get_comb_network_name(comb)
	if network_name then
		local network = map_data.available_trains[network_name]
		if not network then
			network = {}
			map_data.available_trains[network_name] = network
		end
		network[train_id] = true
		train.is_available = true
	end
	depot.available_train_id = train_id
	train.status = STATUS_D
	train.parked_at_depot_id = depot_id
	train.depot_name = depot.entity_stop.backer_name
	train.se_depot_surface_i = depot.entity_stop.surface.index
	train.network_name = network_name
	train.network_flag = mod_settings.network_flag
	train.priority = 0
	if network_name then
		local signals = comb.get_merged_signals(defines.circuit_connector_id.combinator_input)
		if signals then
			for k, v in pairs(signals) do
				local item_name = v.signal.name
				local item_count = v.count
				if item_name then
					if item_name == SIGNAL_PRIORITY then
						train.priority = item_count
					end
					if item_name == network_name then
						train.network_flag = item_count
					end
				end
			end
		end
		interface_raise_train_available(train_id)
	end
end
---@param map_data MapData
---@param train_id uint
---@param train Train
function remove_available_train(map_data, train_id, train)
	---@type uint
	if train.is_available and train.network_name then
		local network = map_data.available_trains[train.network_name--[[@as string]]]
		if network then
			network[train_id] = nil
			if next(network) == nil then
				map_data.available_trains[train.network_name] = nil
			end
		end
		train.is_available = nil
	end
end





---@param map_data MapData
---@param depot_id uint
---@param train_entity LuaTrain
local function on_train_arrives_depot(map_data, depot_id, train_entity)
	local contents = train_entity.get_contents()
	local fluid_contents = train_entity.get_fluid_contents()
	local is_train_empty = next(contents) == nil and next(fluid_contents) == nil
	local train_id = train_entity.id
	local train = map_data.trains[train_id]
	if train then
		if train.status == STATUS_TO_D then
		elseif train.status == STATUS_TO_D_BYPASS or train.status == STATUS_D then
			--shouldn't be possible to get train.status == STATUS_D
			remove_available_train(map_data, train_id, train)
		elseif mod_settings.react_to_train_early_to_depot then
			if train.manifest then
				on_failed_delivery(map_data, train_id, train)
			end
			send_alert_unexpected_train(train.entity)
		else
			return
		end
		if is_train_empty then
			local old_status = train.status
			add_available_train_to_depot(map_data, mod_settings, train_id, train, depot_id, map_data.depots[depot_id])
			set_depot_schedule(train_entity, train.depot_name)
			interface_raise_train_status_changed(train_id, old_status, STATUS_D)
		else
			--train still has cargo
			if mod_settings.react_to_nonempty_train_in_depot then
				lock_train(train_entity)
				remove_train(map_data, train_id, train)
				send_alert_nonempty_train_in_depot(train_entity)
			end
			interface_raise_train_nonempty_in_depot(depot_id, train_entity, train_id)
		end
	elseif is_train_empty then
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
			--parked_at_depot_id = add_available_train_to_depot,
			--depot_name = add_available_train_to_depot,
			--network_name = add_available_train_to_depot,
			--network_flag = add_available_train_to_depot,
			--priority = add_available_train_to_depot,
		}
		set_train_layout(map_data, train)
		map_data.trains[train_id] = train
		add_available_train_to_depot(map_data, mod_settings, train_id, train, depot_id, map_data.depots[depot_id])

		set_depot_schedule(train_entity, train.depot_name)
		interface_raise_train_created(train_id, depot_id)
	else
		if mod_settings.react_to_nonempty_train_in_depot then
			lock_train(train_entity)
			send_alert_nonempty_train_in_depot(train_entity)
		end
		interface_raise_train_nonempty_in_depot(depot_id, train_entity)
	end
end
---@param map_data MapData
---@param station_id uint
---@param train_id uint
---@param train Train
local function on_train_arrives_station(map_data, station_id, train_id, train)
	if train.manifest then
		---@type uint
		if train.status == STATUS_TO_P then
			if train.p_station_id == station_id then
				train.status = STATUS_P
				local station = map_data.stations[station_id]
				set_comb1(map_data, station, train.manifest, 1)
				set_p_wagon_combs(map_data, station, train)
				interface_raise_train_status_changed(train_id, STATUS_TO_P, STATUS_P)
			end
		elseif train.status == STATUS_TO_R then
			if train.r_station_id == station_id then
				train.status = STATUS_R
				local station = map_data.stations[station_id]
				set_comb1(map_data, station, train.manifest, -1)
				set_r_wagon_combs(map_data, station, train)
				interface_raise_train_status_changed(train_id, STATUS_TO_R, STATUS_R)
			end
		elseif train.status == STATUS_P and train.p_station_id == station_id then
			--this is player intervention that is considered valid
		elseif (train.status == STATUS_R or train.status == STATUS_TO_D or train.status == STATUS_TO_D_BYPASS) and train.r_station_id == station_id then
			--this is player intervention that is considered valid
		elseif mod_settings.react_to_train_at_incorrect_station then
			on_failed_delivery(map_data, train_id, train)
			remove_train(map_data, train_id, train)
			lock_train(train.entity)
			send_alert_train_at_incorrect_station(train.entity, train.depot_name)
		end
	elseif mod_settings.react_to_train_at_incorrect_station then
		--train is lost somehow, probably from player intervention
		remove_train(map_data, train_id, train)
		send_alert_train_at_incorrect_station(train.entity, train.depot_name)
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
				if inv and inv.is_filtered() then
					---@type uint
					for i = 1, #inv do
						inv.set_filter(i, nil)
					end
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
			if mod_settings.depot_bypass_enabled then
				train.status = STATUS_TO_D_BYPASS
				add_available_train(map_data, train_id, train)
				interface_raise_train_status_changed(train_id, STATUS_R, STATUS_TO_D_BYPASS)
				return
			end
		else
			local refuelers = map_data.to_refuelers[train.network_name]
			if refuelers then
				local best_refueler_id = nil
				local best_dist = INF
				local best_prior = -INF
				for id, _ in pairs(refuelers) do
					local refueler = map_data.refuelers[id]
					set_refueler_from_comb(mod_settings, refueler)
					if bit32.btest(train.network_flag, refueler.network_flag) and (refueler.allows_all_trains or refueler.accepted_layouts[train.layout_id]) and refueler.trains_total < refueler.entity_stop.trains_limit then
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
					train.status = STATUS_TO_F
					train.refueler_id = best_refueler_id
					local refueler = map_data.refuelers[best_refueler_id]
					refueler.trains_total = refueler.trains_total + 1
					add_refueler_schedule(train.entity, refueler.entity_stop, train.depot_name)
					interface_raise_train_status_changed(train_id, STATUS_R, STATUS_TO_F)
					return
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
		if mod_settings.depot_bypass_enabled then
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
		if train.manifest then
			on_failed_delivery(map_data, train_id, train)
		end
		remove_train(map_data, train_id, train)
	end
end
---@param map_data MapData
---@param pre_train_id uint
local function on_train_modified(map_data, pre_train_id)
	local train = map_data.trains[pre_train_id]
	--NOTE: train.entity is only absent if the train is climbing a space elevator as of 0.5.0
	if train and not train.se_is_being_teleported then
		if train.manifest then
			on_failed_delivery(map_data, pre_train_id, train)
		end
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
	local train_e = event.train--[[@as LuaTrain]]
	if not train_e.valid then return end
	local train_id = train_e.id
	if train_e.state == defines.train_state.wait_station then
		local stop = train_e.station
		if stop and stop.valid and stop.name == "train-stop" then
			local id = stop.unit_number--[[@as uint]]
			if global.stations[id] then
				local train = global.trains[train_id]
				if train then
					on_train_arrives_station(global, id, train_id, train)
				end
			elseif global.depots[id] then
				on_train_arrives_depot(global, id, train_e)
			elseif global.refuelers[id] then
				local train = global.trains[train_id]
				if train then
					on_train_arrives_refueler(global, id, train_id, train)
				end
			end
		end
	elseif event.old_state == defines.train_state.wait_station then
		local train = global.trains[train_id]
		if train then
			on_train_leaves_stop(global, mod_settings, train_id, train)
		end
	end
end

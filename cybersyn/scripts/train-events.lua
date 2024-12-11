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
				signals[i] = {
					value = { type = item.type, name = item.name, quality = item.quality or "normal", comparator = "=" },
					min = sign * item.count,
				}
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
	local p_station_id = train.p_station_id --[[@as uint]]
	local r_station_id = train.r_station_id --[[@as uint]]
	local manifest = train.manifest --[[@as Manifest]]
	local is_p_in_progress = train.status == STATUS_TO_P or train.status == STATUS_P
	local is_r_in_progress = is_p_in_progress or train.status == STATUS_TO_R or train.status == STATUS_R
	if is_p_in_progress then
		local station = map_data.stations[p_station_id]
		if station.entity_comb1.valid and (not station.entity_comb2 or station.entity_comb2.valid) then
			remove_manifest(map_data, station, manifest, 1)
			if train.status == STATUS_P then
				set_comb1(map_data, station, nil)
				unset_wagon_combs(map_data, station)
			end
		end
	end
	if is_r_in_progress then
		local station = map_data.stations[r_station_id]
		if station.entity_comb1.valid and (not station.entity_comb2 or station.entity_comb2.valid) then
			remove_manifest(map_data, station, manifest, -1)
			if train.status == STATUS_R then
				set_comb1(map_data, station, nil)
				unset_wagon_combs(map_data, station)
			end
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
	interface_raise_train_failed_delivery(train_id, is_p_in_progress, p_station_id, is_r_in_progress, r_station_id,
		manifest)
end

---@param map_data MapData
---@param train_id uint
---@param train Train
function add_available_train(map_data, train_id, train)
	if train.network_name then
		local f, a
		if train.network_name == NETWORK_EACH then
			f, a = next, train.network_mask
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
	if comb.valid then
		set_train_from_comb(mod_settings, train, comb)
	end
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
			f, a = next, train.network_mask
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
---@param depot Depot
---@param train_entity LuaTrain
local function on_train_arrives_depot(map_data, depot_id, depot, train_entity)
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
			--network_mask = add_available_train_to_depot,
			--priority = add_available_train_to_depot,
		} --[[@as Train]]
		set_train_layout(map_data, train)
		map_data.trains[train_id] = train
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
---@param station Station
---@param train_id uint
---@param train Train
local function on_train_arrives_station(map_data, station, train_id, train)
	---@type uint
	if train.status == STATUS_TO_P then
		train.status = STATUS_P
		set_comb1(map_data, station, train.manifest, -1)
		set_p_wagon_combs(map_data, station, train)
		interface_raise_train_status_changed(train_id, STATUS_TO_P, STATUS_P)
	elseif train.status == STATUS_TO_R then
		train.status = STATUS_R
		set_comb1(map_data, station, train.manifest, 1)
		set_r_wagon_combs(map_data, station, train)
		interface_raise_train_status_changed(train_id, STATUS_TO_R, STATUS_R)
	end
end

---@param map_data MapData
---@param refueler Refueler
---@param train_id uint
---@param train Train
local function on_train_arrives_refueler(map_data, refueler, train_id, train)
	if train.status == STATUS_TO_F then
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
		color_train_by_stop(train.entity, map_data.stations[train.r_station_id].entity_stop)
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
		local fuel_fill = 1
		if mod_settings.fuel_threshold < 1 then
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
									fuel_total = fuel_total + item.count / get_stack_size(map_data, item.name)
								end
							end
							fuel_fill = min(fuel_fill, fuel_total / inv_size)
						end
					end
				end
			end
		end
		if fuel_fill > mod_settings.fuel_threshold then
			--if fuel_fill == 1, it's probably a modded electric train
			if not train.disable_bypass then
				train.status = STATUS_TO_D_BYPASS
				add_available_train(map_data, train_id, train)
				if not train.use_any_depot then
					-- train using same depot, coord. station was inserted -> we need to color
					color_train_by_stop(train.entity, map_data.depots[train.depot_id].entity_stop)
				end
				interface_raise_train_status_changed(train_id, STATUS_R, STATUS_TO_D_BYPASS)
				return
			end
		else
			-- Train needs refueled. Locate matching refueler.
			local f, a
			if train.network_name == NETWORK_EACH then
				f, a = next, train.network_mask
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
						if not refueler.entity_stop.valid or not refueler.entity_comb.valid then
							on_refueler_broken(map_data, id, refueler)
						else
							set_refueler_from_comb(map_data, mod_settings, id, refueler)

							local refueler_network_mask = get_network_mask(refueler, network_name)
							local train_network_mask = get_network_mask(train, network_name)
							-- Verify refueler compatibility with train.
							if
									btest(train_network_mask, refueler_network_mask) and
									(refueler.allows_all_trains or refueler.accepted_layouts[train.layout_id]) and
									refueler.trains_total < refueler.entity_stop.trains_limit and
									is_train_routable(get_any_train_entity(train.entity), refueler.entity_stop)
							then
								if refueler.priority >= best_prior then
									local t = get_any_train_entity(train.entity)
									local dist = t and get_dist(t, refueler.entity_stop) or INF
									if refueler.priority > best_prior or dist < best_dist then
										best_refueler_id = id
										best_dist = dist
										best_prior = refueler.priority
									end
								end
							end
						end
					end
					if best_refueler_id then
						local refueler = map_data.refuelers[best_refueler_id]
						if add_refueler_schedule(map_data, train.entity, refueler.entity_stop) then
							train.status = STATUS_TO_F
							train.refueler_id = best_refueler_id
							refueler.trains_total = refueler.trains_total + 1
							color_train_by_stop(train.entity, map_data.refuelers[train.refueler_id].entity_stop)
							interface_raise_train_status_changed(train_id, STATUS_R, STATUS_TO_F)
							return
						end
					end
				end
			end
		end
		--the train has not qualified for depot bypass nor refueling
		train.status = STATUS_TO_D
		if not train.use_any_depot then
			-- train using same depot, coord. station was inserted -> we need to color
			color_train_by_stop(train.entity, map_data.depots[train.depot_id].entity_stop)
		end
		interface_raise_train_status_changed(train_id, STATUS_R, STATUS_TO_D)
	elseif train.status == STATUS_F then
		local refueler = map_data.refuelers[train.refueler_id]
		train.refueler_id = nil
		refueler.trains_total = refueler.trains_total - 1
		unset_wagon_combs(map_data, refueler)
		if refueler.entity_comb.valid then
			set_combinator_output(map_data, refueler.entity_comb, nil)
		end
		if not train.disable_bypass then
			train.status = STATUS_TO_D_BYPASS
			add_available_train(map_data, train_id, train)
		else
			train.status = STATUS_TO_D
		end
		if not train.use_any_depot then
			-- train using same depot, coord. station was inserted -> we need to color
			color_train_by_stop(train.entity, map_data.depots[train.depot_id].entity_stop)
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
		on_train_modified(storage, event.old_train_id_1)
	end
	if event.old_train_id_2 then
		on_train_modified(storage, event.old_train_id_2)
	end
end
function on_train_changed(event)
	---@type MapData
	local map_data = storage
	local train_e = event.train --[[@as LuaTrain]]
	if not train_e.valid then return end
	local train_id = train_e.id

	if map_data.active_alerts then
		--remove the alert if the train is interacted with at all
		local data = map_data.active_alerts[train_id]
		if data then
			--we need to wait for the train to come to a stop from being locked
			if data[3] + 10 * mod_settings.tps < map_data.total_ticks then
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
			-- Arrived at explicitly named stop
			local id = stop.unit_number --[[@as uint]]
			local depot = map_data.depots[id]
			if depot then
				if depot.entity_comb.valid and depot.entity_stop.valid then
					on_train_arrives_depot(map_data, id, depot, train_e)
				else
					on_depot_broken(map_data, id, depot)
				end
			end

			-- Check for invalid usage of priority
			if stop.train_stop_priority ~= 50 then
				-- If train under control of Cybersyn arrives at non default priority station, alert user.
				local train = map_data.trains[train_id]
				if train then
					send_alert_station_non_default_priority(stop)
				end
			end
		else
			-- Arrived at stop specified by coordinates. This event fires
			-- slightly before the train arrives at the real target stop.
			-- NOTE: if Factorio API ever allows sending trains to particular
			-- stops, this will have to be changed.
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
						if id and station.entity_stop.valid and station.entity_stop.connected_rail == rail then
							if is_station then
								if station.entity_comb1 and (not station.entity_comb2 or station.entity_comb2.valid) then
									on_train_arrives_station(map_data, station, train_id, train)
								end
							elseif station.entity_comb.valid then
								on_train_arrives_refueler(map_data, station, train_id, train)
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
				-- Check if train has been misdirected along a long rail path due to
				-- the priority of the station at the end.
				local last_rail = path.rails[#path.rails]
				local to_stop = (last_rail and last_rail.valid) and
						(last_rail.get_rail_segment_stop(defines.rail_direction.front) or last_rail.get_rail_segment_stop(defines.rail_direction.back))
				if to_stop and to_stop.train_stop_priority ~= 50 then
					send_alert_station_non_default_priority(to_stop)
					-- Fallthrough: still executing normal cybersyn behavior here even
					-- though it will probably cause a wrong delivery. (This may be
					-- a case where we want to lock the train or give it an invalid
					-- schedule as is done elsewhere in the code.)
				end

				on_train_leaves_stop(map_data, mod_settings, train_id, train)
			end
		end
	end
end

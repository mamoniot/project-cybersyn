---@alias SeZoneType "star"|"planet"|"moon"|"orbit"|"spaceship"|"asteroid-belt"|"asteroid-field"|"anomaly"
---@alias SeZoneIndex integer

---@class SeZone The relevant fields of a Space Exploration zone
---@field type SeZoneType
---@field name string -- the display name of the zone
---@field index SeZoneIndex -- the zone's table index
---@field orbit_index SeZoneIndex? -- the zone index of the orbit
---@field parent_index SeZoneIndex? -- the zone index of the parent zone
---@field surface_index integer? -- the Factorio surface index of the zone
---@field seed integer? -- the mapgen seed

local DESTORY_TYPE_ENTITY = defines.target_type.entity

local Elevator = {
	name_elevator = "se-space-elevator",
	name_stop = "se-space-elevator-train-stop",
}

local ENTITY_SEARCH = { Elevator.name_elevator, Elevator.name_stop }

--- Creates a new ElevatorEndData structure if all necessary entities are present on the given surfaces at the given location
--- @param surface LuaSurface
--- @param position MapPosition supposed to be at the center of an elevator, will be searched in a 12-tile radius
--- @return Cybersyn.ElevatorEndData?
local function search_entities(surface, position)
	local x = position.x or position[1]
	local y = position.y or position[2]
	local search_area = { { x - 12, y - 12 }, { x + 12, y + 12 } } -- elevator is 24x24
	local elevator, stop

	for _, found_entity in pairs(surface.find_entities_filtered({ name = ENTITY_SEARCH, area = search_area, })) do
		if found_entity.name == Elevator.name_stop then
			stop = found_entity
		elseif found_entity.name == Elevator.name_elevator then
			elevator = found_entity
		end
	end

	if not (elevator and elevator.valid and stop and stop.valid) then
		return nil
	end

	return {
		elevator = elevator,
		stop = stop,

		-- these are kept in the record for table cleanup in case the entities become unreadable
		elevator_id = elevator.unit_number,
		stop_id = stop.unit_number,
	}
end

--- Register with Factorio to destroy LTN surface connectors when the corresponding elevator is removed
function Elevator.on_object_destroyed(e)
	if e.type ~= DESTORY_TYPE_ENTITY or not e.useful_id then return end

	local data = storage.se_elevators[e.useful_id] -- useful_id for entities is the unit_number
	if data then
		storage.se_elevators[data.ground.elevator_id] = nil
		storage.se_elevators[data.orbit.elevator_id] = nil
		storage.se_elevators[data.ground.stop_id] = nil
		storage.se_elevators[data.orbit.stop_id] = nil
	end
end

--- Either the surface.index and zone.type of the opposite surface or nil
--- @return integer? surface_index
--- @return string? zone_type
local function find_opposite_surface(surface_index)
	local zone = remote.call("space-exploration", "get_zone_from_surface_index", { surface_index = surface_index }) --[[@as SeZone]]
	if zone then
		local opposite_zone_index = ((zone.type == "planet" or zone.type == "moon") and zone.orbit_index) or (zone.type == "orbit" and zone.parent_index) or nil
		if opposite_zone_index then
			local opposite_zone = remote.call("space-exploration", "get_zone_from_zone_index", { zone_index = opposite_zone_index }) --[[@as SeZone]]
			if opposite_zone and opposite_zone.surface_index then -- a zone might not have a surface, yet
				return opposite_zone.surface_index, opposite_zone.type
			end
		end
	end
	return nil
end

--- Looks up the elevator data for the given unit_number. The data structure *won't* be created if it doesn't exist.
--- @param unit_number integer the unit_number of a `se-space-elevator` or `se-space-elevator-train-stop`
--- @return Cybersyn.ElevatorData|nil
function Elevator.from_unit_number(unit_number)
	local elevator = storage.se_elevators[unit_number]
	return elevator or nil
end

--- Looks up the elevator data for the given entity. Creates the data structure if it doesn't exist, yet.
--- @param entity LuaEntity? must be a `se-space-elevator` or `se-space-elevator-train-stop`
--- @return Cybersyn.ElevatorData?
function Elevator.from_entity(entity)
	if not (entity and entity.valid) then
		return nil
	end
	local data = Elevator.from_unit_number(entity.unit_number)
	if data then return data end

	-- construct new data
	if entity.name ~= Elevator.name_elevator and entity.name ~= Elevator.name_stop then
		error("entity must be an elevator or the corresponding connector entity")
	end

	local opposite_surface_index, opposite_zone_type = find_opposite_surface(entity.surface.index)
	if not opposite_surface_index then return nil end

	local end1 = search_entities(entity.surface, entity.position)
	if not end1 then return nil end

	local end2 = search_entities(game.surfaces[opposite_surface_index], entity.position)
	if not end2 then return nil end

	data = {
		ground = (opposite_zone_type == "planet" or opposite_zone_type == "moon") and end2 or end1,
		orbit = opposite_zone_type == "orbit" and end2 or end1,
		-- no entity in the world has this information so reset to "no network restrictions but disabled"
		cs_enabled = false,
		network_masks = nil,
	}
	if data.ground == data.orbit then
		error("only know how to handle elevators in zone.type 'planet', 'moon' and 'orbit'")
	end

	storage.se_elevators[data.ground.elevator_id] = data
	storage.se_elevators[data.orbit.elevator_id] = data
	storage.se_elevators[data.ground.stop_id] = data
	storage.se_elevators[data.orbit.stop_id] = data

	-- no need to track by registration number, both entities are valid and must have a unit_number
	script.register_on_object_destroyed(data.ground.elevator)
	script.register_on_object_destroyed(data.orbit.elevator)

	return data
end

--- Connects or disconnects the eleator from Cybersyn based on cs_enabled and updates the network_id when connected to 
--- @param data Cybersyn.ElevatorData
function Elevator.update_connection(data)
	if data.cs_enabled then
		local status = surfaces.connect_surfaces(data.ground.stop, data.orbit.stop, data.network_masks)
		if status == surfaces.status.created then
			data.ground.elevator.force.print({ "cybersyn-messages.elevator-connected", gps_text(data.ground.elevator) })
		end
	else
		surfaces.disconnect_surfaces(data.ground.stop, data.orbit.stop)
		data.ground.elevator.force.print({ "cybersyn-messages.elevator-disconnected", gps_text(data.ground.elevator) })
	end
end

return Elevator

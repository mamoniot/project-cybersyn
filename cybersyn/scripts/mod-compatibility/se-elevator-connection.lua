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

local gui = require("__flib__.gui")

Elevators = {
	name_elevator = "se-space-elevator",
	name_stop = "se-space-elevator-train-stop",
	ui_name = "cybersyn-se-elevator-frame",
}

local ENTITY_SEARCH = { Elevators.name_elevator, Elevators.name_stop }

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
		if found_entity.name == Elevators.name_stop then
			stop = found_entity
		elseif found_entity.name == Elevators.name_elevator then
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

local DESTROY_TYPE_ENTITY = defines.target_type.entity

--- Register with Factorio to destroy LTN surface connectors when the corresponding elevator is removed
function Elevators.on_object_destroyed(e)
	if not (e.useful_id and e.type == DESTROY_TYPE_ENTITY) then return end

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
function Elevators.from_unit_number(unit_number)
	local elevator = storage.se_elevators[unit_number]
	return elevator or nil
end

--- Looks up the elevator data for the given entity. Creates the data structure if it doesn't exist, yet.
--- @param entity LuaEntity? must be a `se-space-elevator` or `se-space-elevator-train-stop`
--- @return Cybersyn.ElevatorData?
function Elevators.from_entity(entity)
	if not (entity and entity.valid) then
		return nil
	end
	local data = Elevators.from_unit_number(entity.unit_number)
	if data then return data end

	-- construct new data
	if entity.name ~= Elevators.name_elevator and entity.name ~= Elevators.name_stop then
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
function Elevators.update_connection(data)
	if data.cs_enabled then
		local status = Surfaces.connect_surfaces(data.ground.stop, data.orbit.stop, data.network_masks)
		if status == Surfaces.status.created then
			data.ground.elevator.force.print({ "cybersyn-messages.elevator-connected", gps_text(data.ground.elevator) })
		end
	else
		Surfaces.disconnect_surfaces(data.ground.stop, data.orbit.stop)
		data.ground.elevator.force.print({ "cybersyn-messages.elevator-disconnected", gps_text(data.ground.elevator) })
	end
end

---@param e EventData.on_gui_switch_state_changed
local function se_elevator_toggle(e)
	local player = assert(game.get_player(e.player_index))

	local data = Elevators.from_entity(player.opened --[[@as LuaEntity? ]])
	if not data then return end

	data.cs_enabled = e.element.switch_state == "right"
	Elevators.update_connection(data)
end

gui.add_handlers({
	se_elevator_toggle = se_elevator_toggle,
})

---@param player LuaPlayer
---@param elevator LuaEntity
---@param elevator_data Cybersyn.ElevatorData
local function create_frame(player, elevator, elevator_data)
	gui.add(player.gui.relative, {
		type = "frame", name = Elevators.ui_name,
		anchor = {
			gui = defines.relative_gui_type.assembling_machine_gui,
			position = defines.relative_gui_position.top,
			name = Elevators.name_elevator,
		},
		direction = "horizontal",
		style_mods = { padding = { 5, 5, 0, 5 } }, -- top right bottom left
		{
			type = "flow",
			name = "flow",
			{
				type = "label", style = "frame_title", ignored_by_interaction = true,
				style_mods = { top_margin = -3 },
				caption = "Cybersyn",
			},
			{
				type = "switch", name = "connect_switch",
				style_mods = { top_margin = 2 },
				allow_none_state = false,
				switch_state = elevator_data.cs_enabled and "right" or "left",
				right_label_caption = "Connected",
				handler = { [defines.events.on_gui_switch_state_changed] = se_elevator_toggle }
			},
		}
	})
end

---@param event EventData.on_gui_opened
---@param player LuaPlayer
---@param entity LuaEntity
---@param is_ghost boolean
function Elevators.on_entity_gui_opened(event, player, entity, is_ghost)
	if is_ghost then return end

	local elevator_data = Elevators.from_entity(entity)
	if not elevator_data then return end

	local frame = player.gui.relative[Elevators.ui_name] --[[@as LuaGuiElement?]]
	if frame then
		frame.flow.connect_switch.switch_state = elevator_data.cs_enabled and "right" or "left"
	else
		create_frame(player, entity, elevator_data)
	end
end

---@param event EventData.on_gui_closed
---@param player LuaPlayer
---@param entity LuaEntity
---@param is_ghost boolean
function Elevators.on_entity_gui_closed(event, player, entity, is_ghost)
	local frame = player.gui.relative[Elevators.ui_name]
	if frame then
		frame.destroy()
	end
end

---@param command CustomCommandData
local function command_toggle_elevator(command)
	if not command.player_index then
		game.print("Can only be invoked as a player.")
		return
	end
	local player = assert(game.get_player(command.player_index))

	local elevator = player.selected
	if not (elevator and elevator.valid and elevator.name == Elevators.name_elevator) then
		player.print("You need to hover your mouse over an elevator before executing this command.")
		return
	end

	local data = assert(Elevators.from_entity(elevator))
	data.cs_enabled = not data.cs_enabled
	Elevators.update_connection(data)
end

---@param command CustomCommandData
local function command_reset_elevators(command)
	for _, data in pairs(storage.se_elevators) do
		Surfaces.disconnect_surfaces(data.ground.stop, data.orbit.stop)
	end
	storage.se_elevators = {}
	game.print("All elevator connections reset.")
end

commands.add_command("cte", { "cybersyn-messages.toggle-elevator-command-help" }, command_toggle_elevator)
commands.add_command("cre", { "cybersyn-messages.reset-elevator-command-help" }, command_reset_elevators)

return Elevators

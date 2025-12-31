---@class Cybersyn.ElevatorEndData
---@field public elevator LuaEntity the main assembler entity of the elevator; this is what players interact with and where to attach the UI
---@field public stop LuaEntity the train stop of the elevator; SE allows to rename this stop
---@field public surface_id uint the surface this endpoint is on
---@field public stop_id uint reverse pointer in case the entity is destroyed
---@field public elevator_id uint reverse pointer in case the entity is destroyed
---@field public is_orbit boolean

---Encompasses both ends of an elevator. Only gets created via UI interactions.
---This removes the need to listen for `*_built` events and also the need to wait for all relevant entities to exist.
---@class Cybersyn.ElevatorData
---@field public ground Cybersyn.ElevatorEndData planet or moon in SE, Cybersyn doesn't care which
---@field public orbit Cybersyn.ElevatorEndData
---@field public cs_enabled boolean register a surface connection for this elevator or remove it; toggled via UI
---@field public network_masks {[string]: integer}? network-name to network mask; currently there is no UI for this
---@field public [uint] Cybersyn.ElevatorEndData maps each endpoint by its corresponding surface_index
---@see MapData.se_elevators

---@alias SeZoneType "star"|"planet"|"moon"|"orbit"|"spaceship"|"asteroid-belt"|"asteroid-field"|"anomaly"
---@alias SeZoneIndex integer a zone index is distinct from a surface index because zone can exist without a physical surface

---@class SeZone The relevant fields of a Space Exploration zone; queried with a remote.call
---@field type SeZoneType
---@field name string -- the display name of the zone
---@field index SeZoneIndex -- the zone's table index
---@field orbit_index SeZoneIndex? -- the zone index of the adjacent orbit
---@field parent_index SeZoneIndex? -- the zone index of the adjacent parent zone
---@field surface_index integer? -- the Factorio surface index of the zone
---@field seed integer? -- the mapgen seed

local gui = require("__flib__.gui")
local box = require("__flib__.bounding-box")

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
	local search_area = box.from_dimensions(position, 24, 24) -- elevator is 24x24
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
		surface_id = surface.index,

		-- these are kept in the record for table cleanup in case the entities become unreadable
		elevator_id = elevator.unit_number,
		stop_id = stop.unit_number,
	}
end

local DESTROY_TYPE_ENTITY = defines.target_type.entity

--- Register with Factorio to clean the Cybersyn surface connection when a corresponding elevator is removed
function Elevators.on_object_destroyed(e)
	if not (e.useful_id and e.type == DESTROY_TYPE_ENTITY) then return end

	-- Scan nested connected_surfaces table to remove the connection if this entity was part of one.
	-- This now correctly iterates through the two-level table structure.
	for surface_key, surface_connections in pairs(storage.connected_surfaces) do
		for entity_key, connection in pairs(surface_connections) do
			-- Check if either entity in the connection matches the destroyed entity's ID
			if (connection.entity1 and connection.entity1.valid and connection.entity1.unit_number == e.useful_id) or
			   (connection.entity2 and connection.entity2.valid and connection.entity2.unit_number == e.useful_id) then
				
				-- Remove the specific entity pair connection
				surface_connections[entity_key] = nil
				
				-- If the inner table is now empty, remove the surface pair key as well for cleanliness
				if not next(surface_connections) then
					storage.connected_surfaces[surface_key] = nil
				end
				
				-- We found and removed the connection, so we can stop searching.
				return
			end
		end
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


--- @param unit_number integer the unit_number of either the entity or the train stop entity
--- @return Cybersyn.ElevatorData|nil
--- Deprecated as we no longer maintain a separate elevator database.
function Elevators.from_unit_number(unit_number)
	return nil
end

--- Looks up the elevator data for the given entity. Creates the data structure if it doesn't exist, yet.
--- @param entity LuaEntity? must be a `se-space-elevator` or `se-space-elevator-train-stop`
--- @return Cybersyn.ElevatorData?
function Elevators.from_entity(entity)
	if not (entity and entity.valid) then
		return nil
	end

	-- Identify opposite surface logic remains the same
	local opposite_surface_index, opposite_zone_type = find_opposite_surface(entity.surface.index)
	if not opposite_surface_index then return nil end

	-- Find local end
	local end1 = search_entities(entity.surface, entity.position)
	if not end1 then return nil end

	-- Find remote end
	local end2 = search_entities(game.surfaces[opposite_surface_index], entity.position)
	if not end2 then return nil end

	-- Check if they are currently connected in Cybersyn
	local surfaces_connected = false
	local surface_pair_key = sorted_pair(entity.surface.index, opposite_surface_index)
	local connections = storage.connected_surfaces[surface_pair_key]
	if connections then
		-- Verify if this specific pair of stops is connected
		local entity_pair_key = sorted_pair(end1.stop.unit_number, end2.stop.unit_number)
		if connections[entity_pair_key] then
			surfaces_connected = true
		end
	end

	-- Construct temporary data object for GUI use
	local data = {
		ground = (opposite_zone_type == "planet" or opposite_zone_type == "moon") and end2 or end1,
		orbit = opposite_zone_type == "orbit" and end2 or end1,
		cs_enabled = surfaces_connected, -- Dynamic state check
		network_masks = nil,
		[entity.surface_index] = end1,
		[opposite_surface_index] = end2,
	}
	
	if data.ground == data.orbit then
		-- This check is kept from original code logic
		return nil 
	end
	
	data.ground.is_orbit = false
	data.orbit.is_orbit = true

	-- We DO NOT register to storage.se_elevators or script.on_object_destroyed here anymore.
	-- Cleanup is handled by the global on_object_destroyed scan.

	return data
end

--- @param elevator Cybersyn.ElevatorData
local function warn_same_elevator_name(elevator)
	-- Check for name collisions against active connections in storage.connected_surfaces.
	-- storage.connected_surfaces is a nested table: [surface_pair_key] -> { [entity_pair_key] -> connection }
	
	local current_name = elevator.ground.stop.backer_name
	local self_id_1 = elevator.ground.stop.unit_number
	local self_id_2 = elevator.orbit.stop.unit_number

	-- Outer loop: iterate over surface pairs
	for _, surface_connections in pairs(storage.connected_surfaces) do
		-- Inner loop: iterate over specific connections within that pair
		for _, conn in pairs(surface_connections) do
			if conn and conn.entity1 and conn.entity1.valid and conn.entity2 and conn.entity2.valid then
				-- Check if this connection is NOT the current elevator
				if conn.entity1.unit_number ~= self_id_1 and conn.entity1.unit_number ~= self_id_2 and
				   conn.entity2.unit_number ~= self_id_1 and conn.entity2.unit_number ~= self_id_2 then
					
					-- Check if names match
					if conn.entity1.backer_name == current_name or conn.entity2.backer_name == current_name then
						local msgId = "cybersyn-messages.other-elevator-enabled"
						elevator.ground.elevator.force.print({ msgId, gps_text(conn.entity1) })
						return
					end
				end
			end
		end
	end
end

--- Connects or disconnects the elevator from Cybersyn based on cs_enabled
--- Direct API calls, no database side effects.
--- @param data Cybersyn.ElevatorData
function Elevators.update_connection(data)
	if data.cs_enabled then
		local status = Surfaces.connect_surfaces(data.ground.stop, data.orbit.stop, data.network_masks)
		if status == Surfaces.status.created then
			data.ground.elevator.force.print({ "cybersyn-messages.elevator-connected", gps_text(data.ground.elevator) })
			warn_same_elevator_name(data)
		end
	else
		Surfaces.disconnect_surfaces(data.ground.stop, data.orbit.stop)
		data.ground.elevator.force.print({ "cybersyn-messages.elevator-disconnected", gps_text(data.ground.elevator) })
		warn_same_elevator_name(data)
	end
end

---@param e EventData.on_gui_switch_state_changed
local function se_elevator_toggle(e)
	local player = assert(game.get_player(e.player_index))

	-- Re-scan entities to get fresh state objects
	local data = Elevators.from_entity(player.opened --[[@as LuaEntity? ]])
	if not data then return end

	-- Set the desired state based on switch position
	data.cs_enabled = e.element.switch_state == "right"
	
	-- Apply the change
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
local function command_reset_elevators(command)
	-- Wipe the entire connection table.
	storage.connected_surfaces = {}
	-- Note: storage.se_elevators is deprecated/removed.
	if storage.se_elevators then storage.se_elevators = nil end
	
	game.print("All elevator connections reset.")
end

commands.add_command("cre", { "cybersyn-messages.reset-elevator-command-help" }, command_reset_elevators)

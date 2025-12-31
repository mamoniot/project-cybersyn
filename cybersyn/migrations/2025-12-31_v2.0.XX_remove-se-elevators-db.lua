-- migrations/2025-12-30_remove-se-elevators-db.lua

-- 1. Remove the deprecated se_elevators database.
if storage.se_elevators then
	storage.se_elevators = nil
end

-- 2. [Migration] Convert connected_surfaces from old format to new surface-indexed format.
-- Old format: {entity1 = LuaEntity, entity2 = LuaEntity, network_masks = {...}}
-- New format: {[surface_index_1] = LuaEntity, [surface_index_2] = LuaEntity, network_masks = {...}}

if storage.connected_surfaces then
	local surfaces_to_remove = {}

	for surface_key, connections in pairs(storage.connected_surfaces) do
		for entity_key, conn in pairs(connections) do
			-- Check if this is old format (has entity1/entity2 fields)
			if conn.entity1 and conn.entity2 then
				local entity1 = conn.entity1
				local entity2 = conn.entity2
				
				-- Verify both entities are valid userdata
				if type(entity1) == "userdata" and entity1.valid and 
				   type(entity2) == "userdata" and entity2.valid then
					
					-- Convert to new surface-indexed format
					local s1 = entity1.surface.index
					local s2 = entity2.surface.index
					connections[entity_key] = {
						[s1] = entity1,
						[s2] = entity2,
						network_masks = conn.network_masks
					}
				else
					-- Invalid entities, remove connection
					connections[entity_key] = nil
				end
			else
				-- Already in new format or invalid format, check validity
				local has_valid_entity = false
				for k, v in pairs(conn) do
					if type(v) == "userdata" and v.valid then
						has_valid_entity = true
						break
					end
				end
				if not has_valid_entity then
					connections[entity_key] = nil
				end
			end
		end

		-- Mark empty surface keys for removal
		if next(connections) == nil then
			surfaces_to_remove[surface_key] = true
		end
	end

	-- Final cleanup of empty surface tables
	for k, _ in pairs(surfaces_to_remove) do
		storage.connected_surfaces[k] = nil
	end
end

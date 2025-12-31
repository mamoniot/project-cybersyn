-- migrations/2025-12-30_remove-se-elevators-db.lua

-- 1. Remove the deprecated se_elevators database.
if storage.se_elevators then
	storage.se_elevators = nil
end

-- 2. [Cleanup] Remove invalid/fake entries from connected_surfaces.
-- New Cybersyn architecture requires real Userdata (LuaEntity).
-- Any legacy Lua Table injections (from older compatibility hacks) are considered invalid and must be purged.
-- Note: Valid connections (like native SE ones) are already Userdata and will be preserved.

if storage.connected_surfaces then
	local surfaces_to_remove = {}

	for surface_key, connections in pairs(storage.connected_surfaces) do
		for entity_key, conn in pairs(connections) do
			-- Strict Check: If it's not a real C++ Entity (userdata), delete it.
			if type(conn.entity1) ~= "userdata" or type(conn.entity2) ~= "userdata" then
				connections[entity_key] = nil
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

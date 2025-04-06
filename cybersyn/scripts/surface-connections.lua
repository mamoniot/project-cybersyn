Surfaces = {
    ---@enum Cybersyn.SurfaceConnectionStatus
    status = {
        invalid = 0,
        created = 1,
        updated = 2,
        deleted = 3,
    }
}

local btest = bit32.btest
local format = string.format

local SAME_SURFACE = {}

---Filters a list of matching entity-pairs each connecting the two surfaces.
---@param surface1 LuaSurface
---@param surface2 LuaSurface
---@param force LuaForce
---@param network_name string
---@param network_mask integer
---@return Cybersyn.SurfaceConnection[]? connecting_entity_pairs nil without a match, empty if surface1 == surface2
---@return integer? match_count the size of the list
function Surfaces.find_surface_connections(surface1, surface2, force, network_name, network_mask)
    if surface1 == surface2 then return SAME_SURFACE, 0 end

    local surface_pair_key = sorted_pair(surface1.index, surface2.index)
    local surface_connections = storage.connected_surfaces[surface_pair_key]
    if not surface_connections then return nil end

    local matching_connections = {}
    local count = 0

    for entity_pair_key, connection in pairs(surface_connections) do
        if connection.entity1.valid and connection.entity2.valid then
            if (not connection.network_masks or btest(network_mask, connection.network_masks[network_name] or 0))
                and connection.entity1.force == force
                and connection.entity2.force == force
            then
                count = count + 1
                matching_connections[count] = connection
            end
        else
            if debug_log then log(format("removing invalid surface connection [%s] between surfaces [%s]", entity_pair_key, surface_pair_key)) end
            surface_connections[entity_pair_key] = nil
        end
    end

    if count > 0 then
        return matching_connections, count
    else
        return nil, nil
    end
end

-- removes the surface connection between the given entities from storage.SurfaceConnections. Does nothing if the connection doesn't exist.
---@param entity1 LuaEntity
---@param entity2 LuaEntity
---@return Cybersyn.SurfaceConnectionStatus
function Surfaces.disconnect_surfaces(entity1, entity2)
    if not (entity1 and entity1.valid and entity2 and entity2.valid) then
        return Surfaces.status.invalid -- these will eventually clean up in find_surface_connections()
    end

    local surface_pair_key = sorted_pair(entity1.surface.index, entity2.surface.index)
    local surface_connections = storage.connected_surfaces[surface_pair_key]

    if surface_connections then
        local entity_pair_key = sorted_pair(entity1.unit_number, entity2.unit_number)
        if debug_log then log(format("removing surface connection for entities [%s] between surfaces [%s]", entity_pair_key, surface_pair_key)) end
        surface_connections[entity_pair_key] = nil
    end
    return Surfaces.status.deleted
end

-- adds a surface connection between the given entities; the network_id will be used in delivery processing to discard providers that don't match the surface connection's network_id
---@param entity1 LuaEntity
---@param entity2 LuaEntity
---@param network_masks {[string]: integer}?
---@return Cybersyn.SurfaceConnectionStatus
function Surfaces.connect_surfaces(entity1, entity2, network_masks)
    if not (entity1 and entity1.valid and entity2 and entity2.valid) then
        return Surfaces.status.invalid
    end

    if entity1.surface == entity2.surface then
        if debug_log then
            log(format("(connect_surfaces) Entities [%d] and [%d] are on the same surface %s [%d].",
            entity1.unit_number, entity2.unit_number,
            entity1.surface.name, entity1.surface.index))
        end
        return Surfaces.status.invalid
    end

    local surface_pair_key = sorted_pair(entity1.surface.index, entity2.surface.index)
    local surface_connections = get_or_create(storage.connected_surfaces, surface_pair_key)

    local entity_pair_key = sorted_pair(entity1.unit_number, entity2.unit_number)
    local is_update = surface_connections[entity_pair_key] and true

    if debug_log then
        log(format("(connect_surfaces) %s surface connection between [%d] on %s [%d] and [%d] on %s [%d].",
        is_update and "Updating" or "Creating",
        entity1.unit_number, entity1.surface.name, entity1.surface.index,
        entity2.unit_number, entity2.surface.name, entity2.surface.index))
    end

    -- enforce a consistent order for repeated calls with the same two entities
    if entity2.unit_number < entity1.unit_number then
        surface_connections[entity_pair_key] = { entity1 = entity2, entity2 = entity1, network_masks = network_masks }
    else
        surface_connections[entity_pair_key] = { entity1 = entity1, entity2 = entity2, network_masks = network_masks }
    end

    return is_update and Surfaces.status.updated or Surfaces.status.created
end

function Surfaces.on_surface_deleted(event)
    -- surface connections; surface_index will either be the first half of the key or the second
    local first_surface = "^"..event.surface_index.."|"
    local second_surface = "|"..event.surface_index.."$"

    for surface_pair_key, _ in pairs(storage.connected_surfaces) do
        if string.find(surface_pair_key, first_surface) or string.find(surface_pair_key, second_surface) then
            storage.connected_surfaces[surface_pair_key] = nil
        end
    end
end

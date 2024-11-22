local filter = {
	name = "entity-ghost",
	ghost_name = COMBINATOR_NAME
}

if not storage.to_comb then storage.to_comb = {} end
if not storage.to_comb_params then storage.to_comb_params = {} end

for _, surface in pairs(game.surfaces) do
	local ghosts = surface.find_entities_filtered(filter)
	for _, ghost in pairs(ghosts) do
		if not ghost or not ghost.valid then goto continue end
		local unit_number = ghost.unit_number
		if not unit_number then goto continue end
		if not storage.to_comb[unit_number] or not storage.to_comb_params[unit_number] then
			combinator_build_init(storage, ghost)
		end
		::continue::
	end
end

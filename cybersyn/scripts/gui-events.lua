script.on_event(defines.events.on_gui_click, function(event)
    if event.element.name ~= "allow_list_refresh" then return end
    --game.print(serpent.block(event.element.tags))

    -- < function interface.reset_stop_layout(stop_id, forbidden_entity, force_update)
    local combId = event.element.tags.id
    local stop = storage.to_stop[combId]
    if stop == nil then return end
    local stopId = stop.unit_number
    remote.call("cybersyn", "reset_stop_layout", stopId, nil, true)
    update_allow_list_section(event.player_index, combId)
end)
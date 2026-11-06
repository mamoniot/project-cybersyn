-- What a click on a link cell does: open the entity, show it on the map, pin it, or filter by the item.

local gui = require("__flib__.gui")
local flib_train = require("__flib__.train")

local lint = require("scripts.lint")
local util = require("scripts.gui.util")
local extras = require("scripts.gui.extras")
local hover = require("scripts.gui.utils.hover")
local nav = require("scripts.gui.utils.nav")
local filters = require("scripts.gui.utils.filters")

local links = {}

links.handle = {}

--- Every item cell's click, in any tab and panel: left sets the item filter and selects the
--- Inventory, which shows the item's drill-down while the filter is set (opening the window when the cell is outside
--- it); shift+left sets the filter and selects Stations; right clears the item filter. A stop panel's slot carries its
--- station (tags.station): the click also sets the station chip, and an in-flight slot (tags.flight) lands on the
--- Trains tab, where the trains carrying it to or from that station are; shift there keeps the tab and leaves the
--- chip off, so the view covers every stop, and right does nothing, as the panel shows no filter.
--- @param player LuaPlayer
--- @param player_data PlayerData
--- @param e EventData.on_gui_click
--- @param hash string
function links.item_button_click(player, player_data, e, hash)
	local tags = e.element.tags
	local station = tags.station
	if e.button == defines.mouse_button_type.right then
		-- A stop panel shows no filter, so its slots have nothing to clear.
		if station then return end
		filters.set(player_data, "item", nil)
	elseif e.button == defines.mouse_button_type.left then
		local name = unhash_signal(hash)
		interface_raise_item_selected(player.index, name)
		if station then
			-- Through manager.focus: a chip, search or place filter left from earlier would hide the very station the
			-- slot belongs to, and a closed window would otherwise open on the surface default. Shift lands on the
			-- same tab without the station chip, so the drill-down or Trains cover every stop.
			local tab = tags.flight and "trains_tab" or "inventory_tab"
			nav.focus(player, player_data, tab, { item = hash, station = not e.shift and station or nil,
				reveal = tags.flight and { all = true } or nil })
			return
		end
		filters.set(player_data, "item", hash)
		local tab = e.shift and "stations_tab" or "inventory_tab"
		if not nav.select_tab(player_data, tab) then player_data.selected_tab = tab end
		if not player_data.is_manager_open then
			-- The train panel's cells: a left click opens the window on the drill-down.
			if not e.shift then nav.open(player, player_data) end
			return
		end
	else
		return
	end
	nav.rerender(player, player_data)
end

--- The modifier line at the end of every link cell's tooltip.
links.LINK_FOOTER = { "cybersyn-gui.link-footer" }

local MARKER_TICKS = 300

--- One marker pair per player (map and world view); drawing a new pair removes the old one.
--- @param player LuaPlayer
--- @param player_data PlayerData
--- @param target LuaEntity
function links.draw_markers(player, player_data, target)
	local old = player_data.markers
	if old then
		for _, id in ipairs(old) do
			local obj = rendering.get_object_by_id(id)
			if obj and obj.valid then obj.destroy() end
		end
	end
	local common = {
		color = { 1, 0.27, 0.27 },
		target = target,
		surface = target.surface,
		radius = 2,
		filled = false,
		width = 6,
		time_to_live = MARKER_TICKS,
		players = { player },
	}
	common.render_mode = "game"
	local world = rendering.draw_circle(common)
	common.render_mode = "chart"
	common.radius = 4
	local chart = rendering.draw_circle(common)
	player_data.markers = { world.id, chart.id }
end

-- The zoom a click on a vanilla map pin lands on, measured: re-measure if the pin's zoom changes. It must be written
-- after centered_on, which enters remote view and resets the zoom.
local SHOW_ZOOM = 1.5

--- Shift-click on a link: the view a click on the target's map pin gives (remote view following the target at the
--- screen centre, zoom 1.5) and a marker pair on it. Entering remote view closes the GUI that holds player.opened, so
--- an unpinned manager takes it back in the same switch and stays open, with Back to the view it came from.
--- @param player LuaPlayer
--- @param player_data PlayerData
--- @param target LuaEntity
--- @param follow LuaEntity? an entity for remote view to follow (a train's front stock)
function links.show_on_map(player, player_data, target, follow)
	local window = player_data.refs and player_data.refs.manager_window
	local hold = player_data.is_manager_open and not player_data.pinning and window and window.valid
	if hold and not player_data.map_from then
		-- A player whose own view is the remote one (on a space platform) never leaves remote view: Back returns them
		-- to where they looked from.
		player_data.map_from = { controller = player.controller_type, position = player.position,
			surface = player.surface_index }
	end
	nav.switch_opened(player, function()
		-- centered_on switches to remote view and to the target's surface itself; set_controller{type = remote} would
		-- reset the zoom to 0.6, and a zoom written before the switch does not stick.
		player.centered_on = follow or target
		player.zoom = SHOW_ZOOM
		if hold then player.opened = window end
	end)
	links.draw_markers(player, player_data, target)
	nav.refresh_back(player_data)
end

--- @param e EventData.on_gui_click
--- @return string? kind
--- @return any id
local function link_target(e)
	local tags = e.element.tags
	local kind, id = tags.kind, tags.id
	if kind and id ~= nil then return kind, id end
	if tags.item_hash then return "item", tags.item_hash end
	if tags.train_id then return "train", tags.train_id end
	if tags.stop_kind then return tags.stop_kind, tags.stop_id end
	if tags.station_id then return "station", tags.station_id end
	return nil, nil
end

--- Whether a click came from inside the open manager window, not from a stop or train panel beside a game window.
--- @param player_data PlayerData
--- @param element LuaGuiElement
--- @return boolean
local function in_manager(player_data, element)
	if not player_data.is_manager_open then return false end
	local window = player_data.refs and player_data.refs.manager_window
	if not (window and window.valid) then return false end
	local index = window.index
	while element do
		if element.index == index then return true end
		element = element.parent
	end
	return false
end

--- Shift-click on a link inside the window: the map view replaces the window, pinned or not, instead of the
--- window holding over the map with Back. From a panel the window is not involved and stays as it is.
--- @param player LuaPlayer
--- @param player_data PlayerData
--- @param e EventData.on_gui_click
--- @param target LuaEntity
--- @param follow LuaEntity?
local function show_from_link(player, player_data, e, target, follow)
	if in_manager(player_data, e.element) then nav.close(player, player_data) end
	links.show_on_map(player, player_data, target, follow)
end

--- Every link cell's click: left = open, shift = show on map (closing the window), control = combinator, alt = control combinator,
--- control + shift = a map pin, right on an item = clear the item filter. Train and stop links take no right-click.
--- Tags {kind = "station"|"depot"|"refueler"|"train"|"item"|"entity", id};
--- "entity" is a stop or combinator Cybersyn has not registered, by unit number, as the lint registry recorded it, or a
--- Cybersyn combinator by unit number (a Stations row's inventory marker). The older tag shapes of the Stations and
--- Trains rows are read too.
--- @param player LuaPlayer
--- @param player_data PlayerData
--- @param e EventData.on_gui_click
--- @param kind string? the target when the cell's tags do not carry it (a cell whose tags name something else, e.g. the Trains state icon)
--- @param id (uint|string)?
function links.handle_link_click(player, player_data, e, kind, id)
	if not kind then kind, id = link_target(e) end
	if not kind then return end
	if kind == "item" then
		links.item_button_click(player, player_data, e, id)
		return
	end
	if e.button and e.button ~= defines.mouse_button_type.left then return end
	if e.control and e.shift then
		if kind ~= "entity" then extras.add_pin(player, kind, id) end
		return
	end
	if kind == "train" then
		local train = storage.trains[id]
		local entity = train and train.entity
		if not (entity and entity.valid) then
			util.error_flying_text(player, { "cybersyn-message.error-train-is-invalid" })
			return
		end
		local locomotive = flib_train.get_main_locomotive(entity)
		if e.shift then
			local front = entity.front_stock
			if front then show_from_link(player, player_data, e, front, front) end
			return
		end
		if not (locomotive and locomotive.valid) then
			util.error_flying_text(player, { "cybersyn-gui.train-has-no-locomotive" })
			return
		end
		nav.open_entity(player, player_data, locomotive)
		return
	end
	if kind == "entity" then
		local entity = lint.registry_entity(id)
		if not entity then
			util.error_flying_text(player, { "cybersyn-message.error-station-is-invalid" })
		elseif e.shift then
			show_from_link(player, player_data, e, entity)
		else
			nav.open_entity(player, player_data, entity)
		end
		return
	end
	local record
	if kind == "station" then
		record = storage.stations[id]
	elseif kind == "depot" then
		record = storage.depots[id]
	elseif kind == "refueler" then
		record = storage.refuelers[id]
	end
	local stop = record and record.entity_stop
	if not (stop and stop.valid) then
		util.error_flying_text(player, { "cybersyn-message.error-station-is-invalid" })
		return
	end
	if e.shift then
		show_from_link(player, player_data, e, stop)
	elseif e.control then
		local comb = kind == "station" and record.entity_comb1 or record.entity_comb
		if comb and comb.valid then
			nav.open_entity(player, player_data, comb)
		else
			util.error_flying_text(player, { "cybersyn-message.error-cybernetic-combinator-not-found" })
		end
	elseif e.alt and kind == "station" then
		local comb = record.entity_comb2
		if comb and comb.valid then
			nav.open_entity(player, player_data, comb)
		else
			util.error_flying_text(player, { "cybersyn-message.error-station-control-combinator-not-found" })
		end
	else
		nav.open_entity(player, player_data, stop)
	end
end

--- @param e EventData.on_gui_click
function links.handle.link_click(player, player_data, refs, e)
	hover.touch_hover(e)
	links.handle_link_click(player, player_data, e)
end

gui.add_handlers(links.handle, util.wrapper, "cybersyn_links")

return links

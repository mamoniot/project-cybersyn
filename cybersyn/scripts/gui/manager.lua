local gui = require("__flib__.gui")

local constants = require("scripts.gui.constants")

--local actions = require("scripts.gui.actions")
local templates = require("scripts.gui.templates")

local stations_tab = require("scripts.gui.stations")
local trains_tab = require("scripts.gui.trains")
--local depots_tab = require("scripts.gui.depots")
local inventory_tab = require("scripts.gui.inventory")
--local history_tab = require("scripts.gui.history")
--local alerts_tab = require("scripts.gui.alerts")
local util = require("scripts.gui.util")

local manager = {}

--- @param player LuaPlayer
function manager.create(player)
	local widths = constants.gui["en"]
	---@type table<string, LuaGuiElement>
	local refs = {}

	gui.add(player.gui.screen, {
		{
			name = "manager_window",
			type = "frame",
			direction = "vertical",
			visible = false,
			--handler = manager.handle.manager_close,
			children = {
				{
					name = "manager_titlebar",
					type = "flow",
					style = "flib_titlebar_flow",
					handler = manager.handle.manager_titlebar_click,
					children = {
						{ type = "label", style = "frame_title", caption = { "mod-name.cybersyn" }, ignored_by_interaction = true },
						{ type = "empty-widget", style = "flib_titlebar_drag_handle", ignored_by_interaction = true },
						{
							name = "manager_dispatcher_status_label",
							type = "label",
							style = "bold_label",
							style_mods = { font_color = constants.colors.red.tbl, left_margin = -4, top_margin = 1 },
							caption = { "cybersyn-gui.dispatcher-disabled" },
							tooltip = { "cybersyn-gui.dispatcher-disabled-description" },
							visible = not settings.global["cybersyn-enable-planner"].value,
						},
						--templates.frame_action_button("manager_pin_button", "ltnm_pin", { "cybersyn-gui.keep-open" }, manager.handle.manager_pin),--on_gui_clicked
						--templates.frame_action_button("manager_refresh_button", "ltnm_refresh", { "cybersyn-gui.refresh-tooltip" }, manager.handle.manager_refresh_click),--on_gui_clicked
						templates.frame_action_button(nil, "utility/close", { "gui.close-instruction" }, manager.handle
						.manager_close),                                                                                          --on_gui_clicked
					},
				},
				{
					type = "frame",
					style = "inside_deep_frame",
					direction = "vertical",
					children = {
						{
							type = "frame",
							style = "ltnm_main_toolbar_frame",
							children = {
								{ type = "label", style = "subheader_caption_label", caption = { "cybersyn-gui.search-label" } },
								{
									name = "manager_text_search_field",
									type = "textfield",
									clear_and_focus_on_right_click = true,
									handler = { [defines.events.on_gui_text_changed] = manager.handle.manager_update_text_search },
								},
								{ type = "label", style = "subheader_caption_label", caption = { "cybersyn-gui.search-item-label" } },
								{
									type = "choose-elem-button",
									name = "manager_item_filter",
									elem_type = "signal",
									handler = manager.handle.manager_update_item_search
								},
								{ type = "empty-widget", style = "flib_horizontal_pusher" },
								{ type = "label", style = "caption_label", caption = { "cybersyn-gui.network-name-label" } },
								{
									type = "choose-elem-button",
									name = "network",
									elem_type = "signal",
									tooltip = { "cybersyn-gui.network-tooltip" },
									handler = manager.handle.manager_update_network_name
								},
								{ type = "label", style = "caption_label", caption = { "cybersyn-gui.network-id-label" } },
								{
									name = "manager_network_mask_field",
									type = "textfield",
									style_mods = { width = 120 },
									numeric = true,
									allow_negative = true,
									clear_and_focus_on_right_click = true,
									text = "-1",
									handler = { [defines.events.on_gui_text_changed] = manager.handle.manager_update_network_mask },
								},
								{ type = "label", style = "caption_label", caption = { "cybersyn-gui.surface-label" } },
								{
									name = "manager_surface_dropdown",
									type = "drop-down",
									handler = { [defines.events.on_gui_selection_state_changed] = manager.handle.manager_update_surface },
								},
							},
						},
						{
							name = "manager_tabbed_pane",
							type = "tabbed-pane",
							style = "ltnm_tabbed_pane",
							trains_tab.create(widths),
							stations_tab.create(widths),
							inventory_tab.create(),
							selected_tab_index = 1,
						},
					},
				},
			},
		},
	}, refs)

	refs.manager_titlebar.drag_target = refs.manager_window
	refs.manager_window.force_auto_center()

	return refs
end

--- @param player_data PlayerData
function manager.build(player_data)
	local refs = player_data.refs
	-- Surface dropdown
	--- @type LuaGuiElement
	local surface_dropdown = refs.manager_surface_dropdown
	local surfaces = game.surfaces
	local currently_selected_index = surface_dropdown.selected_index
	local currently_selected_surface = nil
	if currently_selected_index ~= (nil or 0) then
		currently_selected_surface = surface_dropdown.get_item(currently_selected_index)
	end
	surface_dropdown.clear_items()
	surface_dropdown.add_item("all", 1)
	local i = 1
	for name, _ in pairs(surfaces) do
		i = i + 1
		surface_dropdown.add_item(name, i)
		--reselect same surface
		if name == currently_selected_surface then
			refs.manager_surface_dropdown.selected_index = i --[[@as uint]]
		end
	end
	-- Validate that the selected index still exist
	if player_data.search_surface_idx then
		local selected_surface = game.get_surface(player_data.search_surface_idx)
		-- If the surface was invalidated since last update, reset to all
		if not selected_surface then
			player_data.search_surface_idx = nil
		end
	end

	-- sometimes manager_item_filter picked item is not saved for some reason
	-- and then items are filtered but there is no indication in the GUI
	-- restore the GUI elem from player_data here as a workaround
	if player_data.search_item then
		--- @type LuaGuiElement
		local item_filter_elem = refs.manager_item_filter
		item_filter_elem.elem_value = util.signalid_from_name(player_data.search_item)
	end

	-- same as above but for the network GUI elem
	if player_data.search_network_name then
		local network_filter_elem = refs.network
		network_filter_elem.elem_value = util.signalid_from_name(player_data.search_network_name)
	end
end

--- @param map_data MapData
--- @param player_data PlayerData
function manager.update(map_data, player_data, query_limit)
	if player_data.selected_tab ~= nil then
		manager.build(player_data)
	end
	if player_data.selected_tab == "stations_tab" then
		stations_tab.build(map_data, player_data, query_limit)
	elseif player_data.selected_tab == "inventory_tab" then
		inventory_tab.build(map_data, player_data)
	elseif player_data.selected_tab == "trains_tab" then
		trains_tab.build(map_data, player_data, query_limit)
	end
end

manager.handle = {}

--- @param e {player_index: uint}
function manager.wrapper(e, handler)
	local player = game.get_player(e.player_index)
	if not player then return end
	local player_data = storage.manager.players[e.player_index]
	handler(player, player_data, player_data.refs, e)
end

local function toggle_fab(elem, sprite, state)
	if state then
		elem.style = "flib_selected_frame_action_button"
		elem.sprite = sprite .. ""
	else
		elem.style = "frame_action_button"
		elem.sprite = sprite .. ""
	end
end



--- @param player LuaPlayer
--- @param player_data PlayerData
--- @param refs table<string, LuaGuiElement>
function manager.handle.manager_open(player, player_data, refs)
	refs.manager_window.bring_to_front()
	refs.manager_window.visible = true
	player_data.visible = true

	if not player_data.pinning then
		player.opened = refs.manager_window
	end

	player_data.is_manager_open = true
	player.set_shortcut_toggled("cybersyn-toggle-gui", true)
end

--- @param player LuaPlayer
--- @param player_data PlayerData
--- @param refs table<string, LuaGuiElement>
function manager.handle.manager_close(player, player_data, refs)
	util.close_manager_window(player, player_data, refs)
end

--- @param player LuaPlayer
--- @param player_data PlayerData
--- @param refs table<string, LuaGuiElement>
function manager.handle.manager_toggle(player, player_data, refs)
	if player_data.is_manager_open then
		manager.handle.manager_close(player, player_data, refs)
	else
		manager.handle.manager_open(player, player_data, refs)
	end
end

--- @param player LuaPlayer
--- @param player_data PlayerData
--- @param refs table<string, LuaGuiElement>
function manager.handle.manager_recenter(player, player_data, refs)
	refs.window.force_auto_center()
end

--- @param player LuaPlayer
--- @param player_data PlayerData
--- @param refs table<string, LuaGuiElement>
function manager.handle.manager_toggle_auto_refresh(player, player_data, refs)
	player_data.auto_refresh = not player_data.auto_refresh
	toggle_fab(refs.manager_refresh_button, "ltnm_refresh", player_data.auto_refresh)
end

--- @param player LuaPlayer
--- @param player_data PlayerData
--- @param refs table<string, LuaGuiElement>
function manager.handle.manager_toggle_pinned(player, player_data, refs)
	player_data.pinned = not player_data.pinned
	toggle_fab(refs.manager_pin_button, "ltnm_pin", player_data.pinned)
end

--- @param player LuaPlayer
--- @param player_data PlayerData
--- @param refs table<string, LuaGuiElement>
--- @param e GuiEventData
function manager.handle.manager_update_text_search(player, player_data, refs, e)
	local query = e.text
	if query then
		-- Input sanitization
		for pattern, replacement in pairs(constants.input_sanitizers) do
			query = string.gsub(query, pattern, replacement)
		end
	end
	player_data.search_query = query
end

--- @param player LuaPlayer
--- @param player_data PlayerData
--- @param refs table<string, LuaGuiElement>
--- @param e GuiEventData
function manager.handle.manager_update_item_search(player, player_data, refs, e)
	local element = e.element
	if not element then return end
	local signal = e.element.elem_value
	if signal then
		player_data.search_item = signal.name
	else
		player_data.search_item = nil
	end
end

--- @param player LuaPlayer
--- @param player_data PlayerData
--- @param refs table<string, LuaGuiElement>
--- @param e GuiEventData
function manager.handle.manager_update_network_name(player, player_data, refs, e)
	local element = e.element
	if not element then return end
	local signal = element.elem_value
	if signal then
		player_data.search_network_name = signal.name
	else
		player_data.search_network_name = nil
	end
end
--- @param player LuaPlayer
--- @param player_data PlayerData
--- @param refs table<string, LuaGuiElement>
--- @param e GuiEventData
function manager.handle.manager_update_network_mask(player, player_data, refs, e)
	player_data.search_network_mask = tonumber(e.text) or -1
	e.text = tostring(player_data.search_network_mask)
end
--- @param player LuaPlayer
--- @param player_data PlayerData
--- @param refs table<string, LuaGuiElement>
--- @param e GuiEventData
function manager.handle.manager_update_surface(player, player_data, refs, e)
	local element = e.element
	if not element then return end
	local i = element.selected_index
	---@type uint?
	local surface_id = nil
	--all surfaces should always be the first entry with an index of 1
	if i > 1 then
		local surface_name = refs.manager_surface_dropdown.get_item(i)
		local surface = game.get_surface(surface_name)
		if surface then
			surface_id = surface.index
		end
	end

	player_data.search_surface_idx = surface_id
end

gui.add_handlers(manager.handle, manager.wrapper)

return manager

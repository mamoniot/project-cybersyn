local gui = require("__flib__.gui-lite")

local constants = require("scripts.gui.constants")

--local actions = require("scripts.gui.actions")
local templates = require("scripts.gui.templates")

local stations_tab = require("scripts.gui.stations")
--local trains_tab = require("scripts.gui.trains")
--local depots_tab = require("scripts.gui.depots")
--local inventory_tab = require("scripts.gui.inventory")
--local history_tab = require("scripts.gui.history")
--local alerts_tab = require("scripts.gui.alerts")


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
						{ type = "label", style = "frame_title", caption = { "mod-name.LtnManager" }, ignored_by_interaction = true },
						{ type = "empty-widget", style = "flib_titlebar_drag_handle", ignored_by_interaction = true },
						{
							name = "manager_dispatcher_status_label",
							type = "label",
							style = "bold_label",
							style_mods = { font_color = constants.colors.red.tbl, left_margin = -4, top_margin = 1 },
							caption = { "gui.ltnm-dispatcher-disabled" },
							tooltip = { "gui.ltnm-dispatcher-disabled-description" },
							visible = not settings.global["cybersyn-enable-planner"].value,
						},
						templates.frame_action_button("manager_pin_button", "ltnm_pin", { "gui.ltnm-keep-open" }, manager.handle.manager_pin),--on_gui_clicked
						templates.frame_action_button("manager_refresh_button", "ltnm_refresh", { "gui.ltnm-refresh-tooltip" }, manager.handle.manager_refresh_click),--on_gui_clicked
						templates.frame_action_button(nil, "utility/close", { "gui.close-instruction" }, manager.handle.manager_close),--on_gui_clicked
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
								{ type = "label", style = "subheader_caption_label", caption = { "gui.ltnm-search-label" } },
								{
									name = "manager_text_search_field",
									type = "textfield",
									clear_and_focus_on_right_click = true,
									handler = manager.handle.manager_update_text_search, --on_gui_text_changed
								},
								{ type = "empty-widget", style = "flib_horizontal_pusher" },
								{ type = "label", style = "caption_label", caption = { "gui.ltnm-network-id-label" } },
								{
									name = "manager_network_mask_field",
									type = "textfield",
									style_mods = { width = 120 },
									numeric = true,
									allow_negative = true,
									clear_and_focus_on_right_click = true,
									text = "-1",
									handler = manager.handle.manager_update_network_mask, --on_gui_text_changed
								},
								{ type = "label", style = "caption_label", caption = { "gui.ltnm-surface-label" } },
								{
									name = "manager_surface_dropdown",
									type = "drop-down",
									handler = manager.handle.manager_update_surface, --on_gui_selection_state_changed
								},
							},
						},
						{
							name = "manager_tabbed_pane",
							type = "tabbed-pane",
							style = "ltnm_tabbed_pane",
							selected_tab_index = 1,
							tabs = {
								stations_tab.create(widths)
							}
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

--- @param map_data MapData
--- @param player LuaPlayer
--- @param player_data PlayerData
function manager.update(map_data, player, player_data)
	--local tab = trains_tab.build(map_data, player_data)
	--gui.add(_, tab, player_data.refs)
end



manager.handle = {}

--- @param e {player_index: uint}
function manager.wrapper(e, handler)
	local player = game.get_player(e.player_index)
	if not player then return end
	local player_data = global.manager.players[e.player_index]
	handler(player, player_data, player_data.refs, e)
end


local function toggle_fab(elem, sprite, state)
	if state then
		elem.style = "flib_selected_frame_action_button"
		elem.sprite = sprite .. "_black"
	else
		elem.style = "frame_action_button"
		elem.sprite = sprite .. "_white"
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
	player.set_shortcut_toggled("ltnm-toggle-gui", true)
end


--- @param player LuaPlayer
--- @param player_data PlayerData
--- @param refs table<string, LuaGuiElement>
function manager.handle.manager_close(player, player_data, refs)
	if player_data.pinning then
		return
	end

	refs.manager_window.visible = false
	player_data.visible = false

	if player.opened == refs.manager_window then
		player.opened = nil
	end

	player_data.is_manager_open = false
	player.set_shortcut_toggled("ltnm-toggle-gui", false)


	player_data.refs.manager_window.destroy()
	player_data.refs = manager.create(player)
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
function manager.handle.manager_update_network_name(player, player_data, refs)
	local signal = refs.manager_network_name.elem_value
	if signal then
		player_data.search_network_name = signal.name
	else
		player_data.search_network_name = nil
	end
end
--- @param player LuaPlayer
--- @param player_data PlayerData
--- @param refs table<string, LuaGuiElement>
function manager.handle.manager_update_network_mask(player, player_data, refs)
	player_data.search_network_mask = tonumber(refs.manager_network_mask_field.text) or -1
end
--- @param player LuaPlayer
--- @param player_data PlayerData
--- @param refs table<string, LuaGuiElement>
function manager.handle.manager_update_surface(player, player_data, refs)
	local i = refs.manager_surface_dropdown.selected_index
	player_data.search_surface_idx = i--TODO: fix this
end


gui.add_handlers(manager.handle, manager.wrapper)

return manager

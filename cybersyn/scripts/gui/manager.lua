local gui = require("__flib__.gui-lite")

local constants = require("scripts.gui.constants")

--local actions = require("scripts.gui.actions")
local templates = require("scripts.gui.templates")

local trains_tab = require("scripts.gui.trains")
--local depots_tab = require("scripts.gui.depots")
--local stations_tab = require("scripts.gui.stations")
--local inventory_tab = require("scripts.gui.inventory")
--local history_tab = require("scripts.gui.history")
--local alerts_tab = require("scripts.gui.alerts")


--- @class PlayerData
--- @field refs {[string]: LuaGuiElement}?
--- @field search_query string?
--- @field network_name string
--- @field network_flag int
--- @field pinning boolean



function Index:dispatch(msg, e)
	-- "Transform" the action based on criteria
	if msg.transform == "handle_refresh_click" then
		if e.shift then
			msg.action = "toggle_auto_refresh"
		else
			self.state.ltn_data = global.data
			self.do_update = true
		end
	elseif msg.transform == "handle_titlebar_click" then
		if e.button == defines.mouse_button_type.middle then
			msg.action = "recenter"
		end
	end

	-- Dispatch the associated action
	if msg.action then
		local func = self.actions[msg.action]
		if func then
			func(self, msg, e)
		else
			log("Attempted to call action `" .. msg.action .. "` for which there is no handler yet.")
		end
	end

	-- Update if necessary
	if self.do_update then
		self:update()
		self.do_update = false
	end
end

function Index:schedule_update()
	self.do_update = true
end


local manager = {}


function manager.build(player, player_data)
	local widths = constants.gui["en"]
	---@type table<string, LuaGuiElement>
	local refs = {}

	local _, window = gui.add(player.gui.screen, {
		{
			name = "manager_window",
			type = "frame",
			direction = "vertical",
			visible = false,
			handler = manager.handle.close,
			children = {
				{
					name = "manager_titlebar",
					type = "flow",
					style = "flib_titlebar_flow",
					handler = manager.handle.titlebar_click,
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
						templates.frame_action_button("manager_pin_button", "ltnm_pin", { "gui.ltnm-keep-open" }, manager.handle.pin),--on_gui_clicked
						templates.frame_action_button("manager_refresh_button", "ltnm_refresh", { "gui.ltnm-refresh-tooltip" }, manager.handle.refresh_click),--on_gui_clicked
						templates.frame_action_button(nil, "utility/close", { "gui.close-instruction" }, manager.handle.close),--on_gui_clicked
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
									handler = manager.handle.update_text_search_query, --on_gui_text_changed
								},
								{ type = "empty-widget", style = "flib_horizontal_pusher" },
								{ type = "label", style = "caption_label", caption = { "gui.ltnm-network-id-label" } },
								{
									name = "manager_network_id_field",
									type = "textfield",
									style_mods = { width = 120 },
									numeric = true,
									allow_negative = true,
									clear_and_focus_on_right_click = true,
									text = "-1",
									handler = manager.handle.update_network_id_query, --on_gui_text_changed
								},
								{ type = "label", style = "caption_label", caption = { "gui.ltnm-surface-label" } },
								{
									name = "manager_surface_dropdown",
									type = "drop-down",
									handler = manager.handle.change_surface, --on_gui_selection_state_changed
								},
							},
						},
						{
							name = "manager_tabbed_pane",
							type = "tabbed-pane",
							style = "ltnm_tabbed_pane",
							children = {
								trains_tab.build(widths, refs),
							},
						},
					},
				},
			},
		},
	}, refs)



	refs.manager_titlebar.drag_target = window
	window.force_auto_center()
end

--- @param player LuaPlayer
--- @param refs table<string, LuaGuiElement>
function manager.destroy(player, refs)
	refs.manager_window.destroy()

	player.set_shortcut_toggled("ltnm-toggle-gui", false)
	player.set_shortcut_available("ltnm-toggle-gui", false)
end

--- @param player LuaPlayer
--- @param player_data PlayerData
--- @param refs table<string, LuaGuiElement>
function manager.open(player, player_data, refs)
	refs.manager_window.bring_to_front()
	refs.manager_window.visible = true
	player_data.visible = true

	if not player_data.pinning then
		player.opened = refs.manager_window
	end

	player.set_shortcut_toggled("ltnm-toggle-gui", true)
end

--- @param player LuaPlayer
--- @param player_data PlayerData
--- @param refs table<string, LuaGuiElement>
function manager.close(player, player_data, refs)
	if player_data.pinning then
		return
	end

	refs.manager_window.visible = false
	player_data.visible = false

	if player.opened == refs.manager_window then
		player.opened = nil
	end

	player.set_shortcut_toggled("ltnm-toggle-gui", false)
end


manager.handle = {}

--- @param e GuiEventData
function manager.wrapper(e, handler)
	local player = game.get_player(e.player_index)
	if not player then return end
	local player_data = global.manager.players[e.player_index]
	handler(player, player_data, player_data.refs)
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


manager.handle.close = manager.close

--- @param player LuaPlayer
--- @param player_data PlayerData
--- @param refs table<string, LuaGuiElement>
function manager.handle.recenter(player, player_data, refs)
  refs.window.force_auto_center()
end

--- @param player LuaPlayer
--- @param player_data PlayerData
--- @param refs table<string, LuaGuiElement>
function manager.handle.toggle_auto_refresh(player, player_data, refs)
  player_data.auto_refresh = not player_data.auto_refresh
  toggle_fab(refs.manager_refresh_button, "ltnm_refresh", player_data.auto_refresh)
end

--- @param player LuaPlayer
--- @param player_data PlayerData
--- @param refs table<string, LuaGuiElement>
function manager.handle.toggle_pinned(player, player_data, refs)
  player_data.pinned = not player_data.pinned
  toggle_fab(refs.manager_pin_button, "ltnm_pin", player_data.pinned)
end

--- @param player LuaPlayer
--- @param player_data PlayerData
--- @param refs table<string, LuaGuiElement>
--- @param e GuiEventData
function manager.handle.update_text_search_query(player, player_data, refs, e)
  local query = e.text
  -- Input sanitization
  for pattern, replacement in pairs(constants.input_sanitizers) do
    query = string.gsub(query, pattern, replacement)
  end
  player_data.search_query = query

  if Gui.state.search_job then
    on_tick_n.remove(Gui.state.search_job)
  end

  if #query == 0 then
    Gui:schedule_update()
  else
    Gui.state.search_job = on_tick_n.add(
      game.tick + 30,
      { gui = "main", action = "update", player_index = Gui.player.index }
    )
  end
end

--- @param player LuaPlayer
--- @param player_data PlayerData
--- @param refs table<string, LuaGuiElement>
function manager.handle.update_network_id_query(player, player_data, refs)
  Gui.state.network_id = tonumber(Gui.refs.toolbar.network_id_field.text) or -1
  Gui:schedule_update()
end

return manager

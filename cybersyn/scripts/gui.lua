--By Mami
local flib_gui = require("__flib__.gui")
local flib_event = require("__flib__.event")

local RED = "utility/status_not_working"
local GREEN = "utility/status_working"
local YELLOW = "utility/status_yellow"

local STATUS_SPRITES = {}
STATUS_SPRITES[defines.entity_status.working] = GREEN
STATUS_SPRITES[defines.entity_status.normal] = GREEN
STATUS_SPRITES[defines.entity_status.no_power] = RED
STATUS_SPRITES[defines.entity_status.low_power] = YELLOW
STATUS_SPRITES[defines.entity_status.disabled_by_control_behavior] = RED
STATUS_SPRITES[defines.entity_status.disabled_by_script] = RED
STATUS_SPRITES[defines.entity_status.marked_for_deconstruction] = RED
local STATUS_SPRITES_DEFAULT = RED

local STATUS_NAMES = {}
STATUS_NAMES[defines.entity_status.working] = "entity-status.working"
STATUS_NAMES[defines.entity_status.normal] = "entity-status.normal"
STATUS_NAMES[defines.entity_status.no_power] = "entity-status.no-power"
STATUS_NAMES[defines.entity_status.low_power] = "entity-status.low-power"
STATUS_NAMES[defines.entity_status.disabled_by_control_behavior] = "entity-status.disabled"
STATUS_NAMES[defines.entity_status.disabled_by_script] = "entity-status.disabled-by-script"
STATUS_NAMES[defines.entity_status.marked_for_deconstruction] = "entity-status.marked-for-deconstruction"
STATUS_NAMES_DEFAULT = "entity-status.disabled"

---@param comb LuaEntity
---@param player LuaPlayer
function gui_opened(comb, player)
	local rootgui = player.gui.screen
	local control = comb.get_or_create_control_behavior().parameters--[[@as ArithmeticCombinatorParameters]]
	local op = control.operation

	local selected_index = 0
	local switch_state = "none"
	local allows_all_trains, is_pr_state = get_comb_secondary_state(control)
	if is_pr_state == 0 then
		switch_state = "none"
	elseif is_pr_state == 1 then
		switch_state = "left"
	elseif is_pr_state == 2 then
		switch_state = "right"
	end

	if op == OPERATION_PRIMARY_IO or op == OPERATION_PRIMARY_IO_ACTIVE or op == OPERATION_PRIMARY_IO_REQUEST_FAILED then
		selected_index = 1
	elseif op == OPERATION_SECONDARY_IO then
		selected_index = 2
	elseif op == OPERATION_DEPOT then
		selected_index = 3
	elseif op == OPERATION_WAGON_MANIFEST then
		selected_index = 4
	end

	local window = flib_gui.build(rootgui, {
		{type="frame", direction="vertical", ref={"main_window"}, name=COMBINATOR_NAME, children={
			--title bar
			{type="flow", ref={"titlebar"}, children={
				{type="label", style="frame_title", caption={"cybersyn-gui.combinator-title"}, elem_mods={ignored_by_interaction=true}},
				{type="empty-widget", style="flib_titlebar_drag_handle", elem_mods={ignored_by_interaction=true}},
				{type="sprite-button", style="frame_action_button", mouse_button_filter={"left"}, sprite="utility/close_white", hovered_sprite="utility/close_black", name=COMBINATOR_NAME, actions={
					on_click = {"close", comb.unit_number}
				}}
			}},
			{type="frame", style="inside_shallow_frame_with_padding", style_mods={padding=12}, children={
				{type="flow", direction="vertical", style_mods={horizontal_align="left"}, children={
					--status
					{type="flow", style="status_flow", direction="horizontal", style_mods={vertical_align="center", horizontally_stretchable=true, bottom_padding=4}, children={
						{type="sprite", sprite=STATUS_SPRITES[comb.status] or STATUS_SPRITES_DEFAULT, style="status_image", ref={"status_icon"}, style_mods={stretch_image_to_widget_size=true}},
						{type="label", caption={STATUS_NAMES[comb.status] or STATUS_NAMES_DEFAULT}, ref={"status_label"}}
					}},
					--preview
					{type="frame", style="deep_frame_in_shallow_frame", style_mods={minimal_width=0, horizontally_stretchable=true, padding=0}, children={
						{type="entity-preview", style="wide_entity_button", ref={"preview"}},
					}},
					--drop down
					{type="label", style="heading_3_label", caption={"cybersyn-gui.operation"}, style_mods={top_padding=8}},
					{type="flow", name="top", direction="horizontal", style_mods={vertical_align="center"}, children={
						{type="drop-down", style_mods={top_padding=3, right_margin=8}, ref={"operation"}, actions={
							on_selection_state_changed={"drop-down", comb.unit_number}
						}, selected_index=selected_index, items={
							{"cybersyn-gui.comb1"},
							{"cybersyn-gui.comb2"},
							{"cybersyn-gui.depot"},
							{"cybersyn-gui.wagon-manifest"},
						}},
						{type="switch", name="switch", ref={"switch"}, allow_none_state=true, switch_state=switch_state, left_label_caption={"cybersyn-gui.switch-provide"}, right_label_caption={"cybersyn-gui.switch-request"}, left_label_tooltip={"cybersyn-gui.switch-provide-tooltip"}, right_label_tooltip={"cybersyn-gui.switch-request-tooltip"}, actions={
							on_switch_state_changed={"switch", comb.unit_number}
						}}
					}},
					---choose-elem-button
					{type="line", style_mods={top_padding=10}},
					{type="label", name="network_label", ref={"network_label"}, style="heading_3_label", caption={"cybersyn-gui.network"}, style_mods={top_padding=8}},
					{type="flow", name="bottom", direction="horizontal", style_mods={vertical_align="center"}, children={
						{type="choose-elem-button", name="network", style="slot_button_in_shallow_frame", ref={"network"}, elem_type="signal", tooltip={"cybersyn-gui.network-tooltip"}, signal=control.first_signal, style_mods={bottom_margin=1, right_margin=6}, actions={
							on_elem_changed={"choose-elem-button", comb.unit_number}
						}},
						{type="checkbox", name="radio_button", ref={"radio_button"}, state=not allows_all_trains, tooltip={"cybersyn-gui.auto-tooltip"}, actions={
							on_checked_state_changed={"radio_button", comb.unit_number}
						}},
						{type="label", name="radio_label", style_mods={left_padding=3}, ref={"radio_label"}, caption={"cybersyn-gui.auto-description"}},
					}}
				}}
			}}
		}}
	})

	window.preview.entity = comb
	window.titlebar.drag_target = window.main_window
	window.main_window.force_auto_center()
	window.network.visible = selected_index == 1 or selected_index == 3
	window.network_label.visible = selected_index == 1 or selected_index == 3
	window.radio_button.visible = selected_index == 1
	window.radio_label.visible = selected_index == 1
	window.switch.visible = selected_index == 1

	player.opened = window.main_window
end

local function on_gui_opened(event)
	local entity = event.entity
	if not entity or not entity.valid or entity.name ~= COMBINATOR_NAME then return end
	local player = game.get_player(event.player_index)
	if not player then return end

	gui_opened(entity, player)
end

local function on_gui_closed(event)
	if not event.element or event.element.name ~= COMBINATOR_NAME then return end
	local player = game.get_player(event.player_index)
	if not player then return end
	local rootgui = player.gui.screen

	if rootgui[COMBINATOR_NAME] then
		rootgui[COMBINATOR_NAME].destroy()
		player.play_sound({path = COMBINATOR_CLOSE_SOUND})
	end
end

function register_gui_actions()
	flib_gui.hook_events(function(event)
		local msg = flib_gui.read_action(event)
		if msg then
			local player = game.get_player(event.player_index)
			if not player then return end
			local rootgui = player.gui.screen
			-- read the action to determine what to do
			if msg[1] == "close" then
				if rootgui[COMBINATOR_NAME] then
					rootgui[COMBINATOR_NAME].destroy()
					player.play_sound({path = COMBINATOR_CLOSE_SOUND})
				end
			elseif msg[1] == "drop-down" then
				local element = event.element
				if not element then return end
				local comb = global.to_comb[msg[2]]
				if not comb or not comb.valid then return end

				local top_flow = element.parent
				local all_flow = top_flow.parent
				local bottom_flow = all_flow.bottom
				if element.selected_index == 1 then
					set_combinator_operation(comb, OPERATION_PRIMARY_IO)
					top_flow["switch"].visible = true
					all_flow["network_label"].visible = true
					bottom_flow["network"].visible = true
					bottom_flow["radio_button"].visible = true
					bottom_flow["radio_label"].visible = true
				elseif element.selected_index == 2 then
					set_combinator_operation(comb, OPERATION_SECONDARY_IO)
					top_flow["switch"].visible = false
					all_flow["network_label"].visible = false
					bottom_flow["network"].visible = false
					bottom_flow["radio_button"].visible = false
					bottom_flow["radio_label"].visible = false
				elseif element.selected_index == 3 then
					set_combinator_operation(comb, OPERATION_DEPOT)
					top_flow["switch"].visible = false
					all_flow["network_label"].visible = true
					bottom_flow["network"].visible = true
					bottom_flow["radio_button"].visible = false
					bottom_flow["radio_label"].visible = false
				elseif element.selected_index == 4 then
					set_combinator_operation(comb, OPERATION_WAGON_MANIFEST)
					top_flow["switch"].visible = false
					all_flow["network_label"].visible = false
					bottom_flow["network"].visible = false
					bottom_flow["radio_button"].visible = false
					bottom_flow["radio_label"].visible = false
				else
					return
				end

				on_combinator_updated(global, comb)
			elseif msg[1] == "choose-elem-button" then
				local element = event.element
				if not element then return end
				local comb = global.to_comb[msg[2]]
				if not comb or not comb.valid then return end

				local a = comb.get_or_create_control_behavior()--[[@as LuaArithmeticCombinatorControlBehavior]]
				local control = a.parameters

				local signal = element.elem_value
				if signal and (signal.name == "signal-everything" or signal.name == "signal-anything" or signal.name == "signal-each") then
					control.first_signal = nil
					element.elem_value = nil
				else
					control.first_signal = signal
				end
				a.parameters = control

				on_combinator_network_updated(global, comb, signal and signal.name or nil)
			elseif msg[1] == "radio_button" then
				local element = event.element
				if not element then return end
				local comb = global.to_comb[msg[2]]
				if not comb or not comb.valid then return end

				local control = comb.get_or_create_control_behavior()--[[@as LuaArithmeticCombinatorControlBehavior]]

				local allows_all_trains = not element.state
				set_comb_allows_all_trains(control, allows_all_trains)

				local stop = global.to_stop[comb.unit_number]
				if stop then
					local station = global.stations[stop.unit_number]
					if station then
						set_station_train_class(global, station, allows_all_trains)
					end
				end
			elseif msg[1] == "switch" then
				local element = event.element
				if not element then return end
				local comb = global.to_comb[msg[2]]
				if not comb or not comb.valid then return end

				local is_pr_state = (element.switch_state == "none" and 0) or (element.switch_state == "left" and 1) or 2
				local a = comb.get_or_create_control_behavior()--[[@as LuaArithmeticCombinatorControlBehavior]]
				set_comb_is_pr_state(a, is_pr_state)

				local stop = global.to_stop[comb.unit_number]
				if stop then
					local station = global.stations[stop.unit_number]
					if station then
						station.is_p = is_pr_state == 0 or is_pr_state == 1
						station.is_r = is_pr_state == 0 or is_pr_state == 2
					end
				end
			end
		end
	end)
	flib_event.register(defines.events.on_gui_opened, on_gui_opened)
	flib_event.register(defines.events.on_gui_closed, on_gui_closed)
end

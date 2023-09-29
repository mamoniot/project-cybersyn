--By Mami
local flib_gui = require("__flib__.gui-lite")

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


local bit_extract = bit32.extract
local function setting(bits, n)
	return bit_extract(bits, n) > 0
end
local function setting_flip(bits, n)
	return bit_extract(bits, n) == 0
end


---@param main_window LuaGuiElement
---@param selected_index int
local function set_visibility(main_window, selected_index)
	local is_station = selected_index == 1
	local is_depot = selected_index == 2
	local is_wagon = selected_index == 5
	local uses_network = is_station or is_depot or selected_index == 3
	local uses_allow_list = is_station or selected_index == 3

	local vflow = main_window.frame.vflow--[[@as LuaGuiElement]]
	local top_flow = vflow.top--[[@as LuaGuiElement]]
	local bottom_flow = vflow.bottom--[[@as LuaGuiElement]]
	local first_settings = bottom_flow.first--[[@as LuaGuiElement]]
	local depot_settings = bottom_flow.depot--[[@as LuaGuiElement]]

	top_flow.is_pr_switch.visible = is_station
	vflow.network_label.visible = uses_network
	bottom_flow.network.visible = uses_network
	first_settings.allow_list.visible = uses_allow_list
	first_settings.is_stack.visible = is_station
	bottom_flow.enable_inactive.visible = is_station
	top_flow.enable_slot_barring.visible = is_wagon
	depot_settings.visible = is_depot
end


---@param e EventData.on_gui_click
local function handle_close(e)
	local element = e.element
	if not element then return end
	local comb = global.to_comb[element.tags.id]
	if not comb or not comb.valid then return end
	local player = game.get_player(e.player_index)
	if not player then return end
	local rootgui = player.gui.screen

	if rootgui[COMBINATOR_NAME] then
		rootgui[COMBINATOR_NAME].destroy()
		player.play_sound({path = COMBINATOR_CLOSE_SOUND})
	end
end
---@param e EventData.on_gui_selection_state_changed
local function handle_drop_down(e)
	local element = e.element
	if not element then return end
	local comb = global.to_comb[element.tags.id]
	if not comb or not comb.valid then return end

	set_visibility(element.parent.parent.parent.parent, element.selected_index)

	if element.selected_index == 1 then
		set_comb_operation(comb, MODE_PRIMARY_IO)
	elseif element.selected_index == 2 then
		set_comb_operation(comb, MODE_DEPOT)
	elseif element.selected_index == 3 then
		set_comb_operation(comb, MODE_REFUELER)
	elseif element.selected_index == 4 then
		set_comb_operation(comb, MODE_SECONDARY_IO)
	elseif element.selected_index == 5 then
		set_comb_operation(comb, MODE_WAGON)
	else
		return
	end

	combinator_update(global, comb)
end
---@param e EventData.on_gui_switch_state_changed
local function handle_pr_switch(e)
	local element = e.element
	if not element then return end
	local comb = global.to_comb[element.tags.id]
	if not comb or not comb.valid then return end

	local is_pr_state = (element.switch_state == "none" and 0) or (element.switch_state == "left" and 1) or 2
	set_comb_is_pr_state(comb, is_pr_state)

	combinator_update(global, comb)
end
---@param e EventData.on_gui_elem_changed
local function handle_network(e)
	local element = e.element
	if not element then return end
	local comb = global.to_comb[element.tags.id]
	if not comb or not comb.valid then return end

	local signal = element.elem_value--[[@as SignalID]]
	if signal and (signal.name == "signal-everything" or signal.name == "signal-anything" or signal.name == "signal-each") then
		signal.name = NETWORK_EACH
		element.elem_value = signal
	end
	set_comb_network_name(comb, signal)

	combinator_update(global, comb)
end
---@param e EventData.on_gui_checked_state_changed
local function handle_setting(e)
	local element = e.element
	if not element then return end
	local comb = global.to_comb[element.tags.id]
	if not comb or not comb.valid then return end

	set_comb_setting(comb, element.tags.bit--[[@as int]], element.state)

	combinator_update(global, comb)
end
---@param e EventData.on_gui_checked_state_changed
local function handle_setting_flip(e)
	local element = e.element
	if not element then return end
	local comb = global.to_comb[element.tags.id]
	if not comb or not comb.valid then return end

	set_comb_setting(comb, element.tags.bit--[[@as int]], not element.state)

	combinator_update(global, comb)
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
	flib_gui.add_handlers({
		["comb_close"] = handle_close,
		["comb_drop_down"] = handle_drop_down,
		["comb_pr_switch"] = handle_pr_switch,
		["comb_network"] = handle_network,
		["comb_setting"] = handle_setting,
		["comb_setting_flip"] = handle_setting_flip,
	})
	flib_gui.handle_events()
	script.on_event(defines.events.on_gui_opened, on_gui_opened)
	script.on_event(defines.events.on_gui_closed, on_gui_closed)
end

---@param comb LuaEntity
---@param player LuaPlayer
function gui_opened(comb, player)
	combinator_update(global, comb, true)

	local rootgui = player.gui.screen
	local selected_index, signal, switch_state, bits = get_comb_gui_settings(comb)

	local _, main_window = flib_gui.add(rootgui, {
		{type="frame", direction="vertical", name=COMBINATOR_NAME, children={
			--title bar
			{type="flow", name="titlebar", children={
				{type="label", style="frame_title", caption={"cybersyn-gui.combinator-title"}, elem_mods={ignored_by_interaction=true}},
				{type="empty-widget", style="flib_titlebar_drag_handle", elem_mods={ignored_by_interaction=true}},
				{type="sprite-button", style="frame_action_button", mouse_button_filter={"left"}, sprite="utility/close_white", hovered_sprite="utility/close_black", name=COMBINATOR_NAME, handler=handle_close, tags={id=comb.unit_number}}
			}},
			{type="frame", name="frame", style="inside_shallow_frame_with_padding", style_mods={padding=12, bottom_padding=9}, children={
				{type="flow", name="vflow", direction="vertical", style_mods={horizontal_align="left"}, children={
					--status
					{type="flow", style="status_flow", direction="horizontal", style_mods={vertical_align="center", horizontally_stretchable=true, bottom_padding=4}, children={
						{type="sprite", sprite=STATUS_SPRITES[comb.status] or STATUS_SPRITES_DEFAULT, style="status_image", style_mods={stretch_image_to_widget_size=true}},
						{type="label", caption={STATUS_NAMES[comb.status] or STATUS_NAMES_DEFAULT}}
					}},
					--preview
					{type="frame", name="preview_frame", style="deep_frame_in_shallow_frame", style_mods={minimal_width=0, horizontally_stretchable=true, padding=0}, children={
						{type="entity-preview", name="preview", style="wide_entity_button"},
					}},
					--drop down
					{type="label", style="heading_3_label", caption={"cybersyn-gui.operation"}, style_mods={top_padding=8}},
					{type="flow", name="top", direction="horizontal", style_mods={vertical_align="center"}, children={
						{type="drop-down", style_mods={top_padding=3, right_margin=8}, handler=handle_drop_down, tags={id=comb.unit_number}, selected_index=selected_index, items={
							{"cybersyn-gui.comb1"},
							{"cybersyn-gui.depot"},
							{"cybersyn-gui.refueler"},
							{"cybersyn-gui.comb2"},
							{"cybersyn-gui.wagon-manifest"},
						}},
						{type="switch", name="is_pr_switch", allow_none_state=true, switch_state=switch_state, left_label_caption={"cybersyn-gui.switch-provide"}, right_label_caption={"cybersyn-gui.switch-request"}, left_label_tooltip={"cybersyn-gui.switch-provide-tooltip"}, right_label_tooltip={"cybersyn-gui.switch-request-tooltip"}, handler=handle_pr_switch, tags={id=comb.unit_number}},
						{type="checkbox", name="enable_slot_barring", state=setting(bits, SETTING_ENABLE_SLOT_BARRING), handler=handle_setting, tags={id=comb.unit_number, bit=SETTING_ENABLE_SLOT_BARRING}, tooltip={"cybersyn-gui.enable-slot-barring-tooltip"}, caption={"cybersyn-gui.enable-slot-barring-description"}},
					}},
					---choose-elem-button
					{type="line", style_mods={top_padding=10}},
					{type="label", name="network_label", style="heading_3_label", caption={"cybersyn-gui.network"}, style_mods={top_padding=8}},
					{type="flow", name="bottom", direction="horizontal", style_mods={vertical_align="top"}, children={
						{type="choose-elem-button", name="network", style="slot_button_in_shallow_frame", elem_type="signal", tooltip={"cybersyn-gui.network-tooltip"}, signal=signal, style_mods={bottom_margin=1, right_margin=6, top_margin=2}, handler=handle_network, tags={id=comb.unit_number}},
						{type="flow", name="depot", direction="vertical", style_mods={horizontal_align="left"}, children={
							{type="checkbox", name="use_same_depot", state=setting_flip(bits, SETTING_USE_ANY_DEPOT), handler=handle_setting_flip, tags={id=comb.unit_number, bit=SETTING_USE_ANY_DEPOT}, tooltip={"cybersyn-gui.use-same-depot-tooltip"}, caption={"cybersyn-gui.use-same-depot-description"}},
							{type="checkbox", name="depot_bypass", state=setting_flip(bits, SETTING_DISABLE_DEPOT_BYPASS), handler=handle_setting_flip, tags={id=comb.unit_number, bit=SETTING_DISABLE_DEPOT_BYPASS}, tooltip={"cybersyn-gui.depot-bypass-tooltip"}, caption={"cybersyn-gui.depot-bypass-description"}},
						}},
						{type="flow", name="first", direction="vertical", style_mods={horizontal_align="left", right_margin=8}, children={
							{type="checkbox", name="allow_list", state=setting_flip(bits, SETTING_DISABLE_ALLOW_LIST), handler=handle_setting_flip, tags={id=comb.unit_number, bit=SETTING_DISABLE_ALLOW_LIST}, tooltip={"cybersyn-gui.allow-list-tooltip"}, caption={"cybersyn-gui.allow-list-description"}},
							{type="checkbox", name="is_stack", state=setting(bits, SETTING_IS_STACK), handler=handle_setting, tags={id=comb.unit_number, bit=SETTING_IS_STACK}, tooltip={"cybersyn-gui.is-stack-tooltip"}, caption={"cybersyn-gui.is-stack-description"}},
						}},
						{type="checkbox", name="enable_inactive", state=setting(bits, SETTING_ENABLE_INACTIVE), handler=handle_setting, tags={id=comb.unit_number, bit=SETTING_ENABLE_INACTIVE}, tooltip={"cybersyn-gui.enable-inactive-tooltip"}, caption={"cybersyn-gui.enable-inactive-description"}},
					}}
				}}
			}}
		}}
	})

	main_window.frame.vflow.preview_frame.preview.entity = comb
	main_window.titlebar.drag_target = main_window
	main_window.force_auto_center()

	set_visibility(main_window, selected_index)
	player.opened = main_window
end

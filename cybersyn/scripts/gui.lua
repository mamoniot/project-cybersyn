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
	local selected_index = 0
	local control = comb.get_or_create_control_behavior().parameters
	if control.operation == OPERATION_PRIMARY_IO then
		selected_index = 1
	elseif control.operation == OPERATION_SECONDARY_IO then
		selected_index = 2
	elseif control.operation == OPERATION_DEPOT then
		selected_index = 3
	elseif control.operation == OPERATION_WAGON_MANIFEST then
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
					{type="flow", style = "status_flow", direction = "horizontal", style_mods={vertical_align="center", horizontally_stretchable=true, bottom_padding=4}, children={
						{type="sprite", sprite=STATUS_SPRITES[comb.status] or STATUS_SPRITES_DEFAULT, style="status_image", ref={"status_icon"}, style_mods={stretch_image_to_widget_size=true}},
						{type="label", caption={STATUS_NAMES[comb.status] or STATUS_NAMES_DEFAULT}, ref={"status_label"}}
					}},
					--preview
					{type="frame", style="deep_frame_in_shallow_frame", style_mods={minimal_width=0, horizontally_stretchable=true, padding=0}, children={
						{type="entity-preview", style="wide_entity_button", ref={"preview"}},
					}},
					--drop down
					{type="label", style="heading_3_label", caption={"cybersyn-gui.operation"}, style_mods={top_padding=8}},
					{type="drop-down", style_mods={top_padding=3}, ref={"operation"}, actions={
						on_selection_state_changed={"drop-down", comb.unit_number}
					}, selected_index=selected_index, items={
						{"cybersyn-gui.comb1"},
						{"cybersyn-gui.comb2"},
						{"cybersyn-gui.depot"},
						{"cybersyn-gui.wagon-manifest"},
					}},
					---choose-elem-button
					{type="line", style_mods={top_padding=10}},
					{type="label", style="heading_3_label", caption={"cybersyn-gui.network"}, style_mods={top_padding=7}},
					{type="choose-elem-button", style="slot_button_in_shallow_frame", ref={"network"}, elem_type="signal", signal=control.first_signal, style_mods={bottom_margin=2}, actions={
						on_elem_changed={"choose-elem-button", comb.unit_number}
					}},
				}}
			}}
		}}
	})

	window.preview.entity = comb
	window.titlebar.drag_target = window.main_window
	window.main_window.force_auto_center()

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
		--TODO: play close sound to player
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
					--TODO: play close sound to player
				end
			elseif msg[1] == "drop-down" then
				local element = event.element
				if not element then return end
				local comb = global.to_comb[msg[2]]
				if not comb or not comb.valid then return end

				local a = comb.get_or_create_control_behavior()
				local control = a.parameters
				if element.selected_index == 1 then
					control.operation = OPERATION_PRIMARY_IO
				elseif element.selected_index == 2 then
					control.operation = OPERATION_SECONDARY_IO
				elseif element.selected_index == 3 then
					control.operation = OPERATION_DEPOT
				elseif element.selected_index == 4 then
					control.operation = OPERATION_WAGON_MANIFEST
				else
					return
				end
				a.parameters = control
				on_combinator_updated(global, comb)
			elseif msg[1] == "choose-elem-button" then
				local element = event.element
				if not element then return end
				local comb = global.to_comb[msg[2]]
				if not comb or not comb.valid then return end

				local signal = element.elem_value

				local a = comb.get_or_create_control_behavior()
				local control = a.parameters

				control.first_signal = signal

				a.parameters = control
			end
		end
	end)
	flib_event.register(defines.events.on_gui_opened, on_gui_opened)
	flib_event.register(defines.events.on_gui_closed, on_gui_closed)
end

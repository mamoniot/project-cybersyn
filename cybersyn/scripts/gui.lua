--By Mami
local gui = require("__flib__.gui")

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

---@param entity LuaEntity
function gui_opened(entity, player)
	local rootgui = player.gui.screen
	local window = gui.build(rootgui, {
		{type="frame", direction="vertical", ref={"main_window"}, name=COMBINATOR_NAME, tags={unit_number=entity.unit_number}, actions={
			on_close = {"test"}
		}, children={
			--title bar
			{type="flow", ref={"titlebar"}, children={
				{type="label", style="frame_title", caption={"cybersyn-gui.combinator-title"}, elem_mods={ignored_by_interaction=true}},
				{type="empty-widget", style="flib_titlebar_drag_handle", elem_mods={ignored_by_interaction=true}},
				{type="sprite-button", style="frame_action_button", mouse_button_filter={"left"}, sprite="utility/close_white", hovered_sprite="utility/close_black", name=COMBINATOR_NAME, actions={
					on_click = {"test"}
				}}
			}},
			{type="frame", style="inside_shallow_frame_with_padding", style_mods={padding=8}, children={
				{type="flow", direction="vertical", style_mods={horizontal_align="left"}, children={
					--status
					{type="flow", style = "status_flow", direction = "horizontal", style_mods={vertical_align="center", horizontally_stretchable=true}, children={
						{type="sprite", sprite=STATUS_SPRITES[entity.status] or STATUS_SPRITES_DEFAULT, style="status_image", ref={"status_icon"}, style_mods={stretch_image_to_widget_size=true}},
						{type="label", caption={STATUS_NAMES[entity.status] or STATUS_NAMES_DEFAULT}, ref={"status_label"}}
					}},
					--preview
					{type="frame", style="deep_frame_in_shallow_frame", style_mods={minimal_width=0, horizontally_stretchable=true, padding=0}, children={
						{type="entity-preview", style="wide_entity_button", ref={"preview"}},
					}},
					{type="label", caption={"cybersyn-gui.operation"}, style_mods={top_padding=8}},
					{type="drop-down", ref={"operation"}, actions={
						on_selection_state_changed = {"test"}
					}, items={
						{"cybersyn-gui.comb1"},
						{"cybersyn-gui.comb2"},
						{"cybersyn-gui.depot"},
						{"cybersyn-gui.wagon-manifest"},
					}},
				}}
			}}
		}}
	})

	window.preview.entity = entity
	window.titlebar.drag_target = window.main_window
	window.main_window.force_auto_center()

	player.opened = window.main_window
end

local function o(event)
	local entity = event.entity
	if not entity or not entity.valid then return end
	local player = game.get_player(event.player_index)
	if not player then return end
	local rootgui = player.gui.screen

	if rootgui[COMBINATOR_NAME] then
		--rootgui[COMBINATOR_NAME].destroy()
	else
		gui_opened(entity, player)
	end
end

function register_gui_actions()
	gui.hook_events(function(event)
		local msg = gui.read_action(event)
		if msg then
			-- read the action to determine what to do
			local hi = 2
		end
	end)
	script.on_event(defines.events.on_gui_opened, o)
end

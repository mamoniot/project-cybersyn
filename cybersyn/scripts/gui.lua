--By Mami
local flib_gui = require("__flib__.gui")

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
local STATUS_SPRITES_GHOST = YELLOW

local STATUS_NAMES = {}
STATUS_NAMES[defines.entity_status.working] = "entity-status.working"
STATUS_NAMES[defines.entity_status.normal] = "entity-status.normal"
STATUS_NAMES[defines.entity_status.ghost] = "entity-status.ghost"
STATUS_NAMES[defines.entity_status.no_power] = "entity-status.no-power"
STATUS_NAMES[defines.entity_status.low_power] = "entity-status.low-power"
STATUS_NAMES[defines.entity_status.disabled_by_control_behavior] = "entity-status.disabled"
STATUS_NAMES[defines.entity_status.disabled_by_script] = "entity-status.disabled-by-script"
STATUS_NAMES[defines.entity_status.marked_for_deconstruction] = "entity-status.marked-for-deconstruction"
STATUS_NAMES_DEFAULT = "entity-status.disabled"
STATUS_NAMES_GHOST = "entity-status.ghost"

local band = bit32.band
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

	local vflow = main_window.frame.vflow --[[@as LuaGuiElement]]
	local top_flow = vflow.top --[[@as LuaGuiElement]]
	local mode_settings_flow = vflow.mode_settings --[[@as LuaGuiElement]]
	local bottom_flow = vflow.bottom --[[@as LuaGuiElement]]
	local first_settings = bottom_flow.first --[[@as LuaGuiElement]]
	local second_settings = bottom_flow.second --[[@as LuaGuiElement]]
	local depot_settings = bottom_flow.depot --[[@as LuaGuiElement]]

	top_flow.is_pr_switch.visible = is_station
	vflow.network_label.visible = uses_network
	bottom_flow.network.visible = uses_network
	first_settings.allow_list.visible = uses_allow_list
	first_settings.is_stack.visible = is_station
	second_settings.enable_inactive.visible = is_station
	second_settings.enable_circuit_condition.visible = is_station
	second_settings.disable_manifest_condition.visible = is_station
	mode_settings_flow.enable_slot_barring.visible = is_wagon
	mode_settings_flow.enable_train_count.visible = (selected_index == 4)
	mode_settings_flow.enable_manual_inventory.visible = (selected_index == 4)

	depot_settings.visible = is_depot
end


---@param e EventData.on_gui_click|EventData.on_gui_closed
local function handle_close(e)
	local element = e.element
	if not element then return end
	local comb = storage.to_comb[element.tags.id]
	if not comb or not comb.valid then return end
	local player = game.get_player(e.player_index)
	if not player then return end
	local rootgui = player.gui.screen

	if rootgui[COMBINATOR_NAME] then
		rootgui[COMBINATOR_NAME].destroy()
		if comb.name ~= "entity-ghost" then
			player.play_sound({ path = COMBINATOR_CLOSE_SOUND })
		end
	end
end
---@param e EventData.on_gui_switch_state_changed
local function handle_pr_switch(e)
	local element = e.element
	if not element then return end
	local comb = storage.to_comb[element.tags.id]
	if not comb or not comb.valid then return end

	local is_pr_state = (element.switch_state == "none" and 0) or (element.switch_state == "left" and 1) or 2
	set_comb_is_pr_state(comb, is_pr_state)

	combinator_update(storage, comb)
end
---@param e EventData.on_gui_elem_changed
local function handle_network(e)
	local element = e.element
	if not element then return end
	local comb = storage.to_comb[element.tags.id]
	if not comb or not comb.valid then return end

	local signal = element.elem_value --[[@as SignalID]]
	if signal and (signal.name == "signal-everything" or signal.name == "signal-anything" or signal.name == "signal-each") then
		signal.name = NETWORK_EACH
		element.elem_value = signal
	end
	set_comb_network_name(comb, signal)

	combinator_update(storage, comb)
end

local UPDATE_DISABLE_MANIFEST = {
	[SETTING_ENABLE_INACTIVE] = true,
	[SETTING_ENABLE_CIRCUIT_CONDITION] = true,
}
local ANY_REQUIRED_TO_DISABLE_MANIFEST = bit32.bor(
	bit32.lshift(1, SETTING_ENABLE_INACTIVE),
	bit32.lshift(1, SETTING_ENABLE_CIRCUIT_CONDITION))

---@param e EventData.on_gui_checked_state_changed
local function handle_setting(e)
	local element = e.element
	if not element then return end
	local comb = storage.to_comb[element.tags.id]
	if not comb or not comb.valid then return end

	local changed_bit = element.tags.bit
	set_comb_setting(comb, changed_bit --[[@as int]], element.state)

	if UPDATE_DISABLE_MANIFEST[changed_bit] then
		local bits = get_comb_params(comb).second_constant or 0
		element.parent.disable_manifest_condition.enabled = band(bits, ANY_REQUIRED_TO_DISABLE_MANIFEST) > 0
	end

	combinator_update(storage, comb)
end

---@param combId integer
---@return LocalisedString
local function generate_stop_layout_text(combId)
	local targetStop = storage.to_stop[combId]
	local stopLayout = nil
	if targetStop ~= nil then
		local station = storage.stations[targetStop.unit_number]
		local refueler = storage.refuelers[targetStop.unit_number]
		if station ~= nil then
			stopLayout = station.layout_pattern
		elseif refueler ~= nil then
			stopLayout = refueler.layout_pattern
		end
	end

	return stopLayout and serpent.line(stopLayout) or { "cybersyn-gui.allow-list-no-station" }
end

local LAYOUT_ITEM_MAP = {
	[0] = "item/locomotive",
	[1] = "item/cargo-wagon",
	[2] = "item/fluid-wagon",
	[3] = "cybersyn-both-wagon",
	unknown = "utility/questionmark",
}

---@param combId integer
---@return table[]
local function generate_stop_layout_items(combId)
	if storage.to_comb[combId] and storage.to_comb[combId].name == "entity-ghost" then
		return {
			{
				type = "sprite",
				sprite = "entity/entity-ghost",
				style_mods = { size = 32 },
				resize_to_sprite = false,
				ignored_by_interaction = true,
			},
		}
	end

	local targetStop = storage.to_stop[combId]
	local stopLayout = nil
	if targetStop ~= nil then
		local station = storage.stations[targetStop.unit_number]
		local refueler = storage.refuelers[targetStop.unit_number]
		if station ~= nil then
			stopLayout = station.layout_pattern
		elseif refueler ~= nil then
			stopLayout = refueler.layout_pattern
		end
	end

	if not stopLayout then
		return {
			{
				type = "sprite",
				sprite = "utility/rail_path_not_possible",
				style_mods = { size = 32 },
				resize_to_sprite = false,
				ignored_by_interaction = true,
			},
		}
	end

	local items = {}

	local last_i = 1
	for i, type in pairs(stopLayout) do
		if type ~= 0 and type ~= 1 and type ~= 2 and type ~= 3 then
			type = "unknown"
		end
		if i - last_i > 1 then
			for _ = 1, i - last_i - 1 do
				table.insert(items, {
					type = "sprite",
					sprite = LAYOUT_ITEM_MAP[0],
					style_mods = { size = 32 },
					resize_to_sprite = false,
					ignored_by_interaction = true,
				})
			end
		end
		table.insert(items, {
			type = "sprite",
			sprite = LAYOUT_ITEM_MAP[type],
			style_mods = { size = 32 },
			resize_to_sprite = false,
			ignored_by_interaction = true,
		})
		last_i = i
	end

	return items
end

local function get_allow_list_section(player_index)
	local player = game.get_player(player_index)
	if player.opened.name == COMBINATOR_NAME then
		return player.opened.frame.vflow.bottom_allowlist
	end
end

local function update_allow_list_section(player_index, comb_unit_number)
	local layoutSection = get_allow_list_section(player_index)
	if not layoutSection then return end
	local selected_index, signal, switch_state, bits = get_comb_gui_settings(storage.to_comb[comb_unit_number])
	--only for Station (1) and Refueler (3)
	if ((selected_index == 1 or selected_index == 3) and setting_flip(bits, SETTING_DISABLE_ALLOW_LIST)) then
		layoutSection.visible = true
		-- layoutSection.allow_list_label.caption = generate_stop_layout(comb_unit_number)
		local flow = layoutSection.allow_list_items
		flow.clear()
		local items = generate_stop_layout_items(comb_unit_number)
		for _, item in pairs(items) do
			flib_gui.add(flow, item)
		end
		flow.tooltip = generate_stop_layout_text(comb_unit_number)
	else
		layoutSection.visible = false
	end
end

---@param e EventData.on_gui_selection_state_changed
local function handle_drop_down(e)
	local element = e.element
	if not element then return end
	local comb = storage.to_comb[element.tags.id]
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

	combinator_update(storage, comb)

	update_allow_list_section(e.player_index, comb.unit_number)
end

---@param e EventData.on_gui_checked_state_changed
local function handle_setting_flip(e)
	local element = e.element
	if not element then return end
	local comb = storage.to_comb[element.tags.id]
	if not comb or not comb.valid then return end

	set_comb_setting(comb, element.tags.bit --[[@as int]], not element.state)

	combinator_update(storage, comb)

	update_allow_list_section(e.player_index, comb.unit_number)
end

---@param e EventData.on_gui_click
local function handle_refresh_allow(e)
	local combId = e.element.tags.id
	local stop = storage.to_stop[combId]
	if not stop or not stop.valid then return end

	local station = storage.stations[stop.unit_number]
	local stationOrRefueler = station or storage.refuelers[stop.unit_number]
	if stationOrRefueler then
		reset_stop_layout(storage, stationOrRefueler, station ~= nil)
	end
	update_allow_list_section(e.player_index, combId) -- will update to X, if stationOrRefueler is nil
end

---@alias EntityOpenedHandler fun(event: EventData.on_gui_opened, player: LuaPlayer, entity: LuaEntity, is_ghost: boolean) player and entity are guaranteed to be valid, is_ghost indicates if the entity is a ghost
---@type { [string]: EntityOpenedHandler[] }
local entity_opened_handlers = {}

---@alias EntityClosedHandler fun(event: EventData.on_gui_closed, player: LuaPlayer, entity: LuaEntity, is_ghost: boolean) player and entity are guaranteed to be valid, is_ghost indicates if the entity is a ghost
---@type { [string]: EntityClosedHandler[] }
local entity_closed_handlers = {}

--- Adds a gui_opened-handler to a specific entity type.
--- gui_opened-handlers can either attach additional GUIs to the vanilla GUI of an entity or replace it entirely via player.opened
--- In the latter case only one handler must be installed for a single entity type.
--- Handlers also get called for ghosts of the entity and must decide wether to act or not.
---@param entity_name string entity name to add the handler to
---@param handler EntityOpenedHandler the handler
function add_entity_opened_handler(entity_name, handler)
	local event_handlers = get_or_create(entity_opened_handlers, entity_name)
	table.insert(event_handlers, handler)
end

--- Adds a gui_closed-handler for a specific entity type.
--- The handler gets called when the vanilla GUI for that entity type is closed and should close or destroy the attached UI
--- so that it is not visible when the vanilla GUI opens for the same machine type but a different entity type.
--- Handlers also get called for ghosts of the entity and must decide wether to act or not.
--- Fully custom GUIs cannot use this function.
--- Instead, they should install an on_gui_closed handler on the GUI element they passed to player.opened using flib.
---@param entity_name string entity name to add the handler to
---@param handler EntityClosedHandler the handler
function add_entity_closed_handler(entity_name, handler)
	local event_handlers = get_or_create(entity_closed_handlers, entity_name)
	table.insert(event_handlers, handler)
end

---@param event EventData.on_gui_opened|EventData.on_gui_closed
local function on_entity_gui_opened_closed(event)
	local entity = event.entity
	if not (event.gui_type == defines.gui_type.entity and entity and entity.valid) then
		return false
	end

	local name = entity.name
	local is_ghost = name == "entity-ghost"
	if is_ghost then name = entity.ghost_name end

	local event_handlers = event.name == defines.events.on_gui_opened
		and entity_opened_handlers[name]
		or entity_closed_handlers[name]

	if event_handlers then
		local player = assert(game.get_player(event.player_index))
		for _, handler in ipairs(event_handlers) do
			handler(event --[[@as any]], player, entity, is_ghost)
		end
	end
	return true
end

---@param e EventData.on_gui_closed
local function on_gui_closed(e)
	if not on_entity_gui_opened_closed(e) and e.gui_type == defines.gui_type.custom then
		flib_gui.dispatch(e)
	end
end

function register_gui_actions()
	add_entity_opened_handler(COMBINATOR_NAME, gui_opened) -- fully custom GUI, closes via flib handler
	add_entity_opened_handler(Elevators.name_elevator, Elevators.on_entity_gui_opened)
	add_entity_closed_handler(Elevators.name_elevator, Elevators.on_entity_gui_closed)

	flib_gui.add_handlers({
		["handle_close"] = handle_close,
		["comb_close"] = handle_close,
		["comb_refresh_allow"] = handle_refresh_allow,
		["comb_drop_down"] = handle_drop_down,
		["comb_pr_switch"] = handle_pr_switch,
		["comb_network"] = handle_network,
		["comb_setting"] = handle_setting,
		["comb_setting_flip"] = handle_setting_flip,
	})
	flib_gui.handle_events()
	script.on_event(defines.events.on_gui_opened, on_entity_gui_opened_closed)
	script.on_event(defines.events.on_gui_closed, on_gui_closed)
end

---@param event EventData.on_gui_opened
---@param player LuaPlayer
---@param comb LuaEntity
---@param is_ghost boolean
function gui_opened(event, player, comb, is_ghost)
	combinator_update(storage, comb, true)

	local rootgui = player.gui.screen
	local selected_index, signal, switch_state, bits = get_comb_gui_settings(comb)

	local showLayout = false
	local layoutItems = {}
	local layoutTooltip = nil
	--only for Station (1) and Refueler (3)
	if ((selected_index == 1 or selected_index == 3) and setting_flip(bits, SETTING_DISABLE_ALLOW_LIST)) then
		showLayout = true
		layoutItems = generate_stop_layout_items(comb.unit_number)
		layoutTooltip = generate_stop_layout_text(comb.unit_number)
	end

	local existing = rootgui[COMBINATOR_NAME]
	if existing then
		existing.destroy()
	end

	local _, main_window = flib_gui.add(rootgui, {
		{
			type = "frame",
			direction = "vertical",
			name = COMBINATOR_NAME,
			handler = { [defines.events.on_gui_closed] = handle_close },
			tags = { id = comb.unit_number, is_ghost = is_ghost },
			children = {
				--title bar
				{
					type = "flow",
					name = "titlebar",
					children = {
						{
							type = "label",
							style = "frame_title",
							caption = { "cybersyn-gui.combinator-title" },
							elem_mods = { ignored_by_interaction = true },
						},
						{ type = "empty-widget", style = "flib_titlebar_drag_handle", elem_mods = { ignored_by_interaction = true } },
						{
							type = "sprite-button",
							style = "frame_action_button",
							mouse_button_filter = { "left" },
							sprite = "utility/close",
							hovered_sprite = "utility/close",
							name = COMBINATOR_NAME,
							handler = { [defines.events.on_gui_click] = handle_close },
							tags = { id = comb.unit_number, is_ghost = is_ghost },
						},
					},
				},
				{
					type = "frame",
					name = "frame",
					style = "inside_shallow_frame_with_padding",
					style_mods = { padding = 12, bottom_padding = 9 },
					children = {
						{
							type = "flow",
							name = "vflow",
							direction = "vertical",
							style_mods = { horizontal_align = "left" },
							children = {
								--status
								{
									type = "flow",
									style = "flib_titlebar_flow",
									direction = "horizontal",
									style_mods = {
										vertical_align = "center",
										horizontally_stretchable = true,
										bottom_padding = 4,
									},
									children = {
										{
											type = "sprite",
											sprite = is_ghost and STATUS_SPRITES_GHOST or STATUS_SPRITES[comb.status] or STATUS_SPRITES_DEFAULT,
											style = "status_image",
											style_mods = { stretch_image_to_widget_size = true },
										},
										{
											type = "label",
											caption = { is_ghost and STATUS_NAMES_GHOST or STATUS_NAMES[comb.status] or STATUS_NAMES_DEFAULT }
										},
									},
								},
								--preview
								{
									type = "frame",
									name = "preview_frame",
									style = "deep_frame_in_shallow_frame",
									style_mods = {
										minimal_width = 0,
										horizontally_stretchable = true,
										padding = 0,
									},
									children = {
										{ type = "entity-preview", name = "preview", style = "wide_entity_button" },
									},
								},
								--drop down
								{
									type = "label",
									style = "heading_2_label",
									caption = { "cybersyn-gui.operation" },
									style_mods = { top_padding = 8 }
								},
								{
									type = "flow",
									name = "top",
									direction = "horizontal",
									style_mods = { vertical_align = "center" },
									children = {
										{
											type = "drop-down",
											style_mods = { top_padding = 3, right_margin = 8 },
											handler = handle_drop_down,
											tags = { id = comb.unit_number },
											selected_index = selected_index,
											items = {
												{ "cybersyn-gui.comb1" },
												{ "cybersyn-gui.depot" },
												{ "cybersyn-gui.refueler" },
												{ "cybersyn-gui.comb2" },
												{ "cybersyn-gui.wagon-manifest" },
											},
										},
										{
											type = "switch",
											name = "is_pr_switch",
											allow_none_state = true,
											switch_state = switch_state,
											left_label_caption = { "cybersyn-gui.switch-provide" },
											right_label_caption = { "cybersyn-gui.switch-request" },
											left_label_tooltip = { "cybersyn-gui.switch-provide-tooltip" },
											right_label_tooltip = { "cybersyn-gui.switch-request-tooltip" },
											handler = handle_pr_switch,
											tags = { id = comb.unit_number },
										},
									},
								},
								---Settings section for modal settings
								{
									type = "flow",
									name = "mode_settings",
									direction = "vertical",
									style_mods = { horizontal_align = "left" },
									children = {
										{
											type = "checkbox",
											name = "enable_slot_barring",
											state = setting(bits, SETTING_ENABLE_SLOT_BARRING),
											handler = handle_setting,
											tags = { id = comb.unit_number, bit = SETTING_ENABLE_SLOT_BARRING },
											tooltip = { "cybersyn-gui.enable-slot-barring-tooltip" },
											caption = { "cybersyn-gui.enable-slot-barring-description" },
										},
										{
											type = "checkbox",
											name = "enable_train_count",
											state = setting(bits, SETTING_ENABLE_TRAIN_COUNT),
											handler = handle_setting,
											tags = { id = comb.unit_number, bit = SETTING_ENABLE_TRAIN_COUNT },
											tooltip = { "cybersyn-gui.enable-train-count-tooltip" },
											caption = { "cybersyn-gui.enable-train-count-description" },
										},
										{
											type = "checkbox",
											name = "enable_manual_inventory",
											state = setting(bits, SETTING_ENABLE_MANUAL_INVENTORY),
											handler = handle_setting,
											tags = { id = comb.unit_number, bit = SETTING_ENABLE_MANUAL_INVENTORY },
											tooltip = { "cybersyn-gui.enable-manual-inventory-tooltip" },
											caption = { "cybersyn-gui.enable-manual-inventory-description" },
										},
									},
								},
								---Settings section for network
								{ type = "line", style_mods = { top_padding = 10 } },
								{
									type = "label",
									name = "network_label",
									style = "heading_2_label",
									caption = { "cybersyn-gui.network" },
									style_mods = { top_padding = 8 },
								},
								{
									type = "flow",
									name = "bottom",
									direction = "horizontal",
									style_mods = { vertical_align = "top" },
									children = {
										{
											type = "choose-elem-button",
											name = "network",
											style = "slot_button_in_shallow_frame",
											elem_type = "signal",
											tooltip = { "cybersyn-gui.network-tooltip" },
											signal = signal,
											style_mods = { bottom_margin = 1, right_margin = 6, top_margin = 2 },
											handler = handle_network,
											tags = { id = comb.unit_number },
										},
										{
											type = "flow",
											name = "depot",
											direction = "vertical",
											style_mods = { horizontal_align = "left" },
											children = {
												{
													type = "checkbox",
													name = "use_same_depot",
													state = setting_flip(bits, SETTING_USE_ANY_DEPOT),
													handler = handle_setting_flip,
													tags = { id = comb.unit_number, bit = SETTING_USE_ANY_DEPOT },
													tooltip = { "cybersyn-gui.use-same-depot-tooltip" },
													caption = { "cybersyn-gui.use-same-depot-description" },
												},
												{
													type = "checkbox",
													name = "depot_bypass",
													state = setting_flip(bits, SETTING_DISABLE_DEPOT_BYPASS),
													handler = handle_setting_flip,
													tags = { id = comb.unit_number, bit = SETTING_DISABLE_DEPOT_BYPASS },
													tooltip = { "cybersyn-gui.depot-bypass-tooltip" },
													caption = { "cybersyn-gui.depot-bypass-description" },
												},
											},
										},
										{
											type = "flow",
											name = "first",
											direction = "vertical",
											style_mods = { horizontal_align = "left", right_margin = 8 },
											children = {
												{
													type = "checkbox",
													name = "allow_list",
													state = setting_flip(bits, SETTING_DISABLE_ALLOW_LIST),
													handler = handle_setting_flip,
													tags = { id = comb.unit_number, bit = SETTING_DISABLE_ALLOW_LIST },
													tooltip = { "cybersyn-gui.allow-list-tooltip" },
													caption = { "cybersyn-gui.allow-list-description" },
												},
												{
													type = "checkbox",
													name = "is_stack",
													state = setting(bits, SETTING_IS_STACK),
													handler = handle_setting,
													tags = { id = comb.unit_number, bit = SETTING_IS_STACK },
													tooltip = { "cybersyn-gui.is-stack-tooltip" },
													caption = { "cybersyn-gui.is-stack-description" },
												},
											},
										},
										{
											type = "flow",
											name = "second",
											direction = "vertical",
											children = {
												{
													type = "checkbox",
													name = "enable_inactive",
													state = setting(bits, SETTING_ENABLE_INACTIVE),
													handler = handle_setting,
													tags = { id = comb.unit_number, bit = SETTING_ENABLE_INACTIVE },
													tooltip = { "cybersyn-gui.enable-inactive-tooltip" },
													caption = { "cybersyn-gui.enable-inactive-description" },
												},
												{
													type = "checkbox",
													name = "enable_circuit_condition",
													state = setting(bits, SETTING_ENABLE_CIRCUIT_CONDITION),
													handler = handle_setting,
													tags = { id = comb.unit_number, bit = SETTING_ENABLE_CIRCUIT_CONDITION },
													tooltip = { "cybersyn-gui.enable-circuit-condition-tooltip" },
													caption = { "cybersyn-gui.enable-circuit-condition-description" },
												},
												{
													type = "checkbox",
													name = "disable_manifest_condition",
													state = setting(bits, SETTING_DISABLE_MANIFEST_CONDITION ),
													enabled = band(bits, ANY_REQUIRED_TO_DISABLE_MANIFEST) > 0,
													handler = handle_setting,
													tags = { id = comb.unit_number, bit = SETTING_DISABLE_MANIFEST_CONDITION },
													tooltip = { "cybersyn-gui.disable-manifest-tooltip" },
													caption = { "cybersyn-gui.disable-manifest-description" },
												}
											},
										},
									},
								},
								--preview allow list
								{
									type = "flow",
									name = "bottom_allowlist",
									direction = "vertical",
									style_mods = { vertical_align = "top" },
									visible = showLayout,
									children = {
										{
											type = "label",
											name = "allow_list_heading",
											style = "heading_2_label",
											caption = { "cybersyn-gui.allow-list-preview" },
											tooltip = { "cybersyn-gui.allow-list-preview-tooltip" },
											style_mods = { top_padding = 8 },
										},
										{
											type = "flow",
											name = "allow_list_items",
											direction = "horizontal",
											tooltip = layoutTooltip,
											children = layoutItems
										},
										{
											type = "button",
											name = "allow_list_refresh",
											tags = { id = comb.unit_number },
											tooltip = { "cybersyn-gui.allow-list-refresh-tooltip" },
											caption = { "cybersyn-gui.allow-list-refresh-description" },
											enabled = not is_ghost,
											handler = handle_refresh_allow,
										},
									},
								},
							},
						},
					},
				},
			},
		},
	})

	main_window.frame.vflow.preview_frame.preview.entity = comb
	main_window.titlebar.drag_target = main_window
	main_window.force_auto_center()

	set_visibility(main_window, selected_index)
	player.opened = main_window -- replace the default entity UI
end

---@param unit_number integer
---@param silent boolean?
function gui_entity_destroyed(unit_number, silent)
	for _, player in pairs(game.players) do
		if not player or not player.valid then goto continue end
		local screen = player.gui.screen
		local window = screen[COMBINATOR_NAME]
		if window and window.tags.id == unit_number then
			window.destroy()
			if not silent then
				player.play_sound({ path = COMBINATOR_CLOSE_SOUND })
			end
		end
		::continue::
	end
end

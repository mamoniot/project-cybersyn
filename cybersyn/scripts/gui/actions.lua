local train_util = require("__flib__.train")

local constants = require("scripts.gui.constants")

local util = require("scripts.gui.util")

local actions = {}

local function toggle_fab(elem, sprite, state)
	if state then
		elem.style = "flib_selected_frame_action_button"
		elem.sprite = sprite .. ""
	else
		elem.style = "frame_action_button"
		elem.sprite = sprite .. ""
	end
end

function actions.close(Gui)
	Gui:close()
end

function actions.recenter(Gui)
	Gui.refs.window.force_auto_center()
end

function actions.toggle_auto_refresh(Gui)
	Gui.state.auto_refresh = not Gui.state.auto_refresh
	toggle_fab(Gui.refs.titlebar.refresh_button, "ltnm_refresh", Gui.state.auto_refresh)
end

function actions.toggle_pinned(Gui)
	Gui.state.pinned = not Gui.state.pinned
	toggle_fab(Gui.refs.titlebar.pin_button, "ltnm_pin", Gui.state.pinned)

	if Gui.state.pinned then
		Gui.state.pinning = true
		Gui.player.opened = nil
		Gui.state.pinning = false
	else
		Gui.player.opened = Gui.refs.window
		Gui.refs.window.force_auto_center()
	end
end

function actions.update_text_search_query(Gui, _, e)
	local query = e.text
	-- Input sanitization
	for pattern, replacement in pairs(constants.input_sanitizers) do
		query = string.gsub(query, pattern, replacement)
	end
	Gui.state.search_query = query

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

function actions.update_network_id_query(Gui)
	Gui.state.network_id = tonumber(Gui.refs.toolbar.network_id_field.text) or -1
	Gui:schedule_update()
end

function actions.open_train_gui(Gui, msg)
	local train_id = msg.train_id
	local train_data = Gui.state.ltn_data.trains[train_id]

	if not train_data or not train_data.train.valid then
		util.error_flying_text(Gui.player, { "message.ltnm-error-train-is-invalid" })
		return
	end

	train_util.open_gui(Gui.player.index, train_data.train)
end

function actions.open_station_gui(Gui, msg, e)
	local station_id = msg.station_id
	local station_data = Gui.state.ltn_data.stations[station_id]

	if not station_data or not station_data.entity.valid then
		util.error_flying_text(Gui.player, { "message.ltnm-error-station-is-invalid" })
		return
	end

	--- @type LuaPlayer
	local player = Gui.player

	if e.shift then
		player.zoom_to_world(station_data.entity.position, 1)

		rendering.draw_circle({
			color = constants.colors.red.tbl,
			target = station_data.entity.position,
			surface = station_data.entity.surface,
			radius = 0.5,
			filled = false,
			width = 5,
			time_to_live = 60 * 3,
			players = { player },
		})

		if not Gui.state.pinned then
			Gui:close()
		end
	elseif e.control and remote.interfaces["ltn-combinator"] then
		if not remote.call("ltn-combinator", "open_ltn_combinator", e.player_index, station_data.lamp_control, true) then
			util.error_flying_text(player, { "message.ltnm-error-ltn-combinator-not-found" })
		end
	else
		player.opened = station_data.entity
	end
end

function actions.toggle_sort(Gui, msg, e)
	local tab = msg.tab
	local column = msg.column

	local sorts = Gui.state.sorts[tab]
	local active_column = sorts._active
	if active_column == column then
		sorts[column] = e.element.state
	else
		sorts._active = column
		e.element.state = sorts[column]

		local widths = Gui.widths[tab]

		local old_checkbox = Gui.refs[tab].toolbar[active_column .. "_checkbox"]
		old_checkbox.style = "ltnm_sort_checkbox"
		if widths[active_column .. "_checkbox_stretchy"] then
			old_checkbox.style.horizontally_stretchable = true
		else
			old_checkbox.style.width = widths[active_column]
		end
		e.element.style = "ltnm_selected_sort_checkbox"
		if widths[column .. "_checkbox_stretchy"] then
			e.element.style.horizontally_stretchable = true
		else
			e.element.style.width = widths[column]
		end
	end

	Gui:schedule_update()
end

function actions.update(Gui)
	Gui:schedule_update()
end

function actions.change_tab(Gui, msg)
	Gui.state.active_tab = msg.tab
	Gui:schedule_update()
end

function actions.change_surface(Gui, _, e)
	local selected_index = e.element.selected_index
	local selected_surface_index = Gui.state.ltn_data.surfaces.selected_to_index[selected_index]
	if selected_surface_index then
		Gui.state.surface = selected_surface_index
		Gui:schedule_update()
	end
end

function actions.clear_history(Gui)
	storage.flags.deleted_history = true
	Gui:schedule_update()
end

function actions.delete_alert(Gui, msg)
	storage.active_data.alerts_to_delete[msg.alert_id] = true
	Gui:schedule_update()
end

function actions.delete_all_alerts(Gui)
	storage.flags.deleted_all_alerts = true
	Gui:schedule_update()
end

function actions.focus_search(Gui)
	if not Gui.pinned then
		Gui.refs.toolbar.text_search_field.select_all()
		Gui.refs.toolbar.text_search_field.focus()
	end
end

return actions

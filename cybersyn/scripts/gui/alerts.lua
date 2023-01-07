local gui = require("__flib__.gui")
local misc = require("__flib__.misc")

local constants = require("constants")
local util = require("scripts.util")

local templates = require("templates")

local alerts_tab = {}

function alerts_tab.build(widths)
  return {
    tab = {
      type = "tab",
      caption = { "gui.ltnm-alerts" },
      ref = { "alerts", "tab" },
      actions = {
        on_click = { gui = "main", action = "change_tab", tab = "alerts" },
      },
    },
    content = {
      type = "frame",
      style = "ltnm_main_content_frame",
      direction = "vertical",
      ref = { "alerts", "content_frame" },
      {
        type = "frame",
        style = "ltnm_table_toolbar_frame",
        style_mods = { right_padding = 4 },
        templates.sort_checkbox(widths, "alerts", "time", true, nil, true),
        templates.sort_checkbox(widths, "alerts", "train_id", false),
        templates.sort_checkbox(widths, "alerts", "route", false),
        templates.sort_checkbox(widths, "alerts", "network_id", false),
        templates.sort_checkbox(nil, "alerts", "type", false),
        {
          type = "sprite-button",
          style = "tool_button_red",
          sprite = "utility/trash",
          tooltip = { "gui.ltnm-delete-all-alerts" },
          ref = { "alerts", "delete_all_button" },
          actions = {
            on_click = { gui = "main", action = "delete_all_alerts" },
          },
        },
      },
      { type = "scroll-pane", style = "ltnm_table_scroll_pane", ref = { "alerts", "scroll_pane" } },
      {
        type = "flow",
        style = "ltnm_warning_flow",
        visible = false,
        ref = { "alerts", "warning_flow" },
        {
          type = "label",
          style = "ltnm_semibold_label",
          caption = { "gui.ltnm-no-alerts" },
          ref = { "alerts", "warning_label" },
        },
      },
    },
  }
end

function alerts_tab.update(self)
  local dictionaries = self.player_table.dictionaries

  local state = self.state
  local refs = self.refs.alerts
  local widths = self.widths

  local search_query = state.search_query
  local search_network_id = state.network_id
  local search_surface = state.surface

  local ltn_alerts = state.ltn_data.alerts
  local alerts_to_delete = global.active_data.alerts_to_delete

  local scroll_pane = refs.scroll_pane
  local children = scroll_pane.children

  local sorts = state.sorts[state.active_tab]
  local active_sort = sorts._active
  local sorted_alerts = state.ltn_data.sorted_alerts[active_sort]

  local table_index = 0

  -- False = ascending (arrow down), True = descending (arrow up)
  local start, finish, step
  if sorts[active_sort] then
    start = #sorted_alerts
    finish = 1
    step = -1
  else
    start = 1
    finish = #sorted_alerts
    step = 1
  end

  if not global.flags.deleted_all_alerts then
    for sorted_index = start, finish, step do
      local alert_id = sorted_alerts[sorted_index]
      local alerts_entry = ltn_alerts[alert_id]

      if
        (search_surface == -1 or (alerts_entry.train.surface_index == search_surface))
        and bit32.btest(alerts_entry.train.network_id, search_network_id)
        and (#search_query == 0 or string.find(
          alerts_entry.search_strings[self.player.index] or "",
          string.lower(search_query)
        ))
        and not alerts_to_delete[alert_id]
      then
        table_index = table_index + 1
        local row = children[table_index]
        local color = table_index % 2 == 0 and "dark" or "light"
        if not row then
          row = gui.add(scroll_pane, {
            type = "frame",
            style = "ltnm_table_row_frame_" .. color,
            { type = "label", style_mods = { width = widths.alerts.time } },
            {
              type = "label",
              style = "ltnm_clickable_semibold_label",
              style_mods = { width = widths.alerts.train_id, horizontal_align = "center" },
              tooltip = { "gui.ltnm-open-train-gui" },
            },
            {
              type = "flow",
              style_mods = { vertical_spacing = 0 },
              direction = "vertical",
              {
                type = "label",
                style = "ltnm_clickable_semibold_label",
                style_mods = { width = widths.alerts.route },
                tooltip = constants.open_station_gui_tooltip,
              },
              {
                type = "label",
                style = "ltnm_clickable_semibold_label",
                style_mods = { width = widths.alerts.route },
                tooltip = constants.open_station_gui_tooltip,
              },
            },
            { type = "label", style_mods = { width = widths.alerts.network_id, horizontal_align = "center" } },
            { type = "label", style_mods = { width = widths.alerts.type } },
            {
              type = "frame",
              name = "contents_frame",
              style = "ltnm_small_slot_table_frame_" .. color,
              style_mods = { width = widths.alerts.contents },
              { type = "table", name = "contents_table", style = "slot_table", column_count = 4 },
            },
            {
              type = "sprite-button",
              style = "tool_button_red",
              sprite = "utility/trash",
              tooltip = { "gui.ltnm-delete-alert" },
            },
          })
        end

        gui.update(row, {
          { elem_mods = { caption = misc.ticks_to_timestring(alerts_entry.time) } },
          {
            elem_mods = { caption = alerts_entry.train_id },
            actions = {
              on_click = { gui = "main", action = "open_train_gui", train_id = alerts_entry.train_id },
            },
          },
          {
            {
              elem_mods = { caption = alerts_entry.train.from },
              actions = {
                on_click = { gui = "main", action = "open_station_gui", station_id = alerts_entry.train.from_id },
              },
            },
            {
              elem_mods = {
                caption = "[color=" .. constants.colors.caption.str .. "]->[/color]  " .. alerts_entry.train.to,
              },
              actions = {
                on_click = { gui = "main", action = "open_station_gui", station_id = alerts_entry.train.to_id },
              },
            },
          },
          { elem_mods = { caption = util.signed_int32(alerts_entry.train.network_id) } },
          {
            elem_mods = {
              caption = { "gui.ltnm-alert-" .. string.gsub(alerts_entry.type, "_", "-") },
              tooltip = { "gui.ltnm-alert-" .. string.gsub(alerts_entry.type, "_", "-") .. "-description" },
            },
          },
          {},
          {
            actions = {
              on_click = { gui = "main", action = "delete_alert", alert_id = alert_id },
            },
          },
        })

        util.slot_table_update(row.contents_frame.contents_table, {
          { color = "green", entries = alerts_entry.planned_shipment or {}, translations = dictionaries.materials },
          { color = "red", entries = alerts_entry.actual_shipment or {}, translations = dictionaries.materials },
          { color = "red", entries = alerts_entry.unscheduled_load or {}, translations = dictionaries.materials },
          { color = "red", entries = alerts_entry.remaining_load or {}, translations = dictionaries.materials },
        })
      end
    end
  end

  for child_index = table_index + 1, #children do
    children[child_index].destroy()
  end

  if table_index == 0 then
    refs.warning_flow.visible = true
    scroll_pane.visible = false
    refs.content_frame.style = "ltnm_main_warning_frame"
    refs.delete_all_button.enabled = false
  else
    refs.warning_flow.visible = false
    scroll_pane.visible = true
    refs.content_frame.style = "ltnm_main_content_frame"
    refs.delete_all_button.enabled = true
  end
end

return alerts_tab

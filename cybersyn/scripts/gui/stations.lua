local gui = require("__flib__.gui")

local constants = require("constants")

local util = require("scripts.util")

local templates = require("templates")

local stations_tab = {}

function stations_tab.build(widths)
  return {
    tab = {
      type = "tab",
      caption = { "gui.ltnm-stations" },
      ref = { "stations", "tab" },
      actions = {
        on_click = { gui = "main", action = "change_tab", tab = "stations" },
      },
    },
    content = {
      type = "frame",
      style = "ltnm_main_content_frame",
      direction = "vertical",
      ref = { "stations", "content_frame" },
      {
        type = "frame",
        style = "ltnm_table_toolbar_frame",
        templates.sort_checkbox(widths, "stations", "name", true),
        templates.sort_checkbox(widths, "stations", "status", false, { "gui.ltnm-status-description" }),
        templates.sort_checkbox(widths, "stations", "network_id", false),
        templates.sort_checkbox(
          widths,
          "stations",
          "provided_requested",
          false,
          { "gui.ltnm-provided-requested-description" }
        ),
        templates.sort_checkbox(widths, "stations", "shipments", false, { "gui.ltnm-shipments-description" }),
        templates.sort_checkbox(widths, "stations", "control_signals", false),
      },
      { type = "scroll-pane", style = "ltnm_table_scroll_pane", ref = { "stations", "scroll_pane" } },
      {
        type = "flow",
        style = "ltnm_warning_flow",
        visible = false,
        ref = { "stations", "warning_flow" },
        {
          type = "label",
          style = "ltnm_semibold_label",
          caption = { "gui.ltnm-no-stations" },
          ref = { "stations", "warning_label" },
        },
      },
    },
  }
end

function stations_tab.update(self)
  local dictionaries = self.player_table.dictionaries

  local state = self.state
  local refs = self.refs.stations
  local widths = self.widths.stations

  local search_query = state.search_query
  local search_network_id = state.network_id
  local search_surface = state.surface

  local ltn_stations = state.ltn_data.stations
  local scroll_pane = refs.scroll_pane
  local children = scroll_pane.children

  local sorts = state.sorts.stations
  local active_sort = sorts._active
  local sorted_stations = state.ltn_data.sorted_stations[active_sort]

  local table_index = 0

  -- False = ascending (arrow down), True = descending (arrow up)
  local start, finish, step
  if sorts[active_sort] then
    start = #sorted_stations
    finish = 1
    step = -1
  else
    start = 1
    finish = #sorted_stations
    step = 1
  end

  for sorted_index = start, finish, step do
    local station_id = sorted_stations[sorted_index]
    local station_data = ltn_stations[station_id]

    if station_data.entity.valid then
      if
        (search_surface == -1 or station_data.entity.surface.index == search_surface)
        and bit32.btest(station_data.network_id, search_network_id)
        and (
          #search_query == 0 or string.find(station_data.search_strings[self.player.index], string.lower(search_query))
        )
      then
        table_index = table_index + 1
        local row = children[table_index]
        local color = table_index % 2 == 0 and "dark" or "light"
        if not row then
          row = gui.add(scroll_pane, {
            type = "frame",
            style = "ltnm_table_row_frame_" .. color,
            {
              type = "label",
              style = "ltnm_clickable_semibold_label",
              style_mods = { width = widths.name },
              tooltip = constants.open_station_gui_tooltip,
            },
            templates.status_indicator(widths.status, true),
            { type = "label", style_mods = { width = widths.network_id, horizontal_align = "center" } },
            templates.small_slot_table(widths, color, "provided_requested"),
            templates.small_slot_table(widths, color, "shipments"),
            templates.small_slot_table(widths, color, "control_signals"),
          })
        end

        gui.update(row, {
          {
            elem_mods = { caption = station_data.name },
            actions = {
              on_click = { gui = "main", action = "open_station_gui", station_id = station_id },
            },
          },
          {
            { elem_mods = { sprite = "flib_indicator_" .. station_data.status.color } },
            { elem_mods = { caption = station_data.status.count } },
          },
          { elem_mods = { caption = station_data.network_id } },
        })

        util.slot_table_update(row.provided_requested_frame.provided_requested_table, {
          { color = "green", entries = station_data.provided, translations = dictionaries.materials },
          { color = "red", entries = station_data.requested, translations = dictionaries.materials },
        })
        util.slot_table_update(row.shipments_frame.shipments_table, {
          { color = "green", entries = station_data.inbound, translations = dictionaries.materials },
          { color = "blue", entries = station_data.outbound, translations = dictionaries.materials },
        })
        util.slot_table_update(row.control_signals_frame.control_signals_table, {
          {
            color = "default",
            entries = station_data.control_signals,
            translations = dictionaries.virtual_signals,
            type = "virtual-signal",
          },
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
  else
    refs.warning_flow.visible = false
    scroll_pane.visible = true
    refs.content_frame.style = "ltnm_main_content_frame"
  end
end

return stations_tab

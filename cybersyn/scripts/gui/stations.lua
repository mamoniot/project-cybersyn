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

--- @param map_data MapData
--- @param player_data PlayerData
--- @return GuiElemDef
function stations_tab.build(map_data, player_data)

  local widths = constants.gui["en"]

  local search_item = player_data.search_item
  local search_network_name = player_data.search_network_name
  local search_network_mask = player_data.search_network_mask
  local search_surface_idx = player_data.search_surface_idx


  local stations_sorted = {}
  local to_sorted_manifest = {}
  for id, station in pairs(map_data.stations) do
    if search_network_name then
      if search_network_name ~= station.network_name then
        goto continue
      end
      local train_flag = get_network_flag(station, search_network_name)
      if not bit32.btest(search_network_mask, train_flag) then
        goto continue
      end
    elseif search_network_mask ~= -1 then
      if station.network_name == NETWORK_EACH then
        local masks = station.network_flag--[[@as {}]]
        for _, network_flag in pairs(masks) do
          if bit32.btest(search_network_mask, network_flag) then
            goto has_match
          end
        end
        goto continue
        ::has_match::
      elseif not bit32.btest(search_network_mask, station.network_flag) then
        goto continue
      end
    end

    if search_surface_idx then
      local entity = station.entity_stop
      if not entity.valid then
        goto continue
      end
      if entity.surface.index ~= search_surface_idx then
        goto continue
      end
    end

    if search_item then
      if not station.deliveries then
        goto continue
      end
      for item_name, _ in pairs(station.deliveries) do
        if item_name == search_item then
          goto has_match
        end
      end
      goto continue
      ::has_match::
    end

    stations_sorted[#stations_sorted + 1] = id
    --insertion sort
    local manifest = {}
    local manifest_type = {}
    for name, _ in pairs(station.deliveries) do
      local is_fluid = get_is_fluid(name)
      local i = 1
      while i <= #manifest do
        if (not is_fluid and manifest_type[i]) or (is_fluid == manifest_type[i] and name < manifest[i]) then
          break
        end
        i = i + 1
      end
      table.insert(manifest, i, name)
      table.insert(manifest_type, i, is_fluid)
    end
    to_sorted_manifest[id] = manifest
    ::continue::
  end


  table.sort(stations_sorted, function(a, b)
    local station1 = map_data.stations[a]
    local station2 = map_data.stations[b]
    for i, v in ipairs(player_data.trains_orderings) do
      local invert = player_data.trains_orderings_invert[i]
      if v == ORDER_LAYOUT then
        if not station1.allows_all_trains and not station2.allows_all_trains then
          local layout1 = station1.layout_pattern--[[@as uint[] ]]
          local layout2 = station2.layout_pattern--[[@as uint[] ]]
          for j, c1 in ipairs(layout1) do
            local c2 = layout2[j]
            if c1 ~= c2 then
              return invert ~= (c2 and c1 < c2)
            end
          end
          if layout2[#layout1 + 1] then
            return invert ~= true
          end
        elseif station1.allows_all_trains ~= station2.allows_all_trains then
          return invert ~= station2.allows_all_trains
        end
      elseif v == ORDER_NAME then
        local name1 = station1.entity_stop.valid and station1.entity_stop.backer_name
        local name2 = station2.entity_stop.valid and station2.entity_stop.backer_name
        if name1 ~= name2 then
          return invert ~= (name1 and (name2 and name1 < name2 or true) or false)
        end
      elseif v == ORDER_TOTAL_TRAINS then
        if station1.deliveries_total ~= station2.deliveries_total then
          return invert ~= (station1.deliveries_total < station2.deliveries_total)
        end
      elseif v == ORDER_MANIFEST then
        if not next(station1.deliveries) then
          if next(station2.deliveries) then
            return invert ~= true
          end
        elseif not next(station2.deliveries) then
          return invert ~= false
        else
          local first_item = nil
          local first_direction = nil
          for item_name in dual_pairs(station1.deliveries, station2.deliveries) do
            if not first_item or item_lt(map_data.manager, item_name, first_item) then
              local count1 = station1.deliveries[item_name] or 0
              local count2 = station2.deliveries[item_name] or 0
              if count1 ~= count2 then
                first_item = item_name
                first_direction = count1 < count2
              end
            end
          end
          if first_direction ~= nil then
            return invert ~= first_direction
          end
        end
      end
    end
    return (not player_data.trains_orderings_invert[#player_data.trains_orderings_invert]) == (a < b)
  end)


end

function stations_tab.update(self)
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

local gui = require("__flib__.gui-lite")
local train_util = require("__flib__.train")
local format = require("__flib__.format")

local constants = require("constants")
local util = require("scripts.gui.util")

local templates = require("templates")

local alerts_tab = {}

function alerts_tab.create(widths)
  return {
    tab = {
      name = "manager_alerts_tab",
      type = "tab",
      caption = { "cybersyn-gui.alerts" },
      ref = { "alerts", "tab" },
      handler = alerts_tab.handle.on_alerts_tab_selected,
    },
    content = {
      name = "alerts_content_frame",
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
        templates.sort_checkbox(widths, "alerts", "type", false),
      },
      { name = "manager_alerts_tab_scroll_pane", type = "scroll-pane", style = "ltnm_table_scroll_pane", ref = { "alerts", "scroll_pane" } },
      {
        name = "alerts_warning_flow",
        type = "flow",
        style = "ltnm_warning_flow",
        visible = false,
        ref = { "alerts", "warning_flow" },
        {
          type = "label",
          style = "ltnm_semibold_label",
          caption = { "cybersyn-gui.no-alerts" },
          ref = { "alerts", "warning_label" },
        },
      },
    },
  }
end

function alerts_tab.build(map_data, player_data)

  local alert_table = {}
  alert_table[1] = "cybersyn-messages.stuck-train"
  alert_table[2] = "cybersyn-messages.nonempty-train"
  alert_table[3] = "cybersyn-messages.depot-broken"
  alert_table[4] = "cybersyn-messages.station-broken"
  alert_table[5] = "cybersyn-messages.refueler-broken"
  alert_table[6] = "cybersyn-messages.train-at-incorrect"
  alert_table[7] = "cybersyn-messages.cannot-path-between-surfaces"

  local refs = player_data.refs
  local widths = constants.gui["en"]

  -- local search_query = player_data.search_query
  -- local search_item = player_data.search_item
  -- local search_network_id = player_data.network_id
  -- local search_surface = player_data.search_surface_idx

  local alerts = map_data.active_alerts

  local scroll_pane = refs.manager_alerts_tab_scroll_pane
  if next(scroll_pane.children) ~= nil then
    refs.manager_alerts_tab_scroll_pane.clear()
  end



  if alerts then
    refs.alerts_warning_flow.visible = false
    scroll_pane.visible = true
    refs.alerts_content_frame.style = "ltnm_main_content_frame"
    for i, alert in pairs(alerts) do
      ---@type LuaTrain
      local train = alert[1]
      local alert_id = alert[2]
      local tick = alert[3]
      local alert_message = alert_table[alert_id]
      local locomotive = util.get_locomotive(train)
      -- if
      --   (search_surface == -1 or (alerts_entry.train.surface_index == search_surface))
      --   and bit32.btest(alerts_entry.train.network_id, search_network_id)
      --   and (#search_query == 0 or string.find(
      --     alerts_entry.search_strings[self.player.index] or "",
      --     string.lower(search_query)
      --   ))
      -- then
        local color = i % 2 == 0 and "dark" or "light"
        gui.add(scroll_pane, {
            type = "frame",
            style = "ltnm_table_row_frame_" .. color,
            { type = "label", style_mods = { width = widths.alerts.time }, caption = format.time(tick) },
            {
              type = "frame",
              style = "ltnm_table_inset_frame_" .. color,
              {
                type = "minimap",
                name = "train_minimap",
                style = "ltnm_train_minimap",
                style_mods = { width = widths.alerts.train_id, horizontal_align = "center" },
                { type = "label", style = "ltnm_minimap_label", caption = train.id },
                {
                  type = "button",
                  style = "ltnm_train_minimap_button",
                  tooltip = { "cybersyn-gui.open-train-gui" },
                  tags = { train_id = train.id },
                  handler = alerts_tab.handle.alerts_open_train_gui, --on_click
                },
              },
            },
            {
              type = "label", caption = { alert_message }
            },
            -- {
            --   type = "flow",
            --   style_mods = { vertical_spacing = 0 },
            --   direction = "vertical",
            --   {
            --     type = "label",
            --     style = "ltnm_clickable_semibold_label",
            --     style_mods = { width = widths.alerts.route },
            --     tooltip = constants.open_station_gui_tooltip,
            --   },
            --   {
            --     type = "label",
            --     style = "ltnm_clickable_semibold_label",
            --     style_mods = { width = widths.alerts.route },
            --     tooltip = constants.open_station_gui_tooltip,
            --   },
            -- },
            -- { type = "label", style_mods = { width = widths.alerts.network_id, horizontal_align = "center" } },
            -- { type = "label", style_mods = { width = widths.alerts.type } },
            -- {
            --   type = "frame",
            --   name = "contents_frame",
            --   style = "ltnm_small_slot_table_frame_" .. color,
            --   style_mods = { width = widths.alerts.contents },
            --   { type = "table", name = "contents_table", style = "slot_table", column_count = 4 },
            -- },
          }, refs)
          refs.train_minimap.entity = locomotive
        end

          -- util.slot_table_update(row.contents_frame.contents_table, {
          --   { color = "green", entries = alerts_entry.planned_shipment or {}, translations = dictionaries.materials },
          --   { color = "red", entries = alerts_entry.actual_shipment or {}, translations = dictionaries.materials },
          --   { color = "red", entries = alerts_entry.unscheduled_load or {}, translations = dictionaries.materials },
          --   { color = "red", entries = alerts_entry.remaining_load or {}, translations = dictionaries.materials },
          -- })
  else
    refs.alerts_warning_flow.visible = true
    scroll_pane.visible = false
    refs.alerts_content_frame.style = "ltnm_main_warning_frame"
    refs.delete_all_button.enabled = false
  end
end

alerts_tab.handle = {}

--- @param e {player_index: uint}
function alerts_tab.wrapper(e, handler)
	local player = game.get_player(e.player_index)
	if not player then return end
	local player_data = global.manager.players[e.player_index]
	handler(player, player_data, player_data.refs, e)
end

--- @param e GuiEventData
--- @param player_data PlayerData
function alerts_tab.handle.alerts_open_train_gui(player, player_data, refs, e)
  -- TODO: fix this to work with a LuaTrain entity
	-- local train_id = e.element.tags.train_id
	-- --- @type Train
	-- local train = global.trains[train_id]
	-- local train_entity = train.entity

  --   if not train_entity or not train_entity.valid then
  --       util.error_flying_text(gui.player, { "message.ltnm-error-train-is-invalid" })
  --       return
  --   end
	-- train_util.open_gui(player.index, train_entity)
end

---@param player LuaPlayer
---@param player_data PlayerData
function alerts_tab.handle.on_alerts_tab_selected(player, player_data)
    player_data.selected_tab = "alerts_tab"
end

gui.add_handlers(alerts_tab.handle, alerts_tab.wrapper)

return alerts_tab

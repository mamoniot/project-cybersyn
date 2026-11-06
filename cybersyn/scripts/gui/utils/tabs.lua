-- The manager's tabs in pane order: the module that builds each, its content frame, and which of the manager's
-- filters it applies. Data only, so filters.lua can read it without requiring the tabs; manager.lua requires the
-- modules.

--- @class ManagerTab
--- @field name string
--- @field module string require path; the module has create and build, and optionally subheader_right,
---   apply_layout(player_data, layout) and cleanup(map_data, player_data) (run when the tab is left or the window closes)
--- @field content string? content frame that takes the window's content height and width
--- @field analytics true? present only while analytics records
--- @field search true? has the station-name search, and applies it
--- @field station true? applies the station chip (the chip shows on every tab; the others say they ignore it)
--- @field item true? applies the item filter
--- @field train true? applies the train chip, which shows only on such tabs
--- @field item_tooltip string? locale key of the item chip's tooltip, when the tab applies it differently

--- @type ManagerTab[]
local tabs = {
	{ name = "overview_tab", module = "scripts.gui.overview", content = "manager_overview_content_frame", item = true,
		item_tooltip = "cybersyn-gui.filter-chip-overview-tooltip" },
	{ name = "inventory_tab", module = "scripts.gui.inventory", content = "manager_inventory_content_frame",
		search = true, station = true, item = true },
	{ name = "stations_tab", module = "scripts.gui.stations", content = "manager_stations_content_frame",
		search = true, station = true, item = true },
	{ name = "trains_tab", module = "scripts.gui.trains", content = "manager_trains_tab_content_frame",
		search = true, station = true, item = true, train = true },
	{ name = "log_tab", module = "scripts.gui.log", content = "manager_log_content_frame", station = true, item = true },
	{ name = "utilization_tab", module = "scripts.gui.utilization", analytics = true },
	{ name = "delivery_breakdown_tab", module = "scripts.gui.delivery-breakdown", analytics = true, item = true },
}

--- @type {[string]: ManagerTab}
tabs.by_name = {}
for _, t in ipairs(tabs) do tabs.by_name[t.name] = t end

return tabs

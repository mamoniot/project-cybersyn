-- Sort order and pages of the list tabs, kept per tab in player_data.

local gui = require("__flib__.gui")
local format = require("__flib__.format")

local util = require("scripts.gui.util")
local nav = require("scripts.gui.utils.nav")

local listing = {}

listing.handle = {}

--- @param player_data PlayerData
--- @param tab string canonical tab name, e.g. "stations_tab"
--- @param default_column string
--- @return string column
--- @return boolean ascending
function listing.get_sort(player_data, tab, default_column)
	local sorts = get_or_create(player_data, "sort")
	local sort = sorts[tab]
	if not sort then
		sort = { column = default_column, ascending = true }
		sorts[tab] = sort
	end
	return sort.column, sort.ascending
end

--- First selection of a column sorts ascending; selecting the active column again flips it.
--- Passing `ascending` sets the direction explicitly.
--- @param player_data PlayerData
--- @param tab string
--- @param column string
--- @param ascending boolean?
function listing.set_sort(player_data, tab, column, ascending)
	player_data.sort = player_data.sort or {}
	local sort = player_data.sort[tab]
	if ascending == nil then
		if sort and sort.column == column then
			ascending = not sort.ascending
		else
			ascending = true
		end
	end
	player_data.sort[tab] = { column = column, ascending = ascending }
	listing.reset_page(player_data, tab)
end

-- Upper bound for a tab without a window layout: about 9 ms per Stations render at 500 rows on a 2,000-station base,
-- so 200 stays near the 5 ms render budget.
listing.MAX_PAGE_SIZE = 200

--- Rows per page of a list tab: as many as its window height fits (player_data.layout), at most
--- listing.MAX_PAGE_SIZE.
--- @param player_data PlayerData
--- @param tab string?
--- @return integer
function listing.page_size(player_data, tab)
	local size = listing.MAX_PAGE_SIZE
	local layout = tab and player_data.layout
	local rows = layout and layout.rows_by_tab and layout.rows_by_tab[tab]
	if rows and rows < size then return rows end
	return size
end

--- @param player_data PlayerData
--- @param tab string
function listing.reset_page(player_data, tab)
	if player_data.page then player_data.page[tab] = nil end
end

--- @param player_data PlayerData
function listing.reset_pages(player_data)
	player_data.page = {}
end

--- Clamps the tab's page to `total`, refreshes the tab's pager widgets (if built with templates.pager) and
--- returns the 1-based inclusive slice to render. `last < first` when `total` is 0.
--- @param player_data PlayerData
--- @param tab string
--- @param total integer
--- @param size integer? rows per page when the tab gives up some of its rows (default listing.page_size)
--- @param fewer integer? rows the page gives up to a strip the tab shows above its list (Trains: wrapped chips)
--- @param range_key string? the range caption's locale key when the rows are not what the tab's summary counts
--- (Trains grouped by depot: "pager-range-rows", group rows included)
--- @return integer first
--- @return integer last
--- @return integer page
--- @return integer pages
function listing.paginate(player_data, tab, total, size, fewer, range_key)
	size = math.max((size or listing.page_size(player_data, tab)) - (fewer or 0), 1)
	local pages = math.max(1, math.ceil(total / size))
	player_data.page = player_data.page or {}
	local page = math.min(math.max(player_data.page[tab] or 1, 1), pages)
	player_data.page[tab] = page
	local first = (page - 1) * size + 1
	local last = math.min(total, page * size)

	local refs = player_data.refs
	local label = refs and refs[tab .. "_pager_label"]
	if label and label.valid then
		local caption
		if total == 0 then
			caption = { "cybersyn-gui.pager-empty" }
		else
			caption = { range_key or "cybersyn-gui.pager-range", format.number(first), format.number(last), format.number(total) }
		end
		label.caption = caption
		local back, forward = page > 1, page < pages
		refs[tab .. "_pager_first"].enabled = back
		refs[tab .. "_pager_prev"].enabled = back
		refs[tab .. "_pager_next"].enabled = forward
		refs[tab .. "_pager_last"].enabled = forward
	end
	return first, last, page, pages
end

--- @param e EventData.on_gui_click
function listing.handle.pager_click(player, player_data, refs, e)
	local tags = e.element.tags
	local tab, action = tags.pager_tab, tags.pager_action
	if not tab then return end
	player_data.page = player_data.page or {}
	local page = player_data.page[tab] or 1
	if action == "first" then
		page = 1
	elseif action == "prev" then
		page = page - (e.shift and 10 or 1)
	elseif action == "next" then
		page = page + (e.shift and 10 or 1)
	elseif action == "last" then
		page = math.huge
	end
	player_data.page[tab] = math.max(1, page)
	nav.rerender(player, player_data)
end

--- A templates.sort_checkbox header: sorts its tab by that column.
--- @param e EventData.on_gui_checked_state_changed
function listing.handle.sort_click(player, player_data, refs, e)
	local tags = e.element.tags
	if not (tags.sort_tab and tags.column) then return end
	listing.set_sort(player_data, tags.sort_tab, tags.column)
	nav.rerender(player, player_data)
end

--- Restyles a tab's sort header checkboxes to match the stored sort, since the header is built with a fixed
--- default column and the stored sort outlives window rebuilds.
--- @param cell LuaGuiElement? a header cell holding a sort checkbox
--- @param column string
--- @param ascending boolean
function listing.sync_sort_header(cell, column, ascending)
	if not (cell and cell.valid) then return end
	for _, child in pairs(cell.children) do
		if child.type == "checkbox" then
			local tags = child.tags
			if tags.column then
				local active = tags.column == column
				local style = active and "ltnm_selected_sort_checkbox" or "ltnm_sort_checkbox"
				if child.style.name ~= style then child.style = style end
				-- An inactive arrow shows the direction a click on it would sort, not whatever it was last left at.
				local state
				if active then
					state = not ascending
				else
					state = tags.default_state
				end
				if state ~= nil and child.state ~= state then child.state = state end
			end
		end
	end
end

gui.add_handlers(listing.handle, util.wrapper, "cybersyn_listing")

return listing

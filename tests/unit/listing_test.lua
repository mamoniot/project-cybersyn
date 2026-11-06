-- Sort order and paging in scripts/gui/utils/listing.lua, and the flib handler prefixes of the utils modules.

local H = require("harness")

local function listing()
	return H.load("scripts.gui.utils.listing")
end

test("get_sort: creates the default once; later defaults are ignored", function()
	local u = listing()
	local pd = {}
	local c, a = u.get_sort(pd, "stations_tab", "name")
	assert_eq(c, "name")
	assert_true(a)
	assert_eq(pd.sort, { stations_tab = { column = "name", ascending = true } })
	c, a = u.get_sort(pd, "stations_tab", "wait")
	assert_eq(c, "name")
	assert_true(a)
end)

test("set_sort: same column toggles, new column ascending, explicit direction wins", function()
	local u = listing()
	local pd = {}
	u.set_sort(pd, "stations_tab", "name")
	assert_eq(pd.sort.stations_tab, { column = "name", ascending = true })
	u.set_sort(pd, "stations_tab", "name")
	assert_eq(pd.sort.stations_tab, { column = "name", ascending = false })
	u.set_sort(pd, "stations_tab", "name")
	assert_eq(pd.sort.stations_tab, { column = "name", ascending = true })
	u.set_sort(pd, "stations_tab", "wait")
	assert_eq(pd.sort.stations_tab, { column = "wait", ascending = true })
	u.set_sort(pd, "stations_tab", "wait", true)
	assert_eq(pd.sort.stations_tab, { column = "wait", ascending = true })
	u.set_sort(pd, "stations_tab", "name", false)
	assert_eq(pd.sort.stations_tab, { column = "name", ascending = false })
	-- get_sort's implicit default counts as the active column, so the first click flips it.
	local pd2 = {}
	u.get_sort(pd2, "trains_tab", "id")
	u.set_sort(pd2, "trains_tab", "id")
	assert_eq(pd2.sort.trains_tab, { column = "id", ascending = false })
end)

test("set_sort: resets only that tab's page", function()
	local u = listing()
	local pd = { page = { stations_tab = 3, trains_tab = 2 } }
	u.set_sort(pd, "stations_tab", "name")
	assert_eq(pd.page, { trains_tab = 2 })
	local pd2 = {}
	u.set_sort(pd2, "stations_tab", "name")
	assert_nil(pd2.page)
end)

-- ------------------------------------------------------------------ paging

test("page_size: the constant bound without a window layout", function()
	local u = listing()
	assert_eq(u.page_size({ player_index = 2 }), 200)
	assert_eq(u.MAX_PAGE_SIZE, 200)
end)

test("page_size: a tab gets the window's rows, capped by the bound", function()
	local u = listing()
	local pd = { layout = { rows_by_tab = { stations_tab = 18, trains_tab = 12, big_tab = 500 } } }
	assert_eq(u.page_size(pd, "stations_tab"), 18)
	assert_eq(u.page_size(pd, "trains_tab"), 12)
	assert_eq(u.page_size(pd, "big_tab"), 200)
	assert_eq(u.page_size(pd, "other_tab"), 200)
	assert_eq(u.page_size(pd), 200)
	assert_eq({ u.paginate({ layout = pd.layout }, "stations_tab", 40) }, { 1, 18, 1, 3 })
end)

test("paginate: slices, clamping and stored page", function()
	local u = listing()
	local pd = { layout = { rows_by_tab = { t = 10 } } }
	assert_eq({ u.paginate(pd, "t", 0) }, { 1, 0, 1, 1 })
	assert_eq({ u.paginate(pd, "t", 25) }, { 1, 10, 1, 3 })
	pd.page.t = 3
	assert_eq({ u.paginate(pd, "t", 25) }, { 21, 25, 3, 3 })
	pd.page.t = 5
	assert_eq({ u.paginate(pd, "t", 25) }, { 21, 25, 3, 3 })
	assert_eq(pd.page.t, 3)
	pd.page.t = 0
	assert_eq({ u.paginate(pd, "t", 25) }, { 1, 10, 1, 3 })
	pd.page.t = -2
	assert_eq({ u.paginate(pd, "t", 30) }, { 1, 10, 1, 3 })
	pd.page.t = 3
	assert_eq({ u.paginate(pd, "t", 30) }, { 21, 30, 3, 3 })
	pd.page.t = math.huge
	assert_eq({ u.paginate(pd, "t", 10) }, { 1, 10, 1, 1 })
	-- Shrinking the list pulls the page back.
	pd.page.t = 3
	assert_eq({ u.paginate(pd, "t", 12) }, { 11, 12, 2, 2 })
	assert_eq(pd.page.t, 2)
end)

local function pager_refs(tab)
	local refs = { [tab .. "_pager_label"] = H.element({ type = "label" }) }
	for _, k in ipairs({ "first", "prev", "next", "last" }) do
		refs[tab .. "_pager_" .. k] = H.element({ type = "button" })
	end
	return refs
end

test("paginate: pager caption and button states", function()
	local u = listing()
	local refs = pager_refs("t")
	local pd = { refs = refs, page = { t = 2 } }
	u.paginate(pd, "t", 2500, 1000)
	assert_eq(refs.t_pager_label.caption, { "cybersyn-gui.pager-range", "1,001", "2,000", "2,500" })
	assert_true(refs.t_pager_first.enabled)
	assert_true(refs.t_pager_prev.enabled)
	assert_true(refs.t_pager_next.enabled)
	assert_true(refs.t_pager_last.enabled)
	pd.page.t = 1
	u.paginate(pd, "t", 2500, 1000)
	assert_false(refs.t_pager_first.enabled)
	assert_false(refs.t_pager_prev.enabled)
	assert_true(refs.t_pager_next.enabled)
	u.paginate(pd, "t", 0, 1000)
	assert_eq(refs.t_pager_label.caption, { "cybersyn-gui.pager-empty" })
	assert_false(refs.t_pager_next.enabled)
	assert_false(refs.t_pager_last.enabled)
	refs.t_pager_label.valid = false
	refs.t_pager_next.enabled = "untouched"
	u.paginate(pd, "t", 2500, 1000)
	assert_eq(refs.t_pager_next.enabled, "untouched")
end)

test("reset_page and reset_pages", function()
	local u = listing()
	local pd = {}
	u.reset_page(pd, "t")
	assert_nil(pd.page)
	pd.page = { t = 2, u = 3 }
	u.reset_page(pd, "t")
	assert_eq(pd.page, { u = 3 })
	u.reset_pages(pd)
	assert_eq(pd.page, {})
end)

test("listing, hover and links register their handlers with flib under their own prefixes", function()
	listing()
	H.load("scripts.gui.utils.hover")
	H.load("scripts.gui.utils.links")
	assert_not_nil(H.flib_gui.handlers["cybersyn_listing:pager_click"])
	assert_not_nil(H.flib_gui.handlers["cybersyn_listing:sort_click"])
	assert_not_nil(H.flib_gui.handlers["cybersyn_hover:hover_enter"])
	assert_not_nil(H.flib_gui.handlers["cybersyn_links:link_click"])
end)

-- ------------------------------------------------------------------ pager, sort header

test("pager_click: steps, shift steps of 10, clamps at 1, last and first", function()
	local nav, u = H.isolated("scripts.gui.utils.nav", "scripts.gui.utils.listing")
	local calls = 0
	nav.set_window_fns({ render = function() calls = calls + 1 end })
	local pd = {}
	local function click(action, shift, tab)
		u.handle.pager_click(nil, pd, nil, { element = { tags = { pager_tab = tab or "t", pager_action = action } }, shift = shift })
	end
	click("next")
	assert_eq(pd.page.t, 2)
	click("next", true)
	assert_eq(pd.page.t, 12)
	click("prev")
	assert_eq(pd.page.t, 11)
	click("prev", true)
	assert_eq(pd.page.t, 1)
	click("prev", true)
	assert_eq(pd.page.t, 1)
	click("last")
	assert_eq(pd.page.t, math.huge)
	click("first")
	assert_eq(pd.page.t, 1)
	assert_eq(calls, 7)
	u.handle.pager_click(nil, pd, nil, { element = { tags = {} } })
	assert_eq(calls, 7)
end)

test("sort_click: sorts the tagged tab by the tagged column, toggling on a repeat", function()
	local nav, u = H.isolated("scripts.gui.utils.nav", "scripts.gui.utils.listing")
	local calls = 0
	nav.set_window_fns({ render = function() calls = calls + 1 end })
	local pd = {}
	local function click(tags) u.handle.sort_click(nil, pd, nil, { element = { tags = tags } }) end
	click({ sort_tab = "trains_tab", column = "name" })
	assert_eq(pd.sort.trains_tab, { column = "name", ascending = true })
	click({ sort_tab = "trains_tab", column = "name" })
	assert_eq(pd.sort.trains_tab, { column = "name", ascending = false })
	click({ column = "name" })
	assert_eq(calls, 2)
end)

test("sync_sort_header: active column selected with the stored direction, others at their default", function()
	local u = listing()
	local cell = H.element({ name = "cell" })
	local name = cell.add({ type = "checkbox", style = "ltnm_sort_checkbox", state = false, tags = { column = "name", default_state = false } })
	local status = cell.add({ type = "checkbox", style = "ltnm_selected_sort_checkbox", state = false, tags = { column = "status", default_state = true } })
	local wait = cell.add({ type = "checkbox", style = "ltnm_sort_checkbox", state = true, tags = { column = "wait" } })
	local plain = cell.add({ type = "checkbox", style = "plain", state = true })
	local label = cell.add({ type = "label", style = "ltnm_sort_checkbox", tags = { column = "name" } })
	u.sync_sort_header(cell, "name", false)
	assert_eq(name.style, { name = "ltnm_selected_sort_checkbox" })
	assert_true(name.state)
	assert_eq(status.style, { name = "ltnm_sort_checkbox" })
	assert_true(status.state)
	-- No default_state: an inactive arrow keeps whatever it shows.
	assert_eq(wait.style, { name = "ltnm_sort_checkbox" })
	assert_true(wait.state)
	assert_eq(plain.style, { name = "plain" })
	assert_eq(label.style, { name = "ltnm_sort_checkbox" })
	u.sync_sort_header(cell, "name", true)
	assert_false(name.state)
	u.sync_sort_header(cell, "status", true)
	assert_eq(status.style, { name = "ltnm_selected_sort_checkbox" })
	assert_false(status.state)
	assert_eq(name.style, { name = "ltnm_sort_checkbox" })
	assert_false(name.state)
	cell.valid = false
	u.sync_sort_header(cell, "name", true)
	assert_eq(name.style.name, "ltnm_sort_checkbox")
	u.sync_sort_header(nil, "name", true)
end)

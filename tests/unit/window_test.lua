-- The window size from the screen (scripts/gui/sizing.lua) and the search normaliser (utils/filters).

local H = require("harness")

local function sizing()
	return H.load("scripts.gui.sizing")
end

local SCREENS = {
	{ "4K at 1.5", 3840, 2160, 1.5 },
	{ "1080p at 1.0", 1920, 1080, 1.0 },
	{ "1080p at 1.25", 1920, 1080, 1.25 },
	{ "4K at 2.0", 3840, 2160, 2.0 },
}

test("compute: width is 75 % of the logical screen, at most 1,440", function()
	local s = sizing()
	assert_eq(s.compute(3840, 2160, 1.5).width, 1440)
	assert_eq(s.compute(1920, 1080, 1.0).width, 1440)
	assert_eq(s.compute(1920, 1080, 1.25).width, 1152)
	assert_eq(s.compute(3840, 2160, 2.0).width, 1440)
	assert_eq(s.compute(1920, 1080, 1.25).content_width, 1152 - s.OUTER_WIDTH)
end)

test("compute: the window is chrome plus whole Overview rows and as tall as fits in 85 % of the screen", function()
	local s = sizing()
	for _, screen in ipairs(SCREENS) do
		local l = s.compute(screen[2], screen[3], screen[4])
		local limit = math.floor(0.85 * math.floor(screen[3] / screen[4]))
		local rows = l.rows_by_tab.overview_tab
		assert_eq(l.content_height, s.TAB_CHROME.overview_tab + rows * s.ROW_HEIGHT.overview_tab, screen[1])
		assert_true(l.window_height <= limit, screen[1] .. " fits")
		assert_true(l.window_height + s.ROW_HEIGHT.overview_tab > limit, screen[1] .. " one more row would not")
	end
end)

test("compute: the reference screen of the wireframe (4K at 1.5) gets 27 Overview rows", function()
	local s = sizing()
	local l = s.compute(3840, 2160, 1.5)
	assert_eq(l.screen_width, 2560)
	assert_eq(l.screen_height, 1440)
	assert_eq(l.rows_by_tab.overview_tab, math.floor((1224 - s.OUTER_HEIGHT - s.TAB_CHROME.overview_tab) / 32))
end)

test("compute: every other tab fits whole rows of its own height into the Overview's content height", function()
	local s = sizing()
	for _, screen in ipairs(SCREENS) do
		local l = s.compute(screen[2], screen[3], screen[4])
		for tab, h in pairs(s.ROW_HEIGHT) do
			local rows = l.rows_by_tab[tab]
			assert_true(s.TAB_CHROME[tab] + rows * h <= l.content_height, screen[1] .. " " .. tab)
			assert_true(s.TAB_CHROME[tab] + (rows + 1) * h > l.content_height, screen[1] .. " " .. tab .. " is maximal")
		end
	end
end)

test("compute: the filter row and the banner take rows away, never push past 85 %", function()
	local s = sizing()
	local plain = s.compute(3840, 2160, 1.5)
	local both = s.compute(3840, 2160, 1.5, true, true)
	assert_true(both.rows_by_tab.overview_tab < plain.rows_by_tab.overview_tab)
	assert_true(both.window_height <= 1224)
	assert_eq(both.window_height, s.OUTER_HEIGHT + s.FILTER_ROW_HEIGHT + s.BANNER_HEIGHT + both.content_height)
end)

test("compute: a tiny screen gets a window no larger than the screen, at least one row, and a zero scale reads as 1", function()
	local s = sizing()
	local l = s.compute(800, 400, 1)
	assert_true(l.rows_by_tab.overview_tab >= 1)
	assert_eq(l.content_height, s.TAB_CHROME.overview_tab + l.rows_by_tab.overview_tab * s.ROW_HEIGHT.overview_tab)
	assert_eq(l.width, 800)
	assert_true(l.window_height <= 400)
	assert_eq(s.compute(1920, 1080, 0).width, 1440)
end)

test("compute: below the minimum width the window takes MIN_WIDTH, never more than the screen", function()
	local s = sizing()
	-- 1080p at 2.0 is 960 logical px wide: 75 % would be 720
	assert_eq(s.compute(1920, 1080, 2.0).width, 960)
	-- 1366x768 at 1.5 is 910 wide
	assert_eq(s.compute(1366, 768, 1.5).width, 910)
	-- 1080p at 1.5 is 1,280 wide: the share (960) already reaches the minimum
	assert_eq(s.compute(1920, 1080, 1.5).width, 960)
	assert_eq(s.compute(2560, 1440, 1.0).width, 1440)
end)

test("compute: small screens fit every tab's chrome plus its minimum whole rows (the drill-down is the tallest)", function()
	local s = sizing()
	local small = {
		{ 1920, 1080, 2.0 }, { 1366, 768, 1.5 }, { 1280, 720, 1.25 }, { 1280, 800, 1.5 }, { 2560, 1440, 2.5 }, { 800, 400, 1 },
	}
	for _, screen in ipairs(small) do
		for _, filter_row in ipairs({ false, true }) do
			local l = s.compute(screen[1], screen[2], screen[3], filter_row)
			local label = screen[1] .. "x" .. screen[2] .. "@" .. screen[3] .. (filter_row and " +filter" or "")
			local sh = math.floor(screen[2] / screen[3])
			if sh >= 540 then assert_true(l.window_height <= sh, label .. " window within the screen") end
			assert_true(l.width <= math.floor(screen[1] / screen[3]), label .. " window within the screen width")
			-- The minimum rows wherever the screen has the height for them.
			local roomy = s.OUTER_HEIGHT + (filter_row and s.FILTER_ROW_HEIGHT or 0) + s.TAB_CHROME.item_tab
				+ s.MIN_ROWS * s.ROW_HEIGHT.item_tab + s.ROW_HEIGHT.overview_tab <= sh
			for tab, h in pairs(s.ROW_HEIGHT) do
				local rows = l.rows_by_tab[tab]
				if roomy then assert_true(rows >= s.MIN_ROWS, label .. " " .. tab .. " minimum rows") end
				assert_true(rows >= 1, label .. " " .. tab .. " at least one row")
				if sh >= 540 then
					assert_true(s.TAB_CHROME[tab] + rows * h <= l.content_height, label .. " " .. tab .. " fits")
				end
			end
		end
	end
end)

test("location_visible: off-screen positions are refused, in physical pixels", function()
	local s = sizing()
	assert_false(s.location_visible(nil, 3840, 2160, 2160))
	assert_true(s.location_visible({ x = 840, y = 171 }, 3840, 2160, 2160))
	assert_false(s.location_visible({ x = 3800, y = 171 }, 3840, 2160, 2160))
	assert_false(s.location_visible({ x = -2100, y = 171 }, 3840, 2160, 2160))
	assert_false(s.location_visible({ x = 100, y = -5 }, 3840, 2160, 2160))
	assert_false(s.location_visible({ x = 100, y = 2140 }, 3840, 2160, 2160))
	-- A position stored on a 4K screen is off a 1080p one.
	assert_false(s.location_visible({ x = 2500, y = 1500 }, 1920, 1080, 1440))
	assert_true(s.location_visible({ 10, 10 }, 1920, 1080, 1440))
end)

test("fit_location: a position kept after the window grew is moved back onto the screen", function()
	local s = sizing()
	-- Stored at UI scale 1.5 (2,160 px wide), restored at 2.0 (2,880 px wide).
	assert_eq(s.fit_location({ x = 840, y = 96 }, 3840, 2160, 2880, 1784), { x = 840, y = 96 })
	assert_eq(s.fit_location({ x = 1500, y = 96 }, 3840, 2160, 2880, 1784), { x = 960, y = 96 })
	assert_eq(s.fit_location({ x = 100, y = 900 }, 3840, 2160, 2160, 1820), { x = 100, y = 340 })
	assert_nil(s.fit_location({ x = 3800, y = 96 }, 3840, 2160, 2880, 1784))
	assert_nil(s.fit_location(nil, 3840, 2160, 2880, 1784))
end)

-- ------------------------------------------------------------------ search

local function filters()
	return H.load("scripts.gui.utils.filters")
end

test("search_terms: lowercase, split on whitespace, nil for blank", function()
	local u = filters()
	assert_eq(u.search_terms("  Iron  PLATE "), { "iron", "plate" })
	assert_nil(u.search_terms("   "))
	assert_nil(u.search_terms(nil))
end)

test("search_terms: the normaliser is helpers.multilingual_to_lower", function()
	local u = filters()
	local seen
	helpers.multilingual_to_lower = function(s) seen = s; return string.lower(s) end
	assert_eq(u.search_terms("ÄB"), { string.lower("ÄB") })
	assert_eq(seen, "ÄB")
	helpers.multilingual_to_lower = string.lower
end)

test("search: [, %, - and . are plain characters, never patterns", function()
	local u = filters()
	local function match(name, query)
		return u.terms_match(helpers.multilingual_to_lower(name), u.search_terms(query))
	end
	assert_true(match("[item=iron-plate] Iron 50%", "[item=iron"))
	assert_true(match("[item=iron-plate] Iron 50%", "50%"))
	assert_true(match("[item=iron-plate] Iron 50%", "%"))
	assert_true(match("Unload-A", "d-a"))
	assert_false(match("axb", "a.b"))
	assert_true(match("a.b", "a.b"))
	assert_false(match("Iron", "["))
	assert_true(match("[virtual-signal=signal-A] Depot", "[virtual-signal=signal-a]"))
	-- A lone "%" or "[" would raise "malformed pattern" if it ever reached string.find as a pattern.
	assert_true(pcall(match, "x", "%"))
	assert_true(pcall(match, "x", "[%"))
end)

test("station_passes: rich text and pattern characters in the query", function()
	local u = filters()
	local st = { name_lower = "[item=coal] coal 100% (east)", surface_index = 1, network_name = "signal-A", network_mask = 1,
		provided = {}, requested = {}, deliveries = {} }
	local f = { terms = u.search_terms("[item=coal] 100% (east)"), mask = -1 }
	assert_true(u.station_passes(st, f))
	f.terms = u.search_terms("(west)")
	assert_false(u.station_passes(st, f))
end)

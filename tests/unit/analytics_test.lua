-- Analytics tabs: the Breakdown range buttons and the Utilization chart's samples and legend.

local H = require("harness")
local analytics = loadfile("cybersyn/scripts/analytics.lua")()
local utilization = require("scripts.gui.utilization")

--- Ticks a range key names ("10m" = 36,000), nil for anything else.
local function range_ticks(key)
	local n, unit = string.match(key, "^(%d+)([mh])$")
	if not n then return nil end
	return tonumber(n) * (unit == "m" and 3600 or 216000)
end

test("breakdown ranges: every button covers exactly the span its caption names", function()
	local keys = {}
	for i, r in ipairs(analytics.BREAKDOWN_RANGES) do
		keys[i] = r.key
		assert_eq(r.ticks, range_ticks(r.key), r.key)
	end
	assert_eq(keys, { "1m", "10m", "1h", "10h", "50h" })
	assert_eq({ range_ticks("1m"), range_ticks("10h"), range_ticks("5s") }, { 3600, 2160000, nil })
end)

test("breakdown ranges: each range has its caption and tooltip in every locale", function()
	for _, r in ipairs(analytics.BREAKDOWN_RANGES) do
		for _, key in ipairs({ "breakdown-range-" .. r.key, "breakdown-range-tooltip-" .. r.key }) do
			for _, lang in ipairs(H.LOCALES) do
				local text = H.locale_text(lang)
				assert_true(text:find("\n" .. key .. "=", 1, true) ~= nil, lang .. " " .. key)
			end
		end
	end
end)

local function trains()
	return {
		[1] = { layout_id = 1, status = STATUS_TO_P },
		[2] = { layout_id = 1, status = STATUS_D },
		[3] = { layout_id = 2, status = STATUS_R },
		[4] = { layout_id = 1, status = STATUS_F },
		[5] = { layout_id = 1, status = STATUS_TO_R },
		[6] = { status = STATUS_D },
	}
end

test("utilization sample: per layout, the share of its trains on a delivery now, in percent", function()
	local sample = analytics.utilization_sample(trains())
	assert_eq(sample, { ["1"] = 50, ["2"] = 100 }, "a train without a layout is no series")
	assert_eq(analytics.utilization_sample({ [1] = { layout_id = 3, status = STATUS_TO_D } }), { ["3"] = 0 })
	assert_eq(analytics.utilization_sample({}), {})
end)

test("utilization sample: every on-delivery status counts as working, depot, refuel and return do not", function()
	for status, working in pairs({ [STATUS_D] = false, [STATUS_TO_P] = true, [STATUS_P] = true, [STATUS_TO_R] = true,
		[STATUS_R] = true, [STATUS_TO_D] = false, [STATUS_TO_D_BYPASS] = false, [STATUS_TO_F] = false, [STATUS_F] = false }) do
		assert_eq(analytics.utilization_sample({ { layout_id = 1, status = status } })["1"], working and 100 or 0, status)
	end
end)

test("utilization legend: layouts named by their carriage counts, a missing record by its id", function()
	assert_eq(analytics.format_layout_name({ 0, 1, 1, 1, 1 }, 1), "1L-4C")
	assert_eq(analytics.format_layout_name({ 0, 0, 2, 1, 0 }, 2), "3L-1C-1F")
	assert_eq(analytics.format_layout_name(nil, 9), "#9")
	assert_eq(analytics.format_layout_name({}, 4), "#4")
end)

test("utilization legend: highest sum first, ties by name, each with its sample count", function()
	local series = utilization.sorted_series({ counts = { ["1"] = 3, ["2"] = 3, ["10"] = 2 },
		sum = { ["1"] = 150, ["2"] = 300, ["10"] = 150 } })
	assert_eq(series, { { name = "2", sum = 300, count = 3 }, { name = "1", sum = 150, count = 3 },
		{ name = "10", sum = 150, count = 2 } })
	assert_eq(utilization.sorted_series({ counts = {}, sum = {} }), {})
end)

test("utilization: a range button per interval, each interval spanning exactly the time its caption names", function()
	assert_eq(utilization.INTERVAL_NAMES, { "1m", "10m", "1h", "10h", "50h", "250h", "1000h" })
	local defs = analytics.UTILIZATION_INTERVALS
	assert_eq(#defs, #utilization.INTERVAL_NAMES)
	assert_eq(analytics.SAMPLE_TICKS, defs[1].ticks)
	for i, def in ipairs(defs) do
		assert_eq(def.name, utilization.INTERVAL_NAMES[i])
		assert_eq(def.ticks * def.length, range_ticks(def.name), def.name)
		-- Each cascade step of one interval is exactly one sample of the next.
		if defs[i + 1] then assert_eq(def.ticks * def.steps, defs[i + 1].ticks, def.name) else assert_eq(def.steps, nil) end
	end
end)

test("utilization locale: the chart's keys are in en, the table's are gone from every locale", function()
	local en = H.locale_text("en")
	for _, key in ipairs({ "utilization-tab", "utilization-item-filter-note", "train-types", "no-analytics-data",
		"time-range", "analytics-library-missing" }) do
		assert_true(en:find("\n" .. key .. "=", 1, true) ~= nil, key)
	end
	for _, lang in ipairs(H.LOCALES) do
		local text = H.locale_text(lang)
		for _, key in ipairs({ "utilization-header", "utilization-period-tooltip", "utilization-col-busy", "utilization-empty" }) do
			assert_true(text:find("\n" .. key .. "=", 1, true) == nil, lang .. " " .. key)
		end
	end
end)

-- A stand-in for factorio-charts that records what analytics.init frees and allocates.
local function with_charts(fn)
	local destroyed, created = {}, 0
	local surface = { valid = true, index = 9 }
	local fake = {
		create_surface = function()
			created = created + 1
			return { surface = surface, chunk_freelist = {}, next_chunk_x = 0, next_chunk_y = 0 }
		end,
		create_time_series = function(defs)
			local set = {}
			for i, def in ipairs(defs) do set[i] = { name = def.name, line_ids = {}, guis = {}, viewer_count = 0 } end
			return set
		end,
		destroy_render_objects = function(ids)
			for _, id in ipairs(ids) do destroyed[#destroyed + 1] = id end
		end,
		interactive = { destroy = function(state) destroyed[#destroyed + 1] = state end },
	}
	package.preload["__factorio-charts__.charts"] = function() return fake end
	local ok, err = pcall(function()
		local a = loadfile("cybersyn/scripts/analytics.lua")()
		game.forces = {}
		fn(a, destroyed, function() return created end)
	end)
	package.preload["__factorio-charts__.charts"] = nil
	package.loaded["__factorio-charts__.charts"] = nil
	if not ok then error(err, 0) end
end

test("migrate: a series of another shape drops every chart and restarts chunk allocation", function()
	H.fresh()
	with_charts(function(a, destroyed, created)
		local old_cursor = { surface = { valid = true }, chunk_freelist = {}, next_chunk_x = 1, next_chunk_y = 0 }
		storage.analytics = {
			surface_data = old_cursor,
			train_utilization = { { name = "5s", line_ids = { "u1" }, chunk = { coord = { x = 0, y = 0 } } } },
			fulfillment_times = { { name = "5s", line_ids = { "f1" } } },
			total_delivery_times = { { name = "5s", line_ids = { "t1" } } },
			breakdown_interval = { name = "breakdown", line_ids = { "b1" }, chunk = { coord = { x = 0, y = 0 } } },
			fulfillment_ema = {}, total_time_ema = {}, delivery_counts = {},
			delivery_starts = {},
		}
		a.migrate(storage)
		local data = storage.analytics
		table.sort(destroyed)
		assert_eq(destroyed, { "b1", "f1", "t1", "u1" })
		assert_eq(created(), 1)
		assert_true(data.surface_data ~= old_cursor, "a fresh allocation cursor")
		assert_eq(data.surface_data.next_chunk_x, 0)
		assert_nil(data.breakdown_interval)
		assert_eq(#data.train_utilization, #a.UTILIZATION_INTERVALS)
		for _, key in ipairs({ "fulfillment_times", "total_delivery_times", "fulfillment_ema", "total_time_ema",
			"delivery_counts" }) do
			assert_nil(data[key], key)
		end
		-- The current shape keeps its charts and cursor.
		local kept = data.surface_data
		data.breakdown_interval = { line_ids = { "b2" } }
		a.migrate(storage)
		assert_eq(#destroyed, 4)
		assert_true(storage.analytics.surface_data == kept)
		assert_not_nil(storage.analytics.breakdown_interval)
	end)
end)

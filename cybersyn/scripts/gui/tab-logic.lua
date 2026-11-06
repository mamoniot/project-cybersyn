-- Decisions the Stations, Trains and Inventory tabs make from plain values: which columns a page hides,
-- which state chip a train shows, composition strings, deficits, chip membership, column widths. No game API here, so
-- every rule has a host unit test (tests/unit/tab_logic_test.lua).

local logic = {}

-- ---------------------------------------------------------------- columns

--- Whether every row gives the same value for a column; such a column is hidden and its value named in a header
--- tooltip instead. nil is a value like any other, so an all-nil column (electric fuel, never refuelled) is uniform.
--- @param rows any[]
--- @param key_fn fun(row: any): any
--- @return boolean uniform true for an empty list
--- @return any value the shared value when uniform
function logic.single_value(rows, key_fn)
	local n = #rows
	if n == 0 then return true, nil end
	local first = key_fn(rows[1])
	for i = 2, n do
		if key_fn(rows[i]) ~= first then return false, nil end
	end
	return true, first
end

--- Splits `available` px between fixed columns and one flexible column. Columns are {key, width, min?}; a hidden key
--- takes nothing. While the flexible column would fall below `flex_min`, the shrinkable columns (those with a `min`)
--- give up width in list order down to their minimum.
--- @param columns {[1]: string, [2]: int, min: int?}[]
--- @param hidden {[string]: true}?
--- @param available int px for all columns together, spacing excluded
--- @param flex string the flexible column's key
--- @param flex_min int
--- @return {[string]: int}
function logic.allocate(columns, hidden, available, flex, flex_min)
	hidden = hidden or {}
	local out, fixed = {}, 0
	for _, c in ipairs(columns) do
		local key = c[1]
		if key ~= flex and not hidden[key] then
			out[key] = c[2]
			fixed = fixed + c[2]
		end
	end
	local rest = available - fixed
	if rest < flex_min then
		for _, c in ipairs(columns) do
			local key = c[1]
			if c.min and out[key] and rest < flex_min then
				local give = math.min(out[key] - c.min, flex_min - rest)
				if give > 0 then
					out[key] = out[key] - give
					rest = rest + give
				end
			end
		end
	end
	out[flex] = math.max(rest, 0)
	return out
end

--- The Trains detail pane and the gap before it: the table is this much narrower while it shows.
-- The 300 px train panel inside 12 px insets.
logic.PANE_WIDTH = 324
logic.PANE_GAP = 12

-- The pane's fixed parts around its camera and the train panel's scroll body: the pane's subheader 36, the mount's
-- paddings 24, the panel's footer 40 and the frames' borders 8 (the panel's own subheader and paused banner are
-- hidden in the pane: the pane's subheader and the tab's banner say the same).
logic.PANE_FIXED = 36 + 24 + 40 + 8
logic.PANE_CAMERA_GAP = 12
logic.PANE_CAMERA_HEIGHT = 180
logic.PANE_CAMERA_MIN = 90
logic.PANE_BODY_MIN = 120

--- How the pane's height splits between the camera and the train panel's scroll body: the body keeps
--- PANE_BODY_MIN first, the camera shrinks to make room and is dropped below PANE_CAMERA_MIN.
--- @param height int the pane's height in logical px
--- @return int camera the camera's height, 0 = no camera
--- @return int body the scroll body's height cap, never negative
function logic.pane_split(height)
	local camera = math.min(logic.PANE_CAMERA_HEIGHT,
		height - logic.PANE_FIXED - logic.PANE_CAMERA_GAP - logic.PANE_BODY_MIN)
	if camera < logic.PANE_CAMERA_MIN then camera = 0 end
	local body = height - logic.PANE_FIXED - (camera > 0 and camera + logic.PANE_CAMERA_GAP or 0)
	return camera, math.max(body, 0)
end

--- The width the Trains table's columns share: the tab's content width, less the detail pane while it shows.
--- @param content_width int
--- @param pane boolean
--- @return int
function logic.table_width(content_width, pane)
	if pane then return content_width - logic.PANE_WIDTH - logic.PANE_GAP end
	return content_width
end

-- ---------------------------------------------------------------- Trains table widths

local TRAIN_SLOT = 32
--- A depot group row's compositions slot, its Problems marker and its stats run ("Parked 3 / 4 · Inbound 1 ·
--- Trains 5"), in px; the depot name is cut at GROUP_NAME_MAX so the run starts in the row's left part.
logic.GROUP_COMPS = 220
logic.GROUP_MARKER = 110
logic.GROUP_MARKER_ICON = 28
logic.GROUP_STATS = 300
logic.GROUP_BYPASS = 90
logic.GROUP_NAME_MAX = 200
-- Row padding and frame borders, and the gap between two shown columns.
local ROW_PADDING, COLUMN_GAP = 20, 8

--- The Trains table's columns in display order: {key, width, min = shrinkable down to}; the status takes the rest.
--- Widths are fixed because a Factorio table sizes columns to content and cannot fit a width and hide the overflow.
logic.TRAIN_WIDTHS = {
	{ "train_id", 52 },
	{ "train_status", 0 },
	{ "network", 96, min = 64 },
	{ "layout", 112, min = 80 },
	{ "depot", 150, min = 100 },
	{ "state", 64 },
	{ "time_in_state", 72 },
	{ "last_refuel", 80 },
	{ "fuel", 52 },
	{ "shipment", 6 * TRAIN_SLOT, min = 3 * TRAIN_SLOT },
}
logic.TRAIN_STATUS_MIN = 260
--- These go one at a time while the status would stay under its minimum after the shrinkable columns gave up their
--- room (a window narrower than about 1,100 px drops columns even with the pane closed). With the detail pane open,
--- Shipment goes first (the pane shows the cargo), but only then: a wide window keeps it rather than give the status
--- all the room. Id, status and state always stay.
logic.TRAIN_DROP = { "last_refuel", "fuel", "layout", "network", "depot", "time_in_state" }
logic.TRAIN_PANE_DROP = { "shipment", "last_refuel", "fuel", "layout", "network", "depot", "time_in_state" }

--- Column widths of the Trains table. The table is narrower by the detail pane while it shows; columns the pane
--- pushed out are reported in `dropped` and have no width, like the `hidden` ones. Shipment is cut to whole slots,
--- what that leaves goes to the status. The depot group rows keep their name at 120 px or more by dropping the
--- compositions note, then the Bypassed chip.
--- @param content_width int
--- @param hidden {[string]: true} columns hidden because every listed train shares their value
--- @param pane boolean
--- @return {[string]: int|boolean|table} w width per shown column, cw (table width), dropped, group_name, group_comps, group_bypass
function logic.train_widths(content_width, hidden, pane)
	local cw = logic.table_width(content_width, pane)
	local h, dropped = {}, {}
	for k in pairs(hidden) do h[k] = true end
	local order = pane and logic.TRAIN_PANE_DROP or logic.TRAIN_DROP
	local next_drop = 0
	local w
	while true do
		local shown = 0
		for _, c in ipairs(logic.TRAIN_WIDTHS) do
			if not h[c[1]] then shown = shown + 1 end
		end
		w = logic.allocate(logic.TRAIN_WIDTHS, h, cw - ROW_PADDING - (shown - 1) * COLUMN_GAP, "train_status",
			logic.TRAIN_STATUS_MIN)
		if w.train_status >= logic.TRAIN_STATUS_MIN then break end
		local key
		repeat
			next_drop = next_drop + 1
			key = order[next_drop]
		until key == nil or not h[key]
		if not key then break end
		h[key] = true
		dropped[key] = true
	end
	local shipment = w.shipment
	if shipment then
		w.shipment = math.max(TRAIN_SLOT, math.floor(shipment / TRAIN_SLOT) * TRAIN_SLOT)
		w.train_status = w.train_status + math.max(shipment - w.shipment, 0)
	end
	w.cw = cw
	w.dropped = dropped
	-- Group row: toggle 28, name, Problems marker 110, the stats run 300, Bypassed 90, a pusher, compositions 220 at the
	-- right end; the name takes the rest up to GROUP_NAME_MAX. Below 120 px of name the compositions go, then
	-- Bypassed, then the marker keeps its icon only.
	local name = cw - ROW_PADDING - 6 * COLUMN_GAP - 28 - logic.GROUP_MARKER - logic.GROUP_STATS - logic.GROUP_BYPASS
		- logic.GROUP_COMPS
	w.group_comps, w.group_bypass, w.group_marker = true, true, logic.GROUP_MARKER
	if name < 120 then
		w.group_comps = false
		name = name + logic.GROUP_COMPS
	end
	if name < 120 then
		w.group_bypass = false
		name = name + logic.GROUP_BYPASS
	end
	if name < 120 then
		w.group_marker = logic.GROUP_MARKER_ICON
		name = name + logic.GROUP_MARKER - logic.GROUP_MARKER_ICON
	end
	w.group_name = math.min(logic.GROUP_NAME_MAX, name)
	return w
end

--- How many slots of a one-line slot strip show items when `n` items share `capacity` slots: when they do not all
--- fit, the last slot becomes the "+n" overflow count, so a row never wraps.
--- @param n int
--- @param capacity int
--- @return int shown
--- @return int overflow items not shown (0 when all fit)
function logic.fit_slots(n, capacity)
	if capacity < 1 then return 0, n end
	if n <= capacity then return n, 0 end
	local shown = capacity - 1
	return shown, n - shown
end

-- ---------------------------------------------------------------- trains

--- A signal wait shorter than this is ordinary traffic (diag.WAIT_SIGNAL_MIN).
logic.WAIT_SIGNAL_MIN = 600

--- LuaTrain.state names that are a train's normal work: no icon in its row.
local QUIET = { on_the_path = true, wait_station = true, arrive_station = true }
local SIGNAL = { arrive_signal = true, wait_signal = true }

-- Red: the train will not move again without help; orange: it waits on something that may clear by itself.
local STATE_STYLE = {
	no_path = "red",
	path_lost = "red",
	no_schedule = "red",
	destination_full = "orange",
	manual_control = "orange",
	manual_control_stop = "orange",
}

--- The icon of every train state the manager names (every defines.train_state, plus the two Cybersyn conditions
--- "residue" and "refuel" that replace a quiet state). Fluids are the mod's hidden alert icons (prototypes/misc.lua).
logic.STATE_SPRITE = {
	on_the_path = "item/locomotive",
	path_lost = "fluid/cybersyn-lost-train",
	no_schedule = "utility/rail_path_not_possible",
	no_path = "utility/no_path_icon",
	arrive_signal = "item/rail-signal",
	wait_signal = "item/rail-signal",
	arrive_station = "item/train-stop",
	wait_station = "item/train-stop",
	manual_control_stop = "utility/hand",
	manual_control = "utility/hand",
	destination_full = "utility/destination_full_icon",
	residue = "fluid/cybersyn-nonempty-train",
	refuel = "virtual-signal/signal-fuel",
}
--- Used for "refuel" where a mod removes or hides the base signal-fuel.
logic.REFUEL_FALLBACK = "utility/fuel_icon"

--- Two units at most, so it fits a narrow value column and one duration reads the same in every tab: "42s", "3m 05s",
--- "1h 05m", "2d 03h". Lives here rather than in util so the pure modules can format durations without the game API.
--- @param ticks number
--- @return string
function logic.short_duration(ticks)
	local s = math.floor(math.max(ticks or 0, 0) / 60)
	if s < 60 then return s .. "s" end
	local m = math.floor(s / 60)
	if m < 60 then return string.format("%dm %02ds", m, s % 60) end
	local h = math.floor(m / 60)
	if h < 24 then return string.format("%dh %02dm", h, m % 60) end
	return string.format("%dd %02dh", math.floor(h / 24), h % 24)
end

--- Full precision for tooltips: "1h 2m 3s", "2m 3s" or "3s".
--- @param ticks number
--- @return string
function logic.format_duration(ticks)
	local seconds = math.floor(math.max(ticks or 0, 0) / 60)
	local minutes = math.floor(seconds / 60)
	local hours = math.floor(minutes / 60)
	if hours > 0 then
		return string.format("%dh %dm %ds", hours, minutes % 60, seconds % 60)
	elseif minutes > 0 then
		return string.format("%dm %ds", minutes, seconds % 60)
	end
	return string.format("%ds", seconds)
end

--- @class StateChip
--- @field key string the state name, "residue", "refuel" or "unknown"
--- @field sprite string the state's icon (STATE_SPRITE)
--- @field style "red"|"orange"|"grey"|nil the slot colour; nil = a quiet state, no icon in a Trains row
--- @field caption LocalisedString the one wording of the state ([cybersyn-diag] train-state-*)
--- @field tooltip LocalisedString "<caption> · <age>", the caption alone without an age

--- What every place that names a train's state shows (Trains rows, the train panel, the Log): one wording, one
--- icon, one colour. A signal wait or approach of at least WAIT_SIGNAL_MIN is orange, a shorter one grey.
--- @param state string? LuaTrain.state as its defines.train_state name
--- @param since number? tick the train entered the state
--- @param now number? the current tick
--- @param status "residue"|"refuel"|nil a Cybersyn condition: residue (parked with cargo) wins over any state,
---   refuel replaces a quiet one
--- @return StateChip
function logic.state_chip(state, since, now, status)
	local key, style
	if status == "residue" then
		key, style = "residue", "orange"
	elseif not state then
		key = "unknown"
	elseif QUIET[state] then
		key = state
		if status == "refuel" then key, style = "refuel", "grey" end
	elseif SIGNAL[state] then
		key = state
		style = (since and now and now - since >= logic.WAIT_SIGNAL_MIN) and "orange" or "grey"
	else
		key = state
		style = STATE_STYLE[state] or "grey"
	end
	local caption = { "cybersyn-diag.train-state-" .. string.gsub(key, "_", "-") }
	local tooltip = caption
	if since and now then tooltip = { "", caption, " · ", logic.short_duration(now - since) } end
	return {
		key = key,
		sprite = logic.STATE_SPRITE[key] or "utility/questionmark",
		style = style,
		caption = caption,
		tooltip = tooltip,
	}
end

--- The Trains tab's In trouble chip: every engine state whose icon is red or orange (no path, path lost, no schedule,
--- destination full, manual control, a signal of at least WAIT_SIGNAL_MIN). Residue is orange too but is cargo, not
--- a state: Cybersyn's nonempty_in_depot alert brings those trains in (trains.lua train_in_trouble).
--- @param state string?
--- @param waited number ticks in that state
--- @return boolean
function logic.in_trouble(state, waited)
	if not state or QUIET[state] then return false end
	if SIGNAL[state] then return (waited or 0) >= logic.WAIT_SIGNAL_MIN end
	return true
end

--- Sort rank of a state for the State column: red first, then orange, the signal states, the quiet ones, none.
--- Fixed per state, so the order does not move while a wait ages past WAIT_SIGNAL_MIN.
--- @param state string?
--- @return string
function logic.state_sort_key(state)
	if not state then return "5" end
	local style = STATE_STYLE[state]
	if style == "red" then return "1" .. state end
	if style == "orange" then return "2" .. state end
	if SIGNAL[state] then return "3" .. state end
	return "4" .. state
end

--- The lines of a depot group tooltip's "Trains by state", in display order: one per engine state, worded and drawn
--- by state_chip like everywhere else, plus "unknown" for a train without one, so every train counts on one line.
logic.STATE_BUCKETS = { "on_the_path", "arrive_station", "wait_station", "arrive_signal", "wait_signal",
	"manual_control_stop", "manual_control", "no_path", "path_lost", "no_schedule", "destination_full", "unknown" }
local IS_BUCKET = {}
for _, b in ipairs(logic.STATE_BUCKETS) do IS_BUCKET[b] = true end

--- The tooltip line of a LuaTrain state; a state the list does not know (a newer engine) counts as unknown.
--- @param state string?
--- @return string
function logic.state_bucket(state)
	return (state and IS_BUCKET[state]) and state or "unknown"
end

--- The state_chip of a tooltip line.
--- @param bucket string
--- @return StateChip
function logic.bucket_chip(bucket)
	return logic.state_chip(bucket ~= "unknown" and bucket or nil)
end

--- Composition string of a Cybersyn layout (0 = locomotive or any other carriage, 1 = cargo wagon, 2 = fluid wagon):
--- L for a locomotive, C and F for wagons, each run of wagons in angle brackets, so a 1-2-1 train reads "L<CC>L".
--- @param layout int[]
--- @return string
function logic.composition(layout)
	local out, n, open = {}, 0, false
	for i = 1, #layout do
		local c = layout[i]
		if c == 1 or c == 2 then
			if not open then
				n = n + 1
				out[n] = "<"
				open = true
			end
			n = n + 1
			out[n] = c == 1 and "C" or "F"
		else
			if open then
				n = n + 1
				out[n] = ">"
				open = false
			end
			n = n + 1
			out[n] = "L"
		end
	end
	if open then out[n + 1] = ">" end
	return table.concat(out)
end

--- The icon of each carriage class of a Cybersyn layout (layout.lua: 0 = locomotive or any other carriage,
--- 1 = cargo wagon, 2 = fluid wagon; artillery wagons are class 0).
logic.CLASS_SPRITE = { [0] = "item/locomotive", [1] = "item/cargo-wagon", [2] = "item/fluid-wagon" }
--- Composition icons are this wide; a run's count is the badge on its icon.
logic.COMPOSITION_ICON = 28

--- A layout as runs of one carriage class: {0, 1, 1, 0} -> {{class = 0, n = 1}, {class = 1, n = 2}, {class = 0, n = 1}}.
--- @param layout int[]
--- @return {class: int, n: int}[]
function logic.composition_runs(layout)
	local runs = {}
	local last
	for i = 1, #layout do
		local c = layout[i]
		if c ~= 0 and c ~= 1 and c ~= 2 then c = 0 end
		if last and last.class == c then
			last.n = last.n + 1
		else
			last = { class = c, n = 1 }
			runs[#runs + 1] = last
		end
	end
	return runs
end

--- One rich-text icon per carriage, for tooltips: "[item=locomotive][item=cargo-wagon][item=cargo-wagon]".
--- @param layout int[]
--- @return string
function logic.composition_icons(layout)
	local out = {}
	for i = 1, #layout do
		local c = layout[i]
		out[i] = c == 1 and "[item=cargo-wagon]" or c == 2 and "[item=fluid-wagon]" or "[item=locomotive]"
	end
	return table.concat(out)
end

-- A group row's composition: its icons, the "×273" label after them (px per character at the row font) and the gap.
local COMP_LABEL_PAD, COMP_CHAR, COMP_GAP, COMP_MORE = 4, 7, 12, 28

--- How many of a depot group's compositions (most trains first) its row shows as icon runs in `budget` px, at most
--- `max`; the rest go to a "+n" label. One is always shown when there is any.
--- @param list {runs: int, n: int}[] per composition: its run count and its trains
--- @param budget int
--- @param max int
--- @return int shown
--- @return int more
function logic.fit_compositions(list, budget, max)
	local used, shown = 0, 0
	for i, c in ipairs(list) do
		if i > max then break end
		local w = c.runs * logic.COMPOSITION_ICON + COMP_LABEL_PAD + COMP_CHAR * (#tostring(c.n) + 1)
		if i > 1 then w = w + COMP_GAP end
		local reserve = (i < #list) and COMP_MORE or 0
		if shown > 0 and used + w + reserve > budget then break end
		used = used + w
		shown = i
	end
	return shown, #list - shown
end

--- Ticks since `tick`, nil when there is none (never refuelled, no state change recorded).
--- @param now number
--- @param tick number?
--- @return number?
function logic.age(now, tick)
	if not tick then return nil end
	local d = now - tick
	return d > 0 and d or 0
end

--- Whether a train counts for the Not refuelled > N h chip: not seen at a refueler for longer than `hours`. A train
--- never seen at one gets the same time from `refuel_from` (lint.refuel_from: since Cybersyn first saw it, or since
--- refuels are tracked), the grace the lint gives it.
--- @param now number
--- @param refuel_tick number?
--- @param hours number
--- @param refuel_from number?
--- @return boolean
function logic.not_refuelled(now, refuel_tick, hours, refuel_from)
	local since = refuel_tick or refuel_from
	if not since then return true end
	return now - since > hours * 216000
end

--- The next tick at which the passing of time alone changes a train's time-dependent chips (In trouble by a long
--- signal wait, Not refuelled), or nil when nothing will: the chip counts stay valid until the earliest such tick.
--- @param now number
--- @param state string? LuaTrain.state as its defines.train_state name
--- @param state_since number?
--- @param refuel_since number? refuel_tick, else the train's refuel grace start (refuel_from); nil = never refuelled
--- @param hours number
--- @param has_refueler boolean
--- @return number?
function logic.chip_change_tick(now, state, state_since, refuel_since, hours, has_refueler)
	local t
	if SIGNAL[state] and state_since then
		local at = state_since + logic.WAIT_SIGNAL_MIN
		if at > now then t = at end
	end
	if has_refueler and refuel_since then
		local at = math.floor(refuel_since + hours * 216000) + 1
		if at > now and (not t or at < t) then t = at end
	end
	return t
end

--- A duration caption with "never" for no tick: the Last refuel and Last delivery cells.
--- @param now number
--- @param tick number?
--- @return string|nil caption nil = never
--- @return number? age
function logic.age_caption(now, tick)
	local age = logic.age(now, tick)
	if not age then return nil, nil end
	return logic.short_duration(age), age
end

--- Fuel of a train as a percentage of what its burners hold when full, averaged over the locomotives that burn
--- fuel; nil when none does (electric).
--- @param locos {energy: number, capacity: number}[]
--- @return int?
function logic.fuel_percent(locos)
	local sum, n = 0, 0
	for _, l in ipairs(locos) do
		n = n + 1
		if l.capacity > 0 then sum = sum + math.min(l.energy / l.capacity, 1) end
	end
	if n == 0 then return nil end
	return math.floor(100 * sum / n + 0.5)
end

--- Rows of the Trains tab grouped by depot: one group row per name (sorted), followed by its trains when expanded.
--- Group rows count as rows for paging.
--- @param names string[] group names in display order
--- @param members {[string]: any[]} the trains of each group, in display order
--- @param expanded {[string]: true}?
--- @return {group: string, train: any?}[]
function logic.group_rows(names, members, expanded)
	local out = {}
	expanded = expanded or {}
	for _, name in ipairs(names) do
		out[#out + 1] = { group = name }
		if expanded[name] then
			for _, tr in ipairs(members[name] or {}) do
				out[#out + 1] = { group = name, train = tr }
			end
		end
	end
	return out
end

--- The Trains chips in subheader order; "all" clears the chip.
logic.TRAIN_CHIPS = { "all", "parked", "to_p", "loading", "to_r", "unloading", "returning", "refuel", "interrupt",
	"not_refuelled", "in_group", "trouble", "problems" }

--- The Trains chip a Cybersyn train status belongs to, or nil for a custom status. Reads the STATUS_* globals of
--- scripts/constants.lua.
--- @param status int?
--- @return string?
function logic.train_chip(status)
	if status == STATUS_D then return "parked" end
	if status == STATUS_TO_P then return "to_p" end
	if status == STATUS_P then return "loading" end
	if status == STATUS_TO_R then return "to_r" end
	if status == STATUS_R then return "unloading" end
	if status == STATUS_TO_D or status == STATUS_TO_D_BYPASS then return "returning" end
	if status == STATUS_TO_F or status == STATUS_F then return "refuel" end
	return nil
end

--- The locale key of a Trains chip caption (the Trains subheader and the drill-down's train status).
--- @param key string one of TRAIN_CHIPS
--- @return string
function logic.train_chip_locale(key)
	return "cybersyn-gui.trains-chip-" .. string.gsub(key, "_", "-")
end

--- Which chips a tab shows, and on which line: a chip with nothing to show is hidden unless marked `keep` (All, the
--- toggled chip, a count still being worked out); the chips take the subheader's line while they fit beside what else
--- it shows and continue on a second line below it, in order and never abbreviated. What does not fit there either is
--- dropped, except the selected chip, so a filter in force always stays visible.
--- @param chips {key: string, width: int, count: int?, keep: boolean?}[] in display order, widths with their spacing
--- @param selected string? the toggled chip's key
--- @param space1 int px left in the subheader
--- @param space2 int px of the second line
--- @return string[] line1
--- @return string[] line2
function logic.chip_lines(chips, selected, space1, space2)
	local line1, line2 = {}, {}
	local used1, used2 = 0, 0
	local second = false
	for _, c in ipairs(chips) do
		if c.keep or (c.count and c.count > 0) then
			local w = c.width
			if not second and used1 + w <= space1 then
				line1[#line1 + 1] = c.key
				used1 = used1 + w
			else
				second = true
				if used2 + w <= space2 or c.key == selected then
					line2[#line2 + 1] = c.key
					used2 = used2 + w
				end
			end
		end
	end
	return line1, line2
end

--- The hours of the Not refuelled chip as the caption and the tooltip show them: "1", "0.25", "2.75", "12.5".
--- @param hours number
--- @return string
function logic.hours_caption(hours)
	local s = string.format("%.2f", hours)
	s = string.gsub(s, "0+$", "")
	return (string.gsub(s, "%.$", ""))
end

-- ---------------------------------------------------------------- stations

--- Severity order: the Stations status sort and filter chips follow it. The collector's statuses plus "setup", which
--- the Stations tab and the stop panel show in place of "ok" (problems-model shown_status).
logic.STATUSES = { "no_power", "disabled", "warming_up", "starved", "setup", "saturated", "idle", "ok" }
--- flib_indicator_<colour> per status in logic.STATUSES.
logic.STATUS_COLOR = {
	no_power = "red",
	disabled = "purple",
	warming_up = "cyan",
	starved = "pink",
	setup = "yellow",
	saturated = "orange",
	idle = "white",
	ok = "green",
}

--- Locale key of a station status caption; append "-tooltip" for its explanation.
--- @param status string
--- @return string
function logic.status_key(status)
	return "cybersyn-gui.station-status-" .. string.gsub(status, "_", "-")
end

logic.FLAG_UNSERVED = 1
logic.FLAG_SETUP = 2
logic.FLAG_THROTTLING = 4
logic.FLAG_NO_POWER = 8
logic.FLAG_DISABLED = 16
logic.FLAG_STUCK = 32
--- Failing = no power + disabled + throttling + setup (the Overview's Stations failing tile).
logic.FAILING = 8 + 16 + 4 + 2

--- Chip membership of a station record, without the stuck flag (that one comes from the trains).
--- @param st {status: string?, unserved: {count: int}?, lint: int?, throttling: boolean?}
--- @return int
function logic.station_flags(st)
	local f = 0
	local u = st.unserved
	if u and u.count > 0 then f = f + logic.FLAG_UNSERVED end
	if (st.lint or 0) ~= 0 then f = f + logic.FLAG_SETUP end
	if st.throttling then f = f + logic.FLAG_THROTTLING end
	if st.status == "no_power" then f = f + logic.FLAG_NO_POWER end
	if st.status == "disabled" then f = f + logic.FLAG_DISABLED end
	return f
end

--- Stations named by a train with a stuck alert as its provider or requester.
--- @param alerts {train_id: uint, kind: int}[]
--- @param trains {[uint]: {p_station_id: uint?, r_station_id: uint?}}
--- @param stuck_kind int
--- @return {[uint]: true}
function logic.stuck_stations(alerts, trains, stuck_kind)
	local out = {}
	for _, a in ipairs(alerts or {}) do
		if a.kind == stuck_kind then
			local tr = trains[a.train_id]
			if tr then
				if tr.p_station_id then out[tr.p_station_id] = true end
				if tr.r_station_id then out[tr.r_station_id] = true end
			end
		end
	end
	return out
end

-- ---------------------------------------------------------------- inventory

--- What one network is still short of: requested − in transit − the providers' stock not yet promised to a delivery
--- (their signals plus their negative, outgoing deliveries). Stock already promised is in transit too, so it is
--- subtracted once. Never below 0: a surplus on one network covers nothing on another.
--- @param requested number? magnitude or the requested grid's negative count
--- @param in_transit number?
--- @param stock number? provider signals plus outgoing (negative) deliveries
--- @return number
function logic.deficit(requested, in_transit, stock)
	local short = math.abs(requested or 0) - (in_transit or 0) - math.max(stock or 0, 0)
	return short > 0 and short or 0
end

--- Provided items that no requester on the same network asks for: the provide keys ("network:hash") without a
--- matching request key, folded to item hashes. With `network`, only that network's keys count.
--- @param provide_keys {[string]: any}
--- @param request_keys {[string]: any}
--- @param network string?
--- @return {[string]: true}
function logic.unrequested(provide_keys, request_keys, network)
	local provided, matched = {}, {}
	local find, sub = string.find, string.sub
	for key in pairs(provide_keys) do
		local s = find(key, ":", 1, true)
		if s and (not network or sub(key, 1, s - 1) == network) then
			local hash = sub(key, s + 1)
			provided[hash] = true
			if request_keys[key] then matched[hash] = true end
		end
	end
	for hash in pairs(matched) do provided[hash] = nil end
	return provided
end

-- ---------------------------------------------------------------- throughput period

--- Minutes of the Overview's period buttons; the Item view follows the same choice.
logic.PERIODS = { 10, 60, 1440 }
logic.DEFAULT_PERIOD = 60

--- The player's throughput period, repairing a missing or stale value in place so every reader sees the same one.
--- @param player_data PlayerData
--- @return int minutes
function logic.get_period(player_data)
	local period = player_data.tabs.overview_tab.period
	if period ~= 10 and period ~= 60 and period ~= 1440 then
		period = logic.DEFAULT_PERIOD
		player_data.tabs.overview_tab.period = period
	end
	return period
end

-- ---------------------------------------------------------------- duration axis (Delivery breakdown)

--- Gridline steps of a duration axis, in seconds: each one formats exactly ("1m 30s", never a rounded "2m").
logic.DURATION_STEPS = { 1, 2, 5, 10, 15, 20, 30, 60, 90, 120, 180, 300, 600, 900, 1200, 1800, 3600, 5400, 7200,
	10800, 21600, 43200, 86400 }
--- Gridlines above 0 an axis shows at most.
logic.DURATION_LINES = 5

--- "0s", "30s", "1m", "1m 30s", "2h", "1h 30m": whole seconds, zero parts left out, so a gridline says exactly where it
--- sits.
--- @param seconds number
--- @return string
function logic.duration_label(seconds)
	local s = math.floor(seconds + 0.5)
	if s <= 0 then return "0s" end
	local h, m = math.floor(s / 3600), math.floor(s % 3600 / 60)
	s = s % 60
	local parts = {}
	if h > 0 then parts[#parts + 1] = h .. "h" end
	if m > 0 then parts[#parts + 1] = m .. "m" end
	if s > 0 then parts[#parts + 1] = s .. "s" end
	return table.concat(parts, " ")
end

--- The gridlines of a duration axis whose top is `max_seconds`: 0 and every multiple of the smallest step that leaves
--- at most DURATION_LINES lines above 0 and none above the top.
--- @param max_seconds number
--- @return {value: number, label: string}[]
function logic.duration_ticks(max_seconds)
	local steps = logic.DURATION_STEPS
	local step = steps[#steps]
	for _, s in ipairs(steps) do
		if max_seconds / s <= logic.DURATION_LINES then
			step = s
			break
		end
	end
	local out = {}
	for i = 0, math.max(0, math.floor(max_seconds / step)) do
		out[#out + 1] = { value = i * step, label = logic.duration_label(i * step) }
	end
	return out
end


--- How many open and acknowledged rows the Overview's Unserved page shows. With Show acknowledged on, the acknowledged
--- rows sink to the bottom but may take up to half the page, so turning the toggle on always shows them
--- even when the open rows alone would fill the page; open rows that run short leave the rest to acknowledged ones.
--- @param rows int page rows
--- @param open_n int open rows available
--- @param acked_n int acknowledged rows available
--- @param show boolean? Show acknowledged
--- @return int open_take
--- @return int acked_take
function logic.unserved_split(rows, open_n, acked_n, show)
	if rows <= 0 then return 0, 0 end
	if not show then return math.min(open_n, rows), 0 end
	local reserve = math.min(acked_n, math.max(1, math.floor(rows / 2)))
	local open_take = math.min(open_n, rows - reserve)
	return open_take, math.min(acked_n, rows - open_take)
end

return logic

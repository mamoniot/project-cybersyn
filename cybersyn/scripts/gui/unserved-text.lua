-- Captions and tooltips of the Overview's Unserved requests table. Pure: every function takes plain values and
-- returns strings or LocalisedStrings, so the host unit tests cover them without the engine.

local format = require("__flib__.format")
local logic = require("scripts.gui.tab-logic")
local CHIP_STYLE = require("scripts.gui.problems-model").CHIP_STYLE

local text = {}

text.NO_VALUE = "–"
text.INHERITED = "≥"

--- Chip style by the reason's severity: red = nothing changes on its own, orange = waiting on stock or capacity,
--- grey = a setting of the player's.
--- @param reason int REASON_*
--- @return string
function text.chip_style(reason)
	return CHIP_STYLE[REASON_SEVERITY[reason] or DIAG_SEV_INFO]
end

--- @param reason int
--- @return LocalisedString
function text.chip_caption(reason)
	local key = REASON_KEYS[reason]
	if not key then return { "cybersyn-gui.unserved-unknown-reason" } end
	return { "cybersyn-diag.chip-" .. key }
end

local COUNT_SUFFIXES = { { 1e9, "G" }, { 1e6, "M" }, { 1e3, "k" } }

--- Counts in the Overview tiles: exact below 10,000, then "12.3k" (one decimal, rounded down, none when it is 0), so
--- a number is never cut to "…"; the tile's tooltip carries the exact figure.
--- @param n number?
--- @return string
function text.count(n)
	if n == nil then return text.NO_VALUE end
	if math.abs(n) < 10000 then return format.number(n) end
	for _, s in ipairs(COUNT_SUFFIXES) do
		if math.abs(n) >= s[1] then
			local v = math.floor(n / s[1] * 10) / 10
			return string.format(v % 1 == 0 and "%d%s" or "%.1f%s", v, s[2])
		end
	end
end

--- "1.2k / 2.0k" for stock against what is needed; train counts for the train-side reasons.
--- @param reason int
--- @param a int payload
--- @param b int
--- @return LocalisedString
function text.stock_caption(reason, a, b)
	a, b = a or 0, b or 0
	if reason == REASON_P_BELOW_THRESHOLD or reason == REASON_P_RESERVED then
		return format_signal_count(a) .. " / " .. format_signal_count(b)
	elseif reason == REASON_CAPACITY then
		-- What the largest eligible train carries, against what the request needs.
		return format_signal_count(b) .. " / " .. format_signal_count(a)
	elseif reason == REASON_R_AT_LIMIT or reason == REASON_P_AT_LIMIT or reason == REASON_R_DISABLED then
		return { "cybersyn-gui.unserved-stock-trains", tostring(a), tostring(b) }
	elseif reason == REASON_NO_TRAINS_ON_NETWORK then
		return { "cybersyn-gui.unserved-stock-no-trains" }
	elseif reason == REASON_TRAIN_FILTERED then
		return { "cybersyn-gui.unserved-stock-filtered", format.number(a) }
	elseif reason == REASON_R_IS_PROVIDING or reason == REASON_P_IS_REQUESTING then
		return format_signal_count(a)
	end
	return text.NO_VALUE
end

--- Wait column: two units at most, "≥" when the entry predates this diagnostics state (the save load), so the wait is
--- a lower bound rather than a measurement.
--- @param ticks number
--- @param inherited boolean
--- @return string
function text.wait_caption(ticks, inherited)
	return (inherited and text.INHERITED or "") .. logic.short_duration(ticks)
end

--- The "why" line's parameters: __1__ = a, __2__ = b, __3__ = network, __4__..__6__ = the train-filter split.
--- @param reason int
--- @param a int
--- @param b int
--- @param network LocalisedString? the requester's network as rich text
--- @param rej int[]? REJ_* counters of the latest evaluation
--- @param surface_name fun(index: int): string? surface name by index, for NO_SURFACE_ROUTE
--- @return LocalisedString
function text.why(reason, a, b, network, rej, surface_name)
	local key = REASON_KEYS[reason]
	if not key then return { "cybersyn-gui.unserved-unknown-reason" } end
	local p1, p2
	if reason == REASON_MASK_MISMATCH then
		p1, p2 = tostring(a or 0), tostring(b or 0)
	elseif reason == REASON_NO_SURFACE_ROUTE then
		p1 = surface_name and surface_name(a) or tostring(a or 0)
		p2 = surface_name and surface_name(b) or tostring(b or 0)
	else
		p1, p2 = format.number(a or 0), format.number(b or 0)
	end
	local mask, manual, surface = "0", "0", "0"
	if rej then
		mask = format.number(rej[REJ_TRAIN_MASK] or 0)
		manual = format.number(rej[REJ_TRAIN_MANUAL] or 0)
		surface = format.number(rej[REJ_TRAIN_SURFACE] or 0)
	end
	return { "cybersyn-diag.why-" .. key, p1, p2, network or "?", mask, manual, surface }
end

--- @param reason int
--- @param network LocalisedString? the requester's network, __1__ in the fix keys that name it
--- @return LocalisedString
function text.fix(reason, network)
	local key = REASON_KEYS[reason]
	if not key then return "" end
	return { "cybersyn-diag.fix-" .. key, network or "?" }
end

--- @class UnservedTipArgs
--- @field item LocalisedString "[img] Item name"
--- @field requested number? amount the requester asks for (positive); nil when the snapshot does not know it
--- @field requester LocalisedString the requester's name
--- @field reason int
--- @field a int
--- @field b int
--- @field network LocalisedString?
--- @field rej int[]?
--- @field wait int ticks since first_tick
--- @field inherited boolean first_tick inside diagnostics' inherited window (diag.inherit_threshold)
--- @field n int failing evaluations
--- @field read_age int? ticks since the requester was last read by the collector
--- @field surface_name (fun(index: int): string)?

--- The four lines of a reason chip: what is asked, why it is not served, what to do, and how long.
--- @param args UnservedTipArgs
--- @return LocalisedString
function text.chip_tooltip(args)
	local asked
	if args.requested then
		asked = { "cybersyn-gui.unserved-asked", args.item, format.number(args.requested), args.requester }
	else
		asked = { "cybersyn-gui.unserved-asked-no-amount", args.item, args.requester }
	end
	local since_key = args.inherited and "cybersyn-gui.unserved-since-load" or "cybersyn-gui.unserved-since"
	local since = { since_key, logic.format_duration(args.wait), tostring(args.n or 0) }
	if args.read_age then
		since = { "", since, " · ", text.read_ago(args.read_age) }
	end
	return {
		"", asked,
		"\n", { "cybersyn-gui.unserved-why", text.why(args.reason, args.a, args.b, args.network, args.rej, args.surface_name) },
		"\n", { "cybersyn-gui.unserved-fix", text.fix(args.reason, args.network) },
		"\n", since,
	}
end

--- Ages shown in tooltips are rounded down to READ_STEP, so a tooltip is rebuilt at most once per step.
text.READ_STEP = 600

--- "read 20s ago", rounded down to text.READ_STEP.
--- @param ticks number
--- @return LocalisedString
function text.read_ago(ticks)
	if ticks < text.READ_STEP then return { "cybersyn-gui.read-just-now" } end
	return { "cybersyn-gui.read-ago", logic.format_duration(ticks - ticks % text.READ_STEP) }
end

--- Rounded age for a sig, matching text.read_ago.
--- @param ticks number?
--- @return int
function text.read_step(ticks)
	if not ticks then return -1 end
	return math.floor(ticks / text.READ_STEP)
end

-- ---------------------------------------------------------------- inventories (secondary inventory combinators)

--- The combinator row of `st` that advertises `hash` on `side` ("provided" or "requested"), for a station with
--- inventory combinators; nil for a plain station, whose texts name the station's network as before. Of several, the
--- first with an active request (the one the dispatcher is trying to serve), else the first.
--- @param st table? SnapshotStation
--- @param hash string
--- @param side "provided"|"requested"
--- @param inventories (fun(st: table): SnapshotInventory[])? collector.inventories
--- @return SnapshotInventory?
function text.inventory_of(st, hash, side, inventories)
	if not (st and inventories) then return nil end
	local rows = inventories(st)
	if #rows < 2 then return nil end
	local first
	for _, row in ipairs(rows) do
		local v = row[side] and row[side][hash]
		if v then
			if side ~= "requested" or v.active then return row end
			first = first or row
		end
	end
	return first
end

return text

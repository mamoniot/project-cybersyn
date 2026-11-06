-- Texts of the setup lint's findings (shown in the Stations tab's Problems column): the order a station's findings
-- are shown in, the sort rank of a station's lint mask, and the captions, chips, fix lines and detail numbers of a
-- finding. Pure: plain tables in, plain tables and LocalisedStrings out, so the host unit tests cover it without the
-- engine.

local format = require("__flib__.format")

local model = {}

model.CHIP_STYLE = {
	[DIAG_SEV_ERROR] = "cybersyn_chip_red",
	[DIAG_SEV_WARNING] = "cybersyn_chip_orange",
	[DIAG_SEV_INFO] = "cybersyn_chip_grey",
}
model.DOT = {
	[DIAG_SEV_ERROR] = "flib_indicator_red",
	[DIAG_SEV_WARNING] = "flib_indicator_orange",
	[DIAG_SEV_INFO] = "flib_indicator_cyan",
}
model.ACKED_DOT = "flib_indicator_white"

-- A check's place in the worst-first order: severity first, then the check index.
local RANK_STEP = 64

--- @param check int
--- @return int
function model.rank(check)
	return (LINT_SEVERITY[check] or DIAG_SEV_WARNING) * RANK_STEP + check
end

--- The rank of the worst check in a station's lint mask (the Problems column's sort key), nil when the mask is clean.
--- @param mask int?
--- @return int?
function model.mask_rank(mask)
	if not mask or mask == 0 then return nil end
	local best
	for check = 1, LINT_COUNT do
		if bit32.btest(mask, LINT_BIT[check]) then
			local r = model.rank(check)
			if not best or r < best then best = r end
		end
	end
	return best
end

-- A station whose findings are all acknowledged ranks after every open one: past the worst severity's ranks.
local ACKED_RANK = (DIAG_SEV_INFO + 1) * RANK_STEP

local error_mask

--- The bits of the error-severity checks.
--- @return int
function model.error_mask()
	if not error_mask then
		local m = 0
		for check = 1, LINT_COUNT do
			if LINT_SEVERITY[check] == DIAG_SEV_ERROR then m = bit32.bor(m, LINT_BIT[check]) end
		end
		error_mask = m
	end
	return error_mask
end

--- The bits of a station's lint mask whose finding is not acknowledged.
--- @param id uint station id (lint.subject_key of a station)
--- @param bits int? the station's lint bits (SnapshotStation.lint)
--- @param is_acked fun(kind: string, id: uint, check: int): any diag.is_acked
--- @return int
function model.open_mask(id, bits, is_acked)
	local open = bits or 0
	local rest, check = open, 1
	while rest ~= 0 do
		if bit32.btest(rest, 1) and is_acked("lint", id, check) then open = open - LINT_BIT[check] end
		rest = bit32.rshift(rest, 1)
		check = check + 1
	end
	return open
end

--- The Overview's Misconfigured rule for one station: how many of its error-severity checks are not
--- acknowledged. The Stations Problems view ranks exactly these stations first and counts them in its subfooter, so
--- the line and the rows it jumps to agree.
--- @param id uint
--- @param bits int?
--- @param is_acked fun(kind: string, id: uint, check: int): any diag.is_acked
--- @param by_check {[int]: int}? adds 1 per open check
--- @return int open
function model.open_errors(id, bits, is_acked, by_check)
	local mask = bit32.band(bits or 0, model.error_mask())
	local open, check = 0, 1
	while mask ~= 0 do
		if bit32.btest(mask, 1) and not is_acked("lint", id, check) then
			open = open + 1
			if by_check then by_check[check] = (by_check[check] or 0) + 1 end
		end
		mask = bit32.rshift(mask, 1)
		check = check + 1
	end
	return open
end

--- A station's place in the Problems view: its worst open check, so stations with an open error lead (the ones the
--- Overview's Misconfigured line counts), then open warnings and info; a station whose findings are all acknowledged
--- follows every open one, by its worst check. nil when the mask is clean.
--- @param id uint
--- @param bits int?
--- @param is_acked fun(kind: string, id: uint, check: int): any diag.is_acked
--- @return int?
function model.station_rank(id, bits, is_acked)
	if not bits or bits == 0 then return nil end
	local r = model.mask_rank(model.open_mask(id, bits, is_acked))
	if r then return r end
	return ACKED_RANK + model.mask_rank(bits)
end

--- The status a view shows for a station: "setup" in place of "ok" while an error-severity finding
--- nobody acknowledged blocks it, so a station the Overview's Misconfigured line counts never reads "OK". Every other
--- status already says why nothing moves and stays.
--- @param status string? SnapshotStation.status
--- @param id uint
--- @param bits int? the station's lint bits
--- @param is_acked fun(kind: string, id: uint, check: int): any diag.is_acked
--- @return string
function model.shown_status(status, id, bits, is_acked)
	status = status or "ok"
	if status == "ok" and bits and bits ~= 0 and model.open_errors(id, bits, is_acked) > 0 then return "setup" end
	return status
end

-- Checks a Setup status tooltip names; a LocalisedString holds at most 20 parameters.
local SETUP_TOOLTIP_CHECKS = 8

--- The error checks of a station nobody acknowledged, in check order, and their mask (a cache key).
--- @param id uint
--- @param bits int?
--- @param is_acked fun(kind: string, id: uint, check: int): any diag.is_acked
--- @return int[] checks
--- @return int mask
function model.open_error_checks(id, bits, is_acked)
	local mask = bit32.band(model.open_mask(id, bits, is_acked), model.error_mask())
	local checks = {}
	if mask ~= 0 then
		for check = 1, LINT_COUNT do
			if bit32.btest(mask, LINT_BIT[check]) then checks[#checks + 1] = check end
		end
	end
	return checks, mask
end

--- The tooltip of a Setup status: what it means, then the open error checks by name.
--- @param checks int[] model.open_error_checks
--- @return LocalisedString
function model.setup_status_tooltip(checks)
	local tip = { "", { "cybersyn-gui.station-status-setup-tooltip" } }
	for i, check in ipairs(checks) do
		if i > SETUP_TOOLTIP_CHECKS then
			tip[#tip + 1] = "\n+" .. (#checks - SETUP_TOOLTIP_CHECKS)
			break
		end
		tip[#tip + 1] = "\n"
		tip[#tip + 1] = model.caption(check)
	end
	return tip
end

--- @class ProblemEntry
--- @field f LintFinding
--- @field sev int DIAG_SEV_*
--- @field ack DiagAck? the acknowledgement while it holds

--- A station's findings in the order its cell shows them: not acknowledged first, then worst severity, check, what
--- the finding is about and the subject id, so the first entry is the one the cell spells out.
--- @param list LintFinding[]
--- @param is_acked fun(f: LintFinding): DiagAck?
--- @return ProblemEntry[]
function model.order(list, is_acked)
	local out = {}
	for i, f in ipairs(list) do
		out[i] = { f = f, sev = LINT_SEVERITY[f.check] or DIAG_SEV_WARNING, ack = is_acked(f) }
	end
	table.sort(out, function(a, b)
		local aa, ba = a.ack ~= nil, b.ack ~= nil
		if aa ~= ba then return ba end
		if a.sev ~= b.sev then return a.sev < b.sev end
		local fa, fb = a.f, b.f
		if fa.check ~= fb.check then return fa.check < fb.check end
		local ka, kb = tostring(fa.item or fa.message or ""), tostring(fb.item or fb.message or "")
		if ka ~= kb then return ka < kb end
		if fa.subject ~= fb.subject then return fa.subject < fb.subject end
		return fa.id < fb.id
	end)
	return out
end

-- ---------------------------------------------------------------- captions

--- @param check int
--- @return LocalisedString
function model.caption(check)
	return { "cybersyn-diag.lint-" .. (LINT_KEYS[check] or "unknown") }
end

--- The chip's short caption (the group row carries the full one).
--- @param check int
--- @return LocalisedString
function model.chip(check)
	return { "cybersyn-diag.lint-chip-" .. (LINT_KEYS[check] or "unknown") }
end

--- The fix line: what to change, without the numbers (they are in the detail column). A finding that names its own
--- fix (a phantom delivery's counter leak) gets that one.
--- @param check int
--- @param f LintFinding?
--- @return LocalisedString
function model.fix(check, f)
	if f and f.fix then return { "cybersyn-diag.lint-fix-" .. f.fix } end
	return { "cybersyn-diag.lint-fix-" .. (LINT_KEYS[check] or "unknown") }
end

--- @class ProblemsEnv
--- @field item fun(hash: string?): string rich-text icon of an item or fluid hash ("" when none)
--- @field network fun(name: string?): string rich-text icon of a network signal
--- @field is_fluid fun(hash: string?): boolean
--- @field duration fun(ticks: number): string
--- @field count (fun(n: number): string)? an amount as the other cells write it ("2.0k"); format.number without it

local HOUR_TICKS = 216000

--- The numbers behind a finding, for the detail column ("[item] needs 2.0k (400 stacks) · largest train 40 stacks"):
--- what tells two findings of one check apart (the item, its amount) comes first, so a cut cell still shows it.
--- @param f LintFinding
--- @param env ProblemsEnv
--- @return LocalisedString
function model.detail(f, env)
	local count = env.count
	local function n(v)
		if count then return count(v or 0) end
		return format.number(v or 0)
	end
	local check, a, b = f.check, f.a or 0, f.b or 0
	local key = "cybersyn-diag.lint-detail-" .. (LINT_KEYS[check] or "unknown")
	if check == LINT_CAPACITY then
		if env.is_fluid(f.item) then
			return { key .. "-fluid", env.item(f.item), n(a), n(b) }
		end
		-- The threshold as typed, then the stacks the trains are measured in.
		if f.c then return { key .. "-threshold", env.item(f.item), n(f.c), n(a), n(b) } end
		return { key, env.item(f.item), n(a), n(b) }
	elseif check == LINT_LAYOUT then
		if f.item then return { key .. "-item", env.item(f.item), n(a), n(b), env.network(f.network) } end
		return { key, n(a), n(b), env.network(f.network) }
	elseif check == LINT_MASK then
		return { key .. "-zero", env.network(f.network) }
	elseif check == LINT_PHANTOM then
		if f.train then
			local status = { "cybersyn-diag.lint-train-status-" .. (f.status or 0) }
			-- The counter says how many trains, not which: with several bound, the one named may be one it counts.
			if b > 1 then return { key .. "-trains", tostring(f.train), status, n(b), n(a) } end
			return { key .. "-train", tostring(f.train), status, n(a) }
		end
		if a > b then
			if b == 0 then return { key .. "-leak", n(a) } end
			return { key .. "-leak-bound", n(a), n(b), n(a - b) }
		end
	elseif check == LINT_OCCUPANCY and f.train then
		return { key .. "-train", tostring(f.train), n(b), n(a) }
	elseif check == LINT_NO_PROVIDER then
		return { key, env.item(f.item), env.network(f.network) }
	elseif check == LINT_SAME_ITEM then
		if a == 0 then return { key .. "-static", env.item(f.item) } end
		return { key .. (b == 1 and "-in" or "-out"), env.item(f.item), n(a) }
	elseif check == LINT_DEPOT_LIMIT then
		if a < 0 then return { key .. "-none" } end
		return { key, n(a) }
	elseif check == LINT_REFUELER_MASK or check == LINT_TRAIN_MASK then
		return { key, tostring(a), tostring(b), env.network(f.network) }
	elseif check == LINT_NEVER_REFUELLED then
		-- Whole hours: the tracked time grows on every pass, and the row must not change with it.
		return { key, env.network(f.network), env.duration(a - a % HOUR_TICKS) }
	elseif check == LINT_NO_TRAIN then
		return { key, env.network(f.network) }
	elseif f.message then
		return { "cybersyn-gui.problems-world-" .. f.message }
	end
	-- limit_zero, occupancy, phantom, depot_shared_name, in_group, missing_stop, capacity_drift: two counts.
	return { key, n(a), n(b) }
end

--- A signature of model.detail's inputs, for the row sig.
--- @param f LintFinding
--- @return string
function model.detail_sig(f)
	local a = f.a
	if f.check == LINT_NEVER_REFUELLED and a then a = math.floor(a / HOUR_TICKS) end
	return tostring(a) .. ":" .. tostring(f.b) .. ":" .. tostring(f.network) .. ":" .. tostring(f.item) .. ":" .. tostring(f.c) ..
		":" .. tostring(f.train) .. ":" .. tostring(f.status)
end

return model

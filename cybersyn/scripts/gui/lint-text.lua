-- Game-facing texts of the setup lint's findings, shared by the Stations Problems column, the stop and train panels
-- and Explain: the rich-text environment problems-model.detail renders numbers with, the per-check caption/tooltip set
-- and the side of a station a finding predicts the dispatcher's reason for. problems-model keeps the pure parts.

local logic = require("scripts.gui.tab-logic")
local links = require("scripts.gui.utils.links")
local rich_text = require("scripts.gui.rich-text")
local lint = require("scripts.lint")
local pm = require("scripts.gui.problems-model")

local lint_text = {}

--- @param hash string?
--- @return string
local function item_icon(hash)
	if not hash then return "" end
	return rich_text.of_hash(hash)
end

--- @param hash string?
--- @return boolean
local function is_fluid(hash)
	if not hash then return false end
	local name = unhash_signal(hash)
	return prototypes.fluid[name] ~= nil
end

--- @type ProblemsEnv
lint_text.ENV = { item = item_icon, network = rich_text.network_icon, is_fluid = is_fluid, duration = logic.short_duration,
	count = format_signal_count }

-- Captions and tooltips that depend only on the check, the side of the station it predicts for and the finding's
-- own fix variant (f.fix, a small fixed set): built once per Lua state. A pure function of its key, so a cache that
-- differs between states cannot desync anything.
local check_text = {}

--- @param check int
--- @param role "r"|"p"|nil nil when the subject is not a station
--- @param f LintFinding? the finding, when it may carry its own fix line (a counter leak reads "Recount deliveries")
--- @return {key: string, caption: LocalisedString, chip: LocalisedString, fix: LocalisedString, tooltip: LocalisedString, linked: LocalisedString}
function lint_text.texts(check, role, f)
	local variant = f and f.fix
	local key = check .. (role or "-") .. (variant or "")
	local t = check_text[key]
	if t then return t end
	local code = role and lint.predicts(check, role) or nil
	local predicts = code and { "cybersyn-gui.problems-predicts", { "cybersyn-diag.chip-" .. REASON_KEYS[code] } }
		or { "cybersyn-gui.problems-predicts-none" }
	local fix = pm.fix(check, f)
	local tooltip = { "cybersyn-gui.problems-chip-tooltip", pm.caption(check), predicts, fix,
		{ "cybersyn-diag.sev-" .. DIAG_SEV_NAMES[LINT_SEVERITY[check] or DIAG_SEV_WARNING] } }
	t = {
		key = key,
		caption = pm.caption(check),
		chip = pm.chip(check),
		fix = fix,
		tooltip = tooltip,
		linked = { "", tooltip, "\n", links.LINK_FOOTER },
	}
	check_text[key] = t
	return t
end

--- The side of a station a finding predicts the dispatcher's reason for: the provider's when the finding is about
--- what the stop provides (an item on its way in) or the stop only provides.
--- @param f LintFinding
--- @param snapshot Snapshot
--- @return "r"|"p"|nil
function lint_text.role_of(f, snapshot)
	if f.subject ~= LINT_SUBJECT_STATION then return nil end
	if f.check == LINT_SAME_ITEM then return f.b == 1 and "p" or "r" end
	local st = snapshot.stations[f.id]
	if st and st.is_p and not st.is_r then return "p" end
	return "r"
end

return lint_text

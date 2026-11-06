--By Mami

MISSING_TRAIN_NAME = "cybersyn-missing-train"
LOST_TRAIN_NAME = "cybersyn-lost-train"
NONEMPTY_TRAIN_NAME = "cybersyn-nonempty-train"

SIGNAL_PRIORITY = "cybersyn-priority"
REQUEST_THRESHOLD = "cybersyn-request-threshold"
REQUEST_FLUID_THRESHOLD = "cybersyn-fluid-request-threshold"
LOCKED_SLOTS = "cybersyn-locked-slots"
RESERVED_FLUID_CAPACITY = "cybersyn-reserved-fluid-capacity"

COMBINATOR_NAME = "cybersyn-combinator"
COMBINATOR_OUT_NAME = "cybersyn-combinator-output"
COMBINATOR_CLOSE_SOUND = "entity-close/cybersyn-combinator"
ALERT_SOUND = "utility/console_message"

MODE_DEFAULT = "*"
MODE_PRIMARY_IO = "/"
MODE_PRIMARY_IO_FAILED_REQUEST = "^"
MODE_PRIMARY_IO_ACTIVE = "<<"
MODE_SECONDARY_IO = "%"
MODE_SECONDARY_INVENTORY = "AND"
-- Not a mode: the red I an inventory combinator shows while its own request goes unserved, the same display trick
-- as the red S (MODE_PRIMARY_IO_FAILED_REQUEST). A blueprint taken while it is red captures OR, which
-- combinator_build_init turns back into AND, and every operation comparison goes through is_secondary_inventory_op.
MODE_SECONDARY_INVENTORY_FAILED = "OR"
MODE_DEPOT = "+"
MODE_WAGON = "-"
MODE_REFUELER = ">>"

SETTING_DISABLE_ALLOW_LIST = 2
SETTING_IS_STACK = 3
SETTING_ENABLE_INACTIVE = 4
SETTING_USE_ANY_DEPOT = 5
SETTING_DISABLE_DEPOT_BYPASS = 6
SETTING_ENABLE_SLOT_BARRING = 7
SETTING_ENABLE_CIRCUIT_CONDITION = 8
SETTING_ENABLE_TRAIN_COUNT = 9
SETTING_ENABLE_MANUAL_INVENTORY = 10
SETTING_DISABLE_MANIFEST_CONDITION = 11

-- Default second_constant bits for newly placed combinators (bit flags).
-- Build a mask with set_flag(n) to make adding/removing defaults clear and safe.
local function set_flag(n) return bit32.lshift(1, n) end
COMBINATOR_DEFAULT_SECOND_CONSTANT = bit32.bor(
	set_flag(SETTING_ENABLE_TRAIN_COUNT),
	set_flag(SETTING_USE_ANY_DEPOT)
)

NETWORK_SIGNAL_DEFAULT = { name = "signal-A", type = "virtual" }
NETWORK_SIGNAL_GUI_DEFAULT = { name = "signal-each", type = "virtual" }
NETWORK_ANYTHING = "signal-anything"
NETWORK_EACH = "signal-each"
INACTIVITY_TIME = 100
LOCK_TRAIN_TIME = 60 * 60 * 60 * 24 * 7
NO_PATH_SKIP_TIME = 5 * 60 -- 5s

DELTA = 1 / 2048

DEPOT_PRIORITY_MULT = 2048

PROVIDER_ID_ITEM = "cybersyn-provider-id"
REQUESTER_ID_ITEM = "cybersyn-requester-id"
REFUELER_ID_ITEM = "cybersyn-refueler-id"

STATUS_D = 0
STATUS_TO_P = 1
STATUS_P = 2
STATUS_TO_R = 3
STATUS_R = 4
STATUS_TO_D = 5
STATUS_TO_D_BYPASS = 6
STATUS_TO_F = 7
STATUS_F = 8
STATUS_CUSTOM = 256 --this status and any status greater than it can be used by other mods (I've reserved the lower integers for myself in case I want to add more statuses)
-- A train bound to a delivery: to the provider, loading, to the requester, unloading.
STATUS_ON_DELIVERY = { [STATUS_TO_P] = true, [STATUS_P] = true, [STATUS_TO_R] = true, [STATUS_R] = true }

FAILURE_REASON_NO_PROVIDER_STOCK = 0
FAILURE_REASON_NO_TRAIN_AVAILABLE = 1
FAILURE_REASON_TRAIN_CAPACITY = 2
FAILURE_REASON_LAYOUT_MISMATCH = 3

-- What a carriage in a train layout is (map_data.layouts, set_train_layout).
---@alias TrainWagonKind
---| 0 # WAGON_LOCO
---| 1 # WAGON_CARGO
---| 2 # WAGON_FLUID

WAGON_LOCO = 0
WAGON_CARGO = 1
WAGON_FLUID = 2

-- What a wagon position at a stop can load (stop.layout_pattern). Bits of the wagon kinds: both is cargo | fluid.
---@alias StopWagonSupport
---| 0 # PATTERN_NONE
---| 1 # PATTERN_CARGO
---| 2 # PATTERN_FLUID
---| 3 # PATTERN_BOTH

PATTERN_NONE = 0
PATTERN_CARGO = 1
PATTERN_FLUID = 2
PATTERN_BOTH = 3

LONGEST_INSERTER_REACH = 2

STATE_INIT = 0
STATE_POLL_STATIONS = 1
STATE_DISPATCH = 2

DIFFERENT_SURFACE_DISTANCE = 1000000000

-- A stop with its train limit disabled reads back the largest uint; anything this close to it counts as no limit.
TRAIN_LIMIT_UNLIMITED = 2100000000

-- Diagnostics (scripts/diag.lua). Reason codes name the tick_dispatch site that rejected a request.
-- Lost priority is a counter on an entry; P_RESERVED is the reason of a requester whose only provider was locked by
-- a requester evaluated ahead of it although it held enough for this one. There is no "no path" reason (the
-- planner never paths).
---@alias DiagReason
---| 1 # REASON_NO_PROVIDER
---| 2 # REASON_R_AT_LIMIT
---| 3 # REASON_R_DISABLED
---| 4 # REASON_R_IS_PROVIDING
---| 5 # REASON_P_AT_LIMIT
---| 6 # REASON_P_IS_REQUESTING
---| 7 # REASON_MASK_MISMATCH
---| 8 # REASON_NO_SURFACE_ROUTE
---| 9 # REASON_P_BELOW_THRESHOLD
---| 10 # REASON_NO_TRAINS_ON_NETWORK
---| 11 # REASON_TRAIN_FILTERED
---| 12 # REASON_CAPACITY
---| 13 # REASON_R_LAYOUT
---| 14 # REASON_P_LAYOUT
---| 15 # REASON_ALL_IN_INTERRUPT
---| 16 # REASON_P_RESERVED

REASON_NO_PROVIDER = 1
REASON_R_AT_LIMIT = 2
REASON_R_DISABLED = 3
REASON_R_IS_PROVIDING = 4
REASON_P_AT_LIMIT = 5
REASON_P_IS_REQUESTING = 6
REASON_MASK_MISMATCH = 7
REASON_NO_SURFACE_ROUTE = 8
REASON_P_BELOW_THRESHOLD = 9
REASON_NO_TRAINS_ON_NETWORK = 10
REASON_TRAIN_FILTERED = 11
REASON_CAPACITY = 12
REASON_R_LAYOUT = 13
REASON_P_LAYOUT = 14
REASON_ALL_IN_INTERRUPT = 15
REASON_P_RESERVED = 16

REASON_NAMES = {
	"NO_PROVIDER", "R_AT_LIMIT", "R_DISABLED", "R_IS_PROVIDING", "P_AT_LIMIT", "P_IS_REQUESTING", "MASK_MISMATCH",
	"NO_SURFACE_ROUTE", "P_BELOW_THRESHOLD", "NO_TRAINS_ON_NETWORK", "TRAIN_FILTERED", "CAPACITY", "R_LAYOUT",
	"P_LAYOUT", "ALL_IN_INTERRUPT", "P_RESERVED",
}
--- Locale key suffix per reason: [cybersyn-diag] reason-<key>, chip-<key>, why-<key>, fix-<key>.
REASON_KEYS = {}
REASON_BY_NAME = {}
for code, name in ipairs(REASON_NAMES) do
	REASON_KEYS[code] = string.gsub(string.lower(name), "_", "-")
	REASON_BY_NAME[name] = code
end
---@alias DiagSev
---| 1 # DIAG_SEV_ERROR
---| 2 # DIAG_SEV_WARNING
---| 3 # DIAG_SEV_INFO

DIAG_SEV_ERROR = 1
DIAG_SEV_WARNING = 2
DIAG_SEV_INFO = 3
DIAG_SEV_NAMES = { "error", "warning", "info" }

--- DIAG_SEV_* per reason, also its chip colour: error (red) = nothing will change on its own, warning (orange) =
--- waiting on stock or capacity, info (grey) = by design (a setting of the player's). Also the order of "worst
--- reason" for a station. An unknown reason counts as info.
local E, W, I = DIAG_SEV_ERROR, DIAG_SEV_WARNING, DIAG_SEV_INFO
REASON_SEVERITY = {
	[REASON_NO_PROVIDER] = E, [REASON_R_AT_LIMIT] = W, [REASON_R_DISABLED] = I, [REASON_R_IS_PROVIDING] = I,
	[REASON_P_AT_LIMIT] = W, [REASON_P_IS_REQUESTING] = I, [REASON_MASK_MISMATCH] = E, [REASON_NO_SURFACE_ROUTE] = E,
	[REASON_P_BELOW_THRESHOLD] = W, [REASON_NO_TRAINS_ON_NETWORK] = E, [REASON_TRAIN_FILTERED] = E,
	[REASON_CAPACITY] = E, [REASON_R_LAYOUT] = E, [REASON_P_LAYOUT] = E, [REASON_ALL_IN_INTERRUPT] = W,
	[REASON_P_RESERVED] = W,
}

-- Rejection counters of one evaluation (an unserved entry's `rej`): the five provider sites in the order a provider
-- passes them, then the three causes of a train filtered at correctness 1.
---@alias Rej
---| 1 # REJ_P_AT_LIMIT
---| 2 # REJ_P_IS_REQUESTING
---| 3 # REJ_MASK_MISMATCH
---| 4 # REJ_NO_SURFACE_ROUTE
---| 5 # REJ_P_BELOW_THRESHOLD
---| 6 # REJ_TRAIN_MASK
---| 7 # REJ_TRAIN_MANUAL
---| 8 # REJ_TRAIN_SURFACE

REJ_P_AT_LIMIT = 1
REJ_P_IS_REQUESTING = 2
REJ_MASK_MISMATCH = 3
REJ_NO_SURFACE_ROUTE = 4
REJ_P_BELOW_THRESHOLD = 5
REJ_TRAIN_MASK = 6
REJ_TRAIN_MANUAL = 7
REJ_TRAIN_SURFACE = 8
REJ_COUNT = 8
REJ_NAMES = {
	"P_AT_LIMIT", "P_IS_REQUESTING", "MASK_MISMATCH", "NO_SURFACE_ROUTE", "P_BELOW_THRESHOLD", "TRAIN_MASK",
	"TRAIN_MANUAL", "TRAIN_SURFACE",
}
REJ_REASON = {
	REASON_P_AT_LIMIT, REASON_P_IS_REQUESTING, REASON_MASK_MISMATCH, REASON_NO_SURFACE_ROUTE, REASON_P_BELOW_THRESHOLD,
}

-- Event kinds of the two rings; what each kind's columns hold is DIAG_KIND_SCHEMA.
-- Kinds are positional (saved rings and exports hold the numbers): new kinds are appended.
---@alias DiagKind
---| 1 # DIAG_KIND_UNSERVED_REASON
---| 2 # DIAG_KIND_SERVED
---| 3 # DIAG_KIND_FLAPPING
---| 4 # DIAG_KIND_DISPATCH_FAILED
---| 5 # DIAG_KIND_DELIVERY_FAILED
---| 6 # DIAG_KIND_ALERT
---| 7 # DIAG_KIND_STATION_POWER
---| 8 # DIAG_KIND_STATION_LIMIT
---| 9 # DIAG_KIND_STATION_WARMUP_DONE
---| 10 # DIAG_KIND_STATION_DISABLED
---| 11 # DIAG_KIND_SHORT_LOAD
---| 12 # DIAG_KIND_UNEXPECTED_CARGO
---| 13 # DIAG_KIND_RESIDUAL_CARGO
---| 14 # DIAG_KIND_SCHEDULE_EDITED
---| 15 # DIAG_KIND_LINT
---| 16 # DIAG_KIND_ACKNOWLEDGED
---| 17 # DIAG_KIND_UNACKNOWLEDGED
---| 18 # DIAG_KIND_MANUAL_ACTION
---| 19 # DIAG_KIND_DISPATCHED
---| 20 # DIAG_KIND_ARRIVE_P
---| 21 # DIAG_KIND_LEAVE_P
---| 22 # DIAG_KIND_ARRIVE_R
---| 23 # DIAG_KIND_LEAVE_R
---| 24 # DIAG_KIND_RETURNED
---| 25 # DIAG_KIND_TRAIN_STATE
---| 26 # DIAG_KIND_SLOW_DELIVERY

DIAG_KIND_UNSERVED_REASON = 1
DIAG_KIND_SERVED = 2
DIAG_KIND_FLAPPING = 3
DIAG_KIND_DISPATCH_FAILED = 4
DIAG_KIND_DELIVERY_FAILED = 5
DIAG_KIND_ALERT = 6
DIAG_KIND_STATION_POWER = 7
DIAG_KIND_STATION_LIMIT = 8
DIAG_KIND_STATION_WARMUP_DONE = 9
DIAG_KIND_STATION_DISABLED = 10
DIAG_KIND_SHORT_LOAD = 11
DIAG_KIND_UNEXPECTED_CARGO = 12
DIAG_KIND_RESIDUAL_CARGO = 13
DIAG_KIND_SCHEDULE_EDITED = 14
DIAG_KIND_LINT = 15
DIAG_KIND_ACKNOWLEDGED = 16
DIAG_KIND_UNACKNOWLEDGED = 17
DIAG_KIND_MANUAL_ACTION = 18
DIAG_KIND_DISPATCHED = 19
DIAG_KIND_ARRIVE_P = 20
DIAG_KIND_LEAVE_P = 21
DIAG_KIND_ARRIVE_R = 22
DIAG_KIND_LEAVE_R = 23
DIAG_KIND_RETURNED = 24
DIAG_KIND_TRAIN_STATE = 25
DIAG_KIND_SLOW_DELIVERY = 26
DIAG_KIND_NAMES = {
	"unserved_reason", "served", "flapping", "dispatch_failed", "delivery_failed", "alert", "station_power",
	"station_limit", "station_warmup_done", "station_disabled", "short_load", "unexpected_cargo", "residual_cargo",
	"schedule_edited", "lint", "acknowledged", "unacknowledged", "manual_action", "dispatched", "arrive_p", "leave_p",
	"arrive_r", "leave_r", "returned", "train_state", "slow_delivery",
}
--- Locale key suffix per kind: [cybersyn-diag] kind-<key>.
DIAG_KIND_KEYS = {}
for kind, name in ipairs(DIAG_KIND_NAMES) do
	DIAG_KIND_KEYS[kind] = string.gsub(name, "_", "-")
end

-- `code` of an alert event: the alert that was sent. 1-10 match the ids active_alerts already uses.
---@alias DiagAlert
---| 1 # DIAG_ALERT_STUCK
---| 2 # DIAG_ALERT_NONEMPTY_IN_DEPOT
---| 3 # DIAG_ALERT_DEPOT_BROKEN
---| 4 # DIAG_ALERT_STATION_BROKEN
---| 5 # DIAG_ALERT_REFUELER_BROKEN
---| 6 # DIAG_ALERT_AT_INCORRECT_STATION
---| 7 # DIAG_ALERT_CANNOT_PATH_BETWEEN_SURFACES
---| 8 # DIAG_ALERT_GROUP_SCHEDULE_BROKEN
---| 9 # DIAG_ALERT_SCHEDULE_BROKEN
---| 10 # DIAG_ALERT_UNEXPECTED_CARGO
---| 11 # DIAG_ALERT_MISSING_TRAIN
---| 12 # DIAG_ALERT_NO_TRAIN_HAS_CAPACITY
---| 13 # DIAG_ALERT_NO_TRAIN_MATCHES_R_LAYOUT
---| 14 # DIAG_ALERT_NO_TRAIN_MATCHES_P_LAYOUT
---| 15 # DIAG_ALERT_NON_DEFAULT_PRIORITY
---| 16 # DIAG_ALERT_UNEXPECTED_TRAIN
---| 17 # DIAG_ALERT_TRAINS_FILTERED

DIAG_ALERT_STUCK = 1
DIAG_ALERT_NONEMPTY_IN_DEPOT = 2
DIAG_ALERT_DEPOT_BROKEN = 3
DIAG_ALERT_STATION_BROKEN = 4
DIAG_ALERT_REFUELER_BROKEN = 5
DIAG_ALERT_AT_INCORRECT_STATION = 6
DIAG_ALERT_CANNOT_PATH_BETWEEN_SURFACES = 7
DIAG_ALERT_GROUP_SCHEDULE_BROKEN = 8
DIAG_ALERT_SCHEDULE_BROKEN = 9
DIAG_ALERT_UNEXPECTED_CARGO = 10
DIAG_ALERT_MISSING_TRAIN = 11
DIAG_ALERT_NO_TRAIN_HAS_CAPACITY = 12
DIAG_ALERT_NO_TRAIN_MATCHES_R_LAYOUT = 13
DIAG_ALERT_NO_TRAIN_MATCHES_P_LAYOUT = 14
DIAG_ALERT_NON_DEFAULT_PRIORITY = 15
DIAG_ALERT_UNEXPECTED_TRAIN = 16
DIAG_ALERT_TRAINS_FILTERED = 17
DIAG_ALERT_NAMES = {
	"stuck", "nonempty_in_depot", "depot_broken", "station_broken", "refueler_broken", "at_incorrect_station",
	"cannot_path_between_surfaces", "group_schedule_broken", "schedule_broken", "unexpected_cargo", "missing_train",
	"no_train_has_capacity", "no_train_matches_r_layout", "no_train_matches_p_layout", "non_default_priority",
	"unexpected_train", "trains_filtered",
}

---@alias DiagDispatch
---| 1 # DIAG_DISPATCH_TRAIN_INVALID
---| 2 # DIAG_DISPATCH_DEPOT_INVALID
---| 3 # DIAG_DISPATCH_PROVIDER_INVALID
---| 4 # DIAG_DISPATCH_REQUESTER_INVALID
---| 5 # DIAG_DISPATCH_SCHEDULE_REJECTED
---| 6 # DIAG_DISPATCH_NO_PATH
---| 7 # DIAG_DISPATCH_PATH_BLOCKED
---| 8 # DIAG_DISPATCH_NO_PATH_AFTER_WRITE

-- `code` of a dispatch_failed event (create_delivery gave up after the planner chose a train).
DIAG_DISPATCH_TRAIN_INVALID = 1
DIAG_DISPATCH_DEPOT_INVALID = 2
DIAG_DISPATCH_PROVIDER_INVALID = 3
DIAG_DISPATCH_REQUESTER_INVALID = 4
-- set_manifest_schedule refused without naming a reason (6-8 are the reasons it names).
DIAG_DISPATCH_SCHEDULE_REJECTED = 5
-- A train heading back to its depot (bypass) has no route from where it is to the provider.
DIAG_DISPATCH_NO_PATH = 6
-- Same pre-check: a route exists, but its start cannot be reserved now (a busy chain-signalled section).
DIAG_DISPATCH_PATH_BLOCKED = 7
-- The orders were written, then LuaTrain.has_path was false: they stay on the train.
DIAG_DISPATCH_NO_PATH_AFTER_WRITE = 8
DIAG_DISPATCH_NAMES = { "train_invalid", "depot_invalid", "provider_invalid", "requester_invalid", "schedule_rejected",
	"no_path", "path_blocked", "no_path_after_write" }
-- 6 and 7 heal themselves (the train drives on, the request is retried next cycle); 8 leaves untracked orders.
DIAG_DISPATCH_SEVERITY = { DIAG_SEV_ERROR, DIAG_SEV_ERROR, DIAG_SEV_ERROR, DIAG_SEV_ERROR,
	DIAG_SEV_WARNING, DIAG_SEV_INFO, DIAG_SEV_INFO, DIAG_SEV_WARNING }

-- `code` of a delivery_failed event: who ended the delivery.
---@alias DiagFail
---| 1 # DIAG_FAIL_TRAIN_REMOVED
---| 2 # DIAG_FAIL_EARLY_TO_DEPOT
---| 3 # DIAG_FAIL_REMOTE
---| 4 # DIAG_FAIL_MANUAL

DIAG_FAIL_TRAIN_REMOVED = 1
DIAG_FAIL_EARLY_TO_DEPOT = 2
DIAG_FAIL_REMOTE = 3
DIAG_FAIL_MANUAL = 4
DIAG_FAIL_NAMES = { "train_removed", "early_to_depot", "remote_interface", "manual" }

-- `code` of acknowledged/unacknowledged events: what was acknowledged; `b` of unacknowledged: why it ended.
---@alias DiagAckKind
---| 1 # DIAG_ACK_REQUEST
---| 2 # DIAG_ACK_STATION
---| 3 # DIAG_ACK_LINT

DIAG_ACK_REQUEST = 1
DIAG_ACK_STATION = 2
DIAG_ACK_LINT = 3
DIAG_ACK_KINDS = { "request", "station", "lint" }
---@alias DiagAckEnd
---| 1 # DIAG_ACK_END_EXPIRED
---| 2 # DIAG_ACK_END_REASON_CHANGED
---| 3 # DIAG_ACK_END_RESOLVED
---| 4 # DIAG_ACK_END_MANUAL

DIAG_ACK_END_EXPIRED = 1
DIAG_ACK_END_REASON_CHANGED = 2
DIAG_ACK_END_RESOLVED = 3
DIAG_ACK_END_MANUAL = 4

-- Setup lint (scripts/lint.lua). A check is an index 1..LINT_COUNT; its bit in a subject's mask is
-- LINT_BIT[check]. Acknowledgements and the lint ring event (`a`) carry the index, so an index is never reused or
-- renumbered. The combinator and stop-name checks (derelict, ghost, no combinator, wrong side, double, name overlap)
-- come from the setup registry the build handlers keep; the others from the chunked job over storage and the
-- snapshot. LINT_MASK is "no network bit" (mask 0 on a network that has trains).
-- Check indices, written out so they are real globals (the loop below fills the name tables and verifies these).
LINT_CAPACITY = 1
LINT_LAYOUT = 2
LINT_MASK = 3
LINT_NO_PROVIDER = 4
LINT_LIMIT_ZERO = 5
LINT_SAME_ITEM = 6
LINT_OCCUPANCY = 7
LINT_PHANTOM = 8
LINT_DEPOT_LIMIT = 9
LINT_DEPOT_SHARED_NAME = 10
LINT_REFUELER_MASK = 11
LINT_NEVER_REFUELLED = 12
LINT_IN_GROUP = 13
LINT_MISSING_STOP = 14
LINT_CAPACITY_DRIFT = 15
LINT_DERELICT_COMB = 16
LINT_GHOST_COMB = 17
LINT_NO_COMB = 18
LINT_WRONG_SIDE = 19
LINT_DOUBLE_COMB = 20
LINT_PRIORITY = 21
LINT_NAME_OVERLAP = 22
LINT_TRAIN_MASK = 23
LINT_NO_TRAIN = 24
-- One row per check, in index order: name (LINT_<NAME> is its index; LINT_KEYS its locale suffix), DIAG_SEV_*
-- (errors guarantee a request is never served), the reason code it predicts on a requester and, where it differs,
-- on a provider (lint.predicts), and the [cybersyn-problems] messages of a registry check.
LINT_CHECKS = {
	{ "capacity", DIAG_SEV_ERROR, REASON_CAPACITY },
	{ "layout", DIAG_SEV_ERROR, REASON_R_LAYOUT, REASON_P_LAYOUT },
	{ "mask", DIAG_SEV_WARNING, REASON_MASK_MISMATCH },
	{ "no_provider", DIAG_SEV_ERROR, REASON_NO_PROVIDER },
	{ "limit_zero", DIAG_SEV_WARNING, REASON_R_DISABLED, REASON_P_AT_LIMIT },
	{ "same_item", DIAG_SEV_WARNING, REASON_R_IS_PROVIDING, REASON_P_IS_REQUESTING },
	{ "occupancy", DIAG_SEV_WARNING },
	{ "phantom", DIAG_SEV_ERROR, REASON_R_AT_LIMIT, REASON_P_AT_LIMIT },
	{ "depot_limit", DIAG_SEV_WARNING },
	{ "depot_shared_name", DIAG_SEV_WARNING },
	{ "refueler_mask", DIAG_SEV_WARNING },
	{ "never_refuelled", DIAG_SEV_INFO },
	{ "in_group", DIAG_SEV_WARNING },
	{ "missing_stop", DIAG_SEV_WARNING },
	{ "capacity_drift", DIAG_SEV_WARNING, REASON_CAPACITY },
	{ "derelict_comb", DIAG_SEV_WARNING, registry = { "derelict-combinator" } },
	{ "ghost_comb", DIAG_SEV_WARNING, registry = { "ghost-combinator" } },
	{ "no_comb", DIAG_SEV_WARNING, registry = { "stop-no-combinator" } },
	{ "wrong_side", DIAG_SEV_WARNING, registry = { "wrong-side-combinator" } },
	{ "double_comb", DIAG_SEV_ERROR, registry = { "double-station", "double-station-control", "double-depot",
		"double-refueler", "station-and-depot", "station-and-refueler", "depot-and-refueler" } },
	{ "priority", DIAG_SEV_ERROR },
	{ "name_overlap", DIAG_SEV_WARNING, registry = { "name-overlap-with-depot" } },
	{ "train_mask", DIAG_SEV_ERROR, REASON_TRAIN_FILTERED },
	{ "no_train", DIAG_SEV_ERROR, REASON_NO_TRAINS_ON_NETWORK },
}
LINT_COUNT = #LINT_CHECKS
LINT_NAMES, LINT_BY_NAME, LINT_KEYS, LINT_BIT = {}, {}, {}, {}
LINT_SEVERITY, LINT_PREDICTS, LINT_PREDICTS_P = {}, {}, {}
--- Registry checks, and the check each registry message belongs to.
LINT_REGISTRY_CHECKS, LINT_MESSAGE_CHECK = {}, {}
for check, c in ipairs(LINT_CHECKS) do
	local name = c[1]
	assert(_G["LINT_" .. string.upper(name)] == check, "LINT_" .. string.upper(name) .. " is out of step with LINT_CHECKS")
	LINT_NAMES[check] = name
	LINT_BY_NAME[name] = check
	LINT_KEYS[check] = string.gsub(name, "_", "-")
	LINT_BIT[check] = 2 ^ (check - 1)
	LINT_SEVERITY[check], LINT_PREDICTS[check], LINT_PREDICTS_P[check] = c[2], c[3], c[4]
	for _, m in ipairs(c.registry or {}) do
		LINT_REGISTRY_CHECKS[check] = true
		LINT_MESSAGE_CHECK[m] = check
	end
end
LINT_SUBJECT_STATION = 1
LINT_SUBJECT_DEPOT = 2
LINT_SUBJECT_REFUELER = 3
LINT_SUBJECT_TRAIN = 4
LINT_SUBJECT_STOP = 5
LINT_SUBJECT_COMBINATOR = 6
LINT_SUBJECT_NAMES = { "station", "depot", "refueler", "train", "stop", "combinator" }
-- `code` of a lint event: the finding appeared or cleared.
DIAG_LINT_APPEARED = 1
DIAG_LINT_CLEARED = 2

-- A train on a network some refueler serves counts as not refuelled (the lint, the Trains chip) once it went this
-- long without visiting one, measured from its first sighting (Train.seen_tick) and never from before refuel_tick
-- existed (storage.stats.refuel_since), so neither a new train nor one from an older save is flagged before it had
-- the chance to visit a refueler. One hour.
REFUEL_GRACE_TICKS = 216000

-- `a` of a manual_action event: what a state-changing command or action did.
---@alias DiagAction
---| 1 # ACTION_FIX_PRIORITIES
---| 2 # ACTION_ABOLISH_SAME_DEPOT
---| 3 # ACTION_RECALCULATE_TRAIN_SIZE
---| 4 # ACTION_FAIL_DELIVERY
---| 5 # ACTION_REFRESH_ALLOW_LISTS
---| 6 # ACTION_RECOUNT_DELIVERIES

ACTION_FIX_PRIORITIES = 1
ACTION_ABOLISH_SAME_DEPOT = 2
ACTION_RECALCULATE_TRAIN_SIZE = 3
ACTION_FAIL_DELIVERY = 4
ACTION_REFRESH_ALLOW_LISTS = 5
ACTION_RECOUNT_DELIVERIES = 6
ACTION_NAMES = { "fix_priorities", "abolish_same_depot", "recalculate_train_size", "fail_delivery",
	"refresh_allow_lists", "recount_deliveries" }

-- `a` of a dispatch_failed event: the train's defines.train_state plus this, so 0 can mean "not recorded"
-- (on_the_path is 0).
DIAG_STATE_OFFSET = 1
--- defines.train_state value -> name.
DIAG_TRAIN_STATE_NAMES = {}
for name, v in pairs(defines.train_state) do DIAG_TRAIN_STATE_NAMES[v] = name end

--- What the columns of each event kind hold, for every reader of the rings:
--- full: the kind goes to the full ring (written only in full mode), else to the basic ring;
--- station2: "station" (a second station: the provider, the other end of a delivery), "player" (a player index, 0 =
---   the server) or "subject" (a LINT_SUBJECT_*); nil when unused;
--- pass: the delivery column holds the lint pass key (diag.lint), not a delivery;
--- code_names: the name of each `code` (the CSV export);
--- a_named, b_named: `a` / `b` name what the event is about rather than measure it, so two events that differ there
---   are different events.
--- @type {[int]: {full: true?, station2: "station"|"player"|"subject"?, pass: true?, code_names: string[]?, a_named: true?, b_named: true?}}
DIAG_KIND_SCHEMA = {
	[DIAG_KIND_UNSERVED_REASON] = { station2 = "station", code_names = REASON_NAMES },
	[DIAG_KIND_SERVED] = { station2 = "station", code_names = REASON_NAMES },
	[DIAG_KIND_FLAPPING] = { station2 = "station", code_names = REASON_NAMES },
	[DIAG_KIND_DISPATCH_FAILED] = { station2 = "station", code_names = DIAG_DISPATCH_NAMES },
	[DIAG_KIND_DELIVERY_FAILED] = { station2 = "station", code_names = DIAG_FAIL_NAMES },
	[DIAG_KIND_ALERT] = { station2 = "station", code_names = DIAG_ALERT_NAMES },
	[DIAG_KIND_STATION_POWER] = {},
	[DIAG_KIND_STATION_LIMIT] = {},
	[DIAG_KIND_STATION_WARMUP_DONE] = {},
	[DIAG_KIND_STATION_DISABLED] = {},
	[DIAG_KIND_SHORT_LOAD] = { station2 = "station" },
	[DIAG_KIND_UNEXPECTED_CARGO] = { station2 = "station" },
	[DIAG_KIND_RESIDUAL_CARGO] = { station2 = "station" },
	[DIAG_KIND_SCHEDULE_EDITED] = { station2 = "player", a_named = true },
	[DIAG_KIND_LINT] = { station2 = "subject", pass = true, code_names = { "appeared", "cleared" }, a_named = true,
		b_named = true },
	[DIAG_KIND_ACKNOWLEDGED] = { station2 = "player", code_names = DIAG_ACK_KINDS },
	[DIAG_KIND_UNACKNOWLEDGED] = { station2 = "player", code_names = DIAG_ACK_KINDS },
	[DIAG_KIND_MANUAL_ACTION] = { station2 = "player", code_names = ACTION_NAMES, a_named = true, b_named = true },
	[DIAG_KIND_DISPATCHED] = { full = true, station2 = "station" },
	[DIAG_KIND_ARRIVE_P] = { full = true, station2 = "station" },
	[DIAG_KIND_LEAVE_P] = { full = true, station2 = "station" },
	[DIAG_KIND_ARRIVE_R] = { full = true, station2 = "station" },
	[DIAG_KIND_LEAVE_R] = { full = true, station2 = "station" },
	[DIAG_KIND_RETURNED] = { full = true },
	[DIAG_KIND_TRAIN_STATE] = { full = true, code_names = DIAG_TRAIN_STATE_NAMES },
	[DIAG_KIND_SLOW_DELIVERY] = { station2 = "station" },
}

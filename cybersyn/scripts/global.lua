--By Mami
---@class MapData
---@field public total_ticks uint
---@field public layout_top_id uint
---@field public to_comb {[uint]: LuaEntity}
---@field public to_comb_params {[uint]: ArithmeticCombinatorParameters}
---@field public to_output {[uint]: LuaEntity}
---@field public to_stop {[uint]: LuaEntity}
---@field public stations {[uint]: Station}
---@field public active_station_ids uint[]
---@field public warmup_station_cycles {[uint]: int}
---@field public queue_station_update {[uint]: true?}?
---@field public depots {[uint]: Depot}
---@field public refuelers {[uint]: Refueler}
---@field public trains {[uint]: Train}
---@field public available_trains {[string]: {[uint]: true?}} --{[network_name]: {[train_id]: true}}
---@field public to_refuelers {[string]: {[uint]: true?}} --{[network_name]: {[refeuler_id]: true}}
---@field public layouts {[uint]: TrainWagonKind[]}
---@field public layout_train_count {[uint]: int}
---@field public tick_state uint
---@field public tick_data {}
---@field public economy Cybersyn.Economy An indexed cache of all the items on the Cybersyn network. It is updated in `tick_poll_station` and then used in `tick_dispatch` to match providers to requesters. (could contain invalid stations or stations with modified settings from when they were first appended)
---@field public each_refuelers {[uint]: true}
---@field public active_alerts {[uint]: {[1]: LuaTrain, [2]: int}}?
---@field public manager Manager
---@field public se_elevators {[uint]: Cybersyn.ElevatorData} maps relevant entities on both surfaces to one shared data structure for the whole space elevator; the key can be the unit_number of the elevator's main assembler or its train stop
---@field public connected_surfaces {[string]: {[string]: Cybersyn.SurfaceConnection}} maps pairs of surfaces to the pairs of entities connecting them
---@field public perf_cache PerfCache -- This gets reset to an empty table on migration change
---@field public analytics Cybersyn.AnalyticsData? Analytics data for train utilization and delivery times
---@field public stats Stats? delivery throughput and request-wait aggregates for the manager Overview, see scripts/stats.lua
---@field public diag DiagState? dispatcher diagnostics, nil while the cybersyn-diagnostics setting is off, see scripts/diag.lua
---@field public diag_serial int? the last DiagState.id handed out; it outlives the state, so a new state never reuses an id
---@field public acks {request: {[uint]: {[string]: DiagAck}}, station: {[uint]: {[0]: DiagAck}}, lint: {[uint]: {[int]: DiagAck}}, n: int, lint_version: int?}? acknowledgements (diag.acks); kept while diagnostics are off
---@field public lint_registry LintRegistry? setup findings per stop and combinator, see scripts/lint.lua
---@field public alert_dedupe {cycle: int, sent: int, keys: {[string]: NoTrainAlert}}? per-(item, network) no-train alerts of the planner cycle, see central-planning.lua

---@class NoTrainAlert the worst failing evaluation of one item and network in a planner cycle
---@field public cycle int the alert_dedupe cycle that noted it
---@field public code DiagAlert DIAG_ALERT_MISSING_TRAIN or DIAG_ALERT_TRAINS_FILTERED
---@field public r_id uint requester station id
---@field public p_id uint provider station id
---@field public wait number seconds the requester had waited
---@field public shown uint? station id the alert currently on screen is attached to
---@field public shown_text LocalisedString? that alert's message, needed to remove it
---@field public sent int? alerts sent for this key

---@class PerfCache
---@field public se_get_space_elevator_name {}?
---@field public se_get_zone_from_surface_index {}?

---@class Cybersyn.SurfaceConnection
---@field entity1 LuaEntity the entity that represents the conneciton on the first surface; will eventually discard the connection if invalid
---@field entity2 LuaEntity the entity that represents the connection on the second surface; will eventually discard the connection if invalid
---@field network_masks {[string]: integer}? nil means can serve deliveries on any network, otherwise a delivery is matched against the corresponding network_mask in the dictionary

---@class Cybersyn.StationScheduleSettings
---@field public enable_inactive true? If true, enable inactivity timeouts for trains at this station.
---@field public enable_circuit_condition true? If `true`, trains directed to this station will be given a check>0 circuit condition in their schedule.
---@field public disable_manifest_condition true?

---@class (exact) StopInfo
---@field public station_id uint
---@field public unit uint? the inventory combinator's unit number; nil on the station combinator's stop
---@field public priority int
---@field public network_name string?
---@field public network_mask int|{[string]: int} --transient
---@field public r_threshold int >= 0 --transient
---@field public r_fluid_threshold int? --transient
---@field public reserved_fluid_capacity int? an inventory's own reservation; nil uses the station's --transient
---@field public item_p_counts {[string]: int} --transient
---@field public requested {[string]: int}? item hash -> threshold of each item the poll registered as a request; nil when none --transient
---@field public tick_signals {[uint]: Signal}? the combinator's signals as read; item_p_counts and requested say what the poll registered --transient

---@class (exact) Station: Cybersyn.StationScheduleSettings
---@field public entity_stop LuaEntity
---@field public entity_comb1 LuaEntity
---@field public entity_comb2 LuaEntity?
---@field public secondary_inv_combs {[uint]: LuaEntity}
---@field public is_p true?
---@field public is_r true?
---@field public is_stack true?
---@field public enable_train_count true? If `true`, the station control combinator for this station will output the number of trains enroute.
---@field public enable_manual_inventory true? If `true`, the station will not internally compensate for incoming deliveries, and will instead rely on the user to manually control the station's inventory.
---@field public allows_all_trains true?
---@field public deliveries_total int
---@field public last_delivery_tick int
---@field public created_tick uint? total_ticks when built (nil on stations from before 2.2.0)
---@field public request_start_ticks {[string]: uint}? item hash -> tick its request started, for the wait times
---@field public trains_limit int --transient
---@field public priority int --transient
---@field public primary_stop StopInfo? the station combinator's stop from the latest poll, which lets the remote create_manifest take station ids --transient
---@field public inv_stops {[uint]: StopInfo}? the inventory combinators' stops from the latest poll, by unit number; the manager reads these and primary_stop instead of the combinators --transient
---@field public comb2_signals Signal[]? the control combinator's signals as of the latest poll, nil when the station combinator had no input --transient
---@field public item_priority int? --transient
---@field public r_threshold int >= 0 --transient
---@field public r_fluid_threshold int? --transient
---@field public locked_slots int >= 0 --transient
---@field public reserved_fluid_capacity int Reserved fluid capacity, per wagon, to be subtracted from total capacity when calculating fluid orders for this provider.
---@field public network_name string?
---@field public network_mask int|{[string]: int} --transient
---@field public wagon_combs {[int]: LuaEntity}?--NOTE: allowed to be invalid entities or combinators with the wrong operation, these must be checked and lazy deleted when found
---@field public deliveries {[string]: int}
---@field public accepted_layouts {[uint]: true?}
---@field public layout_pattern StopWagonSupport[]?
---@field public item_thresholds {[string]: int}? --transient
---@field public display_state int
---@field public inv_failed {[uint]: true}? inventory combinators (by unit number) whose own request went unserved: their red I; nil when none, and on saves from before it existed
---@field public is_warming_up true?

---@class Depot
---@field public entity_stop LuaEntity
---@field public entity_comb LuaEntity
---@field public available_train_id uint?--train_id, only present when a train is parked here

---@class Refueler
---@field public entity_stop LuaEntity
---@field public entity_comb LuaEntity
---@field public trains_total int
---@field public accepted_layouts {[uint]: true?}
---@field public layout_pattern StopWagonSupport[]?
---@field public wagon_combs {[int]: LuaEntity}?--NOTE: allowed to be invalid entities or combinators with the wrong operation, these must be checked and lazy deleted when found
---@field public allows_all_trains true?
---@field public priority int
---@field public network_name string?
---@field public network_mask int|{[string]: int}

---@class Train
---@field public entity LuaTrain --should only be invalid if se_is_being_teleported is true
---@field public layout_id uint
---@field public dispatch_tick uint? game tick of the last dispatch, for the Overview cycle time and the trip average
---   (analytics.delivery_phases[train_id].dispatch_tick holds the same tick, but only while analytics is enabled)
---@field public item_slot_capacity int
---@field public fluid_capacity int
---@field public status uint
---@field public p_station_id uint?
---@field public r_station_id uint?
---@field public manifest Manifest?
---@field public last_manifest_tick int
---@field public has_filtered_wagon true?
---@field public is_available true?
---@field public depot_surface_id uint -- use_any_depot trains don't need to depend on an existing depot stop
---@field public depot_id uint
---@field public use_any_depot true?
---@field public disable_bypass true?
---@field public network_name string? --can only be nil when the train is parked at a depot
---@field public network_mask int|{[string]: int} --transient
---@field public priority int
---@field public refueler_id uint?
---@field public se_is_being_teleported true? --se only
---@field public se_awaiting_removal boolean? --se only
---@field public se_awaiting_rename any? --se only
---@field public skip_path_checks_until int?
---@field public stuck_departure true?
---@field public in_interrupt boolean? a schedule record was inserted by an interrupt; kept by on_train_schedule_changed, read by tick_dispatch
---@field public last_state defines.train_state? LuaTrain.state at the last on_train_changed_state
---@field public state_tick uint? when last_state began (the load tick for trains that predate the field)
---@field public delivery_id uint? id of the current delivery in the full diagnostics log
---@field public refuel_tick uint? last arrival at a refueler (nil = never seen refuelling)
---@field public seen_tick uint? when Cybersyn first registered the train (nil for trains from before the field)
---@field public edited_tick uint? last schedule edit by a player that the diagnostics log recorded

---@alias Manifest ManifestEntry[]
---@class ManifestEntry
---@field public type string
---@field public name string
---@field public quality string
---@field public count int

---@alias Cybersyn.Economy.ItemNetworkName string A stringified tuple of the form `network_hash:item_hash` for matching specific items between providers and requesters.

---@class Cybersyn.Economy
---@field public all_r_stops {[Cybersyn.Economy.ItemNetworkName]: StopInfo[]} Maps item network names to the requester stops (station or secondary inventory combinators) wanting matching items.
---@field public all_p_stops {[Cybersyn.Economy.ItemNetworkName]: StopInfo[]} Maps item network names to the provider stops (station or secondary inventory combinators) having matching items.
---@field public all_names (Cybersyn.Economy.ItemNetworkName|SignalID)[] A flattened list of pairs. Each pair is of the form `[item_network_name, item_signal]` where `item_signal` is the signal for the named item. The dispatch logic iterates over these pairs to brute-force match providers to requesters.
---@field public starved {[Cybersyn.Economy.ItemNetworkName]: true} The keys requested and provided by no stop, as of the last completed poll; the manager's starved set.

---@class Cybersyn.AnalyticsInterval
---@field public name string Interval name ("5s", "1m", "10m", etc.)
---@field public data table[] Circular buffer of {[series_name]: value}
---@field public index uint Next write position (0-indexed)
---@field public sum {[string]: number} Running sums by series name
---@field public counts {[string]: uint} Sample counts by series name
---@field public ticks uint Game ticks per datapoint
---@field public steps uint? Datapoints per cascade (nil for last interval)
---@field public length uint Buffer capacity
---@field public chunk table? {render_entity, coord} when being viewed
---@field public viewer_count uint Number of players viewing this graph
---@field public guis {[uint]: table} Player GUIs viewing this interval
---@field public last_rendered_tick uint?

---@class Cybersyn.AnalyticsData
---@field public surface LuaSurface Hidden rendering surface
---@field public train_utilization Cybersyn.AnalyticsInterval[] 7 intervals (1m..1000h) for the utilization graph
---@field public train_status_ticks {[uint]: {[uint]: uint}} layout_id -> {status -> ticks}
---@field public train_status_totals {[uint]: uint} layout_id -> total ticks
---@field public chunk_freelist table[] Reusable chunk coordinates
---@field public next_chunk_x uint
---@field public next_chunk_y uint
---@field public enabled boolean

--NOTE: any setting labeled as an "interface setting" can only be changed through the remote-interface, these settings are not save and have to be set at initialization
--As a modder using the remote-interface, you may override any of these settings, including user settings. They will have to be overriden at initialization and whenever a user tries to change one.
---@class CybersynModSettings
---@field public enable_planner boolean
---@field public tps double
---@field public update_rate int
---@field public r_threshold int
---@field public r_fluid_threshold int
---@field public priority int
---@field public locked_slots int
---@field public locked_slots_per_item boolean
---@field public reserved_fluid_capacity int
---@field public network_mask int
---@field public warmup_time double
---@field public stuck_train_time double
---@field public fuel_threshold double
---@field public allow_cargo_in_depot boolean
---@field public alert_unexpected_cargo boolean
---@field public manager_actions string "admins"|"everyone"|"nobody"
---@field public diagnostics string "off"|"basic"|"full"
---@field public missing_train_alert_enabled boolean --interface setting
---@field public stuck_train_alert_enabled boolean --interface setting
---@field public react_to_train_at_incorrect_station boolean --interface setting
---@field public react_to_train_early_to_depot boolean --interface setting
---@field public enable_manager boolean
---@field public manager_ups double
---@field public enable_analytics boolean

--if this is uncommented it means there are migrations to write

---@alias cybersyn.global MapData
---@type CybersynModSettings
mod_settings = {}
---@type boolean
IS_SE_PRESENT = nil

function init_global()
	storage.total_ticks = 0
	storage.tick_state = STATE_INIT
	storage.tick_data = {}
	storage.economy = {
		all_r_stops = {},
		all_p_stops = {},
		all_names = {},
		starved = {},
	}
	storage.to_comb = {}
	storage.to_comb_params = {}
	storage.to_output = {}
	storage.to_stop = {}
	storage.stations = {}
	storage.active_station_ids = {}
	storage.warmup_station_cycles = {}
	storage.depots = {}
	storage.trains = {}
	storage.available_trains = {}
	storage.layouts = {}
	storage.layout_train_count = {}
	storage.layout_top_id = 1
	storage.refuelers = {}
	storage.to_refuelers = {}
	storage.each_refuelers = {}
	storage.perf_cache = {}
	storage.se_elevators = {}
	storage.connected_surfaces = {}

	IS_SE_PRESENT = remote.interfaces["space-exploration"] ~= nil
end

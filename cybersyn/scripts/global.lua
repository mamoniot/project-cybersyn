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
---@field public warmup_station_ids uint[]
---@field public warmup_station_cycles {[uint]: int}
---@field public queue_station_update {[uint]: true?}?
---@field public depots {[uint]: Depot}
---@field public refuelers {[uint]: Refueler}
---@field public trains {[uint]: Train}
---@field public available_trains {[string]: {[uint]: true?}} --{[network_name]: {[train_id]: true}}
---@field public to_refuelers {[string]: {[uint]: true?}} --{[network_name]: {[refeuler_id]: true}}
---@field public layouts {[uint]: (0|1|2)[]}
---@field public layout_train_count {[uint]: int}
---@field public tick_state uint
---@field public tick_data {}
---@field public economy Economy
---@field public each_refuelers {[uint]: true}
---@field public active_alerts {[uint]: {[1]: LuaTrain, [2]: int}}?
---@field public manager Manager
---@field public perf_cache PerfCache -- This gets reset to an empty table on migration change

---@class PerfCache
---@field public se_get_space_elevator_name {}?
---@field public se_get_zone_from_surface_index {}?

---@class Station
---@field public entity_stop LuaEntity
---@field public entity_comb1 LuaEntity
---@field public entity_comb2 LuaEntity?
---@field public is_p true?
---@field public is_r true?
---@field public is_stack true?
---@field public enable_inactive true?
---@field public allows_all_trains true?
---@field public deliveries_total int
---@field public last_delivery_tick int
---@field public trains_limit int --transient
---@field public priority int --transient
---@field public item_priority int? --transient
---@field public r_threshold int >= 0 --transient
---@field public locked_slots int >= 0 --transient
---@field public network_name string?
---@field public network_mask int|{[string]: int} --transient
---@field public wagon_combs {[int]: LuaEntity}?--NOTE: allowed to be invalid entities or combinators with the wrong operation, these must be checked and lazy deleted when found
---@field public deliveries {[string]: int}
---@field public accepted_layouts {[uint]: true?}
---@field public layout_pattern (0|1|2|3)[]?
---@field public tick_signals {[uint]: Signal}? --transient
---@field public item_p_counts {[string]: int} --transient
---@field public item_thresholds {[string]: int}? --transient
---@field public display_state int
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
---@field public layout_pattern (0|1|2|3)[]?
---@field public wagon_combs {[int]: LuaEntity}?--NOTE: allowed to be invalid entities or combinators with the wrong operation, these must be checked and lazy deleted when found
---@field public allows_all_trains true?
---@field public priority int
---@field public network_name string?
---@field public network_mask int|{[string]: int}

---@class Train
---@field public entity LuaTrain --should only be invalid if se_is_being_teleported is true
---@field public layout_id uint
---@field public item_slot_capacity int
---@field public fluid_capacity int
---@field public status uint
---@field public p_station_id uint?
---@field public r_station_id uint?
---@field public manifest Manifest?
---@field public last_manifest_tick int
---@field public has_filtered_wagon true?
---@field public is_available true?
---@field public depot_id uint
---@field public use_any_depot true?
---@field public disable_bypass true?
---@field public network_name string? --can only be nil when the train is parked at a depot
---@field public network_mask int|{[string]: int} --transient
---@field public priority int
---@field public refueler_id uint?
---@field public se_is_being_teleported true? --se only
---@field public se_awaiting_removal any? --se only
---@field public se_awaiting_rename any? --se only

---@alias Manifest ManifestEntry[]
---@class ManifestEntry
---@field public type string
---@field public name string
---@field public count int

---@class Economy
---could contain invalid stations or stations with modified settings from when they were first appended
---@field public all_r_stations {[string]: uint[]} --{["network_name:item_name"]: station_id}
---@field public all_p_stations {[string]: uint[]} --{["network_name:item_name"]: station_id}
---@field public all_names (string|SignalID)[]

--NOTE: any setting labeled as an "interface setting" can only be changed through the remote-interface, these settings are not save and have to be set at initialization
--As a modder using the remote-interface, you may override any of these settings, including user settings. They will have to be overriden at initialization and whenever a user tries to change one.
---@class CybersynModSettings
---@field public enable_planner boolean
---@field public tps double
---@field public update_rate int
---@field public r_threshold int
---@field public priority int
---@field public locked_slots int
---@field public network_mask int
---@field public warmup_time double
---@field public stuck_train_time double
---@field public fuel_threshold double
---@field public invert_sign boolean
---@field public allow_cargo_in_depot boolean
---@field public missing_train_alert_enabled boolean --interface setting
---@field public stuck_train_alert_enabled boolean --interface setting
---@field public react_to_train_at_incorrect_station boolean --interface setting
---@field public react_to_train_early_to_depot boolean --interface setting
---@field public enable_manager boolean
---@field public manager_ups double
---@field public manager_enabled boolean

--if this is uncommented it means there are migrations to write

---@alias cybersyn.global MapData
---@type CybersynModSettings
mod_settings = {}
---@type boolean
IS_SE_PRESENT = nil

function init_global()
	global.total_ticks = 0
	global.tick_state = STATE_INIT
	global.tick_data = {}
	global.economy = {
		all_r_stations = {},
		all_p_stations = {},
		all_names = {},
	}
	global.to_comb = {}
	global.to_comb_params = {}
	global.to_output = {}
	global.to_stop = {}
	global.stations = {}
	global.active_station_ids = {}
	global.warmup_station_ids = {}
	global.warmup_station_cycles = {}
	global.depots = {}
	global.trains = {}
	global.available_trains = {}
	global.layouts = {}
	global.layout_train_count = {}
	global.layout_top_id = 1
	global.refuelers = {}
	global.to_refuelers = {}
	global.each_refuelers = {}
	global.perf_cache = {}

	IS_SE_PRESENT = remote.interfaces["space-exploration"] ~= nil
end

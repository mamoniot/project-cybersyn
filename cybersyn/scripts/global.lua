--By Mami
---@class MapData
---@field public total_ticks uint
---@field public layout_top_id uint
---@field public to_comb {[uint]: LuaEntity}
---@field public to_output {[uint]: LuaEntity}
---@field public to_stop {[uint]: LuaEntity}
---@field public stations {[uint]: Station}
---@field public depots {[uint]: Depot}
---@field public trains {[uint]: Train}
---@field public trains_available {[string]: {[uint]: uint}} --{[network_name]: {[train_id]: depot_id}}
---@field public layouts {[uint]: string}
---@field public layout_train_count {[uint]: int}
---@field public tick_state uint
---@field public tick_data {}
---@field public economy Economy

---@class Station
---@field public is_p boolean
---@field public is_r boolean
---@field public allows_all_trains boolean
---@field public deliveries_total int
---@field public last_delivery_tick int
---@field public priority int --transient
---@field public r_threshold int >= 0 --transient
---@field public locked_slots int >= 0 --transient
---@field public entity_stop LuaEntity
---@field public entity_comb1 LuaEntity
---@field public entity_comb2 LuaEntity?
---@field public wagon_combs {[int]: LuaEntity}?--NOTE: allowed to be invalid entities or combinators with the wrong operation, these must be checked and lazy deleted when found
---@field public deliveries {[string]: int}
---@field public network_name string?
---@field public network_flag int --transient
---@field public accepted_layouts TrainClass
---@field public layout_pattern string?
---@field public tick_signals {[uint]: Signal}? --transient
---@field public p_count_or_r_threshold_per_item {[string]: int} --transient
---@field public display_failed_request true?
---@field public display_update true?

---@class Depot
---@field public priority int --transient
---@field public entity_stop LuaEntity
---@field public entity_comb LuaEntity
---@field public network_name string?
---@field public network_flag int --transient
---@field public available_train uint?

---@class Train
---@field public entity LuaTrain
---@field public layout_id uint
---@field public item_slot_capacity int
---@field public fluid_capacity int
---@field public depot_name string
---@field public depot Depot?
---@field public status int
---@field public p_station_id uint
---@field public r_station_id uint
---@field public manifest Manifest
---@field public has_filtered_wagon boolean

---@alias Manifest {}[]
---@alias TrainClass {[uint]: true}
---@alias cybersyn.global MapData

---@class Economy
---@field public all_r_stations {[string]: uint[]} --{[network_name:item_name]: count}
---@field public all_p_stations {[string]: uint[]} --{[network_name:item_name]: count}
---@field public all_names {[string]: uint[]} --{[network_name:item_name]: count}

---@class CybersynModSettings
---@field public tps int
---@field public r_threshold int
---@field public network_flag int

---@type CybersynModSettings
mod_settings = {}

local pairs = pairs
---@param tab {}
function table_clear(tab)
	for k, _ in pairs(tab) do
		tab[k] = nil
	end
end

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
	global.to_output = {}
	global.to_stop = {}
	global.stations = {}
	global.depots = {}
	global.trains = {}
	global.trains_available = {}
	global.layouts = {}
	global.layout_train_count = {}
	global.layout_top_id = 1
end

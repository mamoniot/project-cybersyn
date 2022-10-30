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
---@field public trains_available {[string]: {[uint]: uint}}
---@field public layouts {[uint]: string}
---@field public layout_train_count {[uint]: int}
---@field public train_classes {[string]: TrainClass}

---@class Station
---@field public deliveries_total int
---@field public priority int
---@field public last_delivery_tick int
---@field public r_threshold int >= 0
---@field public p_threshold int >= 0
---@field public locked_slots int >= 0
---@field public entity_stop LuaEntity
---@field public entity_comb1 LuaEntity
---@field public entity_comb2 LuaEntity?
---@field public wagon_combs {[int]: LuaEntity}?--NOTE: allowed to be invalid entities or combinators with the wrong operation, these must be checked and lazy deleted when found
---@field public deliveries {[string]: int}
---@field public network_name string?
---@field public network_flag int
---@field public train_class SignalID?
---@field public accepted_layouts TrainClass
---@field public layout_pattern string?

---@class Depot
---@field public priority int
---@field public entity_stop LuaEntity
---@field public entity_comb LuaEntity
---@field public network_name string?
---@field public network_flag int

---@class Train
---@field public entity LuaTrain
---@field public layout_id uint
---@field public item_slot_capacity int
---@field public fluid_capacity int
---@field public depot_name string
---@field public status int
---@field public p_station_id uint
---@field public r_station_id uint
---@field public manifest Manifest

---@alias Manifest {}[]
---@alias TrainClass {[uint]: boolean}
---@alias cybersyn.global MapData

---@class Economy
---@field public r_stations_all {[string]: uint[]}
---@field public p_stations_all {[string]: uint[]}
---@field public total_ticks uint

--TODO: only init once
mod_settings = {}
mod_settings.tps = settings.global["cybersyn-ticks-per-second"].value
mod_settings.r_threshold = settings.global["cybersyn-request-threshold"].value
mod_settings.p_threshold = settings.global["cybersyn-provide-threshold"].value

global.total_ticks = 0
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
global.train_classes = {
	--[TRAIN_CLASS_ALL.name] = {},
}

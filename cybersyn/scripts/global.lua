--By Mami

--[[
global: {
	total_ticks: int
	layout_top_id: int
	stations: {[stop_id]: Station}
	trains: {[train_id]: Train}
	trains_available: {[train_id]: bool}
	layouts: {[layout_id]: Layout}
	layout_train_count: {[layout_id]: int}
}
Station: {
	deliveries_total: int
	train_limit: int
	priority: int
	last_delivery_tick: int
	r_threshold: int >= 0
	p_threshold: int >= 0
	entity: LuaEntity
	deliveries: {
		[item_name]: int
	}
	--train_layout: [char]
	accepted_layouts: {
		[layout_id]: bool
	}
}
Train: {
	entity: LuaEntity
	entity_in: LuaEntity
	entity_out: LuaEntity
	layout_id: int
	item_slot_capacity: int
	fluid_capacity: int
	depot_name: string
	status: int
	p_station_id: stop_id
	r_station_id: stop_id
	manifest: [{
		name: string
		type: string
		count: int
	}]
}
Layout: string
]]
--TODO: only init once
mod_settings = {}
mod_settings.tps = settings.global["cybersyn-ticks-per-second"]
mod_settings.r_threshold = settings.global["cybersyn-requester-threshold"]
mod_settings.p_threshold = settings.global["cybersyn-provider-threshold"]

global.total_ticks = 0
global.stations = {}
global.trains = {}
global.trains_available = {}
global.layouts = {}
global.layout_train_count = {}
global.layout_top_id = 1

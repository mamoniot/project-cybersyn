--By Monica Moniot

--[[
global: {
	total_ticks: int
	stations: {[stop_id]: Station}
	trains: {[train_id]: Train}
	trains_available: {[train_id]: bool}
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
	train_layout: [ [ {
		[car_type]: bool
	} ] ]
	accepted_layouts: {
		[layout_id]: bool
	}
}
Train: {
	entity: LuaEntity
	layout_id: int
	item_slot_capacity: int
	fluid_capacity: int
	depot_id: int
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
]]

global.total_ticks = 0
global.stations = {}
global.trains = {}
global.trains_available = {}

STATUS_D = 0
STATUS_D_TO_P = 1
STATUS_P = 2
STATUS_P_TO_R = 3
STATUS_R = 4
STATUS_R_TO_D = 5

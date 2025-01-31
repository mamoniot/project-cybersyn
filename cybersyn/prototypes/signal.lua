--By Mami
subgroup_signal = {
	type = "item-subgroup",
	name = "cybersyn-signal",
	group = "signals",
	order = "f",
}
r_threshold_signal = {
	type = "virtual-signal",
	name = REQUEST_THRESHOLD,
	icon = "__cybersyn__/graphics/icons/request-threshold.png",
	icon_size = 64,
	icon_mipmaps = 4,
	subgroup = "cybersyn-signal",
	order = "a",
}
locked_slots_signal = {
	type = "virtual-signal",
	name = LOCKED_SLOTS,
	icon = "__cybersyn__/graphics/icons/locked-slots.png",
	icon_size = 64,
	icon_mipmaps = 4,
	subgroup = "cybersyn-signal",
	order = "b1",
}
priority_signal = {
	type = "virtual-signal",
	name = SIGNAL_PRIORITY,
	icon = "__cybersyn__/graphics/icons/priority.png",
	icon_size = 64,
	icon_mipmaps = 4,
	subgroup = "cybersyn-signal",
	order = "c",
}
reserved_fluid_capacity_signal = {
	type = "virtual-signal",
	name = RESERVED_FLUID_CAPACITY,
	icon = "__cybersyn__/graphics/icons/reserved-fluid-capacity.png",
	icon_size = 64,
	subgroup = "cybersyn-signal",
	order = "b2",
}

--By Mami
subgroup_signal = {
	type = "item-subgroup",
	name = "cybersyn-signal",
	group = "signals",
	order = "f"
}
r_threshold_signal = {
	type = "virtual-signal",
	name = REQUEST_THRESHOLD,
	icon = "__cybersyn__/graphics/icons/request-threshold.png",
	icon_size = 64,
	icon_mipmaps = 4,
	subgroup = "cybersyn-signal",
	order = "a"
}
priority_signal = {
	type = "virtual-signal",
	name = SIGNAL_PRIORITY,
	icon = "__cybersyn__/graphics/icons/priority.png",
	icon_size = 64,
	icon_mipmaps = 4,
	subgroup = "cybersyn-signal",
	order = "b"
}
locked_slots_signal = {
	type = "virtual-signal",
	name = LOCKED_SLOTS,
	icon = "__cybersyn__/graphics/icons/locked-slots.png",
	icon_size = 64,
	icon_mipmaps = 4,
	subgroup = "cybersyn-signal",
	order = "c"
}

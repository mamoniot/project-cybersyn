--By Mami
subgroup_signal = {
	type = "item-subgroup",
	name = "cybersyn-signal",
	group = "signals",
	order = "cybersyn0[cybersyn-signal]"
}
priority_signal = {
	type = "virtual-signal",
	name = SIGNAL_PRIORITY,
	icon = "__cybersyn__/graphics/icons/priority.png",
	icon_size = 64,
	subgroup = "cybersyn-signal",
	order = "a-a"
}
p_threshold_signal = {
	type = "virtual-signal",
	name = PROVIDE_THRESHOLD,
	icon = "__cybersyn__/graphics/icons/provide-threshold.png",
	icon_size = 64,
	subgroup = "cybersyn-signal",
	order = "a-b"
}
r_threshold_signal = {
	type = "virtual-signal",
	name = REQUEST_THRESHOLD,
	icon = "__cybersyn__/graphics/icons/request-threshold.png",
	icon_size = 64,
	subgroup = "cybersyn-signal",
	order = "a-c"
}
locked_slots_signal = {
	type = "virtual-signal",
	name = LOCKED_SLOTS,
	icon = "__cybersyn__/graphics/icons/locked-slots.png",
	icon_size = 64,
	subgroup = "cybersyn-signal",
	order = "a-d"
}

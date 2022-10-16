--By Mami
cybersyn_subgroup = {
	type = "item-subgroup",
	name = "cybersyn-signal",
	group = "signals",
	order = "cybersyn0[cybersyn-signal]"
}
cybersyn_priority = {
	type = "virtual-signal",
	name = SIGNAL_PRIORITY,
	icon = "__cybersyn__/graphics/icons/priority.png",
	icon_size = 64,
	subgroup = "cybersyn-signal",
	order = "a-a"
}
cybersyn_p_threshold = {
	type = "virtual-signal",
	name = PROVIDE_THRESHOLD,
	icon = "__cybersyn__/graphics/icons/p_threshold.png",
	icon_size = 64,
	subgroup = "cybersyn-signal",
	order = "a-b"
}
cybersyn_r_threshold = {
	type = "virtual-signal",
	name = REQUEST_THRESHOLD,
	icon = "__cybersyn__/graphics/icons/r_threshold.png",
	icon_size = 64,
	subgroup = "cybersyn-signal",
	order = "a-b"
}

--By Mami
flib = require("__flib__.data-util")

require("scripts.constants")
require("prototypes.item")
require("prototypes.tech")
require("prototypes.entity")
require("prototypes.signal")
require("prototypes.sprite")
require("prototypes.misc")

require("prototypes.gui-style")

data:extend({
	combinator_entity,
	combinator_out_entity,
	combinator_item,
	combinator_recipe,
	cybersyn_tech,
	subgroup_signal,
	priority_signal,
	r_threshold_signal,
	r_fluid_threshold_signal,
	locked_slots_signal,
	reserved_fluid_capacity_signal,
	both_wagon_sprite,
	missing_train_icon,
	lost_train_icon,
	nonempty_train_icon,
	provider_id_item,
	requester_id_item,
	refueler_id_item,

	--{
	--  type = "shortcut",
	--  name = "cybersyn-toggle-gui",
	--  icon = data_util.build_sprite(nil, { 0, 0 }, util.paths.shortcut_icons, 32, 2),
	--  disabled_icon = data_util.build_sprite(nil, { 48, 0 }, util.paths.shortcut_icons, 32, 2),
	--  small_icon = data_util.build_sprite(nil, { 0, 32 }, util.paths.shortcut_icons, 24, 2),
	--  disabled_small_icon = data_util.build_sprite(nil, { 36, 32 }, util.paths.shortcut_icons, 24, 2),
	--  toggleable = true,
	--  action = "lua",
	--  associated_control_input = "cybersyn-toggle-gui",
	--  technology_to_unlock = "logistic-train-network",
	--},
})

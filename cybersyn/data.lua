--By Mami
flib = require('__flib__.data-util')

require('scripts.constants')
require('prototypes.item')
require('prototypes.tech')
require('prototypes.entity')
require('prototypes.signal')
require('prototypes.misc')

data:extend({
	combinator_entity,
	combinator_out_entity,
	combinator_item,
	combinator_recipe,
	cybersyn_tech,
	subgroup_signal,
	priority_signal,
	r_threshold_signal,
	locked_slots_signal,
	missing_train_icon,
	lost_train_icon,
	nonempty_train_icon,
	{
		type = "custom-input",
		name = "cybersyn-toggle-planner",
		key_sequence = nil,
		consuming = "game-only"
	}
})

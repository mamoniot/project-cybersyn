--By Mami
flib = require('__flib__.data-util')

require('scripts.constants')
require('prototypes.item')
require('prototypes.tech')
require('prototypes.entity')
require('prototypes.signal')

data:extend({
	combinator_entity,
	combinator_out_entity,
	combinator_item,
	combinator_recipe,
	cybersyn_tech,
	subgroup_signal,
	priority_signal,
	p_threshold_signal,
	r_threshold_signal,
	locked_slots_signal,
})

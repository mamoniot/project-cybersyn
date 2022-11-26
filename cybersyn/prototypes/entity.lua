--By Mami
combinator_entity = flib.copy_prototype(data.raw["arithmetic-combinator"]["arithmetic-combinator"], COMBINATOR_NAME)
combinator_entity.icon = "__cybersyn__/graphics/icons/cybernetic-combinator.png"
combinator_entity.radius_visualisation_specification = {
	sprite = {
		filename = "__cybersyn__/graphics/icons/area-of-effect.png",
		tint = {r = 1, g = 1, b = 0, a = .5},
		height = 64,
		width = 64,
	},
	--offset = {0, .5},
	distance = 1.5,
}
combinator_entity.active_energy_usage = "10KW"
--combinator_entity.allow_copy_paste = false



local comb = combinator_entity
--local display_base = {
--  filename = "__cybersyn__/graphics/combinator/combinator-displays.png",
--  width = 15,
--  height = 11,
--  hr_version = {
--    filename = "__cybersyn__/graphics/combinator/hr-combinator-displays.png",
--    width = 30,
--    height = 21,
--  }
--}

--local north = table.deepcopy(display_base)
--north.scale = comb.and_symbol_sprites.north.scale
--north.shift = comb.and_symbol_sprites.north.shift
--north.hr_version.scale = comb.and_symbol_sprites.north.hr_version.scale
--north.hr_version.shift = comb.and_symbol_sprites.north.hr_version.shift
--local east = table.deepcopy(display_base)
--east.scale = comb.and_symbol_sprites.east.scale
--east.shift = comb.and_symbol_sprites.east.shift
--east.hr_version.scale = comb.and_symbol_sprites.east.hr_version.scale
--east.hr_version.shift = comb.and_symbol_sprites.east.hr_version.shift
--local south = table.deepcopy(display_base)
--south.scale = comb.and_symbol_sprites.south.scale
--south.shift = comb.and_symbol_sprites.south.shift
--south.hr_version.scale = comb.and_symbol_sprites.south.hr_version.scale
--south.hr_version.shift = comb.and_symbol_sprites.south.hr_version.shift
--local west = table.deepcopy(display_base)
--west.scale = comb.and_symbol_sprites.west.scale
--west.shift = comb.and_symbol_sprites.west.shift
--west.hr_version.scale = comb.and_symbol_sprites.west.hr_version.scale
--west.hr_version.shift = comb.and_symbol_sprites.west.hr_version.shift

--local display = {
--  north = north,
--  east = east,
--  south = south,
--  west = west
--}
--comb.and_symbol_sprites = table.deepcopy(display)
--comb.divide_symbol_sprites = table.deepcopy(display)
--comb.left_shift_symbol_sprites = table.deepcopy(display)
--comb.minus_symbol_sprites = table.deepcopy(display)
--comb.modulo_symbol_sprites = table.deepcopy(display)
--comb.multiply_symbol_sprites = table.deepcopy(display)
--comb.or_symbol_sprites = table.deepcopy(display)
--comb.plus_symbol_sprites = table.deepcopy(display)
--comb.power_symbol_sprites = table.deepcopy(display)
--comb.right_shift_symbol_sprites = table.deepcopy(display)
--comb.xor_symbol_sprites = table.deepcopy(display)


--local sprite_base = {
--	filename = "__cybersyn__/graphics/combinator/cybernetic-combinator.png",
--	hr_version = {
--		filename = "__cybersyn__/graphics/combinator/hr-cybernetic-combinator-shadow.png",
--	}
--}

--comb.sprites.north.layers[1].filename = "__cybersyn__/graphics/combinator/cybernetic-combinator.png"
--comb.sprites.north.layers[1].hr_version.filename = "__cybersyn__/graphics/combinator/hr-cybernetic-combinator-shadow.png"
--comb.sprites.north.layers[2].filename = "__cybersyn__/graphics/combinator/cybernetic-combinator.png"
--comb.sprites.north.layers[2].hr_version.filename = "__cybersyn__/graphics/combinator/hr-cybernetic-combinator-shadow.png"

--comb.sprites.east.layers[1].filename = "__cybersyn__/graphics/combinator/cybernetic-combinator.png"
--comb.sprites.east.layers[1].hr_version.filename = "__cybersyn__/graphics/combinator/hr-cybernetic-combinator-shadow.png"
--comb.sprites.east.layers[2].filename = "__cybersyn__/graphics/combinator/cybernetic-combinator.png"
--comb.sprites.east.layers[2].hr_version.filename = "__cybersyn__/graphics/combinator/hr-cybernetic-combinator-shadow.png"

--comb.sprites.south.layers[1].filename = "__cybersyn__/graphics/combinator/cybernetic-combinator.png"
--comb.sprites.south.layers[1].hr_version.filename = "__cybersyn__/graphics/combinator/hr-cybernetic-combinator-shadow.png"
--comb.sprites.south.layers[2].filename = "__cybersyn__/graphics/combinator/cybernetic-combinator.png"
--comb.sprites.south.layers[2].hr_version.filename = "__cybersyn__/graphics/combinator/hr-cybernetic-combinator-shadow.png"

--comb.sprites.west.layers[1].filename = "__cybersyn__/graphics/combinator/cybernetic-combinator.png"
--comb.sprites.west.layers[1].hr_version.filename = "__cybersyn__/graphics/combinator/hr-cybernetic-combinator-shadow.png"
--comb.sprites.west.layers[2].filename = "__cybersyn__/graphics/combinator/cybernetic-combinator.png"
--comb.sprites.west.layers[2].hr_version.filename = "__cybersyn__/graphics/combinator/hr-cybernetic-combinator-shadow.png"



combinator_out_entity = flib.copy_prototype(data.raw["constant-combinator"]["constant-combinator"], COMBINATOR_OUT_NAME)
combinator_out_entity.icon = nil
combinator_out_entity.icon_size = nil
combinator_out_entity.icon_mipmaps = nil
combinator_out_entity.next_upgrade = nil
combinator_out_entity.minable = nil
combinator_out_entity.selection_box = nil
combinator_out_entity.collision_box = nil
combinator_out_entity.collision_mask = {}
combinator_out_entity.item_slot_count = 500
combinator_out_entity.circuit_wire_max_distance = 3
combinator_out_entity.flags = {"not-blueprintable", "not-deconstructable", "placeable-off-grid"}

local origin = {0.0, 0.0}
local invisible_sprite = {filename = "__cybersyn__/graphics/invisible.png", width = 1, height = 1}
local wire_con1 = {
	red = origin,
	green = origin
}
local wire_con0 = {wire = wire_con1, shadow = wire_con1}
combinator_out_entity.sprites = invisible_sprite
combinator_out_entity.activity_led_sprites = invisible_sprite
combinator_out_entity.activity_led_light = {
	intensity = 0,
	size = 0,
}
combinator_out_entity.activity_led_light_offsets = {origin, origin, origin, origin}
combinator_out_entity.draw_circuit_wires = false
combinator_out_entity.circuit_wire_connection_points = {
	wire_con0,
	wire_con0,
	wire_con0,
	wire_con0
}

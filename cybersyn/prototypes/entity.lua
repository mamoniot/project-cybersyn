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

if mods["nullius"] then
	combinator_entity.localised_name = { "entity-name.cybersyn-combinator" }
end

local COMBINATOR_SPRITE = "__cybersyn__/graphics/combinator/cybernetic-combinator.png"
local COMBINATOR_HR_SPRITE = "__cybersyn__/graphics/combinator/hr-cybernetic-combinator.png"
local COMBINATOR_SHADOW = "__cybersyn__/graphics/combinator/cybernetic-combinator-shadow.png"
local COMBINATOR_HR_SHADOW = "__cybersyn__/graphics/combinator/hr-cybernetic-combinator-shadow.png"
combinator_entity.sprites = {
	north = {layers = {
		{
			filename=COMBINATOR_SPRITE,
			priority="high",
			x=0, y=0,
			width=74, height=64,
			frame_count=1,
			shift={ 0.03125, 0.25, },
			scale=1,
			hr_version={
				filename=COMBINATOR_HR_SPRITE,
				priority="high",
				x=0, y=0,
				width=144, height=124,
				frame_count=1,
				shift={ 0.015625, 0.234375, },
				scale=0.5,
			},
		},
		{
			filename=COMBINATOR_SHADOW,
			priority="high",
			x=0, y=0,
			width=76, height=78,
			frame_count=1,
			shift={ 0.4375, 0.75, },
			draw_as_shadow=true,
			scale=1,
			hr_version={
				filename=COMBINATOR_HR_SHADOW,
				priority="high",
				x=0, y=0,
				width=148, height=156,
				frame_count=1,
				shift={ 0.421875, 0.765625, },
				draw_as_shadow=true,
				scale=0.5,
			},
		}
	}},
	east = {layers={
		{
			filename=COMBINATOR_SPRITE,
			priority="high",
			x=74, y=0,
			width=74, height=64,
			frame_count=1,
			shift={ 0.03125, 0.25, },
			scale=1,
			hr_version={
				filename=COMBINATOR_HR_SPRITE,
				priority="high",
				x=144, y=0,
				width=144, height=124,
				frame_count=1,
				shift={ 0.015625, 0.234375, },
				scale=0.5,
			},
		},
		{
			filename=COMBINATOR_SHADOW,
			priority="high",
			x=76, y=0,
			width=76, height=78,
			frame_count=1,
			shift={ 0.4375, 0.75, },
			draw_as_shadow=true,
			scale=1,
			hr_version={
				filename=COMBINATOR_HR_SHADOW,
				priority="high",
				x=148, y=0,
				width=148, height=156,
				frame_count=1,
				shift={ 0.421875, 0.765625, },
				draw_as_shadow=true,
				scale=0.5,
			},
		},
	}},
	south = {layers={
		{
			filename=COMBINATOR_SPRITE,
			priority="high",
			x=148, y=0,
			width=74, height=64,
			frame_count=1,
			shift={ 0.03125, 0.25, },
			scale=1,
			hr_version={
				filename=COMBINATOR_HR_SPRITE,
				priority="high",
				x=288, y=0,
				width=144, height=124,
				frame_count=1,
				shift={ 0.015625, 0.234375, },
				scale=0.5,
			},
		},
		{
			filename=COMBINATOR_SHADOW,
			priority="high",
			x=152, y=0,
			width=76, height=78,
			frame_count=1,
			shift={ 0.4375, 0.75, },
			draw_as_shadow=true,
			scale=1,
			hr_version={
				filename=COMBINATOR_HR_SHADOW,
				priority="high",
				x=296, y=0,
				width=148, height=156,
				frame_count=1,
				shift={ 0.421875, 0.765625, },
				draw_as_shadow=true,
				scale=0.5,
			},
		}
	}},
	west = {layers={
		{
			filename=COMBINATOR_SPRITE,
			priority="high",
			x=222, y=0,
			width=74, height=64,
			frame_count=1,
			shift={ 0.03125, 0.25, },
			scale=1,
			hr_version={
				filename=COMBINATOR_HR_SPRITE,
				priority="high",
				x=432, y=0,
				width=144, height=124,
				frame_count=1,
				shift={ 0.015625, 0.234375, },
				scale=0.5,
			},
		},
		{
			filename=COMBINATOR_SHADOW,
			priority="high",
			x=228, y=0,
			width=76, height=78,
			frame_count=1,
			shift={ 0.4375, 0.75, },
			draw_as_shadow=true,
			scale=1,
			hr_version={
				filename=COMBINATOR_HR_SHADOW,
				priority="high",
				x=444, y=0,
				width=148, height=156,
				frame_count=1,
				shift={ 0.421875, 0.765625, },
				draw_as_shadow=true,
				scale=0.5,
			},
		}
	}},
}

local function create_combinator_display_direction(x, y, shift)
	return {
			filename="__cybersyn__/graphics/combinator/cybernetic-displays.png",
			x=x, y=y,
			width=15, height=11,
			shift=shift,
			draw_as_glow=true,
			hr_version={
				scale=0.5,
				filename="__cybersyn__/graphics/combinator/hr-cybernetic-displays.png",
				x=2*x, y=2*y,
				width=30, height=22,
				shift=shift,
				draw_as_glow=true,
			},
		}
end
local function create_combinator_display(x, y, shiftv, shifth)
	return {
		north=create_combinator_display_direction(x, y, shiftv),
		east=create_combinator_display_direction(x, y, shifth),
		south=create_combinator_display_direction(x, y, shiftv),
		west=create_combinator_display_direction(x, y, shifth),
	}
end
combinator_entity.plus_symbol_sprites = create_combinator_display(0, 0, { 0, -0.140625, }, { 0, -0.328125, })
combinator_entity.minus_symbol_sprites = create_combinator_display(15, 0, { 0, -0.140625, }, { 0, -0.328125, })
combinator_entity.divide_symbol_sprites = create_combinator_display(30, 0, { 0, -0.140625, }, { 0, -0.328125, })
combinator_entity.modulo_symbol_sprites = create_combinator_display(45, 0, { 0, -0.140625, }, { 0, -0.328125, })
combinator_entity.power_symbol_sprites = create_combinator_display(0, 11, { 0, -0.140625, }, { 0, -0.328125, })
combinator_entity.left_shift_symbol_sprites = create_combinator_display(15, 11, { 0, -0.140625, }, { 0, -0.328125, })
combinator_entity.right_shift_symbol_sprites = create_combinator_display(30, 11, { 0, -0.140625, }, { 0, -0.328125, })
combinator_entity.multiply_symbol_sprites = combinator_entity.divide_symbol_sprites


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

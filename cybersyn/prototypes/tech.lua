--By Mami
combinator_recipe = flib.copy_prototype(data.raw["recipe"]["train-stop"], COMBINATOR_NAME)
combinator_recipe.ingredients = {
	{"copper-cable", 5},
	{"advanced-circuit", 5},
}
combinator_recipe.enabled = false
if (mods["nullius"]) then
	-- Enable recipe and place it just after regular station
	combinator_recipe.order = "nullius-eca"
	-- Use the same costs (minus the train stop) and metadata as for LTN
	combinator_recipe.category = "medium-crafting"
	combinator_recipe.always_show_made_in = true
	combinator_recipe.energy_required = 3
	combinator_recipe.ingredients = {
		{"arithmetic-combinator", 2},
		{"green-wire", 4}
	}
end

cybersyn_tech = {
	type = "technology",
	name = "cybersyn-train-network",
	icon = "__cybersyn__/graphics/icons/tech.png",
	icon_size = 256,
	--icon_mipmaps = 4,
	prerequisites = {
		"automated-rail-transportation",
		"circuit-network",
		"advanced-electronics"
	},
	effects = {
		{
			type = "unlock-recipe",
			recipe = COMBINATOR_NAME
		},
	},
	unit = {
		ingredients = {
			{"automation-science-pack", 1},
			{"logistic-science-pack", 1}
		},
		count = 250,
		time = 30
	},
	order = "c-g-c"
}

if (mods["nullius"]) then
	-- Enable technology
	cybersyn_tech.order = "nullius-" .. (cybersyn_tech.order or "")
	-- Use the same costs and requirements as for LTN
	cybersyn_tech.unit = {
		count = 100,
		ingredients = {
			{ "nullius-geology-pack", 1 }, { "nullius-climatology-pack", 1 },
			{ "nullius-mechanical-pack", 1 }, { "nullius-electrical-pack", 1 }
		},
		time = 25
	}
	cybersyn_tech.prerequisites = { "nullius-checkpoint-optimization", "nullius-traffic-control" }
	cybersyn_tech.ignore_cybersyn_tech_cost_multiplier = true
end
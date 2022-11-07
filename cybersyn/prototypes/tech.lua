--By Mami
combinator_recipe = flib.copy_prototype(data.raw["recipe"]["train-stop"], COMBINATOR_NAME)
combinator_recipe.ingredients = {
	{"copper-cable", 5},
	{"advanced-circuit", 5},
}
combinator_recipe.enabled = false

cybersyn_tech = {
	type = "technology",
	name = "cybersyn-train-network",
	icon = "__cybersyn__/graphics/icons/tech.png",
	icon_size = 64,
	icon_mipmaps = 4,
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

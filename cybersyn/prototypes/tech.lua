--By Mami
cybersyn_station_recipe = flib.copy_prototype(data.raw["recipe"]["train-stop"], BUFFER_STATION_NAME)
cybersyn_station_recipe.ingredients = {
	{"train-stop", 1},
	{"advanced-circuit", 5},
}
cybersyn_station_recipe.enabled = false

cybersyn_depot_recipe = flib.copy_prototype(data.raw["recipe"]["train-stop"], BUFFER_STATION_NAME)
cybersyn_depot_recipe.ingredients = {
	{"train-stop", 1},
	{"electronic-circuit", 5},
}
cybersyn_depot_recipe.enabled = false

cybersyn_tech = {
	type = "technology",
	name = "cybernetic-train-network",
	icon = "__cybersyn__/graphics/icon/tech.png",
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
			recipe = BUFFER_STATION_NAME
		},
		{
			type = "unlock-recipe",
			recipe = DEPOT_STATION_NAME
		},
	},
	unit = {
		ingredients = {
			{"automation-science-pack", 1},
			{"logistic-science-pack", 1}
		},
		count = 300,
		time = 30
	},
	order = "c-g-c"
}

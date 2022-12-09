--By Mami
combinator_recipe = flib.copy_prototype(data.raw["recipe"]["arithmetic-combinator"], COMBINATOR_NAME)
combinator_recipe.ingredients = {
	{"copper-cable", 20},
	{"electronic-circuit", 10},
}
combinator_recipe.enabled = false


cybersyn_tech = flib.copy_prototype(data.raw["technology"]["automated-rail-transportation"], "cybersyn-train-network")

cybersyn_tech.icon = "__cybersyn__/graphics/icons/tech.png"
cybersyn_tech.icon_size = 256
cybersyn_tech.prerequisites = {
	"automated-rail-transportation",
	"circuit-network",
}
cybersyn_tech.effects = {
	{
		type = "unlock-recipe",
		recipe = COMBINATOR_NAME
	},
}
cybersyn_tech.unit.count = 3*cybersyn_tech.unit.count
cybersyn_tech.order = "c-g-c"

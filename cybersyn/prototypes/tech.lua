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
	"rail-signals",
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


if (mods["nullius"]) then
	-- Enable recipe and place it just after regular station
	combinator_recipe.order = "nullius-eca"
	-- In Nullius, most combinators are tiny crafts
	combinator_recipe.category = "tiny-crafting"
	combinator_recipe.always_show_made_in = true
	combinator_recipe.energy_required = 3
	combinator_recipe.ingredients = {
		{"arithmetic-combinator", 2},
		{"copper-cable", 10}
	}
	-- Enable technology
	cybersyn_tech.order = "nullius-" .. (cybersyn_tech.order or "")
	cybersyn_tech.unit = {
		count = 100,
		ingredients = {
			{"nullius-geology-pack", 1}, {"nullius-climatology-pack", 1}, {"nullius-mechanical-pack", 1}, {"nullius-electrical-pack", 1}
		},
		time = 25
	}
	cybersyn_tech.prerequisites = { "nullius-checkpoint-optimization", "nullius-traffic-control" }
	cybersyn_tech.ignore_tech_tech_cost_multiplier = true
end

--By Mami
combinator_item = flib.copy_prototype(data.raw["item"]["arithmetic-combinator"], COMBINATOR_NAME)
combinator_item.icon = "__cybersyn__/graphics/icons/cybernetic-combinator.png"
combinator_item.icon_size = 64
combinator_item.icon_mipmaps = 4
combinator_item.subgroup = data.raw["item"]["train-stop"].subgroup
combinator_item.order = data.raw["item"]["train-stop"].order.."-b"
combinator_item.place_result = COMBINATOR_NAME
if mods["nullius"] then
	combinator_item.localised_name = { "item-name.cybersyn-combinator" }
	-- Enable item in Nullius and place next to the regular train stop
	combinator_item.order = "nullius-eca"
end

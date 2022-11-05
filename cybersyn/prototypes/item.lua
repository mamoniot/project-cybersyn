--By Mami
combinator_item = flib.copy_prototype(data.raw["item"]["arithmetic-combinator"], COMBINATOR_NAME)
combinator_item.icon = "__cybersyn__/graphics/icons/cybernetic-combinator.png"
combinator_item.icon_size = 64
combinator_item.icon_mipmaps = 4
combinator_item.order = data.raw["item"]["decider-combinator"].order.."-b"
combinator_item.place_result = COMBINATOR_NAME

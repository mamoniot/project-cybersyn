--By Mami
cybersyn_station_entity = flib.copy_prototype(data.raw["train-stop"]["train-stop"], BUFFER_STATION_NAME)
cybersyn_station_entity.icon = "__cybersyn__/graphics/icons/station.png"
cybersyn_station_entity.icon_size = 64
cybersyn_station_entity.icon_mipmaps = 4
cybersyn_station_entity.next_upgrade = nil

cybersyn_depot_entity = flib.copy_prototype(data.raw["train-stop"]["train-stop"], DEPOT_STATION_NAME)
cybersyn_depot_entity.icon = "__cybersyn__/graphics/icons/depot.png"
cybersyn_depot_entity.icon_size = 64
cybersyn_depot_entity.icon_mipmaps = 4
cybersyn_depot_entity.next_upgrade = nil

cybersyn_station_in = flib.copy_prototype(data.raw["lamp"]["small-lamp"], STATION_IN_NAME)
cybersyn_station_in.icon = "__cybersyn__/graphics/icons/station.png"
cybersyn_station_in.icon_size = 64
cybersyn_station_in.icon_mipmaps = 4
cybersyn_station_in.next_upgrade = nil
cybersyn_station_in.minable = nil
cybersyn_station_in.selection_box = {{-0.5, -0.5}, {0.5, 0.5}}
cybersyn_station_in.selection_priority = 60
cybersyn_station_in.collision_box = {{-0.15, -0.15}, {0.15, 0.15}}
cybersyn_station_in.collision_mask = {"rail-layer"}
cybersyn_station_in.energy_usage_per_tick = "10W"
cybersyn_station_in.light = {intensity = 1, size = 6}
cybersyn_station_in.energy_source = {type="void"}

cybersyn_station_out = flib.copy_prototype(data.raw["constant-combinator"]["constant-combinator"],STATION_OUT_NAME)
cybersyn_station_out.icon = "__cybersyn__/graphics/icons/station.png"
cybersyn_station_out.icon_size = 64
cybersyn_station_out.icon_mipmaps = 4
cybersyn_station_out.next_upgrade = nil
cybersyn_station_out.minable = nil
cybersyn_station_out.selection_box = {{-0.5, -0.5}, {0.5, 0.5}}
cybersyn_station_out.selection_priority = 60
cybersyn_station_out.collision_box = {{-0.15, -0.15}, {0.15, 0.15}}
cybersyn_station_out.collision_mask = {"rail-layer"}

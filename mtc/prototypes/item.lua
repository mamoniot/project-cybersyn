--By Mami
cybersyn_station_item = flib.copy_prototype(data.raw["item"]["train-stop"], BUFFER_STATION_NAME)
cybersyn_station_item.icon = "__cybersyn__/graphics/icons/station.png"
cybersyn_station_item.icon_size = 64
cybersyn_station_item.icon_mipmaps = 4
cybersyn_station_item.order = cybersyn_station_item.order.."-c"

cybersyn_depot_item = flib.copy_prototype(data.raw["item"]["train-stop"], DEPOT_STATION_NAME)
cybersyn_depot_item.icon = "__cybersyn__/graphics/icons/depot.png"
cybersyn_depot_item.icon_size = 64
cybersyn_depot_item.icon_mipmaps = 4
cybersyn_depot_item.order = cybersyn_depot_item.order.."-d"

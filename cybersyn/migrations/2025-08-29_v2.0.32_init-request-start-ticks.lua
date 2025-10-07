-- Initialize request_start_ticks for existing stations to prevent showing incorrect wait times
-- This migration ensures that old saves don't show wait times starting from tick 0

-- Always clear any existing request_start_ticks data to ensure a clean slate
-- This prevents showing wait times like "178 hours" when loading old saves
if storage and storage.map_data then
	for _, map_data in pairs(storage.map_data) do
		if map_data.stations then
			for _, station in pairs(map_data.stations) do
				station.request_start_ticks = nil
			end
		end
	end
end
-- Suggestions engine for Cybersyn
-- Analyzes delivery analytics data to provide performance recommendations

local analytics = require("scripts.analytics")

local suggestions = {}

local THRESHOLDS = {
	loading_pct = 30,
	unloading_pct = 30,
	wait_pct = 40,
	travel_pct = 50,
	low_util_pct = 30,
	high_util_pct = 95,
	slow_item_multiplier = 2.0,
	min_deliveries = 5,
}

---@class Suggestion
---@field type string
---@field identifier string
---@field icon string?
---@field title string
---@field percentage number
---@field avg_time number?
---@field dismissal_key string

---@param seconds number
---@return string
local function format_time(seconds)
	if seconds < 60 then
		return string.format("%.1fs", seconds)
	elseif seconds < 3600 then
		local mins = math.floor(seconds / 60)
		local secs = seconds % 60
		return string.format("%dm %.0fs", mins, secs)
	else
		local hours = math.floor(seconds / 3600)
		local mins = math.floor((seconds % 3600) / 60)
		return string.format("%dh %dm", hours, mins)
	end
end

---@param deliveries table[]
---@return table?
local function calculate_item_stats(deliveries)
	local count = #deliveries
	if count < THRESHOLDS.min_deliveries then
		return nil
	end

	local total_wait, total_travel_p, total_loading = 0, 0, 0
	local total_travel_r, total_unloading, total_time = 0, 0, 0

	for _, d in ipairs(deliveries) do
		total_wait = total_wait + (d.wait or 0)
		total_travel_p = total_travel_p + (d.travel_to_p or 0)
		total_loading = total_loading + (d.loading or 0)
		total_travel_r = total_travel_r + (d.travel_to_r or 0)
		total_unloading = total_unloading + (d.unloading or 0)
		local delivery_total = (d.wait or 0) + (d.travel_to_p or 0) + (d.loading or 0) +
			(d.travel_to_r or 0) + (d.unloading or 0)
		total_time = total_time + delivery_total
	end

	if total_time == 0 then
		return nil
	end

	return {
		loading_pct = (total_loading / total_time) * 100,
		unloading_pct = (total_unloading / total_time) * 100,
		wait_pct = (total_wait / total_time) * 100,
		travel_pct = ((total_travel_p + total_travel_r) / total_time) * 100,
		avg_loading = total_loading / count,
		avg_unloading = total_unloading / count,
		avg_wait = total_wait / count,
		avg_travel = (total_travel_p + total_travel_r) / count,
		avg_total = total_time / count,
		count = count,
	}
end

---@param item_hash string
---@return string
local function get_item_sprite(item_hash)
	local name = item_hash:match("^([^:]+)")
	if not name then
		name = item_hash
	end

	if prototypes.item[name] then
		return "item/" .. name
	end
	if prototypes.fluid[name] then
		return "fluid/" .. name
	end
	if prototypes.virtual_signal[name] then
		return "virtual-signal/" .. name
	end
	return "utility/questionmark"
end

---@param item_hash string
---@return string|table
local function get_item_name(item_hash)
	local name = item_hash:match("^([^:]+)")
	if not name then
		name = item_hash
	end

	local item_proto = prototypes.item[name]
	if item_proto then
		return item_proto.localised_name
	end

	local fluid_proto = prototypes.fluid[name]
	if fluid_proto then
		return fluid_proto.localised_name
	end

	local signal_proto = prototypes.virtual_signal[name]
	if signal_proto then
		return signal_proto.localised_name
	end

	return name
end

---Single-pass generation of all phase-based suggestions (loading, unloading, wait, travel)
---@param map_data MapData
---@param result Suggestion[]
local function generate_phase_suggestions(map_data, result)
	local data = map_data.analytics
	if not data or not data.completed_deliveries then return end

	for item_hash, deliveries in pairs(data.completed_deliveries) do
		local stats = calculate_item_stats(deliveries)
		if stats then
			local icon = get_item_sprite(item_hash)
			local title = get_item_name(item_hash)

			if stats.loading_pct > THRESHOLDS.loading_pct then
				result[#result + 1] = {
					type = "loading",
					identifier = item_hash,
					icon = icon,
					title = title,
					percentage = stats.loading_pct,
					avg_time = stats.avg_loading,
					dismissal_key = "loading:" .. item_hash,
				}
			end

			if stats.unloading_pct > THRESHOLDS.unloading_pct then
				result[#result + 1] = {
					type = "unloading",
					identifier = item_hash,
					icon = icon,
					title = title,
					percentage = stats.unloading_pct,
					avg_time = stats.avg_unloading,
					dismissal_key = "unloading:" .. item_hash,
				}
			end

			if stats.wait_pct > THRESHOLDS.wait_pct then
				result[#result + 1] = {
					type = "wait",
					identifier = item_hash,
					icon = icon,
					title = title,
					percentage = stats.wait_pct,
					avg_time = stats.avg_wait,
					dismissal_key = "wait:" .. item_hash,
				}
			end

			if stats.travel_pct > THRESHOLDS.travel_pct then
				result[#result + 1] = {
					type = "travel",
					identifier = item_hash,
					icon = icon,
					title = title,
					percentage = stats.travel_pct,
					avg_time = stats.avg_travel,
					dismissal_key = "travel:" .. item_hash,
				}
			end
		end
	end
end

---@param map_data MapData
---@param result Suggestion[]
local function generate_utilization_suggestions(map_data, result)
	local data = map_data.analytics
	if not data or not data.train_utilization then return end

	local interval = data.train_utilization[4]
	if not interval or not interval.sum or not next(interval.sum) then return end

	for layout_id_str, sum in pairs(interval.sum) do
		local count = interval.counts[layout_id_str] or 1
		local avg_util = sum / count

		local layout_id = tonumber(layout_id_str)
		local layout = layout_id and map_data.layouts[layout_id]
		local layout_name = analytics.format_layout_name(layout, layout_id)

		if avg_util < THRESHOLDS.low_util_pct then
			result[#result + 1] = {
				type = "low_util",
				identifier = layout_id_str,
				icon = "item/locomotive",
				title = layout_name,
				percentage = avg_util,
				avg_time = nil,
				dismissal_key = "low_util:" .. layout_id_str,
			}
		elseif avg_util > THRESHOLDS.high_util_pct then
			result[#result + 1] = {
				type = "high_util",
				identifier = layout_id_str,
				icon = "item/locomotive",
				title = layout_name,
				percentage = avg_util,
				avg_time = nil,
				dismissal_key = "high_util:" .. layout_id_str,
			}
		end
	end
end

---@param map_data MapData
---@param result Suggestion[]
local function generate_slow_item_suggestions(map_data, result)
	local data = map_data.analytics
	if not data or not data.total_time_ema then return end

	local times = {}
	for item_hash, ema in pairs(data.total_time_ema) do
		times[#times + 1] = {item_hash = item_hash, time = ema}
	end

	if #times < 3 then return end

	table.sort(times, function(a, b) return a.time < b.time end)
	local median = times[math.ceil(#times / 2)].time

	local threshold = median * THRESHOLDS.slow_item_multiplier
	for _, entry in ipairs(times) do
		if entry.time > threshold then
			result[#result + 1] = {
				type = "slow_item",
				identifier = entry.item_hash,
				icon = get_item_sprite(entry.item_hash),
				title = get_item_name(entry.item_hash),
				percentage = (entry.time / median) * 100,
				avg_time = entry.time,
				dismissal_key = "slow_item:" .. entry.item_hash,
			}
		end
	end
end

---@param map_data MapData
---@return Suggestion[]
function suggestions.generate(map_data)
	if not analytics.is_enabled() then return {} end
	if not map_data.analytics then return {} end

	local result = {}

	generate_phase_suggestions(map_data, result)
	generate_utilization_suggestions(map_data, result)
	generate_slow_item_suggestions(map_data, result)

	return result
end

---@return table
function suggestions.get_thresholds()
	return THRESHOLDS
end

---@param seconds number
---@return string
function suggestions.format_time(seconds)
	return format_time(seconds)
end

return suggestions

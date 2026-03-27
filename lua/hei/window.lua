local M = {}

local active_windows = {}

---@class hei.Window
---@field window_id number
---@field buffer_id number
---@field config fun(): table

--- @return number
--- @return number
local function get_ui_dimensions()
	local ui = vim.api.nvim_list_uis()[1]
	return ui.width, ui.height
end

--- @param title string
--- @return vim.api.keyset.win_config
function M.create_centered_config(title, width_percentage, height_percentage)
	local width, height = get_ui_dimensions()
	local win_width = math.floor(width * width_percentage)
	local win_height = math.floor(height * height_percentage)
	return {
		relative = "editor",
		title = title,
		title_pos = "center",
		style = "minimal",
		border = "rounded",
		zindex = 1,
		row = math.floor((height - win_height) / 2),
		col = math.floor((width - win_width) / 2),
		width = win_width,
		height = win_height,
	}
end

--- @param config_func fun(): table
--- @param enter boolean
--- return hei.Window
function M.create_floating_window(config_func, enter)
	local buffer_id = vim.api.nvim_create_buf(false, true)
	local window_id = vim.api.nvim_open_win(buffer_id, enter, config_func())
	vim.wo[window_id].wrap = true

	local window = {
		window_id = window_id,
		buffer_id = buffer_id,
		config = config_func,
	}
	table.insert(active_windows, window)

	return window
end

--- @param window hei.Window
function close_window(window)
	vim.api.nvim_win_close(window.window_id, true)
	for i, w in ipairs(active_windows) do
		if w.win_id == w.window_id then
			table.remove(active_windows, i)
			break
		end
	end
end

function close_all_windows()
	for _, w in ipairs(active_windows) do
		vim.api.nvim_win_close(w.window_id, true)
	end
	active_windows = {}
end

vim.api.nvim_create_autocmd("VimResized", {
	callback = function()
		for _, w in ipairs(active_windows) do
			if w.config and vim.api.nvim_win_is_valid(w.window_id) then
				vim.api.nvim_win_set_config(w.window_id, w.config())
			end
		end
	end,
})

return M

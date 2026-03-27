local function get_ui_dimensions()
	local ui = vim.api.nvim_list_uis()[1]
	return ui.width, ui.height
end

local function create_centered_window()
	local width, height = get_ui_dimensions()
	local win_width = math.floor(width * 2 / 3)
	local win_height = math.floor(height / 3)
	return {
		width = win_width,
		height = win_height,
		row = math.floor((height - win_height) / 2),
		col = math.floor((width - win_width) / 2),
		border = "rounded",
	}
end

local function create_floating_window(config, enter, title)
	local buf = vim.api.nvim_create_buf(false, true)
	local win = vim.api.nvim_open_win(buf, enter, {
		relative = config.relative or "editor",
		style = "minimal",
		title = config.title or title,
		title_pos = config.title_pos or "center",
		border = config.border,
		zindex = config.zindex or 1,
		row = config.row or 0,
		col = config.col or 0,
		width = config.width,
		height = config.height,
	})

	return { buf = buf, win = win }
end

local M = {}

---@class hei.Window
---@field window_id number
---@field buffer_id number
---@field config fun(): table

---@type hei.Window | nil
local window_active = nil

--- @return number
--- @return number
local function get_ui_dimensions()
	local ui = vim.api.nvim_list_uis()[1]
	return ui.width, ui.height
end

--- @return vim.api.keyset.win_config
local function create_centered_config(width_percentage, height_percentage)
	local width, height = get_ui_dimensions()
	local win_width = math.floor(width * width_percentage)
	local win_height = math.floor(height * height_percentage)
	return {
		relative = "editor",
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
local function create_floating_window(config_func, enter)
	local buffer_id = vim.api.nvim_create_buf(false, true)
	vim.bo[buffer_id].bufhidden = "wipe"
	vim.bo[buffer_id].swapfile = false

	local window_id = vim.api.nvim_open_win(buffer_id, enter, config_func())
	vim.wo[window_id].wrap = true

	window_active = {
		window_id = window_id,
		buffer_id = buffer_id,
		config = config_func,
	}
	return window_active
end

local function close_window_active()
	if not window_active then
		return
	end

	if vim.api.nvim_win_is_valid(window_active.window_id) then
		vim.api.nvim_win_close(window_active.window_id, true)
	end

	window_active = nil
end

vim.api.nvim_create_autocmd("VimResized", {
	callback = function()
		if window_active and vim.api.nvim_win_is_valid(window_active.window_id) then
			vim.api.nvim_win_set_config(window_active.window_id, window_active.config())
		end
	end,
})

---@class hei.InputOpts
---@field mode string
---@field visual boolean
---@field on_mode_change fun(new_mode: string)
---@field on_submit fun(prompt: string)
---@field on_cancel fun()

function M.open_input(modes, opts)
	close_window_active()

	local mode_index = 1
	for i, m in ipairs(modes) do
		if m == opts.mode then
			mode_index = i
			break
		end
	end

	local config = function()
		local mode_highlights = {
			ask = "DiagnosticWarn",
			vibe = "DiagnosticError",
			tutorial = "DiagnosticHint",
		}

		local mode = modes[mode_index]
		local label = opts.visual and "Visual " .. mode or mode

		local config = create_centered_config(0.6, 0.20)
		config.footer =
			{ { "[" .. label .. "]  :w submit  q/Esc cancel  <Tab> mode", mode_highlights[mode] or "Comment" } }
		config.footer_pos = "center"
		return config
	end

	local window = create_floating_window(config, true)
	vim.bo[window.buffer_id].buftype = "acwrite"
	vim.cmd("startinsert")

	vim.api.nvim_create_autocmd("BufWriteCmd", {
		buffer = window.buffer_id,
		callback = function()
			local lines = vim.api.nvim_buf_get_lines(window.buffer_id, 0, -1, false)
			local prompt = vim.trim(table.concat(lines, "\n"))
			if prompt == "" then
				return
			end
			close_window_active()
			vim.cmd("stopinsert")
			opts.on_submit(prompt)
		end,
	})

	local function cycle_mode(delta)
		mode_index = ((mode_index - 1 + delta) % #modes) + 1
		vim.api.nvim_win_set_config(window.window_id, config())
		opts.on_mode_change(modes[mode_index])
	end

	vim.keymap.set({ "i", "n" }, "<Tab>", function()
		cycle_mode(1)
	end, { buffer = window.buffer_id })

	vim.keymap.set({ "i", "n" }, "<S-Tab>", function()
		cycle_mode(-1)
	end, { buffer = window.buffer_id })

	vim.keymap.set("n", "q", function()
		close_window_active()
		vim.cmd("stopinsert")
		opts.on_cancel()
	end, { buffer = window.buffer_id, nowait = true })

	return window
end

return M

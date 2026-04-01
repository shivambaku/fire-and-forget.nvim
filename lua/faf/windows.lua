local M = {}

---@class faf.Window
---@field window_id number
---@field buffer_id number
---@field config fun(): table

---@type faf.Window | nil
local window_active = nil

local ns = vim.api.nvim_create_namespace("faf")

local mode_hl = {
	ask = "DiagnosticWarn",
	vibe = "DiagnosticError",
	tutorial = "DiagnosticHint",
}

local state_hl = {
	done = "DiagnosticOk",
	running = "DiagnosticWarn",
	failed = "DiagnosticError",
	cancelled = "Comment",
}

---@return number width
---@return number height
local function get_ui_dimensions()
	local ui = vim.api.nvim_list_uis()[1]
	return ui.width, ui.height
end

---@param width_percentage number
---@param height_percentage number
---@return vim.api.keyset.win_config
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

---@param config_func fun(): table
---@param enter boolean
---@return faf.Window
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

---@class faf.SplitOpts
---@field mode string
---@field session_id string | nil
---@field on_reply fun(prompt: string) | nil

---@param content_lines string[]
---@param opts faf.SplitOpts?
---@return number window_id
local function create_split_window(content_lines, opts)
	opts = opts or {}
	local can_reply = opts.session_id ~= nil

	vim.cmd("rightbelow vsplit")
	local split_win = vim.api.nvim_get_current_win()
	local split_buf = vim.api.nvim_create_buf(false, false)
	vim.api.nvim_win_set_buf(split_win, split_buf)
	vim.api.nvim_buf_set_lines(split_buf, 0, -1, false, content_lines)
	vim.bo[split_buf].buftype = "nofile"
	vim.bo[split_buf].filetype = "markdown"
	vim.bo[split_buf].modifiable = false
	vim.bo[split_buf].buflisted = false
	vim.bo[split_buf].bufhidden = "wipe"
	vim.wo[split_win].wrap = true
	vim.wo[split_win].linebreak = true
	vim.api.nvim_buf_set_name(split_buf, "faf response")
	vim.keymap.set("n", "q", function()
		vim.api.nvim_win_close(split_win, false)
	end, { buffer = split_buf, nowait = true })
	if can_reply and opts.on_reply then
		vim.keymap.set("n", "r", function()
			vim.api.nvim_win_close(split_win, false)
			M.open_input({ opts.mode }, {
				mode = opts.mode,
				visual = false,
				on_mode_change = function() end,
				on_submit = opts.on_reply,
				on_cancel = function() end,
			})
		end, { buffer = split_buf, nowait = true })
	end
	return split_win
end

---@class faf.InputOpts
---@field mode string
---@field visual boolean
---@field on_mode_change fun(new_mode: string)
---@field on_submit fun(prompt: string)
---@field on_cancel fun()

---@param modes string[]
---@param opts faf.InputOpts
---@return faf.Window
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
		local mode = modes[mode_index]
		local label = opts.visual and "visual " .. mode or mode

		local config = create_centered_config(0.6, 0.20)
		config.footer = { { "[" .. label .. "]  :w submit  q/Esc cancel  <Tab> mode", mode_hl[mode] or "Comment" } }
		config.footer_pos = "center"
		return config
	end

	local window = create_floating_window(config, true)
	vim.api.nvim_buf_set_name(window.buffer_id, "faf://input")
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

	local function close()
		close_window_active()
		vim.cmd("stopinsert")
		opts.on_cancel()
	end

	vim.keymap.set({ "i", "n" }, "<Tab>", function()
		cycle_mode(1)
	end, { buffer = window.buffer_id })

	vim.keymap.set({ "i", "n" }, "<S-Tab>", function()
		cycle_mode(-1)
	end, { buffer = window.buffer_id })

	vim.keymap.set("n", "q", close, { buffer = window.buffer_id, nowait = true })

	return window
end

---@class faf.ListOpts
---@field items { display: string, id: number, state: string, label: string, mode: string, req_mode: string, has_qfix: boolean }[]
---@field on_select fun(id: number, cursor_pos: number)
---@field on_cancel fun(id: number)
---@field on_split fun(id: number)

---@param opts faf.ListOpts
---@return faf.Window
function M.open_list(opts)
	close_window_active()

	local function get_footer_text()
		if #opts.items == 0 then
			return "  No requests yet"
		end
		local lnum = vim.api.nvim_win_get_cursor(window_active and window_active.window_id or 0)[1] or 1
		local item = opts.items[lnum]
		if item and not item.has_qfix then
			return "  <CR> view  s split  d cancel  q close"
		end
		return "  <CR> view  d cancel  q close"
	end

	local config = function()
		local config = create_centered_config(0.8, 0.6)
		config.footer = { { get_footer_text(), "Comment" } }
		config.footer_pos = "center"
		return config
	end

	local window = create_floating_window(config, true)
	vim.bo[window.buffer_id].buftype = "nofile"
	vim.wo[window.window_id].cursorline = true
	vim.wo[window.window_id].number = false
	vim.wo[window.window_id].wrap = false

	local lines = #opts.items > 0 and vim.tbl_map(function(i)
		return i.display
	end, opts.items) or { "  No requests yet" }

	vim.api.nvim_buf_set_lines(window.buffer_id, 0, -1, false, lines)
	vim.bo[window.buffer_id].modifiable = false

	for i, item in ipairs(opts.items) do
		local sh = state_hl[item.state]
		if sh then
			vim.hl.range(window.buffer_id, ns, sh, { i - 1, 0 }, { i - 1, 11 }, {})
		end
		local mh = mode_hl[item.req_mode]
		if mh then
			vim.hl.range(window.buffer_id, ns, mh, { i - 1, 11 }, { i - 1, 21 }, {})
		end
	end

	local function update_footer()
		if window_active and vim.api.nvim_win_is_valid(window_active.window_id) then
			vim.api.nvim_win_set_config(window_active.window_id, config())
		end
	end

	local function select()
		if #opts.items == 0 then
			return
		end
		local lnum = vim.api.nvim_win_get_cursor(window.window_id)[1]
		local item = opts.items[lnum]
		if item then
			close_window_active()
			opts.on_select(item.id, lnum)
		end
	end

	local function split_request()
		if #opts.items == 0 then
			return
		end
		local lnum = vim.api.nvim_win_get_cursor(window.window_id)[1]
		local item = opts.items[lnum]
		if item and not item.has_qfix and opts.on_split then
			close_window_active()
			opts.on_split(item.id)
		end
	end

	local function cancel_request()
		if #opts.items == 0 then
			return
		end
		local lnum = vim.api.nvim_win_get_cursor(window.window_id)[1]
		local item = opts.items[lnum]
		if item and item.state == "running" then
			opts.on_cancel(item.id)
			item.state = "cancelled"
			item.label = "[cancelled]"
			item.display = item.display:gsub("^%[running%]", "[cancelled]")
			vim.bo[window.buffer_id].modifiable = true
			vim.api.nvim_buf_set_lines(window.buffer_id, lnum - 1, lnum, false, { item.display })
			vim.bo[window.buffer_id].modifiable = false
			vim.hl.range(window.buffer_id, ns, state_hl["cancelled"], { lnum - 1, 0 }, { lnum - 1, 11 }, {})
			local mh = mode_hl[item.req_mode]
			if mh then
				vim.hl.range(window.buffer_id, ns, mh, { lnum - 1, 11 }, { lnum - 1, 21 }, {})
			end
		end
	end

	vim.api.nvim_create_autocmd("CursorMoved", {
		buffer = window.buffer_id,
		callback = update_footer,
	})

	vim.keymap.set("n", "-", "<NOP>", { buffer = window.buffer_id })

	vim.keymap.set("n", "<CR>", select, { buffer = window.buffer_id })

	vim.keymap.set("n", "s", split_request, { buffer = window.buffer_id })

	vim.keymap.set("n", "d", cancel_request, { buffer = window.buffer_id })

	vim.keymap.set("n", "q", close_window_active, { buffer = window.buffer_id, nowait = true })

	vim.keymap.set("n", "<Esc>", close_window_active, { buffer = window.buffer_id })

	return window
end

---@param items {filename: string, lnum: number, col: number, text: string}[]
---@param title string
function M.open_quickfix(items, title)
	close_window_active()
	vim.fn.setqflist({}, "r", { title = title, items = items })
	vim.cmd("copen")
end

---@class faf.ResponseOpts
---@field id number
---@field mode string
---@field session_id string | nil
---@field started_at number
---@field content string
---@field on_back fun() | nil
---@field on_reply fun(prompt: string) | nil

---@param opts faf.ResponseOpts
---@return faf.Window
function M.open_response(opts)
	close_window_active()

	local time = os.date("%H:%M", opts.started_at)
	local can_reply = opts.session_id ~= nil

	local config = function()
		local footer_text = "  [" .. opts.mode .. "] " .. time .. "  q back  s split"
		if can_reply then
			footer_text = footer_text .. "  r reply"
		end
		local config = create_centered_config(0.8, 0.8)
		config.footer = {
			{ footer_text, "Comment" },
		}
		config.footer_pos = "center"
		return config
	end

	local window = create_floating_window(config, true)
	vim.bo[window.buffer_id].buftype = "nofile"
	vim.bo[window.buffer_id].filetype = "markdown"
	vim.wo[window.window_id].linebreak = true

	local content_lines = vim.split(opts.content, "\n")
	vim.api.nvim_buf_set_lines(window.buffer_id, 0, -1, false, content_lines)
	vim.bo[window.buffer_id].modifiable = false

	local function open_split()
		close_window_active()
		create_split_window(content_lines, {
			mode = opts.mode,
			session_id = opts.session_id,
			on_reply = opts.on_reply,
		})
	end

	local function reply()
		if not can_reply or not opts.on_reply then
			return
		end
		close_window_active()
		M.open_input({ opts.mode }, {
			mode = opts.mode,
			visual = false,
			on_mode_change = function() end,
			on_submit = opts.on_reply,
			on_cancel = function() end,
		})
	end

	vim.keymap.set("n", "q", function()
		close_window_active()
		if opts.on_back then
			opts.on_back()
		end
	end, { buffer = window.buffer_id, nowait = true })

	vim.keymap.set("n", "-", function()
		close_window_active()
		if opts.on_back then
			opts.on_back()
		end
	end, { buffer = window.buffer_id, nowait = true })

	vim.keymap.set("n", "s", open_split, { buffer = window.buffer_id })

	vim.keymap.set("n", "r", reply, { buffer = window.buffer_id })

	vim.keymap.set("n", "<Esc>", close_window_active, { buffer = window.buffer_id })

	return window
end

---@param opts faf.ResponseOpts
---@return number window_id
function M.open_response_split(opts)
	return create_split_window(vim.split(opts.content, "\n"), {
		mode = opts.mode,
		session_id = opts.session_id,
		on_reply = opts.on_reply,
	})
end

return M

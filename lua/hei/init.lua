local window = require("hei.window")

local M = {}

local modes = { "ask", "vibe", "tutorial" }

local agent_map = {
	ask = "plan",
	vibe = "build",
	tutorial = "plan",
}

local tutorial_prefix = [[You are given a prompt and you must craft a tutorial.
Read through any relevant context thoroughly before crafting the tutorial.

<Rule>The response format must be valid Markdown</Rule>
<Rule>The first line of the response must be the title of the tutorial</Rule>

Topic:
]]

local defaults = {
	model = nil,
	max_history = 50,
	keymaps = {
		input = "<leader>ii",
		list = "<leader>io",
		cancel = "<leader>ix",
	},
}

local options = {}

---@return string[] | nil
local function capture_visual()
	local mode = vim.api.nvim_get_mode().mode
	if mode ~= "v" and mode ~= "V" and mode ~= "\22" then
		return nil
	end
	local lines = vim.fn.getregion(vim.fn.getpos("v"), vim.fn.getpos("."))
	if #lines == 0 then
		return nil
	end
	return lines
end

local function cmd_input()
	local visual_text = capture_visual()
	if visual_text ~= nil then
		print(table.concat(visual_text, "\n"))
	end

	local config = function()
		return window.create_centered_config("title", 0.64, 0.32)
	end

	window.create_floating_window(config, true)
end

local function cmd_list()
	vim.notify("hei: all requests cancelled", vim.log.levels.INFO)
end

local function cmd_cancel()
	vim.notify("hei: all requests cancelled", vim.log.levels.INFO)
end

---@param opts? { model?: string, max_history?: number, keymaps?: boolean | table }
function M.setup(opts)
	options = vim.tbl_deep_extend("force", defaults, opts or {})

	-- requests.setup({ max_history = options.max_history })

	vim.api.nvim_create_user_command("HeiInput", cmd_input, {})
	vim.api.nvim_create_user_command("HeiList", cmd_list, {})
	vim.api.nvim_create_user_command("HeiCancel", cmd_cancel, {})

	local km = options.keymaps
	if km == false then
		return
	end

	if km.input then
		vim.keymap.set({ "n", "v" }, km.input, cmd_input, { desc = "hei: input" })
	end
	if km.list then
		vim.keymap.set("n", km.list, cmd_list, { desc = "hei: open requests" })
	end
	if km.cancel then
		vim.keymap.set("n", km.cancel, cmd_cancel, { desc = "hei: cancel all" })
	end
end

return M

-- function M.setup(opts)
--   opts = opts or {}
--
--   requests.setup({ max_history = opts.max_history })
--   core.setup({ model = opts.model })
--
--   vim.keymap.set({ "n", "v" }, "<leader>ii", function()
--     local visual_text = core.capture_visual()
--     local has_selection = visual_text ~= nil
--     local modes = core.get_modes()
--     local current_mode = "ask"
--
--     win.open_input(modes, {
--       mode = current_mode,
--       has_selection = has_selection,
--       on_mode_change = function(new_mode)
--         current_mode = new_mode
--       end,
--       on_submit = function(prompt)
--         core.submit(current_mode, prompt, visual_text)
--       end,
--       on_cancel = function() end,
--     })
--   end, { desc = "hei: input" })
--
--   vim.keymap.set("n", "<leader>io", function()
--     open_request_list()
--   end, { desc = "hei: open requests" })
--
--   vim.keymap.set("n", "<leader>ix", function()
--     requests.cancel_all()
--     vim.notify("hei: all requests cancelled", vim.log.levels.INFO)
--   end, { desc = "hei: cancel all" })
-- end

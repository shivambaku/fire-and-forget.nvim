local windows = require("hei.windows")
local requests = require("hei.requests")
local qfix = require("hei.qfix")

local M = {}

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

local modes = { "ask", "vibe", "tutorial" }

local agent_map = {
	ask = "plan",
	vibe = "build",
	tutorial = "plan",
}

local mode_hints = {
	ask = [[
## Output
Provide your response. If you're surfacing file locations, include them in this format:
/absolute/path/to/file.lua:12:3,1,why this location matters

You may include both a response and file locations.

## Rules for file locations
- Use absolute paths only.
- Use 1-based line and column numbers.
- The value after the first comma is the line span.
- Notes must stay on one line.
]],
	vibe = [[
## Output
After making changes, list ALL modified files in this format:
/absolute/path/to/file.lua:12:3,1,description of change

## Rules
- Use absolute paths only.
- Use 1-based line and column numbers.
- The value after the first comma is the line span.
- Notes must stay on one line.
]],
	tutorial = [[
## Task
Write a tutorial for the topic above.
Read any provided context carefully before writing.

## Output
Return valid Markdown.
The first line must be a Markdown H1 title.

## Rules
- Be accurate and practical.
- Organize the tutorial with clear sections.
- Use examples when helpful.
]],
}

local state_labels = {
	done = "[done]     ",
	running = "[running]  ",
	failed = "[failed]   ",
	cancelled = "[cancelled]",
}

--- @return string[] | nil
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

---@param mode string
---@param prompt string
---@param visual_text string[]?
---@return string[]
local function build_command(mode, prompt, visual_text)
	local agent = agent_map[mode]
	local hint = mode_hints[mode]
	local full_prompt

	if visual_text then
		full_prompt = table.concat(visual_text, "\n") .. "\n\n" .. prompt .. "\n\n" .. hint
	else
		full_prompt = prompt .. "\n\n" .. hint
	end

	local cmd = { "opencode", "run", "--agent", agent }
	if options.model then
		vim.list_extend(cmd, { "-m", options.model })
	end
	table.insert(cmd, full_prompt)

	return cmd
end

---@param s string
---@param max_len number
---@return string
local function truncate(s, max_len)
	if #s > max_len then
		return s:sub(1, max_len - 3) .. "..."
	end
	return s
end

---@param obj vim.SystemCompleted
---@return string response
---@return "done" | "failed" state
local function parse_result(obj)
	local response = obj.stdout or ""
	if obj.code ~= 0 and response == "" then
		return "Error: exit code " .. obj.code .. "\n" .. (obj.stderr or ""), "failed"
	end
	return response, "done"
end

---@param id number
---@param response string
local function handle_qfix_result(id, response)
	local qfix_items = qfix.create_qfix_entries(response)
	requests.set_qfix_items(id, qfix_items)
	if #qfix_items > 0 then
		vim.notify("hei: " .. #qfix_items .. " locations found", vim.log.levels.INFO)
	end
end

---@param r hei.Request
---@return string
local function format_request(r)
	local label = state_labels[r.state] or ("[" .. r.state .. "]")
	return string.format("%s %s: %s", label, r.mode, truncate(r.prompt, 60))
end

---@param mode "ask" | "vibe" | "tutorial"
---@param prompt string
---@param visual_text string[]?
local function submit_request(mode, prompt, visual_text)
	local id = requests.add(mode, prompt, visual_text ~= nil)
	local cmd = build_command(mode, prompt, visual_text)

	local proc = vim.system(cmd, { text = true }, function(obj)
		vim.schedule(function()
			local response, state = parse_result(obj)
			requests.finish(id, response, state)
			if state == "done" then
				handle_qfix_result(id, response)
			end
			local req = requests.get(id)
			if req then
				local symbol = state == "done" and "✓" or "✗"
				local level = state == "done" and vim.log.levels.INFO or vim.log.levels.ERROR
				local prompt_short = truncate(req.prompt, 40)
				vim.notify("hei " .. symbol .. " " .. req.mode .. ": " .. prompt_short, level)
			end
		end)
	end)

	requests.set_handle(id, proc)
end

---@param id number
---@param on_back fun()?
local function select_request(id, on_back)
	local request = requests.get(id)
	if not request or not request.response then
		vim.notify("hei: no response to display", vim.log.levels.WARN)
		return
	end
	windows.open_response({
		mode = request.mode,
		started_at = request.started_at,
		content = request.response,
		qfix_items = request.qfix_items or {},
		on_back = on_back,
	})
end

---@param id number
local function cancel_request(id)
	requests.cancel(id)
	vim.notify("hei: request cancelled", vim.log.levels.INFO)
end

---@param restore_cursor number?
local function open_request_list(restore_cursor)
	local reqs = requests.list()
	local items = vim.iter(reqs)
		:map(function(r)
			return {
				display = format_request(r),
				id = r.id,
				state = r.state,
			}
		end)
		:totable()

	local window = windows.open_list({
		items = items,
		on_select = function(id, cursor_pos)
			select_request(id, function()
				open_request_list(cursor_pos)
			end)
		end,
		on_cancel = cancel_request,
	})

	if restore_cursor and window.window_id and vim.api.nvim_win_is_valid(window.window_id) then
		vim.api.nvim_win_set_cursor(window.window_id, { restore_cursor, 0 })
	end
end

local function cmd_input()
	local visual_text = capture_visual()
	local mode_current = "ask"

	windows.open_input(modes, {
		mode = mode_current,
		visual = visual_text ~= nil,
		on_mode_change = function(mode_new)
			mode_current = mode_new
		end,
		on_submit = function(prompt)
			submit_request(mode_current, prompt, visual_text)
		end,
		on_cancel = function() end,
	})
end

local function cmd_list()
	open_request_list()
end

local function cmd_cancel()
	requests.cancel_all()
	vim.notify("hei: all requests cancelled", vim.log.levels.INFO)
end

---@param opts? { model?: string, max_history?: number, keymaps?: boolean | table }
function M.setup(opts)
	options = vim.tbl_deep_extend("force", defaults, opts or {})
	requests.setup({ max_history = options.max_history })

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

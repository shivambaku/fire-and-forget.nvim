local windows = require("faf.windows")
local requests = require("faf.requests")
local qfix = require("faf.qfix")

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
- Do NOT wrap file paths in backticks or code formatting.
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
- Do NOT wrap file paths in backticks or code formatting.
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
	done = "[done]",
	running = "[running]",
	failed = "[failed]",
	cancelled = "[cancelled]",
}

---@param mode string
---@param prompt string
---@param visual_text string[]?
---@param session_id string?
---@return string[]
local function build_command(mode, prompt, visual_text, session_id)
	local agent = agent_map[mode]
	local hint = mode_hints[mode]
	local full_prompt

	if visual_text then
		full_prompt = table.concat(visual_text, "\n") .. "\n\n" .. prompt .. "\n\n" .. hint
		print(full_prompt)
	else
		full_prompt = prompt .. "\n\n" .. hint
	end

	local cmd = { "opencode", "run", "--format", "json", "--agent", agent }
	if session_id then
		vim.list_extend(cmd, { "--session", session_id })
	end
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

---@param stdout string
---@return string session_id
---@return string response
local function parse_json_result(stdout)
	local session_id = ""
	local response_parts = {}

	for line in stdout:gmatch("[^\n]+") do
		local ok, decoded = pcall(vim.json.decode, line)
		if ok and type(decoded) == "table" then
			if decoded.sessionID and session_id == "" then
				session_id = decoded.sessionID
			end
			if decoded.type == "text" and decoded.part and decoded.part.text then
				table.insert(response_parts, decoded.part.text)
			end
		end
	end

	return session_id, table.concat(response_parts, "\n")
end

---@param id number
---@param response string
local function handle_qfix_result(id, response)
	local qfix_items = qfix.create_qfix_entries(response)
	requests.set_qfix_items(id, qfix_items)
	if #qfix_items > 0 then
		vim.notify("faf: " .. #qfix_items .. " locations found", vim.log.levels.INFO)
	end
end

---@param r faf.Request
---@return string
---@return string state_label
---@return string mode_str
local function format_request(r)
	local label = state_labels[r.state] or ("[" .. r.state .. "]")
	local prompt_clean = r.prompt:gsub("\n", " "):gsub("%s+", " ")
	local mode_str = r.mode
	if r.qfix_items and #r.qfix_items > 0 then
		mode_str = r.mode .. ":" .. #r.qfix_items
	end
	return string.format("%-11s %-9s     %s", label, mode_str, prompt_clean), label, mode_str
end

---@param mode "ask" | "vibe" | "tutorial"
---@param prompt string
---@param visual_text string[]?
local function submit_request(mode, prompt, visual_text)
	local id = requests.add(mode, prompt, visual_text ~= nil)
	vim.cmd("redrawstatus")
	local cmd = build_command(mode, prompt, visual_text, nil)

	local proc = vim.system(cmd, { text = true }, function(obj)
		vim.schedule(function()
			local session_id, response = parse_json_result(obj.stdout or "")
			local state = "done"
			if obj.code ~= 0 and response == "" then
				response = "Error: exit code " .. obj.code .. "\n" .. (obj.stderr or "")
				state = "failed"
			end
			if state == "done" then
				handle_qfix_result(id, response)
			end
			requests.set_session_id(id, session_id)
			requests.finish(id, response, state)
			vim.cmd("redrawstatus")
			local req = requests.get(id)
			if req then
				local symbol = state == "done" and "✓" or "✗"
				local level = state == "done" and vim.log.levels.INFO or vim.log.levels.ERROR
				local prompt_short = truncate(req.prompt, 40)
				vim.notify("faf " .. symbol .. " " .. req.mode .. ": " .. prompt_short, level)
			end
		end)
	end)

	requests.set_handle(id, proc)
end

---@param id number
---@param prompt string
local function submit_followup(id, prompt)
	local req = requests.get(id)
	if not req or not req.session_id then
		vim.notify("faf: no session to continue", vim.log.levels.WARN)
		return
	end

	requests.set_state_running(id)
	vim.cmd("redrawstatus")

	local cmd = build_command(req.mode, prompt, nil, req.session_id)

	local proc = vim.system(cmd, { text = true }, function(obj)
		vim.schedule(function()
			local _, response = parse_json_result(obj.stdout or "")
			local state = "done"
			if obj.code ~= 0 and response == "" then
				response = "Error: exit code " .. obj.code .. "\n" .. (obj.stderr or "")
				state = "failed"
			end
			if state == "done" then
				handle_qfix_result(id, response)
			end
			requests.finish(id, response, state)
			vim.cmd("redrawstatus")
			vim.notify("faf ✓ follow-up complete", vim.log.levels.INFO)
		end)
	end)

	requests.set_handle(id, proc)
end

---@param id number
---@param on_back fun()?
local function select_request(id, on_back)
	local request = requests.get(id)
	if not request or not request.response then
		vim.notify("faf: no response to display", vim.log.levels.WARN)
		return
	end

	local has_qfix = request.qfix_items and #request.qfix_items > 0

	if has_qfix then
		windows.open_quickfix(request.qfix_items, "faf [" .. request.mode .. "]")
	else
		windows.open_response({
			id = request.id,
			mode = request.mode,
			session_id = request.session_id,
			started_at = request.started_at,
			content = request.response,
			on_back = on_back,
			on_reply = function(prompt)
				submit_followup(id, prompt)
			end,
		})
	end
end

---@param id number
local function cancel_request(id)
	requests.cancel(id)
	vim.cmd("redrawstatus")
	vim.notify("faf: request cancelled", vim.log.levels.INFO)
end

---@param restore_cursor number?
local function open_request_list(restore_cursor)
	local reqs = requests.list()
	local items = vim.iter(reqs)
		:map(function(r)
			local display, label, mode_str = format_request(r)
			return {
				display = display,
				id = r.id,
				state = r.state,
				label = label,
				mode = mode_str,
				req_mode = r.mode,
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

---@param visual_text string[]?
local function cmd_input(visual_text)
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
	vim.cmd("redrawstatus")
	vim.notify("faf: all requests cancelled", vim.log.levels.INFO)
end

function M.statusline()
	local count = requests.count_running()
	if count == 0 then
		return ""
	end
	return "faf:" .. count
end

---@param opts? { model?: string, max_history?: number, keymaps?: boolean | table }
function M.setup(opts)
	options = vim.tbl_deep_extend("force", defaults, opts or {})
	requests.setup({ max_history = options.max_history })

	vim.api.nvim_create_user_command("FafInput", function()
		cmd_input(nil)
	end, {})
	vim.api.nvim_create_user_command("FafList", cmd_list, {})
	vim.api.nvim_create_user_command("FafCancel", cmd_cancel, {})

	local km = options.keymaps
	if km == false then
		return
	end

	if km.input then
		vim.keymap.set("n", km.input, function()
			cmd_input(nil)
		end, { desc = "faf: input" })

		vim.keymap.set("v", km.input, function()
			local lines = vim.fn.getregion(vim.fn.getpos("'<"), vim.fn.getpos("'>"), { type = vim.fn.visualmode() })
			local t = {}
			for i, l in ipairs(lines) do
				t[i] = l
			end
			cmd_input(#t > 0 and t or nil)
		end, { desc = "faf: input" })
	end

	if km.list then
		vim.keymap.set("n", km.list, cmd_list, { desc = "faf: open requests" })
	end

	if km.cancel then
		vim.keymap.set("n", km.cancel, cmd_cancel, { desc = "faf: cancel all" })
	end
end

return M

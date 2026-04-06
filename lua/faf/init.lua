local windows = require("faf.windows")
local requests = require("faf.requests")
local qfix = require("faf.qfix")
local attachment_utils = require("faf.attachments")

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
---@param attachments faf.Attachment[]?
---@param session_id string?
---@param include_hint boolean?
---@return string[]
local function build_command(mode, prompt, visual_text, attachments, session_id, include_hint)
	local agent = agent_map[mode]
	local hint = mode_hints[mode]
	local full_prompt
	local should_include_hint = include_hint ~= false

	if visual_text then
		full_prompt = table.concat(visual_text, "\n") .. "\n\n" .. prompt
	else
		full_prompt = prompt
	end

	if should_include_hint then
		full_prompt = full_prompt .. "\n\n" .. hint
	end

	local cmd = { "opencode", "run", "--format", "json", "--agent", agent }
	if session_id then
		vim.list_extend(cmd, { "--session", session_id })
	end
	if options.model then
		vim.list_extend(cmd, { "-m", options.model })
	end
	for _, attachment in ipairs(attachments or {}) do
		vim.list_extend(cmd, { "-f", attachment.path })
	end
	vim.list_extend(cmd, { "--", full_prompt })

	return cmd
end

---@param prompt string
---@param visual_text string[]?
---@param attachments faf.Attachment[]?
---@return string
local function format_user_message(prompt, visual_text, attachments)
	local parts = {}

	if visual_text then
		table.insert(parts, table.concat(visual_text, "\n"))
	end

	local attachment_lines = attachment_utils.summary_lines(attachments)
	if #attachment_lines > 0 then
		table.insert(parts, table.concat(attachment_lines, "\n"))
	end

	table.insert(parts, prompt)

	return table.concat(parts, "\n\n")
end

---@param attachments faf.Attachment[]?
---@return faf.StoredAttachment[]
local function to_stored_attachments(attachments)
	local stored = {}

	for _, attachment in ipairs(attachments or {}) do
		table.insert(stored, {
			path = attachment.temporary and nil or attachment.path,
			name = attachment.name,
			kind = attachment.kind,
		})
	end

	return stored
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

local permission_required_message =
	"Permission required: OpenCode auto-rejected a tool request in fire-and-forget mode."

---@param err string?
---@return boolean
local function is_permission_tool_error(err)
	if type(err) ~= "string" then
		return false
	end

	local lowered = err:lower()
	return lowered:find("rejected permission", 1, true) ~= nil
		or lowered:find("user rejected permission", 1, true) ~= nil
		or (lowered:find("permission to use", 1, true) ~= nil and lowered:find("tool call", 1, true) ~= nil)
end

---@param stderr string
---@return boolean
local function is_permission_auto_reject(stderr)
	local lowered = stderr:lower()
	return lowered:find("permission requested", 1, true) ~= nil and lowered:find("auto-reject", 1, true) ~= nil
end

---@param response string
---@return string
local function format_permission_required_response(response)
	if response == "" then
		return permission_required_message
	end

	return permission_required_message .. "\n\n" .. response
end

---@param stdout string
---@return string session_id
---@return string response
---@return boolean permission_rejected
local function parse_json_result(stdout)
	local session_id = ""
	local response_parts = {}
	local permission_rejected = false

	for line in stdout:gmatch("[^\n]+") do
		local ok, decoded = pcall(vim.json.decode, line)
		if ok and type(decoded) == "table" then
			if decoded.sessionID and session_id == "" then
				session_id = decoded.sessionID
			end
			if decoded.type == "text" and decoded.part and decoded.part.text then
				table.insert(response_parts, decoded.part.text)
			end
			if
				decoded.type == "tool_use"
				and decoded.part
				and decoded.part.state
				and decoded.part.state.status == "error"
				and is_permission_tool_error(decoded.part.state.error)
			then
				permission_rejected = true
			end
		end
	end

	return session_id, table.concat(response_parts, "\n"), permission_rejected
end

---@param obj vim.SystemCompleted
---@return string session_id
---@return string response
---@return "done" | "failed" state
local function parse_command_result(obj)
	local session_id, response, permission_rejected = parse_json_result(obj.stdout or "")
	if permission_rejected then
		return session_id, format_permission_required_response(response), "failed"
	end
	if is_permission_auto_reject(obj.stderr or "") then
		return session_id, format_permission_required_response(response), "failed"
	end
	if obj.code ~= 0 and response == "" then
		return session_id, "Error: exit code " .. obj.code .. "\n" .. (obj.stderr or ""), "failed"
	end
	return session_id, response, "done"
end

---@param state "done" | "failed"
---@return string symbol
---@return integer level
local function completion_status(state)
	if state == "done" then
		return "✓", vim.log.levels.INFO
	end

	return "✗", vim.log.levels.ERROR
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

---@param id number
---@param cmd string[]
---@param opts { set_session_id?: boolean, attachments?: faf.Attachment[], notify: fun(state: "done" | "failed", req: faf.Request) }
local function run_request_command(id, cmd, opts)
	local proc = vim.system(cmd, { text = true }, function(obj)
		vim.schedule(function()
			attachment_utils.cleanup(opts.attachments)
			local req = requests.get(id)
			if not req or req.state == "cancelled" then
				return
			end
			local session_id, response, state = parse_command_result(obj)
			if state == "done" then
				handle_qfix_result(id, response)
			end
			if opts.set_session_id then
				requests.set_session_id(id, session_id)
			end
			requests.add_message(id, "assistant", response)
			requests.finish(id, response, state)
			vim.cmd("redrawstatus")
			req = requests.get(id)
			if req then
				opts.notify(state, req)
			end
		end)
	end)

	requests.set_handle(id, proc)
end

---@param r faf.Request
---@return string
---@return string state_label
---@return string mode_str
---@return boolean unseen
local function format_request(r)
	local label = state_labels[r.state] or ("[" .. r.state .. "]")
	local prompt_clean = (r.prompt .. attachment_utils.prompt_suffix(r.attachments)):gsub("\n", " "):gsub("%s+", " ")
	local mode_str = r.mode
	local unseen = r.unseen == true and r.state ~= "running"
	local unseen_marker = unseen and "*" or " "
	if r.qfix_items and #r.qfix_items > 0 then
		mode_str = r.mode .. ":" .. #r.qfix_items
	end
	return string.format("%s %-11s %-9s     %s", unseen_marker, label, mode_str, prompt_clean), label, mode_str, unseen
end

---@param mode "ask" | "vibe" | "tutorial"
---@param prompt string
---@param visual_text string[]?

---@param attachments faf.Attachment[]?
local function submit_request(mode, prompt, visual_text, attachments)
	local id = requests.add(mode, prompt, visual_text ~= nil, to_stored_attachments(attachments), attachments)
	local user_message = format_user_message(prompt, visual_text, attachments)
	requests.add_message(id, "user", user_message)
	vim.cmd("redrawstatus")
	local cmd = build_command(mode, prompt, visual_text, attachments, nil, true)

	run_request_command(id, cmd, {
		set_session_id = true,
		attachments = attachments,
		notify = function(state, req)
			local symbol, level = completion_status(state)
			local prompt_short = truncate(req.prompt, 40)
			vim.notify("faf " .. symbol .. " " .. req.mode .. ": " .. prompt_short, level)
		end,
	})
end

---@param id number
---@param prompt string
---@param attachments faf.Attachment[]?
local function submit_followup(id, prompt, attachments)
	local req = requests.get(id)
	if not req or not req.session_id then
		vim.notify("faf: no session to continue", vim.log.levels.WARN)
		return
	end

	requests.add_message(id, "user", format_user_message(prompt, nil, attachments))
	requests.set_state_running(id, attachments)
	vim.cmd("redrawstatus")

	local cmd = build_command(req.mode, prompt, nil, attachments, req.session_id, false)

	run_request_command(id, cmd, {
		attachments = attachments,
		notify = function(state)
			local symbol, level = completion_status(state)
			vim.notify("faf " .. symbol .. " follow-up complete", level)
		end,
	})
end

local open_request_qfix

---@param id number
---@param on_back fun()?
local function select_request(id, on_back)
	local request = requests.get(id)
	if not request or not request.response then
		vim.notify("faf: no response to display", vim.log.levels.WARN)
		return
	end
	local has_qfix = request.qfix_items and #request.qfix_items > 0
	requests.mark_seen(id)

	windows.open_response({
		id = request.id,
		mode = request.mode,
		session_id = request.session_id,
		started_at = request.started_at,
		messages = request.messages,
		on_back = on_back,
		on_quickfix = has_qfix and function()
			open_request_qfix(id)
		end or nil,
		on_reply = function(prompt, attachments)
			submit_followup(id, prompt, attachments)
		end,
	})
end

---@param id number
local function open_request_split(id)
	local request = requests.get(id)
	if not request or not request.response then
		vim.notify("faf: no response to display", vim.log.levels.WARN)
		return
	end
	local has_qfix = request.qfix_items and #request.qfix_items > 0
	requests.mark_seen(id)

	windows.open_response_split({
		id = request.id,
		mode = request.mode,
		session_id = request.session_id,
		started_at = request.started_at,
		messages = request.messages,
		on_quickfix = has_qfix and function()
			open_request_qfix(id)
		end or nil,
		on_reply = function(prompt, attachments)
			submit_followup(id, prompt, attachments)
		end,
	})
end

---@param id number
open_request_qfix = function(id)
	local request = requests.get(id)
	if not request then
		vim.notify("faf: request not found", vim.log.levels.WARN)
		return
	end

	local has_qfix = request.qfix_items and #request.qfix_items > 0
	if not has_qfix then
		vim.notify("faf: no locations to display", vim.log.levels.WARN)
		return
	end
	requests.mark_seen(id)

	windows.open_quickfix(request.qfix_items, "faf [" .. request.mode .. "]")
end

---@param id number
local function cancel_request(id)
	local req = requests.get(id)
	local attachments = req and req._attachments or nil
	requests.cancel(id)
	attachment_utils.cleanup(attachments)
	vim.cmd("redrawstatus")
	vim.notify("faf: request cancelled", vim.log.levels.INFO)
end

---@param restore_cursor number?
local function open_request_list(restore_cursor)
	local reqs = requests.list()
	local items = vim.iter(reqs)
		:map(function(r)
			local display, label, mode_str, unseen = format_request(r)
			local has_qfix = r.qfix_items and #r.qfix_items > 0
			local can_open = r.response ~= nil
			return {
				display = display,
				id = r.id,
				state = r.state,
				label = label,
				mode = mode_str,
				req_mode = r.mode,
				has_qfix = has_qfix,
				can_open = can_open,
				unseen = unseen,
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
		on_split = function(id)
			open_request_split(id)
		end,
		on_quickfix = function(id)
			open_request_qfix(id)
		end,
		on_unread = function(id)
			return requests.mark_unseen(id)
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
		on_submit = function(prompt, attachments)
			submit_request(mode_current, prompt, visual_text, attachments)
		end,
		on_cancel = function() end,
	})
end

local function cmd_list()
	open_request_list()
end

local function cmd_cancel()
	local attachments = {}
	for _, req in ipairs(requests.list()) do
		if req.state == "running" then
			table.insert(attachments, req._attachments)
		end
	end
	requests.cancel_all()
	for _, req_attachments in ipairs(attachments) do
		attachment_utils.cleanup(req_attachments)
	end
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

		vim.keymap.set("x", km.input, function()
			local lines = vim.fn.getregion(vim.fn.getpos("v"), vim.fn.getpos("."), { type = vim.fn.mode() })
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

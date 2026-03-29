local window = require("hei.window")
local requests = require("lua.hei.requests")
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

local tutorial_hint = [[
## Task
Write a tutorial for the topic below.
Read any provided context carefully before writing.

## Output
Return valid Markdown.
The first line must be a Markdown H1 title.

## Rules
- Be accurate and practical.
- Organize the tutorial with clear sections.
- Use examples when helpful.
- Do not include standalone file-location lines unless explicitly requested.

## Topic
]]

local qfix_hint = [[
## Task
Return relevant file locations for the request.

## Output
Return only file locations, one per line, in this exact format:
/absolute/path/to/file.lua:12:3,1,why this location matters

## Rules
- Use absolute paths only.
- Use 1-based line and column numbers.
- The value after the first comma is the line span.
- Notes must stay on one line.
- Do not include bullets, headings, code fences, or extra commentary.
- If there are no valid locations, return nothing.
]]

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

local function build_command(mode, prompt, visual_text)
	local agent = agent_map[mode]
	local full_prompt = prompt

	if mode == "tutorial" then
		full_prompt = tutorial_hint .. prompt
	elseif visual_text then
		full_prompt = table.concat(visual_text, "\n") .. "\n\n" .. prompt .. qfix_hint
	else
		full_prompt = prompt .. qfix_hint
	end

	local cmd = { "opencode", "run", "--agent", agent }
	if options.model then
		vim.list_extend(cmd, { "-m", options.model })
	end
	table.insert(cmd, full_prompt)

	return cmd
end

local function parse_result(obj)
	local response = obj.stdout or ""
	if obj.code ~= 0 and response == "" then
		return "Error: exit code " .. obj.code .. "\n" .. (obj.stderr or ""), "failed"
	end
	return response, "done"
end

local function handle_qfix_result(id, response)
	local qfix_items = qfix.create_qfix_entries(response)
	requests.set_qfix_items(id, qfix_items)
	if #qfix_items > 0 then
		vim.notify("hei: " .. #qfix_items .. " locations added to quickfix", vim.log.levels.INFO)
	end
end

local function submit(mode, prompt, visual_text)
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
				vim.notify("hei [" .. req.mode .. "] " .. req.state, vim.log.levels.INFO)
			end
		end)
	end)

	requests.set_handle(id, proc)
end

local function cmd_input()
	local visual_text = capture_visual()
	local mode_current = "ask"

	window.open_input(modes, {
		mode = mode_current,
		visual = visual_text ~= nil,
		on_mode_change = function(mode_new)
			mode_current = mode_new
		end,
		on_submit = function(prompt)
			submit(mode_current, prompt, visual_text)
		end,
		on_cancel = function() end,
	})
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

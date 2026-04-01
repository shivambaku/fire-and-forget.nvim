local M = {}

---@class faf.Message
---@field role "user" | "assistant"
---@field content string

---@class faf.Request
---@field id number
---@field mode "ask" | "vibe" | "tutorial"
---@field prompt string
---@field visual boolean
---@field state "running" | "done" | "failed" | "cancelled"
---@field messages faf.Message[]
---@field response string | nil
---@field started_at number
---@field session_id string | nil
---@field qfix_items {filename: string, lnum: number, col: number, text: string}[]
---@field _handle vim.SystemObj | nil

---@type faf.Request[]
local requests = {}
local next_id = 1
local max_history = 50

---@param messages faf.Message[]
---@param role "user" | "assistant"
---@param content string | nil
local function insert_message(messages, role, content)
	if not content or content == "" then
		return
	end

	table.insert(messages, {
		role = role,
		content = content,
	})
end

---@param r faf.Request
---@return boolean
local function is_valid_request(r)
	return type(r) == "table"
		and type(r.id) == "number"
		and type(r.mode) == "string"
		and type(r.prompt) == "string"
		and type(r.visual) == "boolean"
		and type(r.state) == "string"
		and type(r.messages) == "table"
		and type(r.started_at) == "number"
end

---@return string
local function project_key()
	return vim.fn.fnamemodify(vim.fn.getcwd(), ":p:h"):gsub("[^a-zA-Z0-9]", "_"):sub(1, -2)
end

---@return string
local function data_dir()
	return vim.fn.stdpath("data") .. "/faf/" .. project_key()
end

---@return string
local function data_file()
	return data_dir() .. "/requests.json"
end

local function save()
	local dir = data_dir()
	if vim.fn.isdirectory(dir) == 0 then
		vim.fn.mkdir(dir, "p")
	end

	while #requests > max_history do
		table.remove(requests, 1)
	end

	local to_save = {}
	for _, r in ipairs(requests) do
		table.insert(to_save, {
			id = r.id,
			mode = r.mode,
			prompt = r.prompt,
			visual = r.visual,
			state = r.state,
			messages = r.messages,
			response = r.response,
			started_at = r.started_at,
			session_id = r.session_id,
			qfix_items = r.qfix_items,
		})
	end

	local f = io.open(data_file(), "w")
	if f then
		f:write(vim.json.encode(to_save))
		f:close()
	end
end

local function load()
	local path = data_file()
	local f = io.open(path, "r")
	if not f then
		return
	end
	local content = f:read("*a")
	f:close()

	if content == "" then
		return
	end

	local ok, decoded = pcall(vim.json.decode, content)
	if not ok or not decoded then
		return
	end

	requests = {}
	for _, r in ipairs(decoded) do
		if is_valid_request(r) then
			r.qfix_items = r.qfix_items or {}
			r.response = r.response or nil
			r.session_id = r.session_id or nil
			r._handle = nil
			table.insert(requests, r)
			if r.id >= next_id then
				next_id = r.id + 1
			end
		end
	end
end

---@param opts { max_history?: number }
function M.setup(opts)
	opts = opts or {}
	max_history = opts.max_history or 50
	load()
end

---@param mode "ask" | "vibe" | "tutorial"
---@param prompt string
---@param visual boolean
---@return number id
function M.add(mode, prompt, visual)
	local r = {
		id = next_id,
		mode = mode,
		prompt = prompt,
		visual = visual,
		state = "running",
		messages = {},
		response = nil,
		started_at = os.time(),
		session_id = nil,
		qfix_items = {},
		_handle = nil,
	}
	table.insert(requests, r)
	next_id = next_id + 1

	return r.id
end

---@param id number
---@return faf.Request | nil
function M.get(id)
	for _, r in ipairs(requests) do
		if r.id == id then
			return r
		end
	end
end

---@return faf.Request[]
function M.list()
	local sorted = {}
	for _, r in ipairs(requests) do
		table.insert(sorted, r)
	end
	table.sort(sorted, function(a, b)
		return a.started_at > b.started_at
	end)
	return sorted
end

function M.count_running()
	local count = 0
	for _, r in ipairs(requests) do
		if r.state == "running" then
			count = count + 1
		end
	end
	return count
end

---@param id number
---@param qfix_items {filename: string, lnum: number, col: number, text: string}[]
function M.set_qfix_items(id, qfix_items)
	local r = M.get(id)
	if r then
		r.qfix_items = qfix_items
	end
end

---@param id number
---@param session_id string
function M.set_session_id(id, session_id)
	local r = M.get(id)
	if r then
		r.session_id = session_id
	end
end

---@param id number
function M.set_state_running(id)
	local r = M.get(id)
	if r then
		r.state = "running"
		r._handle = nil
	end
end

---@param id number
---@param state "running" | "done" | "failed" | "cancelled"
function M.set_state(id, state)
	local r = M.get(id)
	if r then
		r.state = state
	end
end

---@param id number
---@param role "user" | "assistant"
---@param content string
function M.add_message(id, role, content)
	local r = M.get(id)
	if r == nil then
		return
	end

	insert_message(r.messages, role, content)
end

---@param id number
---@param handle vim.SystemObj
function M.set_handle(id, handle)
	local r = M.get(id)
	if r == nil then
		return
	end
	r._handle = handle
end

---@param id number
---@param response string
---@param state "done" | "failed"
function M.finish(id, response, state)
	local r = M.get(id)
	if r == nil or r.state == "cancelled" then
		return
	end
	r.response = response
	r.state = state
	r._handle = nil
	save()
end

---@param id number
---@param should_save? boolean
function M.cancel(id, should_save)
	local r = M.get(id)
	if r == nil or r.state ~= "running" then
		return
	end

	if r._handle then
		pcall(r._handle.kill, r._handle, 15)
	end
	r.state = "cancelled"
	r._handle = nil
	if should_save ~= false then
		save()
	end
end

function M.cancel_all()
	for _, r in ipairs(requests) do
		if r.state == "running" then
			M.cancel(r.id, false)
		end
	end
	save()
end

return M

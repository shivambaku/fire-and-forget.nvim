local M = {}

---@class hei.Request
---@field id number
---@field mode "ask" | "vibe" | "tutorial"
---@field prompt string
---@field visual boolean
---@field state "running" | "done" | "failed" | "cancelled"
---@field response string | nil
---@field started_at number
---@field qfix_items {filename: string, lnum: number, col: number, text: string}[]
---@field _handle vim.SystemObj | nil

---@type hei.Request[]
local requests = {}
local next_id = 1
local max_history = 50

local function project_key()
	return vim.fn.fnamemodify(vim.fn.getcwd(), ":p:h"):gsub("[^a-zA-Z0-9]", "_"):sub(1, -2)
end

local function data_dir()
	return vim.fn.stdpath("data") .. "/hei/" .. project_key()
end

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
			response = r.response,
			started_at = r.started_at,
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
		r._handle = nil
		table.insert(requests, r)
		if r.id >= next_id then
			next_id = r.id + 1
		end
	end
end

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
		response = nil,
		started_at = os.time(),
		_handle = nil,
	}
	table.insert(requests, r)
	next_id = next_id + 1

	return r.id
end

---@param id number
---@return hei.Request | nil
function M.get(id)
	for _, r in ipairs(requests) do
		if r.id == id then
			return r
		end
	end
end

---@return hei.Request[]
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

---@param id number
---@param qfix_items {filename: string, lnum: number, col: number, text: string}[]
function M.set_qfix_items(id, qfix_items)
	local r = M.get(id)
	if r then
		r.qfix_items = qfix_items
	end
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

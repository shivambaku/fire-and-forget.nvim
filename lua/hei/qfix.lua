local M = {}

---@class hei.QFixEntry
---@field filename string
---@field lnum number
---@field col number
---@field text string

---@param line string
---@return hei.QFixEntry|nil
local function parse_line(line)
	local filepath, lnum_raw, rest = line:match("^(.-):(%d+):(.+)$")
	if not filepath or not lnum_raw or not rest then
		return nil
	end

	local col_raw, _, notes = rest:match("^(%d+),([^,]+),(.*)$")
	if not col_raw then
		return nil
	end

	local lnum = tonumber(lnum_raw) or 1
	local col = tonumber(col_raw) or 1

	return {
		filename = filepath,
		lnum = lnum,
		col = col,
		text = notes or "",
	}
end

---@param response string
---@return hei.QFixEntry[]
function M.create_qfix_entries(response)
	local qf_list = {}

	local lines = vim.split(response, "\n")
	for _, line in ipairs(lines) do
		line = vim.trim(line)

		if line:match("^```") then
			goto continue
		end

		local res = parse_line(line)
		if res and res.filename and res.filename ~= "" then
			if vim.fn.filereadable(res.filename) == 1 then
				table.insert(qf_list, res)
			end
		end

		::continue::
	end

	return qf_list
end

return M

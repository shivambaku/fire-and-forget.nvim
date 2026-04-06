local M = {}

---@class faf.Attachment
---@field path string
---@field name string
---@field kind "image"
---@field temporary boolean

local preferred_image_mimes = {
	"image/png",
	"image/jpeg",
	"image/webp",
	"image/gif",
	"image/bmp",
	"image/tiff",
}

local mime_extensions = {
	["image/png"] = ".png",
	["image/jpeg"] = ".jpg",
	["image/jpg"] = ".jpg",
	["image/webp"] = ".webp",
	["image/gif"] = ".gif",
	["image/bmp"] = ".bmp",
	["image/tiff"] = ".tiff",
	["image/tif"] = ".tiff",
}

local clipboard_command_timeout_ms = 3000

local error_codes = {
	unavailable = "unavailable",
	no_image = "no_image",
	timeout = "timeout",
	backend_failed = "backend_failed",
	write_failed = "write_failed",
}

-- Shared helpers ------------------------------------------------------------

---@param value string
---@return string
local function escape_applescript_string(value)
	return value:gsub("\\", "\\\\"):gsub('"', '\\"')
end

---@param path string
local function cleanup_path(path)
	if path == "" then
		return
	end

	pcall(vim.uv.fs_unlink, path)
end

---@param command string[]
---@param opts? vim.SystemOpts
---@return vim.SystemCompleted
local function run(command, opts)
	return vim.system(command, opts or {}):wait(clipboard_command_timeout_ms)
end

---@param data string|string[]
---@return string
local function normalize_output(data)
	if type(data) == "table" then
		return table.concat(data, "")
	end
	return data or ""
end

---@param result vim.SystemCompleted
---@return boolean
local function timed_out(result)
	return result.code == 124
end

---@param backend_name string
---@param action string
---@param result vim.SystemCompleted
---@return string
local function command_failure_message(backend_name, action, result)
	local stderr = vim.trim(normalize_output(result.stderr))
	if stderr ~= "" then
		return string.format("%s failed to %s: %s", backend_name, action, stderr)
	end

	return string.format("%s failed to %s", backend_name, action)
end

---@param path string
---@param data string|string[]
---@return boolean
local function write_file(path, data)
	local fd = vim.uv.fs_open(path, "w", 420)
	if not fd then
		return false
	end

	local payload = normalize_output(data)
	local total_written = 0
	while total_written < #payload do
		local chunk = payload:sub(total_written + 1)
		local written = vim.uv.fs_write(fd, chunk, total_written)
		if not written or written <= 0 then
			vim.uv.fs_close(fd)
			return false
		end
		total_written = total_written + written
	end
	vim.uv.fs_close(fd)
	return total_written == #payload
end

---@param mime string
---@return string
local function extension_for_mime(mime)
	return mime_extensions[mime] or ".img"
end

---@param mime string
---@return string
local function filename_for_mime(mime)
	return "clipboard" .. extension_for_mime(mime)
end

---@param mime string
---@return string
local function temp_path_for_mime(mime)
	return vim.fn.tempname() .. extension_for_mime(mime)
end

---@param mime string
---@return boolean
local function is_image_mime(mime)
	return mime:match("^image/") ~= nil
end

---@param output string
---@return string[]
local function parse_lines(output)
	local trimmed = vim.trim(output)
	if trimmed == "" then
		return {}
	end

	return vim.split(trimmed, "%s+", { trimempty = true })
end

---@param mimes string[]
---@return string | nil
local function pick_image_mime(mimes)
	local available = {}
	for _, mime in ipairs(mimes) do
		available[mime] = true
	end

	for _, mime in ipairs(preferred_image_mimes) do
		if available[mime] then
			return mime
		end
	end

	for _, mime in ipairs(mimes) do
		if is_image_mime(mime) then
			return mime
		end
	end
	return nil
end

---@param mime string
---@param data string|string[]
---@return faf.Attachment | nil
---@return string? err
---@return string? err_code
local function create_attachment_from_data(mime, data)
	local path = temp_path_for_mime(mime)
	if not write_file(path, data) then
		cleanup_path(path)
		return nil, "could not write clipboard image", error_codes.write_failed
	end

	if vim.fn.filereadable(path) == 0 then
		cleanup_path(path)
		return nil, "clipboard image capture failed", error_codes.write_failed
	end

	return {
		path = path,
		name = filename_for_mime(mime),
		kind = "image",
		temporary = true,
	}, nil, nil
end

---@param command string[]
---@param backend_name string
---@return string[] | nil
---@return string? err
---@return string? err_code
local function list_clipboard_mimes(command, backend_name)
	local result = run(command, { text = true })
	if timed_out(result) then
		return nil, string.format("%s timed out while reading clipboard types", backend_name), error_codes.timeout
	end
	if result.code ~= 0 then
		return nil, command_failure_message(backend_name, "read clipboard types", result), error_codes.backend_failed
	end

	return parse_lines(normalize_output(result.stdout)), nil, nil
end

---@param command string[]
---@param mime string
---@param backend_name string
---@return faf.Attachment | nil
---@return string? err
---@return string? err_code
local function capture_with_command(command, mime, backend_name)
	local result = run(command, { text = false })
	if timed_out(result) then
		return nil, string.format("%s timed out while reading the clipboard image", backend_name), error_codes.timeout
	end
	if result.code ~= 0 then
		return nil, command_failure_message(backend_name, "read the clipboard image", result), error_codes.backend_failed
	end

	local stdout = normalize_output(result.stdout)
	if stdout == "" then
		return nil, "clipboard does not contain an image", error_codes.no_image
	end

	return create_attachment_from_data(mime, stdout)
end

---@class faf.ClipboardBackend
---@field name string
---@field supported fun(): boolean
---@field capture fun(): faf.Attachment | nil, string?

-- macOS ---------------------------------------------------------------------

---@return boolean
local function supports_macos_clipboard_image()
	return vim.fn.has("macunix") == 1 and vim.fn.executable("osascript") == 1
end

---@return faf.Attachment | nil
---@return string? err
---@return string? err_code
local function capture_macos_clipboard_image()
	if not supports_macos_clipboard_image() then
		return nil, "clipboard image paste is unavailable", error_codes.unavailable
	end

	local path = temp_path_for_mime("image/png")
	local escaped_path = escape_applescript_string(path)
	local result = run({
		"osascript",
		"-e",
		'set imageData to the clipboard as "PNGf"',
		"-e",
		'set fileRef to open for access POSIX file "' .. escaped_path .. '" with write permission',
		"-e",
		"set eof fileRef to 0",
		"-e",
		"write imageData to fileRef",
		"-e",
		"close access fileRef",
	}, { text = true })

	if timed_out(result) then
		cleanup_path(path)
		return nil, "osascript timed out while reading the clipboard image", error_codes.timeout
	end

	if result.code ~= 0 then
		cleanup_path(path)
		return nil, "clipboard does not contain an image", error_codes.no_image
	end

	if vim.fn.filereadable(path) == 0 then
		cleanup_path(path)
		return nil, "osascript failed to capture a clipboard image", error_codes.backend_failed
	end

	return {
		path = path,
		name = filename_for_mime("image/png"),
		kind = "image",
		temporary = true,
	}, nil, nil
end

-- Wayland -------------------------------------------------------------------

---@return boolean
local function supports_wayland_clipboard_image()
	return vim.fn.has("unix") == 1
		and vim.env.WAYLAND_DISPLAY ~= nil
		and vim.env.WAYLAND_DISPLAY ~= ""
		and vim.fn.executable("wl-paste") == 1
end

---@return string[]
local function list_wayland_clipboard_mimes()
	return list_clipboard_mimes({ "wl-paste", "--list-types" }, "wl-paste")
end

---@return faf.Attachment | nil
---@return string? err
---@return string? err_code
local function capture_wayland_clipboard_image()
	if not supports_wayland_clipboard_image() then
		return nil, "clipboard image paste is unavailable", error_codes.unavailable
	end

	local mimes, err, err_code = list_wayland_clipboard_mimes()
	if not mimes then
		return nil, err, err_code
	end

	local mime = pick_image_mime(mimes)
	if not mime then
		return nil, "clipboard does not contain an image", error_codes.no_image
	end

	return capture_with_command({ "wl-paste", "--no-newline", "--type", mime }, mime, "wl-paste")
end

-- X11 -----------------------------------------------------------------------

---@return boolean
local function supports_x11_clipboard_image()
	return vim.fn.has("unix") == 1
		and vim.env.DISPLAY ~= nil
		and vim.env.DISPLAY ~= ""
		and vim.fn.executable("xclip") == 1
end

---@return string[]
local function list_x11_clipboard_mimes()
	return list_clipboard_mimes({ "xclip", "-selection", "clipboard", "-t", "TARGETS", "-o" }, "xclip")
end

---@return faf.Attachment | nil
---@return string? err
---@return string? err_code
local function capture_x11_clipboard_image()
	if not supports_x11_clipboard_image() then
		return nil, "clipboard image paste is unavailable", error_codes.unavailable
	end

	local mimes, err, err_code = list_x11_clipboard_mimes()
	if not mimes then
		return nil, err, err_code
	end

	local mime = pick_image_mime(mimes)
	if not mime then
		return nil, "clipboard does not contain an image", error_codes.no_image
	end

	return capture_with_command({ "xclip", "-selection", "clipboard", "-t", mime, "-o" }, mime, "xclip")
end

-- Backend selection ---------------------------------------------------------

---@type faf.ClipboardBackend[]
local clipboard_backends = {
	{
		name = "macos",
		supported = supports_macos_clipboard_image,
		capture = capture_macos_clipboard_image,
	},
	{
		name = "wayland",
		supported = supports_wayland_clipboard_image,
		capture = capture_wayland_clipboard_image,
	},
	{
		name = "x11",
		supported = supports_x11_clipboard_image,
		capture = capture_x11_clipboard_image,
	},
}

---@return faf.ClipboardBackend[]
local function supported_clipboard_backends()
	local backends = {}
	for _, backend in ipairs(clipboard_backends) do
		if backend.supported() then
			table.insert(backends, backend)
		end
	end
	return backends
end

---@return boolean
function M.supports_clipboard_image()
	return #supported_clipboard_backends() > 0
end

---@param err_code string?
---@return boolean
function M.is_no_image_error(err_code)
	return err_code == error_codes.no_image
end

---@return faf.Attachment | nil
---@return string? err
---@return string? err_code
function M.capture_clipboard_image()
	local backends = supported_clipboard_backends()
	if #backends == 0 then
		return nil, "clipboard image paste is unavailable", error_codes.unavailable
	end

	local saw_no_image = false
	local first_error
	local first_error_code

	for _, backend in ipairs(backends) do
		local attachment, err, err_code = backend.capture()
		if attachment then
			return attachment, nil, nil
		end

		if err_code == error_codes.no_image then
			saw_no_image = true
		elseif first_error == nil then
			first_error = err
			first_error_code = err_code
		end
	end

	if saw_no_image then
		return nil, "clipboard does not contain an image", error_codes.no_image
	end

	return nil, first_error or "clipboard image paste is unavailable", first_error_code or error_codes.unavailable
end

---@param attachments faf.Attachment[]?
function M.cleanup(attachments)
	for _, attachment in ipairs(attachments or {}) do
		if attachment.temporary then
			cleanup_path(attachment.path)
		end
	end
end

---@param attachments faf.Attachment[]?
---@return string[]
function M.summary_lines(attachments)
	local lines = {}

	for _, attachment in ipairs(attachments or {}) do
		if attachment.kind == "image" then
			table.insert(lines, "[Attached image: " .. attachment.name .. "]")
		else
			table.insert(lines, "[Attached file: " .. attachment.name .. "]")
		end
	end

	return lines
end

---@param attachments faf.Attachment[]?
---@return string
function M.prompt_suffix(attachments)
	local image_count = 0

	for _, attachment in ipairs(attachments or {}) do
		if attachment.kind == "image" then
			image_count = image_count + 1
		end
	end

	if image_count == 0 then
		return ""
	end

	if image_count == 1 then
		return " [image]"
	end

	return string.format(" [%d images]", image_count)
end

return M

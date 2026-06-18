local M = {}

---@type { file_wd: string, wd: string }?
local cache = nil

---Resolve symlinks so `wd` and `server.cwd` (from HTTP `/path`) compare apples-to-apples.
---Returns the input unchanged if it can't be resolved (e.g. missing path).
---@param path string
---@return string
local function realpath(path)
  local ok, resolved = pcall(vim.uv.fs_realpath, path)
  if ok and type(resolved) == "string" and resolved ~= "" then
    return (resolved:gsub("/+$", ""))
  end
  return (path:gsub("/+$", ""))
end

---@param path string
---@return string? Parent directory, or nil.
local function dirname(path)
  if path == nil or path == "" then
    return nil
  end
  local parent = vim.fn.fnamemodify(path, ":h")
  if parent == "" or parent == "." then
    return nil
  end
  return parent
end

---Directory of the currently active buffer's file.
---Falls back to `vim.fn.getcwd()` when there's no buffer-backed file.
---@return string
local function file_wd()
  local current = vim.api.nvim_get_current_buf()
  if current and vim.api.nvim_buf_is_valid(current) then
    local name = vim.api.nvim_buf_get_name(current)
    if name and name ~= "" then
      local abs = vim.fn.fnamemodify(name, ":p")
      local parent = dirname(abs)
      if parent then
        return realpath(parent)
      end
    end
  end
  return realpath(vim.fn.getcwd())
end

---@param start string
---@return string? Absolute git toplevel, or nil if `start` is not in a git repo.
local function git_root(start)
  if vim.fn.executable("git") ~= 1 then
    return nil
  end
  local out = vim.fn.system({ "git", "-C", start, "rev-parse", "--show-toplevel" })
  if vim.v.shell_error ~= 0 then
    return nil
  end
  local root = (out:gsub("%s+$", "")) ---@type string
  if root == "" then
    return nil
  end
  return realpath(root)
end

---Compute the working directory for server discovery.
---Cached per `file_wd`; invalidated by `M.invalidate()`.
---
---`file_wd` = directory of the current buffer's file (falls back to `getcwd()`).
---If `file_wd` is inside a git repo, `wd` is the repo toplevel. Otherwise `wd == file_wd`.
---@return string
function M.get()
  local fw = file_wd()
  if cache and cache.file_wd == fw then
    return cache.wd
  end
  local wd = git_root(fw) or fw
  cache = { file_wd = fw, wd = wd }
  return wd
end

---Invalidate the cache. Hooked to buffer-change autocmds.
function M.invalidate()
  cache = nil
end

---Wire `BufEnter` / `BufFilePost` / `BufNew` autocmds that invalidate the cache whenever the
---active buffer's file path may have changed. Idempotent.
function M.setup()
  local group = vim.api.nvim_create_augroup("OpencodeCwd", { clear = true })
  vim.api.nvim_create_autocmd({ "BufEnter", "BufFilePost", "BufNew" }, {
    group = group,
    callback = function()
      M.invalidate()
    end,
    desc = "Invalidate opencode.nvim wd cache when buffer path changes",
  })
end

return M
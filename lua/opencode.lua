---opencode.nvim public API.
local M = {}

---Generation counter so that a second `ask()` supersedes the first before it sends a prompt.
---@type number
local _ask_generation = 0

---Context of the current `ask()`, so it can be resumed when superseded by another `ask()`.
---@type opencode.context.Context?
local _ask_context = nil

---Cancel function for the current `ask()`, so the input UI can be closed when superseded.
---@type fun()?
local _ask_cancel = nil

---@param err? string
local function on_error(err)
  if err then
    vim.notify(err, vim.log.levels.ERROR, { title = "opencode" })
  end
end

---Input a prompt for OpenCode.
---
--- - Passes the text to `prompt()`.
--- - Press `<Up>` to browse recent asks.
--- - Highlights and completes contexts and OpenCode subagents.
---   - Press `<Tab>` to trigger built-in completion.
---   - Provided by in-process LSP when using [snacks.input](https://github.com/folke/snacks.nvim/blob/main/docs/input.md).
---
---If called while another `ask()` is still in flight, the previous one is cancelled
---(its input closed, context resumed, and its prompt will not be sent).
---
---@param default? string Text to pre-fill the input with.
function M.ask(default)
  if _ask_cancel then
    _ask_cancel()
    _ask_cancel = nil
  end

  if _ask_context then
    _ask_context:resume()
  end

  local generation = _ask_generation + 1
  _ask_generation = generation
  _ask_context = nil

  require("opencode.server.discovery")
    .get()
    :next(function(server)
      if _ask_generation ~= generation then
        return
      end
      local context = require("opencode.context").new(server)
      _ask_context = context
      local ask_promise, cancel = require("opencode.ui.ask").ask(default, context)
      _ask_cancel = cancel
      return ask_promise:next(function(input)
        _ask_cancel = nil
        if _ask_generation ~= generation then
          return
        end
        context:resume()
        return require("opencode.api.prompt").prompt(input, context)
      end)
    end)
    :catch(function(err)
      if _ask_generation == generation then
        if _ask_context then
          _ask_context:resume()
        end
        _ask_context = nil
        _ask_cancel = nil
      end
      on_error(err)
    end)
end

---Select from all opencode.nvim functionality.
---
--- - Prompts
--- - Commands
--- - Servers
---
--- Highlights and previews items when using [snacks.picker](https://github.com/folke/snacks.nvim/blob/main/docs/picker.md).
---
---@param opts? opencode.select.Opts Override configured options for this call.
function M.select(opts)
  require("opencode.server.discovery")
    .get()
    :next(function(server)
      local context = require("opencode.context").new(server)
      return require("opencode.ui.select").select(context, opts)
    end)
    :catch(on_error)
end

M.statusline = require("opencode.events.status").statusline

---Prompt OpenCode.
---
--- - Injects configured contexts.
--- - Trailing space appends; trailing "..." opens in `ask()`.
--- - OpenCode will interpret references to files or subagents.
---
---@param prompt string
function M.prompt(prompt)
  require("opencode.server.discovery")
    .get()
    :next(function(server)
      local context = require("opencode.context").new(server)
      return require("opencode.api.prompt").prompt(prompt, context)
    end)
    :catch(on_error)
end

---Command OpenCode.
---
---@param command opencode.server.Command | string
function M.command(command)
  require("opencode.server.discovery")
    .get()
    :next(function(server)
      return require("opencode.api.command").command(command, server)
    end)
    :catch(on_error)
end

---Wraps `prompt` as an operator, supporting ranges and dot-repeat.
---
---@param prompt string
function M.operator(prompt)
  _G.opencode_prompt_operator = function(kind) ---@param kind "char" | "line" | "block"
    local start_pos = vim.api.nvim_buf_get_mark(0, "[")
    local end_pos = vim.api.nvim_buf_get_mark(0, "]")
    if start_pos[1] > end_pos[1] or (start_pos[1] == end_pos[1] and start_pos[2] > end_pos[2]) then
      start_pos, end_pos = end_pos, start_pos
    end

    require("opencode.server.discovery")
      .get()
      :next(function(server)
        local context = require("opencode.context").new(server, {
          from = { start_pos[1], start_pos[2] },
          to = { end_pos[1], end_pos[2] },
          kind = kind,
        })

        return require("opencode.api.prompt").prompt(prompt, context)
      end)
      :catch(on_error)
  end

  vim.o.operatorfunc = "v:lua.opencode_prompt_operator"
  return "g@"
end

M.format = require("opencode.context").format

return M

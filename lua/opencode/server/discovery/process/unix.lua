local M = {}

---@param stdout string `lsof -Fpc` output
---@return table<number, { comm: string, ports: number[] }>
local function parse_listen(stdout)
  ---@type table<number, { comm: string, ports: number[] }>
  local by_pid = {}
  local current ---@type { comm: string, ports: number[] }?
  for line in stdout:gmatch("[^\n]+") do
    local prefix = line:sub(1, 1)
    local value = line:sub(2)
    if prefix == "p" then
      current = { comm = "", ports = {} }
      by_pid[tonumber(value)] = current
    elseif prefix == "c" and current then
      current.comm = value
    elseif prefix == "n" and current then
      local port = tonumber(value:match(":(%d+)$"))
      if port then
        table.insert(current.ports, port)
      end
    end
  end
  return by_pid
end

---@param stdout string `lsof -Fpcn` output filtered to `-d cwd`
---@return table<number, string>
local function parse_cwd(stdout)
  ---@type table<number, string>
  local cwd_by_pid = {}
  local current_pid
  for line in stdout:gmatch("[^\n]+") do
    local prefix = line:sub(1, 1)
    local value = line:sub(2)
    if prefix == "p" then
      current_pid = tonumber(value)
    elseif prefix == "c" and current_pid then
    elseif prefix == "n" and current_pid then
      if value:sub(1, 1) == "/" and not value:find(" ", 1, true) then
        cwd_by_pid[current_pid] = value
      end
    end
  end
  return cwd_by_pid
end

---@param comm string
---@return boolean
local function is_opencode(comm)
  return comm == "opencode"
end

---@return Promise<opencode.server.discovery.process.Process[]>
function M.get()
  return require("opencode.promise.system")
    .system({
      "lsof",
      "-Fpcn",
      "-w",
      "-iTCP",
      "-sTCP:LISTEN",
      "-P",
      "-n",
    })
    :next(function(stdout)
      local by_pid = parse_listen(stdout)

      local opencode_pids = {}
      for pid, entry in pairs(by_pid) do
        if is_opencode(entry.comm) and #entry.ports > 0 then
          table.insert(opencode_pids, pid)
        end
      end

      if #opencode_pids == 0 then
        return {}
      end

      return require("opencode.promise.system")
        .system({
          "lsof",
          "-Fpcn",
          "-w",
          "-d",
          "cwd",
          "-p",
          table.concat(opencode_pids, ","),
        })
        :next(function(cwd_stdout)
          local cwd_by_pid = parse_cwd(cwd_stdout)

          ---@type opencode.server.discovery.process.Process[]
          local processes = {}
          for _, pid in ipairs(opencode_pids) do
            local cwd = cwd_by_pid[pid]
            if cwd then
              for _, port in ipairs(by_pid[pid].ports) do
                table.insert(processes, { pid = pid, port = port, cwd = cwd })
              end
            end
          end
          return processes
        end)
    end)
end

return M

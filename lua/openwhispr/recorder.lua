-- Audio recording with ffmpeg.
local M = {}

---Start recording to `path`. `on_exit(result)` runs on the main loop when
---ffmpeg exits, whether stopped by `M.stop`, by the duration limit, or by an
---error.
---@return vim.SystemObj|nil proc, string|nil err
function M.start(opts, path, on_exit)
  local cmd = vim.deepcopy(opts.recording.cmd)
  if vim.fn.executable(cmd[1]) ~= 1 then
    return nil, ("recorder executable not found: %s"):format(cmd[1])
  end
  if opts.recording.max_duration then
    vim.list_extend(cmd, { "-t", tostring(opts.recording.max_duration) })
  end
  table.insert(cmd, path)
  local ok, proc = pcall(vim.system, cmd, { stdin = true, text = true }, function(res)
    vim.schedule(function()
      on_exit(res)
    end)
  end)
  if not ok then
    return nil, tostring(proc)
  end
  return proc
end

---Stop recording so that ffmpeg finalizes the WAV header: send `q` on stdin,
---escalate to SIGINT and then SIGKILL if ffmpeg does not exit.
---@param proc vim.SystemObj
function M.stop(proc)
  pcall(proc.write, proc, "q")
  vim.defer_fn(function()
    if not proc:is_closing() then
      pcall(proc.kill, proc, "sigint")
      vim.defer_fn(function()
        if not proc:is_closing() then
          pcall(proc.kill, proc, "sigkill")
        end
      end, 2000)
    end
  end, 2000)
end

---Abort recording without caring about the output file.
function M.kill(proc)
  pcall(proc.kill, proc, "sigkill")
end

return M

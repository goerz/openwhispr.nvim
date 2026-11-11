-- Speech to text: OpenWhispr CLI, with parakeet-mlx as fallback.
local M = {}

local OPENWHISPR_UNREACHABLE = 2 -- exit code: desktop app (backend) not reachable

local function executable(exe)
  return type(exe) == "string" and vim.fn.executable(exe) == 1
end

local function first_line(s)
  s = vim.trim(s or "")
  return s:match("[^\n]*") or s
end

local function parakeet(opts, path, cb)
  local exe = opts.transcription.parakeet
  local outdir = vim.fn.tempname()
  vim.fn.mkdir(outdir, "p")
  local cmd = { exe, path, "--output-format", "txt", "--output-dir", outdir }
  if opts.transcription.parakeet_model then
    vim.list_extend(cmd, { "--model", opts.transcription.parakeet_model })
  end
  vim.system(cmd, { text = true, timeout = opts.transcription.timeout * 1000 }, function(res)
    vim.schedule(function()
      local stem = vim.fn.fnamemodify(path, ":t:r")
      local txt = vim.fs.joinpath(outdir, stem .. ".txt")
      local text
      if res.code == 0 and vim.uv.fs_stat(txt) then
        text = vim.trim(table.concat(vim.fn.readfile(txt), "\n"))
      end
      vim.fn.delete(outdir, "rf")
      if text then
        cb(nil, text, "parakeet-mlx")
      else
        cb(("parakeet-mlx failed (exit %d): %s"):format(res.code, first_line(res.stderr)))
      end
    end)
  end)
end

---Transcribe the WAV file at `path`. Calls `cb(err, text, backend)` on the
---main loop.
function M.run(opts, path, cb)
  local exe = opts.transcription.openwhispr
  local can_fallback = executable(opts.transcription.parakeet)
  if not executable(exe) then
    if can_fallback then
      return parakeet(opts, path, cb)
    end
    return cb("neither the openwhispr CLI nor parakeet-mlx is executable")
  end
  local cmd = { exe, "--local", "transcribe", path, "--format", "text" }
  if opts.transcription.model then
    vim.list_extend(cmd, { "--model", opts.transcription.model })
  end
  vim.system(cmd, { text = true, timeout = opts.transcription.timeout * 1000 }, function(res)
    vim.schedule(function()
      if res.code == 0 then
        cb(nil, vim.trim(res.stdout or ""), "openwhispr")
      elseif res.code == OPENWHISPR_UNREACHABLE and can_fallback then
        parakeet(opts, path, cb)
      else
        cb(("openwhispr failed (exit %d): %s"):format(res.code, first_line(res.stderr)))
      end
    end)
  end)
end

---Fetch the OpenWhispr dictionary. Calls `cb(words)` on the main loop with a
---(possibly empty) list of strings; failures are silent.
function M.dictionary(opts, cb)
  local exe = opts.transcription.openwhispr
  if not executable(exe) then
    return cb({})
  end
  vim.system(
    { exe, "--local", "dictionary", "list" },
    { text = true, timeout = 10000 },
    function(res)
      vim.schedule(function()
        local words = {}
        if res.code == 0 then
          local ok, data = pcall(vim.json.decode, res.stdout or "")
          if ok and type(data) == "table" then
            for _, item in ipairs(data) do
              local w = type(item) == "table" and item.word or item
              if type(w) == "string" and w ~= "" then
                table.insert(words, w)
              end
            end
          end
        end
        cb(words)
      end)
    end
  )
end

return M

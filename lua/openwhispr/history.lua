-- Transcript history: one JSON line per dictation plus the recording, so
-- that misrecognitions can be corrected and used to improve transcription.
--
-- Each entry has: id, time, duration, backend, filetype, raw (the
-- transcript), cleaned (or cleanup_error), audio (path relative to the
-- history directory), and, once reviewed, verbatim (the corrected
-- transcript; "" marks an entry as unusable).
local config = require("openwhispr.config")

local M = {}

local api = vim.api

local function notify(msg, level)
  vim.notify("openwhispr: " .. msg, level or vim.log.levels.INFO, { title = "openwhispr" })
end

---The history directory.
function M.dir()
  return config.options.history.dir or (vim.fn.stdpath("data") .. "/openwhispr")
end

---The history file (JSON Lines).
function M.file()
  return M.dir() .. "/history.jsonl"
end

---A unique, sortable id from the wall-clock time.
function M.new_id()
  local sec, usec = vim.uv.gettimeofday()
  return os.date("%Y%m%d-%H%M%S", sec) .. ("-%03d"):format(math.floor(usec / 1000))
end

---Duration of a WAV file in seconds, from its byte rate and size.
function M.wav_duration(path)
  local f = io.open(path, "rb")
  if not f then
    return nil
  end
  local header = f:read(44)
  local size = f:seek("end")
  f:close()
  if not header or #header < 44 or header:sub(1, 4) ~= "RIFF" then
    return nil
  end
  local b1, b2, b3, b4 = header:byte(29, 32)
  local rate = b1 + b2 * 0x100 + b3 * 0x10000 + b4 * 0x1000000
  if rate == 0 then
    return nil
  end
  return math.floor((size - 44) / rate * 100 + 0.5) / 100
end

---Add an entry. The recording at `audio_path` is moved into the history
---directory (copied if `recording.keep_audio` is set). Returns true, or nil
---and an error message.
function M.add(entry, audio_path)
  local dir = M.dir()
  if vim.fn.mkdir(dir .. "/audio", "p", tonumber("700", 8)) == 0 then
    return nil, "could not create " .. dir
  end
  entry.duration = M.wav_duration(audio_path)
  if config.options.history.audio then
    local rel = ("audio/%s.wav"):format(entry.id)
    local dest = dir .. "/" .. rel
    local ok
    if not config.options.recording.keep_audio then
      ok = vim.uv.fs_rename(audio_path, dest)
    end
    ok = ok or vim.uv.fs_copyfile(audio_path, dest)
    if ok then
      entry.audio = rel
    end
  end
  local f, err = io.open(M.file(), "a")
  if not f then
    return nil, err
  end
  f:write(vim.json.encode(entry), "\n")
  f:close()
  return true
end

---All entries, oldest first. Lines that are not valid JSON are kept as
---`{ _line = ... }` so that rewriting the file preserves them.
function M.read()
  local entries = {}
  local f = io.open(M.file(), "r")
  if not f then
    return entries
  end
  for line in f:lines() do
    if line ~= "" then
      local ok, e = pcall(vim.json.decode, line, { luanil = { object = true } })
      if ok and type(e) == "table" and e.id then
        table.insert(entries, e)
      else
        table.insert(entries, { _line = line })
      end
    end
  end
  f:close()
  return entries
end

---Replace the history file with `entries` (atomically).
function M.write(entries)
  local path = M.file()
  local tmp = path .. ".tmp"
  local f = assert(io.open(tmp, "w"))
  for _, e in ipairs(entries) do
    f:write(e._line or vim.json.encode(e), "\n")
  end
  f:close()
  assert(vim.uv.fs_rename(tmp, path))
end

local BUFNAME = "openwhispr://history"

local function oneline(text)
  return (text or ""):gsub("\n", " ⏎ ")
end

---Entry id of the block the cursor is in.
local function id_at_cursor(buf)
  local row = api.nvim_win_get_cursor(0)[1]
  local lines = api.nvim_buf_get_lines(buf, 0, row, false)
  for i = #lines, 1, -1 do
    local id = lines[i]:match("^## (%S+)")
    if id then
      return id
    end
  end
end

local player ---@type vim.SystemObj|nil

---Play the recording of the entry under the cursor.
function M.play(buf)
  local id = id_at_cursor(buf or api.nvim_get_current_buf())
  if not id then
    return notify("no entry under the cursor", vim.log.levels.WARN)
  end
  local entry
  for _, e in ipairs(M.read()) do
    if e.id == id then
      entry = e
    end
  end
  local path = entry and entry.audio and (M.dir() .. "/" .. entry.audio)
  if not path or vim.fn.filereadable(path) == 0 then
    return notify("no recording for " .. id, vim.log.levels.WARN)
  end
  if player and not player:is_closing() then
    player:kill(15)
  end
  local cmd = vim.list_extend(vim.deepcopy(config.options.history.player), { path })
  local ok, res = pcall(vim.system, cmd)
  if ok then
    player = res
  else
    notify("could not play the recording: " .. tostring(res), vim.log.levels.ERROR)
  end
end

---Store the verbatim lines of the review buffer. Every entry whose block
---still has its verbatim line counts as reviewed.
function M.save(buf)
  local updates, current = {}, nil
  for _, line in ipairs(api.nvim_buf_get_lines(buf, 0, -1, false)) do
    local id = line:match("^## (%S+)")
    if id then
      current = id
    elseif current then
      local v = line:match("^verbatim:(.*)$")
      if v then
        updates[current] = vim.trim(v)
        current = nil
      end
    end
  end
  local entries = M.read()
  local n = 0
  for _, e in ipairs(entries) do
    if e.id and updates[e.id] then
      e.verbatim = updates[e.id]
      n = n + 1
    end
  end
  if n > 0 then
    M.write(entries)
  end
  vim.bo[buf].modified = false
  notify(("%d %s reviewed"):format(n, n == 1 and "entry" or "entries"))
end

local HELP = {
  "# Correct each verbatim line to what you actually said, then :w to save.",
  "# Saving marks every entry below as reviewed; delete an entry's lines to",
  "# leave it for later. An empty verbatim line marks a recording as unusable.",
  "# <CR> plays the recording of the entry under the cursor.",
}

---Open the review buffer with the unreviewed entries, or all with `all`.
function M.open(all)
  local lines = vim.deepcopy(HELP)
  local count = 0
  for _, e in ipairs(M.read()) do
    if e.id and (all or e.verbatim == nil) then
      count = count + 1
      local cleaned = e.cleaned and oneline(e.cleaned)
        or ("(%s)"):format(e.cleanup_error or "no cleanup")
      vim.list_extend(lines, {
        "",
        ("## %s  %s s  %s"):format(
          e.id,
          e.duration or "?",
          (e.filetype or "") ~= "" and e.filetype or "-"
        ),
        "raw:      " .. oneline(e.raw),
        "cleaned:  " .. cleaned,
        "verbatim: " .. oneline(e.verbatim or e.raw),
      })
    end
  end
  if count == 0 then
    return notify(all and "the history is empty" or "no unreviewed entries")
  end
  local buf = vim.fn.bufnr(BUFNAME)
  if buf == -1 then
    buf = api.nvim_create_buf(true, false)
    api.nvim_buf_set_name(buf, BUFNAME)
    vim.bo[buf].buftype = "acwrite"
    vim.bo[buf].swapfile = false
    vim.bo[buf].bufhidden = "wipe"
    vim.bo[buf].filetype = "openwhispr_history"
    api.nvim_create_autocmd("BufWriteCmd", {
      buffer = buf,
      callback = function()
        M.save(buf)
      end,
    })
    vim.keymap.set("n", "<CR>", function()
      M.play(buf)
    end, { buffer = buf, desc = "Play the recording" })
  end
  api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modified = false
  api.nvim_set_current_buf(buf)
  api.nvim_win_set_cursor(0, { #HELP + 2, 0 })
end

return M

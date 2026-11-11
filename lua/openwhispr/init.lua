-- openwhispr.nvim: dictation into Neovim buffers.
--
-- Pipeline: record (ffmpeg) -> transcribe (OpenWhispr CLI, or parakeet-mlx)
-- -> clean up with Claude (Anthropic API) -> insert at the position where
-- dictation started, or replace the visual selection.
local config = require("openwhispr.config")
local recorder = require("openwhispr.recorder")
local transcribe = require("openwhispr.transcribe")
local context = require("openwhispr.context")
local cleanup = require("openwhispr.cleanup")
local insert = require("openwhispr.insert")
local history = require("openwhispr.history")

local M = {}

local api = vim.api
local levels = vim.log.levels
local ns = api.nvim_create_namespace("openwhispr")

local sessions = {} ---@type table<integer, table>
local recording = nil ---@type table|nil  the session that is currently recording
local next_id = 0
local dictionary_cache = nil ---@type string[]|nil

local LABELS = {
  recording = "● rec",
  stopping = "… transcribing",
  transcribing = "… transcribing",
  cleaning = "… cleaning up",
}

local function notify(msg, level)
  vim.notify("openwhispr: " .. msg, level or levels.INFO, { title = "openwhispr" })
end

local function label(s)
  local text = LABELS[s.state] or s.state
  if s.state == "recording" and s.started then
    local secs = math.floor((vim.uv.now() - s.started) / 1000)
    text = ("%s %d:%02d"):format(text, math.floor(secs / 60), secs % 60)
  end
  return text
end

---Statusline component: an empty string when idle.
function M.status()
  if recording then
    return label(recording)
  end
  local latest
  local count = 0
  for _, s in pairs(sessions) do
    count = count + 1
    if not latest or s.id > latest.id then
      latest = s
    end
  end
  if not latest then
    return ""
  end
  return count > 1 and ("%s (%d)"):format(label(latest), count) or label(latest)
end

local function emit()
  pcall(vim.cmd, "redrawstatus!")
  api.nvim_exec_autocmds("User", {
    pattern = "OpenWhisprStatus",
    modeline = false,
    data = { status = M.status() },
  })
end

---Current target range of a session as {srow, scol, erow, ecol}, or nil if
---the buffer is gone.
local function target_range(s)
  if not api.nvim_buf_is_valid(s.buf) or not api.nvim_buf_is_loaded(s.buf) then
    return nil
  end
  local pos = api.nvim_buf_get_extmark_by_id(s.buf, ns, s.mark, { details = true })
  if #pos == 0 then
    return nil
  end
  local d = pos[3]
  return { pos[1], pos[2], d.end_row or pos[1], d.end_col or pos[2] }
end

local function show(s)
  local where = config.options.indicator
  if not where then
    return
  end
  local r = target_range(s)
  if not r then
    return
  end
  local hl = s.state == "recording" and "OpenWhisprRecording" or "OpenWhisprProcessing"
  local ok, id = pcall(api.nvim_buf_set_extmark, s.buf, ns, r[1], r[2], {
    id = s.ind,
    virt_text = { { " " .. label(s) .. " ", hl } },
    virt_text_pos = where,
    right_gravity = r[1] == r[3] and r[2] == r[4],
  })
  if ok then
    s.ind = id
  end
end

local function update(s, state)
  s.state = state
  show(s)
  emit()
end

local KEY_MODES = { "n", "i" }

---Map the stop and cancel keys in the session's buffer for the duration of
---the recording, saving any buffer-local mappings they shadow.
local function map_keys(s)
  local keys = config.options.recording.keys
  if not keys then
    return
  end
  s.keymaps = {}
  local actions = {
    {
      keys.stop,
      function()
        M.stop()
      end,
      "Stop dictation",
    },
    {
      keys.cancel,
      function()
        M.cancel()
      end,
      "Cancel dictation",
    },
  }
  for _, a in ipairs(actions) do
    local lhs, fn, desc = a[1], a[2], a[3]
    if lhs then
      for _, mode in ipairs(KEY_MODES) do
        local prev = vim.fn.maparg(lhs, mode, false, true)
        if prev.buffer ~= 1 then
          prev = nil
        end
        vim.keymap.set(mode, lhs, fn, { buffer = s.buf, nowait = true, desc = desc })
        table.insert(s.keymaps, { mode = mode, lhs = lhs, prev = prev })
      end
    end
  end
end

---Remove the keys set by map_keys() and restore what they shadowed.
local function unmap_keys(s)
  local maps = s.keymaps
  s.keymaps = nil
  if not maps or not api.nvim_buf_is_valid(s.buf) then
    return
  end
  api.nvim_buf_call(s.buf, function()
    for _, m in ipairs(maps) do
      pcall(vim.keymap.del, m.mode, m.lhs, { buffer = s.buf })
      if m.prev then
        pcall(vim.fn.mapset, m.mode, false, m.prev)
      end
    end
  end)
end

local function finish(s)
  if s.finished then
    return
  end
  s.finished = true
  unmap_keys(s)
  if s.timer then
    s.timer:stop()
    s.timer:close()
    s.timer = nil
  end
  if api.nvim_buf_is_valid(s.buf) then
    pcall(api.nvim_buf_del_extmark, s.buf, ns, s.mark)
    if s.ind then
      pcall(api.nvim_buf_del_extmark, s.buf, ns, s.ind)
    end
  end
  if not config.options.recording.keep_audio then
    vim.fn.delete(s.audio)
  end
  if recording == s then
    recording = nil
  end
  sessions[s.id] = nil
  emit()
end

local function deliver(s, text)
  local r = target_range(s)
  if not r then
    vim.fn.setreg('"', text)
    notify("the buffer is gone; the text is in the unnamed register", levels.WARN)
    return finish(s)
  end
  -- Move the cursor behind the new text if the user is still where they
  -- started, or typed at the insertion point while waiting.
  local move = false
  if api.nvim_get_current_buf() == s.buf then
    local cur = api.nvim_win_get_cursor(0)
    local at_point = r[1] == r[3] and r[2] == r[4] and cur[1] - 1 == r[1] and cur[2] == r[2]
    local unchanged = vim.b[s.buf].changedtick == s.tick
      and cur[1] == s.cursor[1]
      and cur[2] == s.cursor[2]
    move = at_point or unchanged
  end
  local in_comment = false
  local ok_syn, names = pcall(context.syntax_at, s.buf, r[1], r[2])
  for _, name in ipairs(ok_syn and names or {}) do
    in_comment = in_comment or name:lower():find("comment", 1, true) ~= nil
  end
  local ok, erow, ecol =
    pcall(insert.apply, config.options, s.buf, r[1], r[2], r[3], r[4], text, in_comment)
  if not ok then
    vim.fn.setreg('"', text)
    notify(
      ("insertion failed (%s); the text is in the unnamed register"):format(erow),
      levels.ERROR
    )
    return finish(s)
  end
  if move then
    local mode = api.nvim_get_mode().mode
    if not mode:match("^[iR]") and ecol > 0 then
      local line = api.nvim_buf_get_lines(s.buf, erow, erow + 1, false)[1] or ""
      ecol = ecol - 1 + vim.str_utf_start(line, ecol)
    end
    pcall(api.nvim_win_set_cursor, 0, { erow + 1, ecol })
  end
  finish(s)
end

local function vocabulary(s)
  local words = vim.deepcopy(config.options.context.vocabulary)
  vim.list_extend(words, s.dictionary or dictionary_cache or {})
  return words
end

---Add the dictation to the history (if enabled). This moves the recording
---into the history directory.
local function save_history(s, raw, cleaned, err)
  if not config.options.history.enabled then
    return
  end
  local ok, res, herr = pcall(history.add, {
    id = s.history_id,
    time = s.time,
    backend = s.backend,
    filetype = s.filetype,
    raw = raw,
    cleaned = cleaned,
    cleanup_error = err,
  }, s.audio)
  if not ok or not res then
    notify("could not save the history entry: " .. tostring(herr or res), levels.WARN)
  end
end

local function process(s, transcript)
  local opts = config.options
  if not opts.cleanup.enabled then
    save_history(s, transcript)
    return deliver(s, transcript)
  end
  local r = target_range(s)
  if not r then
    save_history(s, transcript)
    return deliver(s, transcript)
  end
  update(s, "cleaning")
  local ok, ctx = pcall(context.gather, opts, s.buf, r[1], r[2], r[3], r[4])
  if not ok then
    notify("could not gather context: " .. tostring(ctx), levels.WARN)
    ctx = { filename = "", filetype = vim.bo[s.buf].filetype, before = "", after = "" }
  end
  cleanup.run(opts, ctx, transcript, vocabulary(s), function(err, text)
    if s.cancelled then
      return finish(s)
    end
    save_history(s, transcript, not err and text or nil, err)
    if err then
      notify("cleanup failed, inserting the raw transcript: " .. err, levels.WARN)
      return deliver(s, transcript)
    end
    if text == "" then
      notify("nothing to insert after cleanup (raw transcript: " .. transcript .. ")", levels.WARN)
      return finish(s)
    end
    deliver(s, text)
  end)
end

local function on_record_exit(s, res)
  if s.timer then
    s.timer:stop()
    s.timer:close()
    s.timer = nil
  end
  if s.cancelled then
    return finish(s)
  end
  local stderr = vim.trim(res.stderr or "")
  if recording == s then
    -- ffmpeg ended without a stop request: duration limit or failure.
    recording = nil
    unmap_keys(s)
    if res.code ~= 0 then
      notify(("recording failed (exit %d): %s"):format(res.code, stderr), levels.ERROR)
      return finish(s)
    end
    notify("maximum recording duration reached", levels.WARN)
  end
  local stat = vim.uv.fs_stat(s.audio)
  if not stat or stat.size <= 44 then -- 44 bytes: an empty WAV header
    notify("no audio was recorded" .. (stderr ~= "" and (": " .. stderr) or ""), levels.ERROR)
    return finish(s)
  end
  update(s, "transcribing")
  transcribe.run(config.options, s.audio, function(err, text, backend)
    if s.cancelled then
      return finish(s)
    end
    if err then
      notify(err, levels.ERROR)
      return finish(s)
    end
    if text == "" then
      notify("no speech detected", levels.WARN)
      return finish(s)
    end
    s.backend = backend
    if backend ~= "openwhispr" and config.options.transcription.openwhispr then
      notify("OpenWhispr app not reachable; transcribed with " .. backend)
    end
    process(s, text)
  end)
end

local function char_len(line, col1)
  if #line == 0 then
    return 0
  end
  return 1 + vim.str_utf_end(line, col1)
end

---Range of a visual selection, 0-based, end-exclusive. `p1`, `p2` are
---{row, col} pairs (1-based, byte columns).
local function selection_range(vmode, buf, p1, p2)
  if p2[1] < p1[1] or (p2[1] == p1[1] and p2[2] < p1[2]) then
    p1, p2 = p2, p1
  end
  local l1 = api.nvim_buf_get_lines(buf, p1[1] - 1, p1[1], false)[1] or ""
  local l2 = api.nvim_buf_get_lines(buf, p2[1] - 1, p2[1], false)[1] or ""
  if vmode == "V" then
    return p1[1] - 1, 0, p2[1] - 1, #l2
  end
  local scol = math.min(p1[2] - 1, #l1)
  local c2 = math.min(p2[2], math.max(#l2, 1))
  local ecol = math.min(c2 - 1 + char_len(l2, c2), #l2)
  return p1[1] - 1, scol, p2[1] - 1, ecol
end

---Start dictation. In visual mode (or with `range` from a command), the
---dictated text replaces the selection; otherwise it is inserted at the
---cursor (insert mode) or after the cursor (normal mode).
---@param range? {line1: integer, line2: integer}
function M.start(range)
  if recording then
    return notify("already recording", levels.WARN)
  end
  local opts = config.options
  local buf = api.nvim_get_current_buf()
  if not vim.bo[buf].modifiable then
    return notify("buffer is not modifiable", levels.ERROR)
  end
  local mode = api.nvim_get_mode().mode
  local srow, scol, erow, ecol
  if mode:match("^[vV\22]") then
    local vmode = mode:sub(1, 1)
    if vmode == "\22" then
      api.nvim_feedkeys(vim.keycode("<Esc>"), "nx", false)
      return notify("blockwise selections are not supported", levels.WARN)
    end
    local v, c = vim.fn.getpos("v"), vim.fn.getpos(".")
    srow, scol, erow, ecol = selection_range(vmode, buf, { v[2], v[3] }, { c[2], c[3] })
    api.nvim_feedkeys(vim.keycode("<Esc>"), "nx", false)
  elseif range then
    local vmode = vim.fn.visualmode()
    local p1, p2 = vim.fn.getpos("'<"), vim.fn.getpos("'>")
    if (vmode == "v" or vmode == "V") and p1[2] == range.line1 and p2[2] == range.line2 then
      srow, scol, erow, ecol = selection_range(vmode, buf, { p1[2], p1[3] }, { p2[2], p2[3] })
    else
      srow, scol, erow, ecol = selection_range("V", buf, { range.line1, 1 }, { range.line2, 1 })
    end
  else
    local cur = api.nvim_win_get_cursor(0)
    srow, scol = cur[1] - 1, cur[2]
    if not mode:match("^[iR]") then
      scol = scol + char_len(api.nvim_get_current_line(), scol + 1)
    end
    erow, ecol = srow, scol
  end

  local point = srow == erow and scol == ecol
  local mark = api.nvim_buf_set_extmark(buf, ns, srow, scol, {
    end_row = not point and erow or nil,
    end_col = not point and ecol or nil,
    right_gravity = point,
    end_right_gravity = not point or nil,
  })
  next_id = next_id + 1
  local s = {
    id = next_id,
    buf = buf,
    mark = mark,
    state = "recording",
    audio = vim.fn.tempname() .. ".wav",
    cursor = api.nvim_win_get_cursor(0),
    tick = vim.b[buf].changedtick,
    started = vim.uv.now(),
    time = os.date("!%Y-%m-%dT%H:%M:%SZ"),
    history_id = history.new_id(),
    filetype = vim.bo[buf].filetype,
  }
  local proc, err = recorder.start(opts, s.audio, function(res)
    on_record_exit(s, res)
  end)
  if not proc then
    pcall(api.nvim_buf_del_extmark, buf, ns, mark)
    return notify("could not start recording: " .. err, levels.ERROR)
  end
  s.proc = proc
  sessions[s.id] = s
  recording = s
  map_keys(s)

  -- Tick the elapsed-time display once a second.
  s.timer = vim.uv.new_timer()
  s.timer:start(
    1000,
    1000,
    vim.schedule_wrap(function()
      if recording == s then
        show(s)
        emit()
      end
    end)
  )

  if opts.cleanup.enabled and opts.context.dictionary then
    transcribe.dictionary(opts, function(words)
      s.dictionary = words
      dictionary_cache = words
    end)
  end
  update(s, "recording")
end

---Stop recording and process the audio.
function M.stop()
  local s = recording
  if not s then
    return notify("not recording", levels.WARN)
  end
  recording = nil
  unmap_keys(s)
  update(s, "stopping")
  recorder.stop(s.proc)
end

---Start or stop dictation.
---@param range? {line1: integer, line2: integer}
function M.toggle(range)
  if recording then
    M.stop()
  else
    M.start(range)
  end
end

---Abort the current recording and discard any dictation still in progress.
function M.cancel()
  local any = false
  for _, s in pairs(sessions) do
    any = true
    s.cancelled = true
    unmap_keys(s)
    if s.proc and not s.proc:is_closing() then
      recorder.kill(s.proc)
    end
    if s.state ~= "recording" and s.state ~= "stopping" then
      finish(s)
    end
  end
  recording = nil
  if any then
    notify("dictation cancelled")
  end
  emit()
end

---Open the transcript history for review: the unreviewed entries, or all
---entries with `all`.
---@param all? boolean
function M.history(all)
  history.open(all)
end

---Whether a recording is in progress.
function M.is_recording()
  return recording ~= nil
end

---Configure the plugin. Calling it is optional; without it, the defaults
---apply.
---@param opts? table
function M.setup(opts)
  config.setup(opts)
end

-- Exposed for tests and :checkhealth.
M._selection_range = selection_range

return M

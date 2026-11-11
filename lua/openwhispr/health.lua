local M = {}

function M.check()
  local h = vim.health
  local opts = require("openwhispr.config").options

  h.start("openwhispr: Neovim")
  if vim.fn.has("nvim-0.11") == 1 then
    h.ok("Neovim " .. tostring(vim.version()))
  else
    h.error("Neovim 0.11 or later is required")
  end

  h.start("openwhispr: recording")
  local rec = opts.recording.cmd[1]
  if vim.fn.executable(rec) == 1 then
    h.ok(("%s: %s"):format(rec, vim.fn.exepath(rec)))
  else
    h.error(rec .. " not found", "Install ffmpeg (brew install ffmpeg) or set recording.cmd")
  end
  h.info(
    "On macOS, the first recording asks whether the terminal application may use the microphone."
  )

  h.start("openwhispr: transcription")
  local ow = opts.transcription.openwhispr
  local have_ow = type(ow) == "string" and vim.fn.executable(ow) == 1
  if have_ow then
    h.ok(("openwhispr CLI: %s"):format(vim.fn.exepath(ow)))
    local res = vim.system({ ow, "doctor" }, { text = true }):wait(10000)
    local ok, data = pcall(vim.json.decode, res.stdout or "")
    if ok and type(data) == "table" and type(data["local"]) == "table" then
      if data["local"].reachable then
        h.ok("OpenWhispr desktop app is reachable")
      else
        h.warn("OpenWhispr desktop app is not reachable", "Start the OpenWhispr app")
      end
    else
      h.warn("`openwhispr doctor` gave no usable answer")
    end
  elseif ow then
    h.warn(("openwhispr CLI not found: %s"):format(ow), "npm install -g @openwhispr/cli")
  else
    h.info("openwhispr CLI disabled (transcription.openwhispr = false)")
  end
  local pk = opts.transcription.parakeet
  if type(pk) == "string" and vim.fn.executable(pk) == 1 then
    h.ok(("fallback parakeet-mlx: %s"):format(vim.fn.exepath(pk)))
  elseif pk then
    if have_ow then
      h.info(("fallback %s not found (optional): uv tool install parakeet-mlx"):format(pk))
    else
      h.error(("no transcription backend: %s not found"):format(pk))
    end
  end

  h.start("openwhispr: history")
  if opts.history.enabled then
    local history = require("openwhispr.history")
    h.ok(
      ("enabled: %s (%d entries)%s"):format(
        history.file(),
        #history.read(),
        opts.history.audio and ", with recordings" or ""
      )
    )
    local player = opts.history.player[1]
    if opts.history.audio and vim.fn.executable(player) ~= 1 then
      h.warn(player .. " not found; recordings cannot be played (history.player)")
    end
  else
    h.info("disabled (history.enabled = false)")
  end

  h.start("openwhispr: cleanup")
  if not opts.cleanup.enabled then
    h.info("cleanup disabled; raw transcripts are inserted")
    return
  end
  if vim.fn.executable("curl") == 1 then
    h.ok("curl: " .. vim.fn.exepath("curl"))
  else
    h.error("curl not found")
  end
  h.info("model: " .. opts.cleanup.model)
  if opts.cleanup.api_key_cmd then
    h.info("API key from api_key_cmd: " .. table.concat(opts.cleanup.api_key_cmd, " "))
  else
    -- Without -w, `security` prints only the item's attributes, not the secret.
    local res = vim
      .system({ "security", "find-generic-password", "-s", opts.cleanup.keychain_service })
      :wait(10000)
    if res.code == 0 then
      h.ok(("Keychain item '%s' exists"):format(opts.cleanup.keychain_service))
    else
      h.error(
        ("Keychain item '%s' not found"):format(opts.cleanup.keychain_service),
        'security add-generic-password -a "$USER" -s anthropic-api-key -w'
      )
    end
  end
  if vim.env.ANTHROPIC_API_KEY then
    h.info("ANTHROPIC_API_KEY is set in the environment; this plugin does not use it")
  end
end

return M

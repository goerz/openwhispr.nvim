local M = {}

local MARKDOWN = "GitHub-flavored Markdown. The output must be valid Markdown: "
  .. "put code in backticks as inline code (identifiers, function and variable names, "
  .. "file names and paths, commands, options, keys, literal values); "
  .. "write mathematics as LaTeX, inline as $...$ and displayed as $$...$$ on lines of their own; "
  .. "use Markdown lists, emphasis, and links where the dictation calls for them. "
  .. "Add no backticks or dollar signs if the insertion point is already inside inline code, "
  .. "a code block, or math."

---@class openwhispr.Config
M.defaults = {
  recording = {
    -- ffmpeg command line without the output file (the plugin appends `-t
    -- <max_duration>` and the file). The default records the macOS default
    -- audio input device as 16 kHz mono.
    cmd = {
      "ffmpeg",
      "-hide_banner",
      "-loglevel",
      "error",
      "-f",
      "avfoundation",
      "-i",
      ":default",
      "-ar",
      "16000",
      "-ac",
      "1",
      "-y",
    },
    max_duration = 600, -- seconds; recording stops automatically after this
    keep_audio = false, -- keep the WAV file after processing (for debugging)
    -- Buffer-local keys (normal and insert mode) that exist only while
    -- recording; false disables one or both.
    keys = { stop = "<Esc>", cancel = "<C-c>" },
  },
  transcription = {
    openwhispr = "openwhispr", -- OpenWhispr CLI executable; false to skip
    model = nil, -- local OpenWhispr model id (`--model`); nil for the app's default
    parakeet = "parakeet-mlx", -- fallback when the OpenWhispr app is unreachable; false to disable
    parakeet_model = nil, -- Hugging Face repo for parakeet-mlx; nil for its default
    timeout = 120, -- seconds
  },
  context = {
    lines_before = 40, -- lines of buffer text before the insertion point sent as context
    lines_after = 15, -- lines of buffer text after the insertion point
    max_chars = 6000, -- cap on surrounding text (trimmed away from the cursor)
    syntax = true, -- send syntax context (comment, string, math) from treesitter or syntax groups
    dictionary = true, -- send the OpenWhispr dictionary as known vocabulary
    vocabulary = {}, -- extra words or phrases to send as known vocabulary
  },
  cleanup = {
    enabled = true, -- false inserts the raw transcript
    model = "claude-haiku-5-5",
    effort = "low",
    thinking = "disabled", -- "disabled" or "adaptive"
    max_tokens = 4096,
    timeout = 20, -- seconds
    keychain_service = "anthropic-api-key", -- macOS Keychain generic-password service name
    api_key_cmd = nil, -- command (list) that prints the API key; overrides keychain_service
    instructions = nil, -- extra text appended to the system prompt
    filetype_hints = {
      tex = "LaTeX document. Write mathematics in LaTeX: inline math as $...$ in running text, no delimiters inside a math environment.",
      plaintex = "TeX document. Write mathematics in TeX inline math ($...$).",
      markdown = MARKDOWN,
      quarto = MARKDOWN,
      rmd = MARKDOWN,
      pandoc = MARKDOWN,
      julia = "Julia source code. Docstrings are Markdown (Documenter.jl): code in single backticks; "
        .. "math as LaTeX in double backticks (``\\omega_q``) instead of dollar signs, "
        .. "which takes precedence over generic Markdown rules.",
      python = "Python source code. Docstrings follow PEP 257.",
      gitcommit = "Git commit message: a short imperative summary line, a blank line, then the body as plain prose.",
      mail = "Email, plain text.",
      text = "Plain text.",
    },
  },
  smart_spacing = true, -- add a space between inserted text and adjacent words
  wrap = true, -- wrap inserted lines longer than 'textwidth' (gw), following 'formatoptions'
  indicator = "inline", -- "inline" (at the insertion point), "eol", or false
  history = {
    -- Keep every recording with its raw and cleaned transcript, for
    -- correcting misrecognitions (:OpenWhispr history).
    enabled = false,
    dir = nil, -- nil for stdpath("data") .. "/openwhispr"
    audio = true, -- keep the recordings (WAV)
    player = { "afplay" }, -- command to play a recording in the review buffer
  },
}

---@type openwhispr.Config
M.options = vim.deepcopy(M.defaults)

local function validate(opts)
  vim.validate("recording.cmd", opts.recording.cmd, "table")
  vim.validate("recording.max_duration", opts.recording.max_duration, "number", true)
  vim.validate("recording.keys", opts.recording.keys, { "table", "boolean" })
  if type(opts.recording.keys) == "table" then
    vim.validate("recording.keys.stop", opts.recording.keys.stop, { "string", "boolean" }, true)
    vim.validate("recording.keys.cancel", opts.recording.keys.cancel, { "string", "boolean" }, true)
  end
  vim.validate("transcription.openwhispr", opts.transcription.openwhispr, { "string", "boolean" })
  vim.validate("transcription.parakeet", opts.transcription.parakeet, { "string", "boolean" })
  vim.validate("cleanup.enabled", opts.cleanup.enabled, "boolean")
  vim.validate("cleanup.model", opts.cleanup.model, "string")
  vim.validate("cleanup.keychain_service", opts.cleanup.keychain_service, "string")
  vim.validate("cleanup.api_key_cmd", opts.cleanup.api_key_cmd, "table", true)
  vim.validate("context.vocabulary", opts.context.vocabulary, "table")
  vim.validate("history.enabled", opts.history.enabled, "boolean")
  vim.validate("history.dir", opts.history.dir, "string", true)
  vim.validate("history.player", opts.history.player, "table")
  if opts.indicator ~= false and opts.indicator ~= "inline" and opts.indicator ~= "eol" then
    error("openwhispr: indicator must be 'inline', 'eol', or false")
  end
end

function M.setup(opts)
  local merged = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts or {})
  -- Lists replace the defaults instead of being merged index by index.
  if opts and opts.recording and opts.recording.cmd then
    merged.recording.cmd = opts.recording.cmd
  end
  if opts and opts.context and opts.context.vocabulary then
    merged.context.vocabulary = opts.context.vocabulary
  end
  if opts and opts.history and opts.history.player then
    merged.history.player = opts.history.player
  end
  if merged.history.dir then
    merged.history.dir = vim.fs.normalize(merged.history.dir)
  end
  validate(merged)
  M.options = merged
end

return M

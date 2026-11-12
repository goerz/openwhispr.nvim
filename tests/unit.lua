-- Unit tests for the pure parts of openwhispr.nvim (no audio, no network).
-- Run: nvim --headless -u NONE -l tests/unit.lua
vim.opt.rtp:prepend(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h"))

local failures = 0
local function eq(name, got, want)
  if not vim.deep_equal(got, want) then
    failures = failures + 1
    print(("FAIL %s\n  got:  %s\n  want: %s"):format(name, vim.inspect(got), vim.inspect(want)))
  else
    print("ok   " .. name)
  end
end

local insert = require("openwhispr.insert")
eq("space after word", insert.smart_space("world", "o", ""), " world")
eq("space before word", insert.smart_space("hello", "", "w"), "hello ")
eq("no space after paren", insert.smart_space("x", "(", ")"), "x")
eq("space after period", insert.smart_space("Next.", ".", ""), " Next.")
eq("no space before punctuation", insert.smart_space(", and", "o", ""), ", and")
eq("no space at blank", insert.smart_space("a", " ", " "), "a")
eq("math after word", insert.smart_space("$x$", "s", ""), " $x$")

local cleanup = require("openwhispr.cleanup")
eq("unfence", cleanup.unfence("```latex\n$x$\n```"), "$x$")
eq(
  "commentary detected",
  cleanup.looks_like_commentary("The cursor sits in a comment, so ...", "the hamiltonian is"),
  true
)
eq(
  "strip commentary",
  cleanup.strip_commentary("The cursor is in a comment.\n\nThe text.", "the text"),
  "The text."
)
eq("keep paragraphs", cleanup.strip_commentary("One.\n\nTwo.", "one two"), "One.\n\nTwo.")
eq("dictated word ok", cleanup.looks_like_commentary("Move the cursor.", "move the cursor"), false)
eq("unfence plain", cleanup.unfence("$x$"), "$x$")

local ow = require("openwhispr")
local buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "abc def", "ghé", "" })
eq("charwise", { ow._selection_range("v", buf, { 1, 5 }, { 2, 3 }) }, { 0, 4, 1, 4 })
eq("charwise reversed", { ow._selection_range("v", buf, { 2, 3 }, { 1, 5 }) }, { 0, 4, 1, 4 })
eq(
  "charwise past eol",
  { ow._selection_range("v", buf, { 1, 1 }, { 1, 2147483647 }) },
  { 0, 0, 0, 7 }
)
eq("linewise", { ow._selection_range("V", buf, { 1, 3 }, { 2, 1 }) }, { 0, 0, 1, 4 })
eq("empty line", { ow._selection_range("v", buf, { 3, 1 }, { 3, 1 }) }, { 2, 0, 2, 0 })

local config = require("openwhispr.config")
local context = require("openwhispr.context")
config.setup({ context = { lines_before = 1, lines_after = 1, max_chars = 20 } })
local b2 = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_lines(b2, 0, -1, false, { "one", "two", "three", "four", "five" })
local ctx = context.gather(config.options, b2, 2, 2, 2, 2)
eq("context before", ctx.before, "two\nth")
eq("context after", ctx.after, "ree\nfour")
eq("no selection", ctx.selection, nil)
ctx = context.gather(config.options, b2, 1, 0, 2, 2)
eq("selection", ctx.selection, "two\nth")
config.setup({ context = { max_chars = 10 } })
local b3 = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_lines(b3, 0, -1, false, { "ééééé|ééééé" })
ctx = context.gather(config.options, b3, 0, 11, 0, 11)
eq("utf8 trim before", ctx.before, "éé|")
eq("utf8 trim after", ctx.after, "éé")

local b4 = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_lines(b4, 0, -1, false, { "    # foo", "\tx = 1" })
vim.bo[b4].commentstring = "# %s"
vim.bo[b4].textwidth = 79
vim.bo[b4].expandtab = true
vim.bo[b4].shiftwidth = 4
vim.bo[b4].tabstop = 8
local ed = context.editor_settings(b4, 0)
eq("editor settings", ed, { commentstring = "# %s", indent = "4 spaces", indent_unit = "4 spaces" })
eq("tab indent", context.editor_settings(b4, 1).indent, "1 tab")

local msg = cleanup.user_message(config.options, {
  filename = "a.tex",
  filetype = "tex",
  before = "x ",
  after = " y",
  syntax = { "comment" },
  editor = {
    commentstring = "%%s",
    indent = "none",
    indent_unit = "2 spaces",
    textwidth = 0,
    column = 2,
  },
}, "hello", { "transmon" })
eq("message has cursor", msg:find(context.CURSOR, 1, true) ~= nil, true)
eq("message has hint", msg:find("LaTeX document", 1, true) ~= nil, true)
eq("message has settings", msg:find("comment format: %…", 1, true) ~= nil, true)
eq("message has vocab", msg:find("<vocabulary>transmon</vocabulary>", 1, true) ~= nil, true)

eq("leader", insert.comment_leader(b4), "#")
eq("strip leader", insert.strip_repeated_leader("# Foo", "    # ", "#"), "Foo")
eq("keep leader in prose", insert.strip_repeated_leader("# Foo", "x = 1  ", "#"), "# Foo")

eq(
  "add leaders",
  insert.add_leaders("One.\n\nTwo.\n# Three.", "    ", "#"),
  "One.\n    #\n    # Two.\n    # Three."
)

local mdmsg = cleanup.user_message(config.options, {
  filename = "a.jl",
  filetype = "julia",
  before = "",
  after = "",
  syntax = { "language: markdown", "language: markdown_inline" },
}, "x", {})
eq("embedded markdown hint", select(2, mdmsg:gsub('<embedded_language name="markdown">', "")), 1)

local b5 = vim.api.nvim_create_buf(false, true)
vim.api.nvim_set_current_buf(b5)
vim.bo[b5].comments = ":#"
vim.bo[b5].commentstring = "# %s"
vim.bo[b5].formatoptions = "cq"
vim.bo[b5].textwidth = 30
vim.api.nvim_buf_set_lines(b5, 0, -1, false, { "    # ", "code = 1" })
vim.api.nvim_win_set_cursor(0, { 2, 3 })
local er, ec = insert.apply(
  { smart_spacing = true, wrap = true },
  b5,
  0,
  6,
  0,
  6,
  "# one two three four five six seven eight nine",
  true
)
eq("wrapped comment", vim.api.nvim_buf_get_lines(b5, 0, -1, false), {
  "    # one two three four five",
  "    # six seven eight nine",
  "code = 1",
})
eq("end after wrap", { er, ec }, { 1, 26 })
eq("cursor kept", vim.api.nvim_win_get_cursor(0), { 3, 3 })
vim.api.nvim_buf_set_lines(b5, 0, -1, false, { "x = " })
insert.apply(
  { smart_spacing = true, wrap = true },
  b5,
  0,
  4,
  0,
  4,
  "aaaa bbbb cccc dddd eeee ffff gggg",
  false
)
eq(
  "no wrap in code without fo-t",
  vim.api.nvim_buf_get_lines(b5, 0, -1, false),
  { "x = aaaa bbbb cccc dddd eeee ffff gggg" }
)

-- Stop and cancel keys while recording (recorder stubbed out).
do
  local recorder = require("openwhispr.recorder")
  local calls = {}
  recorder.start = function()
    local proc = { closed = false }
    function proc:is_closing()
      return self.closed
    end
    return proc
  end
  recorder.stop = function()
    table.insert(calls, "stop")
  end
  recorder.kill = function(proc)
    proc.closed = true
    table.insert(calls, "kill")
  end
  require("openwhispr.transcribe").dictionary = function() end
  local notify = vim.notify
  vim.notify = function() end
  local ow = require("openwhispr")
  local function feed(keys)
    vim.api.nvim_feedkeys(vim.keycode(keys), "x", false)
  end
  vim.keymap.set({ "n", "i" }, "<F5>", ow.toggle)
  local recording = {}
  vim.keymap.set("i", "<F6>", function()
    table.insert(recording, ow.is_recording())
  end)

  vim.cmd("enew!")
  vim.keymap.set("i", "<C-c>", "OLD", { buffer = true })
  feed("i<F5><F6><Esc><F6>abc<Esc>")
  eq("Esc stops in insert mode", { recording, calls }, { { true, false }, { "stop" } })
  eq("insert mode kept after Esc", vim.api.nvim_get_current_line(), "abc")
  eq("Esc unmapped after stop", vim.fn.maparg("<Esc>", "i"), "")
  eq("shadowed buffer-local map restored", vim.fn.maparg("<C-c>", "i"), "OLD")
  ow.cancel()

  vim.cmd("enew!")
  calls = {}
  feed("<F5><C-c>")
  eq("C-c cancels in normal mode", { ow.is_recording(), calls }, { false, { "kill" } })

  ow.setup({ recording = { keys = { cancel = false } } })
  feed("<F5>")
  eq(
    "cancel = false",
    { vim.fn.maparg("<Esc>", "n") ~= "", vim.fn.maparg("<C-c>", "n") },
    { true, "" }
  )
  ow.cancel()
  ow.setup()
  vim.notify = notify
end

-- Transcript history.
do
  local history = require("openwhispr.history")
  local ow = require("openwhispr")
  local dir = vim.fn.tempname()
  local notify = vim.notify
  vim.notify = function() end

  -- A one-second 16 kHz mono 16-bit WAV file (byte rate 32000).
  local function fake_wav()
    local path = vim.fn.tempname() .. ".wav"
    local f = assert(io.open(path, "wb"))
    local function u32(n)
      return string.char(n % 256, math.floor(n / 256) % 256, math.floor(n / 65536) % 256, 0)
    end
    f:write("RIFF", u32(36 + 32000), "WAVEfmt ", u32(16), "\1\0\1\0", u32(16000), u32(32000))
    f:write("\2\0\16\0", "data", u32(32000), string.rep("\0", 32000))
    f:close()
    return path
  end

  ow.setup({ history = { enabled = true, dir = dir } })
  local wav = fake_wav()
  eq("wav duration", history.wav_duration(wav), 1)
  assert(history.add({ id = "A", raw = "into any of him", cleaned = "into any of them" }, wav))
  assert(history.add({ id = "B", raw = "second", cleanup_error = "HTTP 401" }, fake_wav()))
  eq("recording moved", vim.fn.filereadable(wav), 0)
  eq("recording stored", vim.fn.filereadable(dir .. "/audio/A.wav"), 1)
  local entries = history.read()
  eq(
    "entries",
    vim.tbl_map(function(e)
      return { e.id, e.audio, e.duration }
    end, entries),
    { { "A", "audio/A.wav", 1 }, { "B", "audio/B.wav", 1 } }
  )

  -- Review: correct A, delete B's block (left unreviewed), save.
  ow.history()
  local buf = vim.api.nvim_get_current_buf()
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  eq("review buffer entry", vim.list_slice(lines, 6, 9), {
    "## A  1 s  -",
    "raw:      into any of him",
    "cleaned:  into any of them",
    "verbatim: into any of him",
  })
  eq("cleanup error shown", lines[13], "cleaned:  (HTTP 401)")
  vim.api.nvim_buf_set_lines(buf, 8, 9, false, { "verbatim: into Neovim" })
  vim.api.nvim_buf_set_lines(buf, 9, -1, false, {})
  vim.cmd("write")
  eq("buffer saved", vim.bo[buf].modified, false)
  entries = history.read()
  eq("verbatim stored", { entries[1].verbatim, entries[2].verbatim }, { "into Neovim", nil })
  vim.cmd("bwipeout!")
  ow.history()
  eq("only unreviewed shown", vim.api.nvim_buf_get_lines(0, 5, 6, false)[1], "## B  1 s  -")
  vim.cmd("bwipeout!")

  -- Invalid lines survive a rewrite.
  local f = assert(io.open(history.file(), "a"))
  f:write("not json\n")
  f:close()
  history.write(history.read())
  eq("invalid line kept", vim.fn.readfile(history.file())[3], "not json")

  -- Full flow with recording, transcription and cleanup stubbed out.
  local recorder = require("openwhispr.recorder")
  local on_exit
  recorder.start = function(_, path, cb)
    on_exit = cb
    local src = fake_wav()
    vim.uv.fs_rename(src, path)
    return {
      is_closing = function()
        return true
      end,
    }
  end
  recorder.stop = function() end
  require("openwhispr.transcribe").run = function(_, _, cb)
    cb(nil, "edit this in neo vim", "openwhispr")
  end
  require("openwhispr.cleanup").run = function(_, _, _, _, cb)
    cb(nil, "Edit this in Neovim.")
  end
  vim.cmd("enew!")
  vim.bo.filetype = "markdown"
  ow.start()
  ow.stop()
  on_exit({ code = 0, stderr = "" })
  local last = history.read()[4]
  eq("flow: entry", {
    last.raw,
    last.cleaned,
    last.backend,
    last.filetype,
    last.duration,
    vim.fn.filereadable(dir .. "/" .. last.audio),
  }, { "edit this in neo vim", "Edit this in Neovim.", "openwhispr", "markdown", 1, 1 })
  eq("flow: text inserted", vim.api.nvim_get_current_line(), "Edit this in Neovim.")

  -- Disabled: nothing is recorded.
  ow.setup({ history = { enabled = false, dir = dir } })
  vim.cmd("enew!")
  ow.start()
  ow.stop()
  on_exit({ code = 0, stderr = "" })
  eq("disabled: no entry", #history.read(), 4)

  ow.setup()
  vim.notify = notify
  vim.fn.delete(dir, "rf")
end

-- Project files and instructions.
do
  local context = require("openwhispr.context")
  local cleanup = require("openwhispr.cleanup")
  local cfg = require("openwhispr.config")
  local root = vim.fn.resolve(vim.fn.tempname())
  vim.fn.mkdir(root .. "/a/b/c", "p")
  vim.fn.writefile({ "Outer notes." }, root .. "/a/.dictation.md")
  vim.fn.writefile({ "Inner notes." }, root .. "/a/b/.dictation.md")
  vim.fn.writefile({ "Untrusted." }, root .. "/a/b/c/.dictation.md")
  local buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_name(buf, root .. "/a/b/c/paper.tex")
  -- The test tree is itself in a temporary directory.
  local temp_roots = context.temp_roots
  context.temp_roots = function()
    return { root .. "/tmp" }
  end
  vim.fn.mkdir(root .. "/tmp/claude", "p")
  local prompt_buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_name(prompt_buf, root .. "/tmp/claude/prompt.md")
  local cwd = vim.fn.getcwd()
  vim.fn.chdir(root .. "/a/b")
  eq("file in temp dir uses cwd", context.project_dir(prompt_buf), root .. "/a/b")
  eq("file elsewhere uses its directory", context.project_dir(buf), root .. "/a/b/c")
  vim.fn.chdir(cwd)
  vim.api.nvim_buf_delete(prompt_buf, { force = true })

  cfg.setup({ cleanup = { instructions = "Global." } })
  eq("project files, outermost first", context.project_files(cfg.options, buf), {
    root .. "/a/.dictation.md",
    root .. "/a/b/.dictation.md",
    root .. "/a/b/c/.dictation.md",
  })
  local read_trusted = context.read_trusted
  context.read_trusted = function(path)
    if path:find("/c/", 1, true) then
      return nil -- not trusted
    end
    return table.concat(vim.fn.readfile(path), "\n")
  end
  vim.b[buf].openwhispr_instructions = "Buffer."
  local list = context.instructions(cfg.options, buf)
  eq(
    "instruction order",
    vim.tbl_map(function(i)
      return i.text
    end, list),
    { "Global.", "Outer notes.", "Inner notes.", "Buffer." }
  )
  eq("instruction source", list[2].source, vim.fn.fnamemodify(root .. "/a/.dictation.md", ":~"))

  local prompt = cleanup.system_prompt(cfg.options, { instructions = list })
  eq("system prompt starts unchanged", vim.startswith(prompt, cleanup.SYSTEM_PROMPT), true)
  eq(
    "system prompt instructions",
    prompt
      :sub(#cleanup.SYSTEM_PROMPT + 1)
      :match('<instructions source="b:openwhispr_instructions">\nBuffer.\n</instructions>$')
      ~= nil,
    true
  )
  eq(
    "no instructions",
    cleanup.system_prompt(cfg.options, { instructions = {} }),
    cleanup.SYSTEM_PROMPT
  )
  eq(
    "fallback to cleanup.instructions",
    cleanup.system_prompt(cfg.options, {}):match("Global%.\n</instructions>$") ~= nil,
    true
  )

  eq("no warning for short notes", context.instructions_warning(cfg.options, list), nil)
  local long = { { source = "~/p/.dictation.md", text = string.rep("x", 12000) }, list[1] }
  eq(
    "warning for long notes",
    context.instructions_warning(cfg.options, long),
    "the instructions and project notes are long (12,007 characters), and they are sent with "
      .. "every dictation: ~/p/.dictation.md (12,000), cleanup.instructions (7)"
  )
  cfg.setup({ context = { instructions_warn_chars = false } })
  eq("warning disabled", context.instructions_warning(cfg.options, long), nil)
  cfg.setup({ context = { project_file = false } })
  eq("project_file = false", context.project_files(cfg.options, buf), {})
  eq("only the buffer variable", #context.instructions(cfg.options, buf), 1)

  context.read_trusted = read_trusted
  context.temp_roots = temp_roots
  cfg.setup()
  vim.api.nvim_buf_delete(buf, { force = true })
  vim.fn.delete(root, "rf")
end

print(failures == 0 and "all passed" or (failures .. " failed"))
os.exit(failures == 0 and 0 or 1)

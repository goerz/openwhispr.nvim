-- Buffer context for the cleanup step.
local M = {}

M.CURSOR = "⟨CURSOR⟩"

local SYNTAX_PATTERNS = { "comment", "string", "math", "doc", "markup", "quote", "code" }

local function interesting(name)
  local lower = name:lower()
  for _, pat in ipairs(SYNTAX_PATTERNS) do
    if lower:find(pat, 1, true) then
      return true
    end
  end
  return false
end

---Syntax context at (row, col), 0-based: treesitter captures if a highlighter
---is active, otherwise legacy syntax groups. Returns a list of names.
function M.syntax_at(buf, row, col)
  local names, seen = {}, {}
  local function add(name)
    if not seen[name] then
      seen[name] = true
      table.insert(names, name)
    end
  end
  local line = vim.api.nvim_buf_get_lines(buf, row, row + 1, false)[1] or ""
  -- At the end of a line there is nothing to inspect; look at the character
  -- before the insertion point instead.
  local c = (col >= #line and col > 0) and col - 1 or col
  local ok, captures = pcall(vim.treesitter.get_captures_at_pos, buf, row, c)
  if ok and captures and #captures > 0 then
    local ft = vim.bo[buf].filetype
    for _, cap in ipairs(captures) do
      if interesting(cap.capture) then
        add(cap.capture)
      end
      if cap.lang and cap.lang ~= ft and cap.lang ~= "comment" then
        add("language: " .. cap.lang)
      end
    end
    return names
  end
  if vim.bo[buf].syntax ~= "" and buf == vim.api.nvim_get_current_buf() then
    local ok2, stack = pcall(vim.fn.synstack, row + 1, c + 1)
    if ok2 then
      for _, id in ipairs(stack) do
        local name = vim.fn.synIDattr(id, "name")
        if interesting(name) then
          add(name)
        end
      end
    end
  end
  return names
end

---Gather context for the range (srow, scol)-(erow, ecol), 0-based, end
---exclusive. An empty range is an insertion point.
function M.gather(opts, buf, srow, scol, erow, ecol)
  local copts = opts.context
  local name = vim.api.nvim_buf_get_name(buf)
  local ctx = {
    filename = name ~= "" and vim.fn.fnamemodify(name, ":~:.") or "[No Name]",
    filetype = vim.bo[buf].filetype,
  }
  local first = math.max(0, srow - copts.lines_before)
  local before_lines = vim.api.nvim_buf_get_lines(buf, first, srow + 1, false)
  before_lines[#before_lines] = (before_lines[#before_lines] or ""):sub(1, scol)
  local last = math.min(vim.api.nvim_buf_line_count(buf), erow + 1 + copts.lines_after)
  local after_lines = vim.api.nvim_buf_get_lines(buf, erow, last, false)
  after_lines[1] = (after_lines[1] or ""):sub(ecol + 1)

  local half = math.floor(copts.max_chars / 2)
  local before = table.concat(before_lines, "\n")
  local after = table.concat(after_lines, "\n")
  -- Trim byte-wise, then move the cut to a UTF-8 character boundary.
  if #before > half then
    local i = #before - half + 1
    while i <= #before and before:byte(i) >= 0x80 and before:byte(i) < 0xC0 do
      i = i + 1
    end
    before = before:sub(i)
  end
  if #after > half then
    local j = half + 1
    while j > 1 and after:byte(j) >= 0x80 and after:byte(j) < 0xC0 do
      j = j - 1
    end
    after = after:sub(1, j - 1)
  end
  ctx.before, ctx.after = before, after
  if srow ~= erow or scol ~= ecol then
    ctx.selection = table.concat(vim.api.nvim_buf_get_text(buf, srow, scol, erow, ecol, {}), "\n")
  end
  if copts.syntax then
    ctx.syntax = M.syntax_at(buf, srow, scol)
  end
  ctx.editor = M.editor_settings(buf, srow)
  -- Without syntax information, a line that starts with the comment leader
  -- still marks the insertion point as a comment.
  if copts.syntax and #ctx.syntax == 0 and ctx.editor.commentstring then
    local leader = vim.trim(ctx.editor.commentstring:match("^(.-)%%s") or "")
    local line = vim.api.nvim_buf_get_lines(buf, srow, srow + 1, false)[1] or ""
    if leader ~= "" and vim.startswith(vim.trim(line:sub(1, scol)), leader) then
      table.insert(ctx.syntax, "comment")
    end
  end
  return ctx
end

-- Reads a project file, asking the user to trust it first (like 'exrc').
-- Replaced in tests.
M.read_trusted = vim.secure.read

---Directories for temporary files. A buffer whose file is in one of them
---(for example, a prompt that another program opened in Neovim for editing)
---belongs to the project of the working directory.
function M.temp_roots()
  local roots = { "/tmp", "/private/tmp", "/var/folders", "/private/var/folders" }
  if vim.env.TMPDIR and vim.env.TMPDIR ~= "" then
    table.insert(roots, 1, vim.env.TMPDIR)
  end
  return roots
end

local function in_temp_dir(dir)
  for _, root in ipairs(M.temp_roots()) do
    root = vim.fs.normalize(root):gsub("/+$", "")
    if root ~= "" and (dir == root or vim.startswith(dir, root .. "/")) then
      return true
    end
  end
  return false
end

---The directory where the search for project files starts: the directory
---of the buffer's file, or the working directory for a buffer without a
---file or with a file in a temporary directory.
function M.project_dir(buf)
  local file = vim.api.nvim_buf_get_name(buf)
  local dir = file ~= "" and vim.fs.dirname(vim.fs.normalize(file)) or nil
  if not dir or vim.fn.isdirectory(dir) == 0 or in_temp_dir(dir) then
    return vim.fn.getcwd()
  end
  return dir
end

---Project files (`context.project_file`) that apply to `buf`: every file of
---that name from the home directory down to M.project_dir(), outermost
---first. Outside the home directory, the search goes up to the root.
function M.project_files(opts, buf)
  local name = opts.context.project_file
  if not name then
    return {}
  end
  local dir = M.project_dir(buf)
  local home = vim.fs.normalize("~")
  local found = vim.fs.find(name, {
    upward = true,
    path = dir,
    type = "file",
    limit = math.huge,
    stop = vim.fs.dirname(home),
  })
  local files = {}
  for i = #found, 1, -1 do
    table.insert(files, found[i])
  end
  return files
end

---Instructions for the cleanup prompt, in order: `cleanup.instructions`,
---the trusted project files (outermost first), and the buffer variable
---`b:openwhispr_instructions`. Returns a list of {source, text}.
function M.instructions(opts, buf)
  local list = {}
  local function add(source, text)
    if type(text) == "string" and vim.trim(text) ~= "" then
      table.insert(list, { source = source, text = vim.trim(text) })
    end
  end
  add("cleanup.instructions", opts.cleanup.instructions)
  for _, path in ipairs(M.project_files(opts, buf)) do
    local ok, text = pcall(M.read_trusted, path)
    if ok then
      add(vim.fn.fnamemodify(path, ":~"), text)
    end
  end
  add("b:openwhispr_instructions", vim.b[buf].openwhispr_instructions)
  return list
end

---Describe a run of leading whitespace, e.g. "4 spaces", "1 tab", "none".
local function describe_whitespace(ws)
  if ws == "" then
    return "none"
  end
  local tabs = select(2, ws:gsub("\t", ""))
  local spaces = #ws - tabs
  local parts = {}
  if tabs > 0 then
    table.insert(parts, ("%d tab%s"):format(tabs, tabs == 1 and "" or "s"))
  end
  if spaces > 0 then
    table.insert(parts, ("%d space%s"):format(spaces, spaces == 1 and "" or "s"))
  end
  return table.concat(parts, " + ")
end

---Buffer settings that affect how multi-line text should be laid out:
---comment format and indentation. `row` is 0-based.
function M.editor_settings(buf, row)
  local bo = vim.bo[buf]
  local line = vim.api.nvim_buf_get_lines(buf, row, row + 1, false)[1] or ""
  local sw = bo.shiftwidth > 0 and bo.shiftwidth or bo.tabstop
  return {
    commentstring = bo.commentstring ~= "" and bo.commentstring or nil,
    indent = describe_whitespace(line:match("^%s*")),
    indent_unit = bo.expandtab and ("%d spaces"):format(sw)
      or ("tabs (tabstop %d)"):format(bo.tabstop),
  }
end

return M

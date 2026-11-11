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

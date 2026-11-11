-- Insert the final text into the buffer.
local M = {}

local ns = vim.api.nvim_create_namespace("openwhispr_insert")

-- Characters after which a following word needs a separating space.
local function ends_word(ch)
  return ch ~= "" and (ch:match("[%w%.,;:!%?%)%]}]") ~= nil or ch:byte() >= 0x80)
end

-- Characters that start a word (or an opening bracket, math, or command).
local function starts_word(ch)
  return ch ~= "" and (ch:match("[%w%(%[{%$\\]") ~= nil or ch:byte() >= 0x80)
end

---Add spaces between `text` and adjacent non-blank characters where a word
---boundary needs one.
function M.smart_space(text, before_char, after_char)
  if text == "" then
    return text
  end
  if ends_word(before_char) and starts_word(text:sub(1, 1)) then
    text = " " .. text
  end
  if ends_word(text:sub(-1)) and starts_word(after_char) then
    text = text .. " "
  end
  return text
end

---The comment leader from 'commentstring' (e.g. "#", "--", "%"), or nil.
function M.comment_leader(buf)
  local leader = vim.bo[buf].commentstring:match("^(.-)%%s")
  leader = leader and vim.trim(leader) or ""
  return leader ~= "" and leader or nil
end

---If the text before the insertion point is just indentation and a comment
---leader, drop a copy of that leader from the start of `text`.
function M.strip_repeated_leader(text, prefix, leader)
  if leader and vim.trim(prefix) == leader and vim.startswith(text, leader) then
    return (text:sub(#leader + 1):gsub("^%s+", ""))
  end
  return text
end

---Start each line after the first with `indent .. leader .. " "`, unless it
---already starts with the leader. Blank lines get the bare leader.
function M.add_leaders(text, indent, leader)
  local lines = vim.split(text, "\n", { plain = true })
  for i = 2, #lines do
    local body = vim.trim(lines[i])
    if body == "" then
      lines[i] = indent .. leader
    elseif not vim.startswith(body, leader) then
      lines[i] = indent .. leader .. " " .. body
    else
      lines[i] = indent .. body
    end
  end
  return table.concat(lines, "\n")
end

---Format the lines srow..erow (0-based) that are longer than 'textwidth'
---with `gww`, as Vim would while typing: only with 'formatoptions' "t", or
---"c" inside a comment. `gw` uses the internal formatter ('comments',
---'formatoptions'), never 'formatexpr' or 'formatprg'.
function M.wrap(buf, srow, erow, in_comment)
  local bo = vim.bo[buf]
  local tw = bo.textwidth
  local fo = bo.formatoptions
  if tw <= 0 or not (fo:find("t", 1, true) or (in_comment and fo:find("c", 1, true))) then
    return
  end
  vim.api.nvim_buf_call(buf, function()
    for row = erow, srow, -1 do
      local line = vim.api.nvim_buf_get_lines(buf, row, row + 1, false)[1]
      if line and vim.fn.strdisplaywidth(line) > tw then
        vim.cmd(("silent! undojoin | keepjumps normal! %dGgww"):format(row + 1))
      end
    end
  end)
end

---Replace the range (srow, scol)-(erow, ecol), 0-based and end-exclusive, in
---`buf` with `text`, then wrap long lines (see `M.wrap`). The cursor of the
---current window keeps its place in the text. Returns the 0-based position
---just after the inserted text.
function M.apply(opts, buf, srow, scol, erow, ecol, text, in_comment)
  local api = vim.api
  local sline = api.nvim_buf_get_lines(buf, srow, srow + 1, false)[1] or ""
  local eline = api.nvim_buf_get_lines(buf, erow, erow + 1, false)[1] or ""
  local prefix, leader = sline:sub(1, scol), M.comment_leader(buf)
  text = M.strip_repeated_leader(text, prefix, leader)
  -- Without syntax information, a line that starts with the comment leader
  -- still counts as a comment.
  in_comment = in_comment or (leader ~= nil and vim.startswith(vim.trim(prefix), leader))
  if in_comment and leader then
    text = M.add_leaders(text, prefix:match("^%s*"), leader)
  end
  if opts.smart_spacing then
    text = M.smart_space(text, sline:sub(scol, scol), eline:sub(ecol + 1, ecol + 1))
  end
  local lines = vim.split(text, "\n", { plain = true })
  api.nvim_buf_set_text(buf, srow, scol, erow, ecol, lines)
  local end_row = srow + #lines - 1
  local end_col = (#lines == 1 and scol or 0) + #lines[#lines]
  if not opts.wrap then
    return end_row, end_col
  end

  -- Track the end of the new text and the cursor through the reformatting.
  local current = api.nvim_get_current_buf() == buf
  local view = current and vim.fn.winsaveview() or nil
  local cur = api.nvim_win_get_cursor(0)
  local end_mark = api.nvim_buf_set_extmark(buf, ns, end_row, end_col, { right_gravity = false })
  local cur_mark = current
    and api.nvim_buf_set_extmark(buf, ns, cur[1] - 1, cur[2], { right_gravity = false })
  M.wrap(buf, srow, end_row, in_comment)
  local pos = api.nvim_buf_get_extmark_by_id(buf, ns, end_mark, {})
  api.nvim_buf_del_extmark(buf, ns, end_mark)
  if cur_mark then
    local cpos = api.nvim_buf_get_extmark_by_id(buf, ns, cur_mark, {})
    api.nvim_buf_del_extmark(buf, ns, cur_mark)
    vim.fn.winrestview(view)
    pcall(api.nvim_win_set_cursor, 0, { cpos[1] + 1, cpos[2] })
  end
  return pos[1], pos[2]
end

return M

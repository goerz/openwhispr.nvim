if vim.g.loaded_openwhispr then
  return
end
vim.g.loaded_openwhispr = true

local function set_highlights()
  vim.api.nvim_set_hl(
    0,
    "OpenWhisprRecording",
    { link = "DiagnosticVirtualTextError", default = true }
  )
  vim.api.nvim_set_hl(
    0,
    "OpenWhisprProcessing",
    { link = "DiagnosticVirtualTextInfo", default = true }
  )
end
set_highlights()

local group = vim.api.nvim_create_augroup("openwhispr", { clear = true })
vim.api.nvim_create_autocmd("ColorScheme", { group = group, callback = set_highlights })
vim.api.nvim_create_autocmd("VimLeavePre", {
  group = group,
  callback = function()
    if package.loaded["openwhispr"] then
      require("openwhispr").cancel()
    end
  end,
})

local subcommands = { "toggle", "start", "stop", "cancel", "history" }

vim.api.nvim_create_user_command("OpenWhispr", function(cmd)
  local sub = cmd.fargs[1] or "toggle"
  if not vim.tbl_contains(subcommands, sub) then
    vim.notify("openwhispr: unknown subcommand: " .. sub, vim.log.levels.ERROR)
    return
  end
  local range = cmd.range > 0 and { line1 = cmd.line1, line2 = cmd.line2 } or nil
  local ow = require("openwhispr")
  if sub == "history" then
    if cmd.fargs[2] and cmd.fargs[2] ~= "all" then
      vim.notify("openwhispr: usage: :OpenWhispr history [all]", vim.log.levels.ERROR)
      return
    end
    ow.history(cmd.fargs[2] == "all")
  elseif sub == "toggle" or sub == "start" then
    ow[sub](range)
  else
    ow[sub]()
  end
end, {
  nargs = "*",
  range = true,
  desc = "Dictation: toggle, start, stop, cancel, or history",
  complete = function(arglead, cmdline)
    local words = vim.split(vim.trim(cmdline), "%s+")
    local nargs = #words - 1 + (arglead == "" and 1 or 0)
    local choices = nargs <= 1 and subcommands
      or (nargs == 2 and words[2] == "history" and { "all" } or {})
    return vim.tbl_filter(function(s)
      return s:find(arglead, 1, true) == 1
    end, choices)
  end,
})

local function plug(name, fn, modes, desc)
  vim.keymap.set(modes, "<Plug>(openwhispr-" .. name .. ")", function()
    require("openwhispr")[fn]()
  end, { desc = desc })
end

plug("toggle", "toggle", { "n", "i", "x" }, "Dictation: start or stop")
plug("start", "start", { "n", "i", "x" }, "Dictation: start")
plug("stop", "stop", { "n", "i", "x" }, "Dictation: stop")
plug("cancel", "cancel", { "n", "i", "x" }, "Dictation: cancel")

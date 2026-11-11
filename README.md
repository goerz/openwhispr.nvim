# openwhispr.nvim

Dictation for Neovim. Press a key, speak, press it again: the speech is transcribed locally, cleaned up by Claude with the surrounding buffer text as context, and inserted at the cursor.

The pipeline:

1. Record the microphone with `ffmpeg`.
2. Transcribe locally with the [OpenWhispr](https://openwhispr.com) desktop app through its CLI (Parakeet model, about 0.3 s). If the app is not running, fall back to [parakeet-mlx](https://github.com/senstella/parakeet-mlx).
3. Clean up the transcript with Claude Haiku through the Anthropic Messages API: remove filler words, apply spoken self-corrections ("actually no, I mean…"), fix punctuation and misheard technical terms, and format the text for the file type (for example, spoken math becomes LaTeX in a `.tex` file).
4. Insert the result at the position where dictation started, as one change, or replace the visual selection.

From stopping the recording to text in the buffer typically takes 1 to 2 seconds.

## Requirements

- Neovim 0.11 or later
- macOS for the default configuration (recording through AVFoundation, API key in the Keychain). Both are configurable; see `recording.cmd` and `cleanup.api_key_cmd`.
- `ffmpeg` (`brew install ffmpeg`)
- The OpenWhispr desktop app, running, plus its CLI (`npm install -g @openwhispr/cli`), and/or `parakeet-mlx` (`uv tool install parakeet-mlx`)
- `curl` and an Anthropic API key for the cleanup step (optional; without it, raw transcripts are inserted)

Run `:checkhealth openwhispr` to verify the setup.

### API key

The plugin reads the key from the macOS Keychain on every call, from a generic-password item with the service name `anthropic-api-key`:

```sh
security add-generic-password -a "$USER" -s anthropic-api-key -w
```

The key is passed to `curl` on standard input, so it does not appear in the process list, in environment variables, or in any file. The plugin ignores `ANTHROPIC_API_KEY`. To get the key some other way, set `cleanup.api_key_cmd` to a command that prints it.

### Microphone permission

`ffmpeg` runs as a child process of Neovim, so macOS asks whether your terminal application may use the microphone the first time you dictate. If the permission is denied, recordings are silent and you get "no speech detected"; grant it in System Settings under Privacy & Security > Microphone.

### Choosing the microphone

Recording uses the macOS default input device, the one selected in System Settings > Sound > Input. To record from a specific microphone regardless of that setting, list the device names:

```sh
ffmpeg -hide_banner -f avfoundation -list_devices true -i "" 2>&1 | sed -n '/audio devices/,/Error/p'
```

The output looks like this (the final "Error opening input" line is expected, since no input was given):

```
[AVFoundation indev @ 0x...] AVFoundation audio devices:
[AVFoundation indev @ 0x...] [0] Studio Display Microphone
[AVFoundation indev @ 0x...] [1] Yeti Stereo Microphone
[AVFoundation indev @ 0x...] [2] MacBook Pro Microphone
[in#0 @ 0x...] Error opening input: Input/output error
```

Then replace `":default"` in `recording.cmd` with a colon followed by the name:

```lua
opts = {
  recording = {
    cmd = { "ffmpeg", "-hide_banner", "-loglevel", "error", "-f", "avfoundation",
            "-i", ":Yeti Stereo Microphone", "-ar", "16000", "-ac", "1", "-y" },
  },
}
```

The index (`":1"`) works too, but indices change when devices are plugged in or removed.

## Installation

With [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  "goerz/openwhispr.nvim",
  cmd = "OpenWhispr",
  keys = {
    { "<C-x><C-v>", "<Plug>(openwhispr-toggle)", mode = { "n", "i", "x" }, desc = "Dictation" },
  },
  opts = {},
}
```

Calling `setup()` is optional; the defaults apply without it.

With lazy-loading, `:checkhealth openwhispr` reports "No healthcheck found" until the plugin has loaded. Run `:Lazy load openwhispr.nvim` first, or dictate once.

## Usage

The plugin defines no keymaps. Map `<Plug>(openwhispr-toggle)` in the modes you want:

```lua
vim.keymap.set({ "n", "i", "x" }, "<C-x><C-v>", "<Plug>(openwhispr-toggle)")
```

Dictation is a toggle (start, then stop), because terminal Neovim receives no key-release events, which rules out hold-to-talk.

- Insert mode: the text goes in at the cursor.
- Normal mode: the text goes in after the character under the cursor.
- Visual mode (charwise or linewise): the text replaces the selection.

While dictation runs, an indicator at the insertion point shows the state (`● rec 0:07`, `… transcribing`, `… cleaning up`). You can keep editing; the insertion point moves with the text around it.

Commands:

| Command | Effect |
|---|---|
| `:OpenWhispr` or `:OpenWhispr toggle` | start or stop dictation |
| `:OpenWhispr start` | start recording |
| `:OpenWhispr stop` | stop recording and process it |
| `:OpenWhispr cancel` | stop recording and discard everything in progress |

With a range (`:'<,'>OpenWhispr`), the dictated text replaces the selected text.

`<Plug>(openwhispr-start)`, `<Plug>(openwhispr-stop)`, and `<Plug>(openwhispr-cancel)` exist as well.

If the cleanup step fails (offline, invalid key, no credits), the raw transcript is inserted and a warning tells you why.

### Statusline

`require("openwhispr").status()` returns the current state as a short string, or `""` when idle. A `User OpenWhisprStatus` autocommand fires on every change. For lualine:

```lua
sections = { lualine_x = { function() return require("openwhispr").status() end } }
```

## Configuration

Defaults:

```lua
require("openwhispr").setup({
  recording = {
    -- ffmpeg command without the output file
    cmd = { "ffmpeg", "-hide_banner", "-loglevel", "error", "-f", "avfoundation",
            "-i", ":default", "-ar", "16000", "-ac", "1", "-y" },
    max_duration = 600, -- seconds
    keep_audio = false,
  },
  transcription = {
    openwhispr = "openwhispr", -- CLI executable; false to skip
    model = nil, -- local OpenWhispr model id; nil for the app's default
    parakeet = "parakeet-mlx", -- fallback executable; false to disable
    parakeet_model = nil, -- Hugging Face repo; nil for the default
    timeout = 120, -- seconds
  },
  context = {
    lines_before = 40,
    lines_after = 15,
    max_chars = 6000,
    syntax = true, -- tell the model if the cursor is in a comment, string, math, ...
    dictionary = true, -- send the OpenWhispr dictionary as known vocabulary
    vocabulary = {}, -- extra known words, e.g. { "transmon", "Krotov" }
  },
  cleanup = {
    enabled = true,
    model = "claude-haiku-5-5",
    effort = "low",
    thinking = "disabled", -- "adaptive" is slower (about 4 s)
    max_tokens = 4096,
    timeout = 20, -- seconds
    keychain_service = "anthropic-api-key",
    api_key_cmd = nil, -- e.g. { "pass", "show", "anthropic" }
    instructions = nil, -- extra text for the system prompt
    filetype_hints = { markdown = "...", tex = "...", julia = "...", ... },
  },
  smart_spacing = true, -- add spaces between inserted text and adjacent words
  wrap = true, -- wrap long inserted lines at 'textwidth' (as if typed)
  indicator = "inline", -- "inline", "eol", or false
})
```

`filetype_hints` maps a filetype to a description of the file for the model; your entries are merged with the defaults. The defaults cover `markdown` (also `quarto`, `rmd`, `pandoc`), `tex`, `plaintex`, `julia`, `python`, `gitcommit`, `mail`, and `text`. The Markdown hint asks for valid GitHub-flavored Markdown, with code in backticks and math as `$...$` / `$$...$$`. It also applies wherever treesitter reports Markdown embedded at the cursor, for example in a docstring.

## What the model sees

Besides the transcript, the cleanup request includes the file name and filetype with its hint, the syntax context at the cursor (comment, string, math, embedded language, from treesitter or syntax groups), the buffer's `commentstring`, the indentation of the current line and the indent unit (`shiftwidth`, `expandtab`), the text around the cursor with the insertion point marked, the selected text when replacing, and the vocabulary.

Line wrapping is done by the plugin, not the model: inserted lines longer than `textwidth` are formatted with `gw`, as if you had typed them, so `formatoptions` (`t`, or `c` in comments) and `comments` decide what wraps. Comment leaders on new lines are also added by the plugin.

## Privacy

Audio stays on your machine. The cleanup step sends the transcript, the file name and filetype, and up to `context.lines_before` + `context.lines_after` lines around the cursor (at most `context.max_chars` characters) to the Anthropic API. Set `cleanup.enabled = false` to keep everything local.

## License

[MIT](LICENSE)

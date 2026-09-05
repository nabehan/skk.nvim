# skk.nvim

English | [日本語](README.md)

A SKK (Japanese input method) plugin implemented purely in Lua for Neovim only (not Vim-compatible), with no dependency on denops or any external process.

**Current status:** In addition to romaji→kana/katakana conversion and switching between the 4 modes (with a mode indicator shown at the cursor on each switch), it supports dictionary conversion (`▽`/`▼`, with/without okurigana, and abbrev), a candidate-selection window (with `<C-n>`/`<C-p>` focus movement), word registration (a UI that supports recursive word registration via recursive calls to `vim.fn.input()`), sticky-shift, a personal dictionary (learning), merging multiple dictionaries, and SKK server integration. Large dictionary files are loaded with asynchronous, lazy parsing. Beyond insert-mode buffers, it also supports romaji→kana conversion, the 4 mode switches, the mode indicator, dictionary conversion (`▽`/`▼`, candidate window), and word registration in **command-line mode** (`:`/`/`). The built-in terminal is intentionally not supported (see below).

## Installation

Minimal [lazy.nvim](https://github.com/folke/lazy.nvim) configuration (you can load it and try mode switching even without a dictionary; dictionary conversion requires loading a dictionary file separately — see "Usage" below):

```lua
{
  "nabehan/skk.nvim",
  -- version = "*", -- Uncomment if you only want tagged releases (e.g. v0.1.0).
  --                   If omitted, tracks the latest of the main branch (may include work in progress).
  config = function()
    require("skk").setup({
      -- Customize as you like. See "Usage" below for the defaults.
    })

    -- Dictionary conversion (▽/▼) requires loading a dictionary file separately from setup().
    -- SKK-JISYO.L and similar files are available from https://github.com/skk-dev/dict.
    require("skk.dict").load_dictionary_async(
      "/usr/share/skk/SKK-JISYO.L",
      "euc-jp"
    )
  end,
}
```

For configuration examples combining this with [blink.cmp](https://github.com/Saghen/blink.cmp) or a SKK server (skkserv/yaskkserv2, etc.), see "Usage" and "blink.cmp native source integration" below. The `init.lua` in [nvim-skk-sandbox](https://github.com/nabehan/nvim-skk-sandbox) is also a useful reference for a working minimal setup.

Requirements: Neovim 0.10 or later (uses key consumption via an empty-string return from `vim.on_key()`, `vim.schedule`, extmarks, etc.). No dependency on denops or any other external process.

## Modes (`mode.lua` + `kana_util.lua`)

Traditional SKK has 5 modes (ASCII / hiragana / katakana / full-width ASCII / half-width katakana), but this plugin implements only 4, having decided not to implement half-width katakana.

| Mode                       | Description                                                                                                                       |
| -------------------------- | --------------------------------------------------------------------------------------------------------------------------------- |
| `ascii`                    | SKK is effectively OFF. Key input passes through completely.                                                                      |
| `hira` (hiragana)          | Normal romaji input.                                                                                                              |
| `kata` (katakana)          | The result of romaji input is displayed in katakana.                                                                              |
| `zenei` (full-width ASCII) | Converts all printable half-width ASCII characters to full-width (e.g. typing `q` yields `ｑ`). Not treated as a mode-switch key. |

**Mode transition table (`lua/skk/mode.lua`):**

```
ascii  --<C-j>--> hira
zenei  --<C-j>--> hira
hira   --l-->     ascii
hira   --q-->     kata
hira   --L-->     zenei
kata   --l-->     ascii
kata   --q-->     hira
kata   --L-->     zenei
```

Since `l`/`q`/`L` are printable characters, the `vim.on_key()` callback in `capture.lua` treats them specially as mode-switch keys **only when the pending romaji buffer is empty** (if the buffer is non-empty, they're processed as ordinary romaji input). `<C-j>` is a control key, so `init.lua` calls `capture.transition()` directly via an ordinary `vim.keymap.set`.

**On half-width katakana mode:** Implementing it, following traditional SKK, was originally planned. However, in practice **inserting half-width katakana was found to cause instability in terminal emulators**, so the decision was made not to implement it. The `<C-q>` key isn't used for mode switching, but during abbrev mode only, it means "convert to full-width and confirm" (see "Conversion (`▽`/`▼`, henkan)" below).

**Conversion method to katakana:** Rather than duplicating `kana_table.lua` as a katakana version, the conversion functions in `kana_util.lua` are applied as "post-processing after hiragana is confirmed."

- Hiragana→katakana: Hiragana (`U+3041`–`U+3096`) and katakana (`U+30A1`–`U+30F6`), including small kana, correspond exactly via a `+0x60` offset without exception, so the conversion is a single codepoint arithmetic operation.
- Half-width ASCII→full-width ASCII: Half-width ASCII (`0x21`–`0x7E`) corresponds to the full-width forms (`U+FF01`–`U+FF5E`) via `+0xFEE0`. The half-width space (`0x20`) needs special handling to map to the full-width space (`U+3000`), since applying `+0xFEE0` would land on the unassigned `U+FF00`.

This approach lets `kana_table.lua` stay a single table, with no risk of double-maintenance or drift between two tables (indeed, when small kana such as `xa`/`xya` were added, the katakana side followed automatically).

**Why hand-rolled UTF-8 decoding/encoding:** The standard `utf8` library from Lua 5.3+ is not included in LuaJIT (Neovim's default Lua implementation). Even code that works in this development environment (`lua5.4`) could break on real Neovim (LuaJIT) if it relied on `utf8.codes` and similar, which don't exist there. So `kana_util.lua` implements its own minimal decoder/encoder that reads/writes codepoints directly from/to byte sequences.

## Usage

```lua
require("skk").setup({
  enter_key = "<C-j>", -- ascii/zenei -> hira. During henkan, equivalent to <CR> (confirm). Default "<C-j>"
  -- If you want different keys for the buffer and the command line (e.g. to avoid
  -- conflicts with other plugins), specify the following two instead of, or in
  -- addition to, enter_key:
  -- buffer_enter_key = "<C-j>", cmdline_enter_key = "<C-j>",

  -- The physical keys for l/q/L and starting abbrev ("/"). Specify these if you
  -- want to change them for coexistence with other plugins (e.g. skkeleton) or
  -- due to keyboard layout constraints. Defaults are as shown.
  -- char_key_to_ascii = "l",         -- hira/kata -> ascii
  -- char_key_to_kata_or_hira = "q",  -- hira <-> kata
  -- char_key_to_zenei = "L",         -- hira/kata -> zenei
  -- abbrev_key = "/",                -- start abbrev mode

  sticky_shift_enabled = true, -- Enable/disable sticky-shift. Default true
  sticky_shift_key = ";",      -- The sticky-shift trigger key. Default ";" (ignored if sticky_shift_enabled=false)

  egg_like_newline = true, -- true: <CR> during ▼ only confirms (no newline, skk.nvim's default)
                            -- false: confirms and also inserts a newline (traditional SKK behavior)

  candidate_window = {
    border = "rounded",   -- "rounded"/"single"/"double"/"none"/a custom character array. Default "rounded"
    annotation = true,    -- Whether to show dictionary annotations (;annotation) in the candidate list. Default true
    page_indicator = true, -- Whether to show "current page/total pages" (e.g. "2/3") at the bottom. Default true
    threshold = 2, -- How many times <SPC> must be pressed before the candidate window is shown. Default 2

    -- Colors (all default to the colorscheme's NormalFloat/FloatBorder, same as now, if omitted)
    -- fg = "#d8dee9", bg = "#2e3440",   -- unselected candidate rows
    -- border_fg = "#88c0d0",            -- border
    -- alt_fg = "#d8dee9", alt_bg = "#1b4252", -- alternating-row stripes (no stripes if omitted)
  },

  -- Colors for the inline ▽/▼ display (defaults to Comment/IncSearch, same as now, if omitted).
  -- candidate_fg/bg also drive the highlight of the selected row in the candidate window.
  -- midashi_fg = "#81a1c1", midashi_bg = nil,
  -- candidate_fg = "#ebcb8b", candidate_bg = "#4c566a",

  -- Colors for the indicator (hira/kata/latn/ＬＡ) briefly shown at the cursor on
  -- mode switches (defaults to NormalFloat, same as now, if omitted).
  -- indicator_fg = "#2e3440", indicator_bg = "#ff9e64",

  -- <C-n>/<C-p> focus movement while the candidate window is shown. A workaround
  -- for environments where blink.cmp etc. have already bound real <C-n>/<C-p>
  -- keymaps in insert mode (see "blink.cmp native source integration" below for
  -- details). Requires that setup() for blink.cmp etc. has already been called
  -- before this setup(). Enabled by default.
  -- candidate_navigation = { enabled = true, next_key = "<C-n>", prev_key = "<C-p>" },

  -- Additional candidate focus-movement key(s), for when <C-n>/<C-p> (the
  -- candidate_navigation above) don't work inside an external UI's prompt that
  -- holds its own buffer-local <C-n>/<C-p> real keymaps (e.g. Telescope). See
  -- "The `<C-n>`/`<C-p>` conflict with Telescope and other external UIs" below
  -- for details and background. Default nil (no extra key).
  -- Recommended: Ctrl+arrow keys etc., which arrive as a single CSI sequence
  -- (confirmed on real hardware). Alt-modified keys or Ctrl+punctuation are
  -- unsuitable for this purpose because terminal-dependent encoding quirks can
  -- split them into ESC plus a separate character. Keys with a built-in
  -- Vim/Neovim meaning, such as <C-j>/<C-k> (equivalent to <CR> / digraph
  -- input), should also be avoided, since pressing them outside the ▼ state
  -- falls through to that built-in behavior (see the same section for details).
  -- extra_candidate_next_key = "<C-Right>",
  -- extra_candidate_prev_key = "<C-Left>",

  user_dictionary = "~/.local/share/skk/SKK-JISYO.user", -- Path to the personal (learning) dictionary file. Default shown
})
```

For details on each option (defaults, caveats when combining them), see the docstring for `SkkSetupOpts` in `lua/skk/init.lua`, or `:help skk.nvim-options`.

The initial mode is `ascii` (SKK effectively OFF). Pressing `<C-j>` in insert mode enters hiragana mode. From there, switch modes using the transition table above (`l`/`q`/`L`) while typing. Use `:SkkMode` to check the current mode.

For integration with other plugins, `require("skk").enable()`/`disable()`/`toggle()`/`is_enabled()` are provided (roughly equivalent to skkeleton's `<Plug>(skkeleton-enable)` etc.), along with the corresponding `:SkkEnable`/`:SkkDisable`/`:SkkToggle` commands. `enable()` switches to hiragana mode; `disable()` switches to ascii mode (canceling an in-progress henkan first, if any).

For candidate list (▼) focus movement, `require("skk").focus_next_candidate()`/`focus_prev_candidate()` (no-op returning `false` when henkan isn't active) and the corresponding `:SkkFocusNextCandidate`/`:SkkFocusPrevCandidate` commands are also provided. Use these when an integration wants to trigger candidate advancement synchronously, only while henkan is active, from its own configuration (though for key-based integration, `extra_candidate_next_key`/`extra_candidate_prev_key` are often more suitable — see "The `<C-n>`/`<C-p>` conflict with Telescope and other external UIs" below for why).

`:checkhealth skk` diagnoses the Neovim version requirement, whether `setup()` has run, detection of blink.cmp (optional), local dictionary loading results, and skkserv connectivity.

To use a dictionary (`▽`/`▼` conversion), you need to load and register a dictionary separately from `setup()`. For large dictionary files like SKK-JISYO.L or .LL, `load_dictionary_async()` (asynchronous, lazy parsing) is recommended:

```lua
local dict = require("skk.dict")

dict.load_dictionary_async("/path/to/SKK-JISYO.L", "euc-jp", function(ok, err)
  if not ok then
    vim.notify("skk.nvim: failed to load dictionary: " .. tostring(err), vim.log.levels.WARN)
  end
end)
```

For small dictionaries, or when synchronous loading is fine, `file_source.load()` + `dict.set_dict()` also works:

```lua
local dict = require("skk.dict")
local file_source = require("skk.dict.file_source")

local parsed, err = file_source.load("/path/to/SKK-JISYO.L", "euc-jp") -- match the encoding to the dictionary file
if parsed then
  dict.set_dict(parsed)
end
```

To combine multiple dictionary files with a SKK server (equivalent to `skkeleton`'s `globalDictionaries`/`skk_server` setup):

```lua
require("skk").setup({
  skkserv = { host = "127.0.0.1", port = 1178, encoding = "euc-jp" },
  -- ...other options
})

local dict = require("skk.dict")
dict.load_dictionary_async("/usr/share/skk/SKK-JISYO.L", "euc-jp") -- main dictionary
dict.add_dictionary_async("/usr/local/share/skk/SKK-JISYO.edict2", "utf-8")
dict.add_dictionary_async("/usr/local/share/skk/SKK-JISYO.emoji", "utf-8")
```

The same setup can also be written entirely via the `dictionaries` option of `setup()` (it just delegates to calling `dict.add_dictionary_async()` in registration order, so priority, asynchronicity, and lazy parsing behave identically to the form above). This keeps the `setup()` call in one place, which is handy if you want to keep the body of `config = function() ... end` short:

```lua
require("skk").setup({
  skkserv = { host = "127.0.0.1", port = 1178, encoding = "euc-jp" },
  dictionaries = {
    { path = "/usr/share/skk/SKK-JISYO.L", encoding = "euc-jp" }, -- main dictionary
    { path = "/usr/local/share/skk/SKK-JISYO.edict2", encoding = "utf-8" },
    { path = "/usr/local/share/skk/SKK-JISYO.emoji", encoding = "utf-8" },
  },
  on_dictionary_loaded = function(path, ok, err) -- optional, called every time loading completes
    if not ok then
      vim.notify("skk.nvim: failed to load " .. path .. ": " .. tostring(err), vim.log.levels.WARN)
    end
  end,
  -- ...other options
})
```

`dictionaries` always uses `add_dictionary_async()` (asynchronous, lazy parsing, adding multiple dictionaries). If you want to use `load_dictionary_async()` for the first entry as the main dictionary (i.e. you want any first entry to be entirely replaced once a second one is added), keep calling `dict.load_dictionary_async()` directly as shown above.

`skk_test_init.lua` lets you try this configuration as-is via the environment variables `SKK_SKKSERV_HOST`/`SKK_JISYO_PATHS` (colon-separated)/`SKK_JISYO_PATHS_ENCODING` (see the comment at the top of the file).

When combining with blink.cmp, pass the `blink_source.lua`-side settings (`max_items`, `skip_skkserv`, `skkserv_candidates`, `skkserv_candidate_limit` — see "blink.cmp native source integration" below for details) via `require("skk").setup({ blink = {...} })`, then register it as a source in blink.cmp's own `sources.providers` (this registration itself is outside this plugin's scope — it's the user configuration's responsibility). Use the `SkkHenkanChanged` autocmd to toggle the menu display in step with `▽`/`▼` (see "blink.cmp native source integration" below for details):

```lua
require("skk").setup({
  blink = {
    max_items = 50,               -- Max number of readings fetched by prefix match. Default 50
    skip_skkserv = false,         -- Whether to include the SKK server in "4" (fetch reading list). Default false
    skkserv_candidates = true,    -- Whether to include the SKK server in "1" (fetch actual candidates). Default true
    skkserv_candidate_limit = 20, -- Max number of readings sent to the SKK server via "1". Default 20
  },
  -- ...other options
})

require("blink-cmp").setup({
  sources = {
    default = { "skk", "lsp", "path", "snippets", "buffer" },
    providers = {
      skk = {
        name = "skk",
        module = "skk.blink_source",
        enabled = function()
          -- Enable not just during "midashi" (▽, ordinary kana-kanji
          -- conversion) but also during "abbrev" (▽, an ASCII string
          -- itself used as the headword, started with "/"). See
          -- "further note 4" below for details.
          local phase = require("skk.henkan.state").get_phase()
          return phase == "midashi" or phase == "abbrev"
        end,
      },
    },
  },
})

-- show()/hide() blink.cmp's menu in step with the ▽/▼ display.
-- During ▼ (candidate selection), skk.nvim's own candidate window appears,
-- so hide() to avoid clashing with blink.cmp's menu.
--
-- IMPORTANT: always pass providers = { "skk" } to show().
-- blink.cmp's show() has a guard that does nothing "if the menu is already
-- open and providers isn't specified." skk.nvim's ▽/▼ are shown via extmarks
-- (virtual text), so the real buffer doesn't change, and blink.cmp's own
-- mechanism of "detect real-text changes and auto-refetch" never kicks in.
-- If you omit providers, the menu opens on the first show() call (right
-- after entering ▽, with an empty reading), but subsequent show() calls are
-- ignored as the reading grows, so the candidate list stops updating.
vim.api.nvim_create_autocmd("User", {
  pattern = "SkkHenkanChanged",
  callback = function(ev)
    local phase = ev.data and ev.data.phase
    if phase == "midashi" or phase == "abbrev" then
      vim.schedule(function()
        require("blink.cmp").show({ providers = { "skk" } })
      end)
    else
      require("blink.cmp").hide()
    end
  end,
})
```

## Known limitations

- Compatibility issues with plugins that auto-insert closing characters, such as nvim-autopairs (insertion-position intrusion, cursor-position drift, full-width/half-width mismatch for `z(`) have been resolved. See "Compatibility issue with nvim-autopairs" below for details. A separate compatibility issue — typing a symbol while the abbrev headword is empty or has zero candidates causes immediate confirmation — has also been resolved, by disabling the autopair plugin while henkan is active. See "Autopair compatibility issue in abbrev mode, and the recommended workaround" below for details.
- Merging multiple dictionaries and SKK server integration are implemented (`dict.add_dict()`/`dict.add_dictionary_async()`/`require("skk").setup({ skkserv = {...} })`). Verified working against a real yaskkserv2. Other skkserv implementations (`dbskkd-cdb`, etc.) are untested.
- Word registration is implemented (a UI via recursive calls to `vim.fn.input()`; see "Word-registration UI" below). It works from conversions started either in a buffer or on the command line, and has been verified on real hardware.
- Both ordinary buffers (insert mode) and command-line mode (`c`, including `/`, `?`, and `:`) support romaji→kana conversion, the 4 mode switches, the mode indicator, and dictionary conversion (`▽`/`▼`, candidate window) (`target.lua`, verified on real hardware). This coexists fine with actual search and substitution (`:%s`).
- **The built-in terminal (`t`) is intentionally not supported**, for two reasons:
  - (Technical cost) The built-in terminal is a PTY, not an ordinary Neovim buffer, so direct writes like `nvim_buf_set_text()` aren't available; confirmed text must instead be sent to the PTY as a byte stream via `chansend()`. Safely implementing the literal display of pending romaji fragments, or the `▽`/`▼` preedit display and its rewriting via `<BS>` etc., using only this one-directional byte-stream mechanism, is significantly harder to implement correctly. In fact, when trying [skkeleton](https://github.com/vim-skk/skkeleton) in the built-in terminal, a real-hardware issue was observed where it could be enabled with `<C-j>`, but confirmed characters did not persist in the terminal.
  - (Cost-benefit) There's inherently little occasion to type long Japanese text in the built-in terminal, and while shell completion works there, completion engines like `blink.cmp` do not — meaning the problem this plugin originally set out to solve (compatibility with `blink.cmp`; see "Why build this" below) has little relevance to the built-in terminal, so the value of supporting it was judged low.
- Cursor-movement keys like `<Left>`/`<Right>` and mouse clicks can be handled safely with respect to the pending romaji buffer when henkan is not active (since any key not matching `is_target_key` unconditionally resets the buffer, no byte-string corruption of already-confirmed kana can occur), but **display inconsistency** (a leftover, unconverted romaji fragment) can still occur. Behavior when these keys arrive while henkan (▽/▼) is active is untested. Note that `<Left>`/`<Right>` within the composite key sequences generated by nvim-autopairs and similar plugins (intercepted only while a batch is awaiting flush, to correct the cursor position — see "Compatibility issue with nvim-autopairs" below for details) are handled separately and are not subject to this limitation.
- Integration as a native blink.cmp source has been implemented and verified on real hardware up through Phase 2 (the design that shows actual conversion candidates — kanji — not just readings; see "blink.cmp native source integration" below). Both ordinary buffers and command-line mode have been verified working in the sandbox environment ([nvim-skk-sandbox](https://github.com/nabehan/nvim-skk-sandbox)), and the `show()` re-trigger bug and the key conflict with external UIs (`passthrough_guard`) have also been fixed. It has not yet actually been wired into the day-to-day real-hardware configuration, [nvim-config-blink-skkeleton](https://github.com/nabehan/nvim-config-blink-skkeleton). By design, prefix-match completion with okurigana is unsupported, and there's no live ghost-text preview before a candidate is chosen.
- `egg_like_newline = false` (traditional SKK behavior: confirm plus a newline) is implemented and verified working, but since it re-injects `<CR>` via `vim.api.nvim_feedkeys()`, unexpected interactions may occur in environments where other plugins also map `<CR>`.
- Automatic switching of the candidate window's display position (above/below) depends on an actual measurement via `vim.fn.screenpos()`, so it cannot be tested in a `nvim --headless` (no UI attached) environment (verified on real hardware only).
- Displaying the mode in the statusline (currently only a temporary indicator at the cursor) is not implemented.

## Verifying during development

A minimal init file (`skk_test_init.lua`) is included so you can try things out using just this repository, without touching your normal Neovim configuration.

```bash
nvim -u ./skk_test_init.lua
```

After starting, in insert mode try `<C-j>` then typing `ka`, `kka`, `kyou`, `xtu`, etc., and check that they convert. Also try mode switching: `q` (hiragana⇔katakana), `l` (→ ascii), `L` (→ zenei). Use `:SkkMode` to check the current mode.

`skk_debug_float.lua` is a throwaway debug script for isolating whether a floating window is actually reflected on screen while editing the command line (load it with `nvim -u skk_test_init.lua -c "source skk_debug_float.lua"`). It's not part of skk.nvim itself, but it's kept in the repository for now since it may be useful again when implementing/debugging command-line-oriented UI (such as the candidate window).

## Tests

Runs `tests/*_spec.lua` with [plenary.nvim](https://github.com/nvim-lua/plenary.nvim)'s busted-compatible runner. `make test` automatically fetches plenary.nvim into `.tests/site/pack/deps/start/` before running, so it works regardless of whether plenary.nvim is installed in your personal Neovim setup.

```bash
make test
```

If you want to run it manually, or if plenary.nvim is already elsewhere, you can specify it with the `PLENARY_DIR` environment variable.

```bash
PLENARY_DIR=~/.local/share/nvim/lazy/plenary.nvim \
  nvim --headless --noplugin -u tests/minimal_init.lua \
  -c "PlenaryBustedDirectory tests/ {minimal_init = 'tests/minimal_init.lua'}"
```

## Roadmap

1. ~~Romaji → kana conversion engine~~ ✅
2. ~~Key interception via `vim.on_key()`~~ ✅
3. ~~Switching among the 4 modes (ascii/hiragana/katakana/zenei)~~ ✅
4. ~~Replace the `▽`/`▼` pre-edit display with an extmark-based one~~ ✅
5. ~~Dictionary lookup (without okurigana / with okurigana / abbrev)~~ ✅
6. ~~Candidate window (listing multiple candidates, paging)~~ ✅
7. ~~Sticky-shift~~ ✅
8. ~~Personal dictionary / learning (recency-based reordering)~~ ✅
9. ~~Merging multiple dictionaries / skkserv integration~~ ✅
10. ~~Word registration (adding a reading with no matching candidates to the dictionary on the spot)~~ ✅ (a UI via recursive calls to `vim.fn.input()`; recursive word registration is also possible; verified on real hardware — see "Word-registration UI" below)
11. ~~Integration as a native blink.cmp source~~ ✅ (both the reading-only live completion design (v2) and the design that also shows actual candidates — kanji (Phase 2) — have been verified working on real hardware in the sandbox environment [nvim-skk-sandbox](https://github.com/nabehan/nvim-skk-sandbox). Wiring it into the day-to-day real-hardware configuration is the next step — see "blink.cmp native source integration" below and "Known limitations" above for details)
12. ~~Surrounding UI (mode indicator)~~ ✅ (only a temporary display at the cursor position; a statusline display is not yet started)
13. ~~Command-line mode support~~ ✅ (`target.lua`. Romaji→kana conversion, the 4 mode switches, the mode indicator, and dictionary conversion (`▽`/`▼`, candidate window) have all been verified on real hardware. The built-in terminal was decided against — see "Known limitations" above)
14. Parallel parsing via a thread pool using `vim.uv.new_work()` (to further reduce startup load for large dictionaries)

## Projects referenced

- [vim-skk/skkeleton](https://github.com/vim-skk/skkeleton) — Its word-registration UI (recursive calls to `vim.fn.input()`, detecting `<Esc>`/`<C-g>` via a sentinel string) was consulted by reading `registerWord()` (`denops/skkeleton/function/dictionary.ts`) before implementation.
- [uga-rosa/skk-learning.nvim](https://github.com/uga-rosa/skk-learning.nvim) — An introduction to implementing SKK in Lua.
- [yuys13/skk-develop.nvim](https://github.com/yuys13/skk-develop.nvim) — A SKK dictionary downloader.
- [wachikun/yaskkserv2](https://github.com/wachikun/yaskkserv2) — The SKK server used to verify skkserv integration on real hardware.
- [Saghen/blink.cmp](https://github.com/Saghen/blink.cmp) — Its native-source API (`get_completions`/`execute`/`resolve`, the need to call `default_implementation` yourself, etc.) was consulted by reading the source before implementing `blink_source.lua`.
- [nabehan/nvim-config-blink-skkeleton](https://github.com/nabehan/nvim-config-blink-skkeleton) — A full real-hardware configuration running skkeleton + blink.cmp. Its `skkeleton_source.lua` (textEdit range computation, the lesson of forgetting to call `default_implementation`) and `blink.lua` (show()/hide() in step with `▽`/`▼`, suppression during `▼`, keymap setup) were referenced when designing `blink_source.lua`. The fact that this real-hardware setup assigns `<CR>`, not the default `<C-y>`, to accept was the deciding factor in reconsidering the design of `passthrough_guard` (basing it on `is_visible()` rather than a fixed key).
- [nabehan/nvim-skk-sandbox](https://github.com/nabehan/nvim-skk-sandbox) — An `NVIM_APPNAME`-based sandbox environment for verifying blink.cmp integration in isolation from the day-to-day real-hardware configuration.

---

Everything below is a record of internal implementation and design decisions, intended for developers.

## Design goals

- Neovim only. No Vim (vanilla) compatibility layer, no Vimscript.
- Pure Lua, no external process (no denops/Deno dependency).
- Key interception via `vim.on_key()` (does not take the approach of issuing a large number of `<expr>` mappings in insert mode).
- Target: Neovim 0.10+ (assumes key consumption via an empty-string return from `vim.on_key()`, `vim.schedule`, extmarks, etc.)

## Why build this

The existing [vim-skk/skkeleton](https://github.com/vim-skk/skkeleton) runs on denops (Deno/TypeScript), and the Vimscript side (`autoload/skkeleton.vim`) hard-codes detection of "which completion engine is running" (only three: `pum.vim` / `nvim-cmp` / native completion). When trying to combine it with [blink.cmp](https://github.com/Saghen/blink.cmp), it doesn't match any of these, so, for example, the `<CR>`-confirmation logic driven by `eggLikeNewline` doesn't fire — and fundamental compatibility issues like this kept recurring.

These stem from skkeleton's architecture (a denops + Vimscript hybrid, with a fixed set of recognized completion engines), and this project was started on the judgment that **a Neovim-only, pure-Lua implementation would not have this problem in principle**.

## Architecture

```
lua/skk/
├── init.lua              -- Entry point. setup() registers the capture layer, keymaps, and options
├── capture.lua            -- Intercepts key input via vim.on_key(), and dispatches to mode/henkan handling
├── target.lua              -- A layer that abstracts away the difference in write destination (insert-mode buffer / command line)
├── mode.lua                -- The state-transition logic for the 4 modes (vim.*-independent, unit-testable)
├── mode_indicator.lua      -- Briefly shows a glyph (hira/kata/latn/ＬＡ) at the cursor on mode switches
├── context.lua            -- An object holding input state (confirmed output / pending buffer / current mode)
├── input.lua              -- The core state machine for romaji → kana conversion
├── kana_table.lua          -- The romaji → hiragana conversion table (mechanically generated from consonant × vowel)
├── kana_util.lua           -- Mutual conversion among hiragana ⇔ katakana ⇔ full-width ASCII
├── encoding.lua            -- Character-encoding conversion for dictionary files (a wrapper around vim.fn.iconv())
├── blink_source.lua        -- Native source for blink.cmp (live prefix-match completion while in the ▽ state)
├── henkan/                -- The state machine and appearance for ▽/▼ (kanji conversion)
│   ├── state.lua            -- The core state machine (idle/midashi/select/abbrev). Called from capture.lua
│   ├── session.lua          -- The reading, candidates, and page state held by a single conversion session
│   ├── preedit.lua          -- Displays the ▽/▼ appearance as extmark virtual text
│   └── candidate_window.lua -- Displays the list of multiple candidates in a floating window
└── dict/                  -- Dictionaries
    ├── init.lua              -- The lookup interface
    ├── jisyo_parser.lua      -- A parser for the SKK dictionary format (SKK-JISYO)
    └── file_source.lua       -- Loading dictionary files (including character-encoding conversion)
```

### Conversion engine (`context.lua` + `input.lua` + `kana_table.lua`)

For each key press, `input.kanaInput(context, char)` is called. Priority order of judgment:

1. Does it exactly match an entry in the conversion table? → Confirm and finish.
2. Is it `"nn"`? → Confirm "ん" and finish.
3. Is it still a prefix of some conversion-table entry? → Wait for more input (do nothing).
4. Is it a consonant repeated twice (sokuon)? → Confirm "っ" and start over from the second character.
5. Is it `"n"` followed by a character that's neither a vowel, `y`, nor `n`? → Confirm "ん" and start over from that character.
6. None of the above → Discard the first character and start over (recovery from mistyping).

A trailing lone `n` (e.g. at the end of `"nihon"`) is inherently ambiguous between continuing into a "na"-row syllable and being confirmed as "ん", so it's kept pending until the next input arrives. This is common to SKK in general and is not a bug.

Sokuon ("っ") can be produced not only by a repeated consonant (`kka` → `っか`) but also explicitly, since `kana_table.lua` defines `M["xtu"] = "っ"`, so typing `xtu` alone also produces "っ" (a conventional input method found in many Japanese IMEs).

Full-width symbols can be entered with `z` + symbol (also a convention in many Japanese IMEs): `z(` → `（`, `z)` → `）`, `z` + space → `　` (a full-width space). When adding these to `EXTRA_TARGET_CHARS` in `capture.lua`, identity mappings (e.g. `M["("] = "("`) were also added to `kana_table.lua` so that `(`, `)`, and space alone pass through unchanged as half-width (otherwise, as a standalone symbol matching neither a table entry nor a prefix, it would be mistakenly discarded).

See `tests/input_spec.lua` (using [plenary.nvim](https://github.com/nvim-lua/plenary.nvim)'s busted-compatible runner) for tests.

### The capture layer (`capture.lua`)

It's confirmed, per the official Neovim documentation (`:help vim.on_key()`), that `vim.on_key()` allows a key to be discarded if the callback returns an empty string `""`:

> If {fn} returns an empty string, {key} is discarded/ignored

This is used to discard the original key every time a half-width letter (`a-z`) arrives in insert mode, and rewrite the buffer with the result after running it through the conversion engine.

A pending romaji fragment (e.g. right after typing just `"k"`, not yet an exact match for any conversion-table entry) is displayed as-is, as an ordinary character, in the real buffer; the moment conversion is confirmed, that many characters are deleted and replaced with kana. This approach is simple to implement and has the advantage that nothing is left un-displayed, but it differs from traditional SKK's appearance. **This is distinct from `▽`/`▼` (henkan, see below)** — the henkan side has already been replaced with extmark virtual-text display via `henkan/preedit.lua`.

The actual buffer rewrite (`nvim_buf_set_text`) is not done directly inside the `vim.on_key()` callback, but is delayed by one tick via `vim.schedule()`. This is a preventive measure, taken out of consideration that a similar constraint might apply here as well, based on the lesson learned from repeatedly hitting an `E565: Not allowed to change text or change window` textlock error during [the blink.cmp integration work](https://github.com/nabehan/nvim-config-blink-skkeleton).

### The `<C-n>`/`<C-p>` conflict with Telescope and other external UIs, and `extra_candidate_next_key`/`extra_candidate_prev_key` (discovered on real hardware — important)

Candidate list (▼) focus movement (default `<C-n>`/`<C-p>`) is implemented via the `candidate_navigation` option, not through `vim.on_key()` but through an actual `vim.keymap.set()` (a **global** insert-mode keymap). This was originally for coexistence with plugins such as blink.cmp that bind real `<C-n>`/`<C-p>` keymaps in insert mode (it reads and saves whatever mapping was already set at `setup()` time, and delegates to it outside the ▼ state; the core decision logic lives in `lua/skk/candidate_nav.lua`).

**The problem (discovered on real hardware)**: [Telescope](https://github.com/nvim-telescope/telescope.nvim)'s prompt (`buftype="prompt"`) has its own **buffer-local** real keymaps on `<C-n>`/`<C-p>` (`move_selection_next`/`move_selection_previous`, for moving the selection in the results list). Since buffer-local mappings in Neovim always take priority over global ones, `candidate_navigation`'s global keymap effectively never fires inside Telescope's prompt, and pressing `<C-n>`/`<C-p>` while in the ▼ state doesn't move the candidate (discovered through real-hardware verification in [nvim-config-blink-skknvim](https://github.com/nabehan/nvim-config-blink-skknvim)).

**The first fix attempted, which didn't work (a solution purely at the integration layer)**: Without touching skk.nvim itself, a `FileType` autocommand on the Telescope side overrode `<C-n>`/`<C-p>` buffer-locally on the target buffer, calling `M.focus_next_candidate()`/`M.focus_prev_candidate()` (described below; these are no-ops returning `false` when henkan isn't active) when henkan was active, and otherwise falling back to Telescope's own `move_selection_next`/`move_selection_previous` — the same "override in the integration buffer" pattern used for `<C-j>` (see below). This had no effect on real hardware (nothing visibly changed; the candidate was confirmed immediately and Telescope's own selection movement started).

The cause lies in the ▼-state key handling in `capture.lua`. Unlike the `▽`-state key handling, for any key other than `CTRL_N`/`CTRL_P`/`space`/`x`/home-row selection, there is a catch-all branch that **unconditionally**, without the `defer_to_external_ui` guard, confirms the current candidate on the spot. Since `vim.on_key()` fires **before** real keymaps are resolved, this catch-all branch finishes confirming before the Telescope-side override keymap ever runs, so it cannot in principle be solved at the integration layer (the Telescope-side configuration) alone. As a test, assigning an unused key such as `<M-n>`/`<M-p>` instead of `<C-n>`/`<C-p>`, via the same integration-layer approach, also failed to work for the same reason.

**The final solution**: `extra_candidate_next_key`/`extra_candidate_prev_key` options were added, recognized within `capture.lua`'s own ▼-state key handling as additional keys on par with `CTRL_N`/`CTRL_P` (see "Usage" above). Since `vim.on_key()` itself processes these keys first, neither a race with an external UI's real keymap, nor an unintended fall-through into the catch-all branch, can occur in principle.

**How to choose the key for `extra_candidate_next_key`/`extra_candidate_prev_key` (discovered on real hardware — important)**:

- `<C-Up>`/`<C-Down>` was verified first on real hardware, but since it's far from the home row, `<M-n>`/`<M-p>` (Alt+n/p, directly below the home row and not claimed by Telescope) was tried instead, and it **did not work on real hardware** (e.g., pressing `<M-n>` while "人" was selected confirmed "人" as-is instead of moving the candidate, and the following `n` was then processed as new romaji input, resulting in something like "人n"). The cause lies in how Alt-modified keys are encoded. Many terminals express Alt+character as a 2-byte sequence — sending ESC, then the character (an ESC-prefix scheme) — and while Neovim interprets these as a single `<M-x>` if both bytes arrive together within the short `ttimeoutlen` window, depending on timing and the terminal's implementation, ESC and the character can arrive at `vim.on_key()` as **separate key inputs**. A standalone ESC falls into the ▼-state catch-all branch described above and is immediately confirmed, and the following character is then processed as new input after confirmation.
- `<C-.>`/`<C-,>` (Ctrl+period/comma, close to the home row) was also tried, but results varied by terminal (real-hardware reports: worked on Alacritty, did not work on Konsole). Encoding of Ctrl+printable-character combinations depends heavily on the terminal, e.g. whether it supports the Kitty keyboard protocol.
- Arrow-key-based keys (`<C-Up>`/`<C-Down>`/`<C-Left>`/`<C-Right>`) are sent as CSI escape sequences — a single "chunk" with predetermined length and content — so this kind of splitting cannot happen in principle. This is also why they worked reliably from the start.
- **Take care when choosing ASCII control codes with a built-in Vim/Neovim meaning, such as `<C-j>`/`<C-k>` (discovered on real hardware — important)**: These keys themselves carry no risk of encoding-level splitting, since they're single raw control bytes. However, in a configuration where `enter_key` (default `<C-j>`) has been changed to another key (e.g. `<C-\>`) and `<C-j>` is repurposed as `extra_candidate_next_key`, `<C-j>` is **no longer claimed by any real keymap** on the skk.nvim side. Since `extra_candidate_next_key`/`extra_candidate_prev_key` are processed via `vim.on_key()` and are only recognized during the ▼ state of henkan (`phase=="select"`), pressing `<C-j>`/`<C-k>` in any other situation (henkan inactive, or the ▽ state) falls straight through to Neovim's built-in default behavior. `<C-j>` is treated in insert mode as equivalent to `<CR>` (a newline), and `<C-k>` is a built-in key that triggers digraph input (e.g. `<C-k>a:` → `ä`) (both verified on real hardware and headless). Pressing them unintentionally can lead to an unwarned newline insertion, or the next keystroke being swallowed by a pending digraph. Back when `enter_key = "<C-j>"`, this built-in behavior was always masked by the real keymap, so it never became an issue — but `extra_candidate_next_key`/`extra_candidate_prev_key` is only `vim.on_key()` processing limited to the ▼ state, and cannot "claim the key at all times" in the same way. When choosing a key of this kind, check in advance whether Neovim has a default behavior for it outside the `▼` state.
- **The same "terminal-dependent encoding variance" problem also occurs with `enter_key` (a setting other than `extra_candidate_next_key`/`prev_key`) (discovered on real hardware)**: Trying a configuration that changes `enter_key` from `<C-j>` to `<C-;>` found that `<C-;>` did not work on Konsole (it worked on other terminals). This is thought to be the same underlying cause as the `<C-.>`/`<C-,>` case above — encoding of Ctrl+printable characters (symbols) is terminal-dependent. **The key-selection caveats described in this section apply not only to `extra_candidate_next_key`/`extra_candidate_prev_key`, but to every key-configuration option in skk.nvim, including `enter_key`/`buffer_enter_key`/`cmdline_enter_key`.** In addition, there are cases where the system side (the desktop environment or an input-method framework) intercepts a key as a global shortcut (for example, KDE Plasma's or fcitx5's Clipboard addon by default binds `<C-;>` to invoke clipboard history, consuming the key before it reaches Neovim). If a particular key doesn't work, check not only the terminal's encoding but also the OS's, the desktop environment's, and the input method's shortcut settings.

In [nvim-config-blink-skknvim](https://github.com/nabehan/nvim-config-blink-skknvim), the final settled configuration is `enter_key = "<C-j>"` (left at the default), with `extra_candidate_next_key = "<C-Left>"`/`extra_candidate_prev_key = "<C-Right>"` (`<C-n>`/`<C-p>` themselves, part of the user's own muscle memory, were left unchanged). On the Telescope side, `config.lua` ended up reverted to only overriding `enter_key` (`<C-j>`), with the `<C-n>`/`<C-p>` override removed.

Note that this investigation also revealed a limitation of headless `nvim --server --remote-send`: for Ctrl/Alt-modified keys (`<C-n>`/`<M-n>`, etc.), the byte sequence actually observed by `vim.on_key()` can differ from both the output of `vim.api.nvim_replace_termcodes()` and from what an actual terminal sends. This was pinpointed by reproducing the same symptom in the existing, entirely unmodified `candidate_navigation` feature under headless testing alone. Verification involving modified keys must be confirmed on real hardware and not taken on faith from headless results.

### Compatibility issue with nvim-autopairs (discovered on real hardware — important)

When used together with plugins like [nvim-autopairs](https://github.com/windwp/nvim-autopairs) that auto-insert a matching closing character for an opening bracket or quote, there was a bug where a new character would intrude into the middle of an already-confirmed string, for `(`/`[` in hiragana/katakana mode (keys handled via `EXTRA_TARGET_CHARS`) and for any symbol in zenei mode (e.g. typing `(` right after `いろは` resulted in `いろ()_は`, intruding just before `は`).

**Investigation method**: `nvim_feedkeys(keys, "x", false)` never runs `vim.schedule()` until Neovim's entire typeahead processing finishes, so it can't be used to reproduce this kind of bug that depends on async timing (nothing reproduced as intended, no matter what was tried). Eventually, switching to starting a server with `nvim --headless --listen <socket>` and sending real keystrokes from a separate process as a single RPC call via `nvim --server <socket> --remote-send '<keys>'` reproduced the exact same symptom seen on real hardware, reliably. Since `--remote-send` interrupts Neovim's event loop in a way close to genuine key input, it's more reliable than `feedkeys` for verifying bugs involving delayed `vim.schedule()` execution or timing dependencies.

**The root cause was a combination of two things**:

1. nvim-autopairs returns a composite key sequence like `<C-g>u()<C-g>U<Left><C-g>u` (a standard Vim undo-boundary idiom) when an opening character is typed. If both the opening and closing characters are conversion targets for `process_romaji()`, this function ends up called multiple times in a row within the same tick. The old implementation independently created an extmark and independently scheduled a write via `vim.schedule()` each time a key arrived, so the second call would erase and replace the first call's extmark — and because Lua closures capture variables by reference, the first write closure (which runs earlier) would end up mistakenly using and consuming what was actually the second call's extmark, causing a conflict.
2. The `<Left>` in the composite key sequence (meant to move the cursor back between the opening and closing characters) passes through untouched in `capture.lua` and is handled natively by Neovim, but the corresponding write hasn't run yet (it's delayed by one tick via `vim.schedule`), so the cursor ends up moving against a stale buffer state where nothing has been written yet. At the time, `M.replace_before_cursor()` in `target.lua` had a guard that treated it as inconsistent and fell back if the extmark's position was behind the current cursor — as a result, the extmark, which should have pointed to the correct position, was distrusted, and it fell back to the cursor position that had drifted after `<Left>` moved it.

**The fix (a root-cause fix)**:

- A new mechanism, `hira_kata_batch`/`zenei_batch`, was added to `capture.lua`, treating "a group of key inputs accumulated within the same tick, not yet flushed even once" as a single batch (zenei mode, which originally had no extmark tracking at all and was the most fragile, got the same treatment). Only the first key of a batch creates the extmark and schedules the `vim.schedule()`; subsequent keys simply accumulate. This ensures that no matter how many times `process_romaji()` is called within the same tick, the actual write happens exactly once, eliminating any possibility of extmarks conflicting with each other. Under ordinary typing (with a gap between each key), the previous batch's flush has already run before the next key arrives, so in effect the batch size is always 1, and behavior is identical to before.
- `M.replace_before_cursor()` in `target.lua` was redesigned to compute the end of the deletion range not from "the current cursor" but from "`start_pos` (the extmark) advanced by `byte_len` bytes," and the fallback based on comparing against the current cursor position was removed. This makes both the start and end fully independent of the real cursor, so they are no longer affected at all by cursor movement in between, such as `<Left>`.
- A mechanism was added to intercept `<Left>`/`<Right>` only while a batch is awaiting flush, accumulating them as an offset (in characters, respecting multi-byte character boundaries via `vim.fn.strcharpart()`) and applying it to the cursor after the flush. This reproduces the autopair's `<Left>`'s originally intended movement — "move the cursor back between the opening and closing character" — even while the write itself remains delayed by one tick by design.
- Two secondary bugs found during the same investigation were also fixed. One: if an opening character subject to autopair immediately followed SKK's temporary full-width-symbol input (`z(` → `（`, etc.), the `<C-g>` at the start of the autopair's composite key sequence mistakenly triggered a "reset the pending buffer on an unknown key," erasing the state where `z`'s input was awaiting confirmation (`z(` became `z()`). `<C-g>` itself was fixed to also stop processing on the spot. The other: the `)` that autopair automatically adds for the `z(` conversion (`（`) was processed as an independent key unaffected by `z`, so it stayed half-width (`（)`) — this asymmetry was resolved by adding a one-shot flag indicating that a `z(` conversion just occurred on the previous key, and reinterpreting the following `)` alone as the full-width `）`.

**Verification method**: In addition to the RPC-based reproduction above, existing regression tests (`tests/*_spec.lua`, via `test.sh`) — covering sokuon, `<Del>`/`<F11>` misfire prevention, ordinary typing, and so on — were confirmed not broken at every step along the way.

**Known limitation**: In extreme cases — such as a macro sending romaji input together with `<Left>`/`<Del>` completely within the same tick (a gap that could never occur in actual human typing) — it's been confirmed that this can still act against a stale buffer state. This doesn't affect realistic key intervals (including actual autopair use), though, and is accepted as a limitation inherent to the "delay writes by one tick" architecture itself.

### Autopair compatibility issue in abbrev mode, and the recommended workaround (discovered on real hardware — important)

After the "Compatibility issue with nvim-autopairs" above was resolved, a new symptom was reported after the v0.1.1 release: in abbrev mode (where the headword itself is an ASCII string, started with `/`), typing `"` `'` `` ` `` `(` `[` `{` while the headword is empty, or while there are zero dictionary candidates, would cause live completion (blink.cmp, etc.) to fail to start, and pair characters like `()` would be confirmed immediately as plain text (particularly noticeable in a case like typing `(` right after `/` — `<C-j>/(`).

**Cause**: In the composite key sequence `<C-g>u()<C-g>U<Left><C-g>u` generated by nvim-autopairs and similar plugins, the `<Left>` right after `<C-g>U` (part of the join_left idiom that moves the cursor back between the opening and closing character), while blink.cmp's popup had never yet been shown (`is_visible()==false`), reached `capture.lua`'s fallback of "when a non-printable-ASCII key arrives, confirm the headword so far if no external UI is visible," mistakenly confirming `()` immediately, closing bracket included.

**An approach that was tried but couldn't be confirmed effective on real hardware**: A patch on the `capture.lua` side (`pending_autopair_cursor_move`) was implemented that, only once right after consuming the `<C-g>U` marker, also neutralized the following `<Left>`/`<Right>`. This resolved the symptom in headless Neovim (the same v0.12.4 binary as real hardware, reproducing keystrokes via RPC with `nvim --headless --listen` + `--remote-send`), but **on real hardware, even after confirming the exact same key sequence, that the patch was in effect, and after a full restart of Neovim, the symptom did not go away**. The cause could not be identified (interference among multiple simultaneously registered `vim.on_key()` listeners was suspected and investigated, but no reproducible evidence was found, so it was ruled out). It became clear that this whole approach — interpreting an autopair plugin's composite key sequence after the fact on the `capture.lua` side — was inherently poorly reproducible and hard to verify, since headless and real hardware could disagree; this patch was therefore reverted (skk.nvim itself has no changes from this attempt).

**The final solution adopted**: Rather than trying to interpret the autopair plugin's composite key sequence on the `capture.lua` side, the approach was changed to **disable the autopair plugin entirely while henkan (▽/▼/abbrev) is active, and re-enable it once back to `idle`**. skk.nvim already fires a `User autocmd "SkkHenkanChanged"` with `data.phase` on every `▽`/`▼`/abbrev state change (see "blink.cmp native source integration" below for details), so this can be reused directly. No change to skk.nvim itself is needed — **it's entirely self-contained in the user's own configuration**:

```lua
vim.api.nvim_create_autocmd("User", {
  pattern = "SkkHenkanChanged",
  callback = function(ev)
    local phase = ev.data and ev.data.phase
    local ok, autopairs = pcall(require, "nvim-autopairs")
    if ok then
      if phase == "idle" then
        autopairs.enable()
      else
        autopairs.disable()
      end
    end
    -- ...(coexists with existing phase-based logic, such as blink.cmp's show()/hide())
  end,
})
```

While henkan is active, not just abbrev but also `▽` (midashi) and `▼` (select) are covered, since the `▽` (midashi) phase shares the same `defer_to_external_ui` logic as abbrev, and so could in theory suffer the same kind of bug (though only abbrev was actually reported affected in practice).

Verified, pushed, and confirmed on real hardware ([nvim-config-blink-skknvim](https://github.com/nabehan/nvim-config-blink-skknvim)): the expected behavior for `"` `'` `` ` `` `(` `[` `{` in abbrev mode (the preedit continues, with only the single symbol entering the headword) coexists with autopair's closing-symbol completion during ordinary (direct-input-mode) typing outside `▽`/`▼`. The command line and search mode are unaffected by this issue in the first place (since autopair plugins generally don't operate on the command line anyway), and continue to work as before.

As a side effect, this approach also resolves a separate problem where the headword (reading) would end up including not just the opening character but also the auto-inserted closing character (e.g. typing `(` would make the headword `"()"` instead of `"("`, preventing it from being looked up as a single symbol). Since autopair itself doesn't run while henkan is active, the closing character is never auto-inserted in the first place.

#### Survey of enable/disable APIs in other autopair plugins

The approach above simply calls `require("nvim-autopairs").enable()`/`.disable()`, an existing global toggle API that nvim-autopairs provides — skk.nvim's side has no dependency on any specific plugin. On the assumption that the same approach should work with other autopair plugins as long as they offer an equivalent enable/disable-style API, three representative ones were surveyed (implementation and real-hardware verification have not been done yet — this is a desk check based on reading the source only).

| Plugin                                                                      | API                                                                                         | Notes                                                                                                                                                                                                                                                                                                                                                                                                                               |
| --------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| [nvim-autopairs](https://github.com/windwp/nvim-autopairs)                  | `require("nvim-autopairs").enable()` / `.disable()` / `.toggle()`                           | Adopted, verified on real hardware. A simple implementation that directly toggles a global state flag (`M.state.disabled`).                                                                                                                                                                                                                                                                                                         |
| [mini.pairs](https://github.com/nvim-mini/mini.pairs)                       | `vim.g.minipairs_disable = true/false` (global) or `vim.b.minipairs_disable` (buffer-local) | Controlled via variable assignment rather than function calls. Writing `vim.g.minipairs_disable = (phase ~= "idle")` inside the `SkkHenkanChanged` handler should achieve the same effect.                                                                                                                                                                                                                                          |
| [autoclose.nvim](https://github.com/m4xshen/autoclose.nvim)                 | Only `require("autoclose").toggle()`                                                        | No dedicated `enable()`/`disable()`; only `toggle()`, which flips the current state, is exposed. Since the internal state flag (`config.disabled`) isn't exposed outside the module, reliably reaching the intended state requires tracking "which state we last set it to" in a separate variable on this side, and calling `toggle()` only when needed (there's still a risk of drift if the user also manually uses `toggle()`). |
| [ultimate-autopair.nvim](https://github.com/altermo/ultimate-autopair.nvim) | `require("ultimate-autopair").enable()` / `.disable()` / `.toggle()` / `.isenabled()`       | Like nvim-autopairs, has a symmetric enable/disable API. `isenabled()` can also fetch the current state.                                                                                                                                                                                                                                                                                                                            |

Real-hardware verification hasn't been done yet for the three plugins other than nvim-autopairs. In particular, note that autoclose.nvim only exposes `toggle()`, so the exact same approach used for the other three (unconditionally calling `enable()`/`disable()`) won't work correctly there.

### Command-line mode support (`target.lua`)

Insert-mode buffer operations are the pair `nvim_buf_set_text()` + `nvim_win_get_cursor()`, but the command line (`:`/`/`) isn't a buffer, so these APIs aren't available. `target.lua` is a layer that absorbs this difference — `capture.lua` doesn't need to be aware of the mode; it only needs to call `target.replace_before_cursor(byte_len, text)`.

- **Buffer implementation**: `nvim_buf_set_text()`, as before.
- **Command-line implementation**: `vim.fn.getcmdline()`/`setcmdline()`/`getcmdpos()` (all added in Neovim 0.10+, consistent with the "Target: Neovim 0.10+" premise mentioned earlier). The purely `vim.*`-independent text-operation part — "delete the N bytes before the cursor and replace them" (`target._compute_cmdline_replace()`) — is factored out in a form that's unit-testable.

**Separation of modes**: Sharing `context.mode` (the current input mode) between the buffer and the command line causes two problems (discovered through real-hardware testing) — "entering the command line keeps the mode from the buffer just before it" and "the mode last used on the command line leaks into the buffer side." `capture.lua` saves and restores the mode via `CmdlineEnter`/`CmdlineLeave` autocommands, so the command line is treated as an independent piece of state that always starts from `cmdline_start_mode` (default `ascii`) and, on exit, returns to whatever mode the buffer was in just before.

**Floating windows during command-line editing need `redraw`**: It was confirmed on real hardware that a floating window newly created or repositioned while editing the command line (before pressing Enter) doesn't get picked up by Neovim's normal screen-redraw cycle, and isn't actually drawn until the command line is next exited (this isn't an issue in insert mode, since a normal redraw runs on every keystroke). `mode_indicator.lua` handles this during command-line mode by explicitly calling `vim.cmd("redraw")` every time the window is shown/hidden. This knowledge will also apply as-is to future command-line support for the candidate window.

**Command-line support for henkan (`▽`/`▼`, dictionary conversion)**: `henkan/preedit.lua` doesn't use extmarks on the command line; instead it displays `▽`/`▼` by writing directly into the command-line string itself (the same approach as ddskk/skkeleton — tracking the length of the currently displayed marker text relative to the anchor point's `getcmdpos()`, deleting and reinserting it on every update). The candidate window (`henkan/candidate_window.lua`'s `M.show_cmdline()`) is fixed in place just above the command-line row using `relative="editor"`, and applies the `redraw` forcing described above as well. It's been confirmed on real hardware that this works fine even when the converted string is actually used as part of a search (`/`, `?`) or substitution (`:%s`). As noted, the built-in terminal is not supported (see "Known limitations" above).

### Conversion (`▽`/`▼`, henkan) (`henkan/`, `dict/`)

When an uppercase key arrives while the pending buffer is empty, the state machine in `henkan/state.lua` begins (`idle` → `midashi` (▽) → `select` (▼)). During a conversion session, nothing is written to the real buffer at all — `henkan/preedit.lua` continuously displays `▽reading`/`▼candidate` as inline extmark virtual text, and only inserts into the real buffer at the moment of confirmation (a design where canceling the reading with `<BS>` has zero effect on the real buffer, and is therefore safe).

**There are 3 kinds of start triggers:**

| Trigger                    | Example       | Behavior                                                                                                                                                                                                                                                                                                                       |
| -------------------------- | ------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Uppercase key              | `Kanji<SPC>`  | The standard traditional-SKK operation of using Shift+letter to signal both starting ▽ and its first character at the same time.                                                                                                                                                                                               |
| Sticky-shift (default `;`) | `;kanji<SPC>` | Avoids the Shift operation, using `;` only to signal starting ▽ / where okurigana begins (see [ddskk's explanation](https://ddskk.readthedocs.io/ja/latest/06_apps.html)). `;` itself carries no character; it's a marker only. Can be enabled/disabled or have its key changed via `sticky_shift_enabled`/`sticky_shift_key`. |
| `/` (abbrev)               | `/Bug<SPC>`   | Skips romaji→kana conversion, using the ASCII string itself as the headword (`henkan/session.lua`'s `input_abbrev`). For dictionary entries where you want an English word itself as the headword.                                                                                                                             |

**Okurigana conversion**: when another uppercase key (or the sticky-shift key) arrives a second time while in ▽, `start_okuri()` in `state.lua` marks where the okurigana starts, and subsequent romaji input switches to the okurigana side. The moment a consonant+vowel is confirmed, dictionary lookup (the transition to ▼) happens automatically (no space needed).

**The candidate window** (`henkan/candidate_window.lua`) opens as a floating window on the transition to `▼` (the timing of its appearance can also be delayed via `candidate_window.threshold`, see below). It shows up to 7 candidates per page, assigned from top to bottom to the home-row keys `a s d f j k l`; pressing one immediately selects and confirms the candidate at that position. `<SPC>` advances to the next 7 candidates (next page), `x` goes back 7 (previous page). `<C-n>`/`<C-p>` moves the focus one candidate at a time (wrapping to the next/previous page at page boundaries), with the focused candidate shown via row highlighting (`SkkHenkanCandidate`). `<CR>`/`<C-j>` confirms the currently focused candidate. A dictionary annotation (`candidate;annotation`), if present, is shown according to `candidate_window.annotation` (default on). The bottom row shows `"current page/total pages"` (e.g. `"2/3"`) according to `candidate_window.page_indicator` (default on).

**The timing of the candidate window's appearance** can be tuned via `candidate_window.threshold` (default 2). Given that the personal dictionary's learning makes the top candidate more likely to be the right one, until the number of `<SPC>` presses reaches this value, candidates are advanced one at a time using only the inline `▼candidate` display, without showing the window itself (setting it to 1 restores the traditional behavior of showing the window immediately on the first `<SPC>`). **Only while the window is actually shown** are the home-row keys (`a s d f j k l`) treated as candidate selection. Before it's shown (during the inline-preview-only stage), treating them as candidate selection would mean choosing from options the user can't see, risking accidental confirmation — so during that stage these keys behave like any other character: "confirm the candidate currently shown inline, then continue with that key as new input" (determined by `is_candidate_window_visible()` in `henkan/state.lua`).

The display position defaults to directly below the preedit line, but if the number of remaining rows to the bottom of the screen is less than the candidate window's height (including its border), it's shown above instead (measured via `vim.fn.screenpos()`). Once either side is chosen, it stays on that side for the rest of the session (sticky), even as `<SPC>`/`x` page through and change the candidate count — this reduces eye movement, and the position is recalculated fresh for the next session once confirmed or canceled.

**The dictionary** (`dict/`) is parsed from the SKK-JISYO format (`;; okuri-ari entries.` / `;; okuri-nasi entries.` sections, `reading /candidate1/candidate2;annotation/` format) by `jisyo_parser.lua`. There are two ways to load one:

- `dict.set_dict(jisyo_parser.parse(text))` — Synchronous, parses everything at once. Good for tests and small dictionaries.
- `dict.load_dictionary_async(path, encoding, on_done)` — Asynchronous, lazy parsing. For large dictionaries (SKK-JISYO.L/LL etc., several MB to over ten MB), designed to avoid blocking Neovim's startup or editing operations, in two stages:
  1. File loading, character-encoding conversion, and building a lightweight "reading → raw candidate string" index are all deferred via `vim.schedule()` until after startup completes, and the indexing itself proceeds while yielding to the event loop at regular time budgets (default 30ms). The candidate strings themselves are not parsed at this stage.
  2. Actual candidate parsing happens for the first time only when that reading is actually looked up, with the result memoized. Since even for a huge dictionary, only a tiny fraction of readings actually get looked up in practice, this further reduces the perceived startup load.

In measurements (a 17MB, 520,000-line dictionary, in this development environment's Lua 5.4), a full synchronous parse took about 4 seconds, while the asynchronous, lazy parse completed in about 2.1 seconds without freezing Neovim in the meantime. Actual Neovim runs on LuaJIT (generally faster than this development environment's Lua 5.4), so it's expected to be even faster on real hardware. Compared to implementations that use an external process (such as skkeleton, via denops), being a single-threaded, cooperative scheduling approach means it may not quite match the perceived "instant startup" of those. `vim.uv.new_work()` (true parallel parsing using the libuv thread pool) could shrink this further, but worker threads can't access closures or `vim.*`, so this needs to be approached carefully with repeated real-hardware verification (not yet started).

**Multiple dictionaries** can be registered additionally with `dict.add_dict(dict, name)` (synchronous) / `dict.add_dictionary_async(path, encoding, on_done, time_budget_ms, name)` (asynchronous, lazy parsing). Priority follows registration order (a source added earlier takes priority; for a candidate whose `word` is duplicated, the one from a later-added source is ignored). `dict.set_dict()`/`dict.load_dictionary_async()`, by contrast, behave as "replace as the sole source," so when using multiple dictionaries, use `add_dict`/`add_dictionary_async` instead. `dict.clear_dicts()` clears all registered local dictionary sources (the personal dictionary and SKK server settings are unaffected).

**The SKK server** (`dict/skkserv.lua`) is a TCP client for the traditional SKK server protocol (`skkserv`/`dbskkd-cdb`/`yaskkserv2`, etc.). Enable it with `require("skk").setup({ skkserv = { host = "127.0.0.1", port = 1178, encoding = "euc-jp" } })` (verified working, both connectivity and conversion, against a real [yaskkserv2](https://github.com/wachikun/yaskkserv2)).

Care is needed since the terminator differs per command in this protocol (this is covered in detail in yaskkserv2's README, in the "SKK protocol memo" section). It's an easy thing to get wrong — in fact, this implementation initially got it wrong too:

- `"1"` (lookup): client → server is `"1" .. reading .. " "` (terminated by a **space**, not a newline). server → client is `"1/candidate1/candidate2/.../\n"` (newline-terminated), or `"4" .. reading .. "\n"` if not found.
- `"2"` (version check): client → server is just `"2"` (no terminator). server → client is `"A.B "` (terminated by a **space**, not a newline).
- `"0"` (disconnect): no terminator, and no response either.

Since lookups from `henkan/state.lua` are called as a synchronous API, internally this is a wrapper that polls the asynchronous TCP communication via `vim.wait()`; if the server doesn't respond, it gives up after `timeout_ms` (default 300ms) and returns an empty array (to keep Neovim from freezing). After a failed connection, it won't retry for 5 seconds (a cooldown). Setting `debug = true` will print the raw sent/received data via `vim.notify()` (`dict.skkserv_version()`/`dict.skkserv_status()`/`dict.skkserv_last_connect_error()` are also available for checking connectivity). The protocol implementation has been verified against both the lightweight test server bundled in this repository (`tests/fixtures/fake_skkserv.py`) and a real yaskkserv2. Other server implementations (`dbskkd-cdb`, etc.) are untested.

**Merge priority** is: personal dictionary > SKK server (if enabled) > local dictionary sources (in registration order). For a candidate with a duplicated `word`, only the one with the highest priority is kept.

### Word-registration UI (`M._trigger_registration()` in `henkan/state.lua`)

When no candidates are found, or when advancing past the last candidate via candidate-advance (`<SPC>`/`<C-n>`) (previously this would wrap back to the first candidate, but that wrap-around has been removed), the word-registration UI opens.

The implementation uses **recursive calls** to Neovim's built-in `vim.fn.input()`. `input()` keeps `mode()=="c"` throughout its call, and automatically returns to whatever called it once it finishes (continuing in insert mode if that's where it was called from, or continuing the command line being edited if called from there) — and thanks to this property, the existing command-line-mode support in `target.lua`/`preedit.lua` (romaji→kana conversion, henkan) works as-is for the registration UI, with no dedicated code needed. The registration UI works through the same code path whether the conversion that triggered it started in a buffer or on the command line, and this naturally makes **SKK's characteristic recursive word registration — converting further inside the registration UI itself to register an unknown word — possible** (simply reusing the same `henkan_state` module recursively, with no dedicated stack management needed — `_trigger_registration()` always fully ends the conversion session at that point, either by confirming or canceling it, before calling `input()`, so there's no notion of "returning to the caller" in the first place). [skkeleton's](https://github.com/vim-skk/skkeleton) `registerWord()` (`function/dictionary.ts`) was consulted before implementing this, and it's been confirmed that using recursive calls to `vim.fn.input()`, and temporarily remapping `<Esc>`/`<C-g>` to a sentinel string + `<CR>` to detect cancellation, are essentially the same design.

- The moment you enter the registration UI, it automatically starts in hiragana mode (a mechanism in `capture.lua`'s `M.reserve_next_cmdline_mode()` that reserves the starting mode for the next command-line session, just once — since there's overwhelmingly more occasion to do conversion here, this saves having to press `<C-j>` every time).
- Pressing `<Esc>`/`<C-g>`, or `<CR>` with an empty entry, is treated as a cancellation: nothing is written to the dictionary, and whatever text was on screen right before entering the registration UI (just the `▽` reading, or the `▼` candidate) is confirmed as-is.
- Typing a word and pressing `<CR>` writes it to the personal dictionary via `dict.record_selection()`, and that word (plus any okurigana) is confirmed.
- The `▽`/`▼` marker display is cleared **before** calling `vim.fn.input()` (clearing it afterward caused a bug where a nested conversion would overwrite `preedit.lua`'s internal state, leaving the marker stuck on screen with the new word inserted alongside it — discovered and fixed on real hardware).

### blink.cmp native source integration (`blink_source.lua`)

skk.nvim also works as a native source for [blink.cmp](https://github.com/Saghen/blink.cmp) (registering it into `sources.providers` itself is outside this plugin — it's the user configuration's responsibility; see "Usage" above). It offers prefix-match results from `dict.lookup_prefix()` as live completion candidates, only while in the `▽`/abbrev (headword-entry) state (roughly equivalent to `getCompletionResult()` in skkeleton for denops).

**v2 (background)**: The first implementation (v1) unconditionally fetched the actual conversion candidates (via the `"1"` command) for every prefix-matched reading, which had the structural problem that a single keystroke could trigger up to `max_items+1` synchronous TCP round trips (see "SKK server communication reliability" below). So v2 narrowed live completion down to returning only the **list of matching readings**, not the actual candidates.

**Phase 2 (the current design)**: v2's "safe, but no kanji visible" limitation has been resolved, and actual conversion candidates (kanji) are now fetched and shown for the personal dictionary, local dictionaries, and the SKK server alike. For the personal dictionary and local dictionaries, `M.lookup()` is an in-memory synchronous operation, so calling it any number of times costs essentially nothing — but calling `"1"` on the SKK server carries two risks: (1) the number of round trips, and (2) a notfound-fallback landmine (described below) stemming from the fact that the readings returned by `dict.lookup_prefix()` are the "union" of the personal dictionary, local dictionaries, and the SKK server. To avoid this, the second return value of `dict.lookup_prefix()`, `from_skkserv` (the set of readings that were actually included in the SKK server's own `"4"` response), is used, and `"1"` is only sent to the SKK server for readings that are in `from_skkserv`, up to a count limit (`blink.skkserv_candidate_limit`, default 20). **However, it turned out on real hardware that this alone doesn't fully prevent (2)**, so an additional safeguard was added: if a reading contains `(` `)` `"` `\` or similar characters (used in SKK's program-candidate syntax), `"1"` is not sent for it even if it's in `from_skkserv` (details in the 6th item of "SKK server communication reliability" below). Any reading beyond the limit, not in `from_skkserv`, matching the safeguard above, or with zero candidates found, becomes a "reading only" fallback item, same as in v2 (selecting it just replaces the reading via `M.set_reading()`, staying in `▽`).

Selecting and confirming (`execute()`) an actual candidate (with `data.word`) delegates to `henkan/state.lua`'s `M.confirm_external(reading, false, word, annotation)`, just as in v1, doing both personal-dictionary learning and the actual text insertion in one go, ending the `▽`/`▼` state. Selecting a reading-only fallback item just replaces the reading via `M.set_reading()`, as before, and `<SPC>` then proceeds to `▼` (selecting from the actual conversion candidates), as usual.

Calling `require("skk").setup({ blink = { skkserv_candidates = false } })` can stop calls to `"1"` on the SKK server entirely (leaving only personal-dictionary and local-dictionary candidates — an independent switch from `skip_skkserv`, which controls fetching the reading list via `"4"`).

**A key design difference (compared to the skkeleton source)**: skkeleton displays `▽`/`▼` by writing directly into the real buffer, so the real-hardware `skkeleton_source.lua` can use the approach of "replace the real text's range via textEdit." skk.nvim's `▽`/`▼`, on the other hand, are shown via extmarks (virtual text), with nothing written into the real buffer. So `blink_source.lua` keeps textEdit as "an empty insertion (no-op) at the current cursor position," and delegates the actual state update from `execute()` to `M.set_reading()`.

**Keeping the display in sync**: `henkan/state.lua` fires a `User autocmd "SkkHenkanChanged"` (roughly equivalent to skkeleton's `skkeleton-mode-changed`) with `data.phase`/`data.reading`/`data.has_okuri`/`data.source_mode` on every `▽`/`▼` state change. Actually calling show()/hide() on the blink.cmp menu is not this source's responsibility — it's expected that the user's own configuration watches this autocmd and does so (the same approach as the `skkeleton-mode-changed` handler in the real-hardware [nvim-config-blink-skkeleton](https://github.com/nabehan/nvim-config-blink-skkeleton)). During `▼` (candidate selection), skk.nvim's own candidate window would clash visually, so it's assumed the blink.cmp side suppresses its menu then.

#### Known quirks in the implementation (discovered on real hardware)

- **Re-triggering `show()`**: While in `▽`, `SkkHenkanChanged` fires every time the reading changes by one character, but blink.cmp's `show()` has a guard that does nothing "if the menu is already open and `providers` isn't specified." With skkeleton, real-buffer text changes let it ride blink.cmp's own automatic refetch, but skk.nvim's `▽`/`▼` are extmark displays that never change the real buffer, so it can't ride that. When calling `show()` from user configuration, always pass `providers = { "skk" }` explicitly, forcing a re-trigger every time regardless of whether the menu is already open (omitting it means the menu opens on the first call right after entering ▽, but then stops updating as the reading grows). See the sample code under "Usage" above for details.
- **Range computation in command-line mode**: `enter_key` is mapped not just in insert mode but also in command-line mode (e.g. `vim.fn.input()` in the word-registration UI), so `▽` conversion can happen while on the command line. Since blink.cmp itself assumes "the line number is always 0" in command-line mode, the textEdit range computation in `get_completions()` needs to branch depending on whether it's command-line mode (using the ordinary buffer's line number as-is would crash the candidate preview processing). This is implemented.
- **A clash with keyword extraction**: blink.cmp itself, regardless of which source a candidate came from, uniformly queries a "keyword" independently extracted from the real buffer's cursor position (based on Unicode's "letter" category, which includes kanji) and fuzzy-matches it against each candidate's `filterText` (or `label` if absent) (`list.fuzzy()` in `completion/list.lua`). This always happens, regardless of `is_incomplete_forward`/`is_incomplete_backward`, and there's no official way for a source to bypass it. If real text such as kanji or alphanumerics immediately precedes the cursor, that whole thing gets extracted as the "keyword," which barely matches the `filterText` returned here (the reading itself), wiping out every candidate in the filter so the candidate window never opens. As a workaround, `get_completions()` calls the same function blink.cmp itself actually uses for extraction (`blink.cmp.fuzzy.get_keyword_range()`) to pre-fetch what it will extract, and prepends that to the front of `filterText` (this depends on a near-internal, semi-private implementation detail of blink.cmp, and could break on a blink.cmp update — it's protected with `pcall`).
- **Symmetry with abbrev mode**: abbrev mode (started with `/`, where the headword itself is an ASCII string) should also get live completion just like `▽`, but `get_completions()` originally only targeted `phase == "midashi"`, so no candidate window ever appeared during abbrev mode. Since the actual conversion-candidate lookup in `henkan/state.lua` (`M.space()`/`M.search()`) already treats `"midashi"` and `"abbrev"` symmetrically, `"abbrev"` was added to `get_completions()`'s phase check as well, fixing this. The user configuration's own `enabled()` and `SkkHenkanChanged` handler's phase checks need to include `"abbrev"` similarly (see "Usage" above).

#### The key conflict with an external UI (blink.cmp) and `passthrough_guard` (discovered on real hardware — important)

`capture.lua` observes all key input via `vim.on_key()`, but **`vim.on_key()` is an observation-only API — it cannot stop the firing of a key that another plugin (blink.cmp) has explicitly bound via `vim.keymap.set()`**. Because of this, when a key assigned to blink.cmp's accept action or similar arrives while in `▽`/abbrev, the following two things would fire **independently, at the same time**:

1. blink.cmp's own keymap (`execute()` → `set_reading()`. As intended.)
2. skk.nvim's own auto-confirm logic — "an unrecognized key (`<CR>` included) confirms the reading as-is and exits `▽`" (`henkan_state.confirm()`. This does an actual insertion into the real buffer, plus ending the `▽` state.)

This wasn't noticed while testing with blink.cmp's default keymap (`<C-y>` = accept), but the real-hardware configuration ([nvim-config-blink-skkeleton](https://github.com/nabehan/nvim-config-blink-skkeleton)) is a full custom setup with `keymap.preset = "none"`, assigning `<CR>`, not `<C-y>`, to accept. **A fix that hard-codes some specific key as "reserved for blink.cmp" doesn't work in an environment like this** (`<CR>` is also the key skk.nvim itself uses to mean "confirm," so including it in a hard-coded list wouldn't be a real fix either).

As a fix, `M.set_passthrough_guard(fn)` was added to `capture.lua`. While `fn(key)` returns `true`, none of the `<CR>`/"unrecognized key" auto-confirm logic during `▽`/abbrev runs at all (regardless of which key it is). `blink_source.lua`'s `source.setup()` automatically registers `require("blink.cmp").is_visible()` (a public API that returns whether the menu or ghost text is currently visible, independent of key bindings) as this `fn`. By **judging based on "is an external UI currently visible" rather than "a specific key,"** this works no matter how the user has bound keys on the blink.cmp side.

Note that, given the nature of `vim.on_key()`, skk.nvim stopping its own processing via this guard doesn't prevent — or get prevented by — blink.cmp's own keymap firing (that's resolved independently through Neovim's normal keymap resolution, as always). The purpose of this guard is to prevent skk.nvim's side from doubly performing the confirmation itself. Romaji reading input itself (characters matching `is_target_key`) is excluded from this guard, so it can continue as before even while an external UI is displayed. See "Delegating to an external UI (blink.cmp etc.) (passthrough_guard)" in `tests/capture_henkan_routing_spec.lua` for the regression test.

#### Including the SKK server in live completion as well

`skip_skkserv` (default `false`) controls whether the SKK server is included in the prefix-match search (the `"4"` command, fetching the reading list). Enabled by default (including the SKK server's own prefix-match results, same as skkeleton). It's confirmed that the `"4"` command handler has no google-japanese-input fallback, so there's no risk of the kind of latency associated with the `"1"`-family calls. If this is a concern, `require("skk").setup({ blink = { skip_skkserv = true } })` narrows it to the personal and local dictionaries only.

`skkserv_candidates` (default `true`) and `skkserv_candidate_limit` (default 20) control the SKK server's involvement in fetching actual conversion candidates (the `"1"` command) — an independent switch from `skip_skkserv`. See "Phase 2 (the current design)" above for details.

#### SKK server communication reliability (discovered on real hardware — important, in chronological order)

Verifying `skip_skkserv = false` on real hardware uncovered and fixed a number of latency, timeout, and mismatched-response issues.

1. **`TCP_NODELAY` not set**: The combination of Nagle's algorithm and delayed ACKs on the receiving side caused around ~40ms of latency on every round trip for a small request like `"1<reading> "` (a classic TCP pitfall that occurs even on localhost). Since the design could involve up to `max_items+1` such round trips per headword entry, this added up to multi-second delays. Fixed by calling `sock:nodelay(true)` in `connect_to_ip()`.
2. **Mismatched responses (reentrancy)**: `send_request_and_wait()`'s assumption of reusing a single connection and treating "the next line received" as "the response to the request just sent" could break down due to **reentrancy** — the event loop keeps running while waiting inside `vim.wait()` (i.e., key-input processing keeps proceeding normally). An initial fix using an `in_flight` flag (immediately giving up on any collision) prevented the collision but had the side effect of silently dropping requests. This was ultimately replaced with a strictly sequential queue approach (`enqueue()`) that queues a colliding request rather than discarding it (details in the "SKK server" section above).
3. **Candidate-parsing overhead**: `_parse_response()` was calling `vim.fn.iconv()` for every single candidate, which became noticeably slow for readings with many candidates (sometimes hundreds). Fixed to convert the entire response body to UTF-8 just once, then split it into candidates (`M._parse_prefix_response()` was fixed the same way).
4. **Leftover data after a timeout**: `send_request_and_wait()` didn't close the connection on timeout, so a late-arriving response left sitting in the OS's socket receive buffer could be mistakenly received as the response to the next, unrelated request. Fixed to `close()` the connection and set `client = nil` on timeout, ensuring a fresh connection is always established next time.
5. **An irregular dictionary entry as the trigger for #4**: The trigger for the issue above was an irregular entry in the `jawiki` dictionary, such as `t(concat "\057")c` (where SKK's program-candidate syntax had leaked in as a literal reading), containing a space within the reading. The old tokenization in `M._parse_prefix_response()` (which also split on spaces) mis-split this, causing it to query the server about a nonexistent fragment. Fixed to split only on `"/"`.
6. **A notfound fallback that Phase 2's `from_skkserv` alone couldn't fully prevent (discovered on real hardware — important)**: Phase 2 above was designed to avoid the notfound fallback by only sending `"1"` for readings the SKK server itself had confirmed existed via `"4"` (`from_skkserv`), but this alone turned out to be insufficient. For an irregular entry in the same family as #5 above in the `jawiki` dictionary, such as `a(concat ...)` (again, program-candidate syntax leaking into the reading), it was confirmed on real hardware that yaskkserv2's `"4"` (prefix match) finds it, but `"1"` (exact match) returns notfound, triggering the `google-japanese-input` fallback (a query to Google Translate's `transliterate` API, which by default only kicks in on `notfound`) to time out and stall. abbrev mode (which does a prefix search directly on the raw ASCII string) is prone to hitting this kind of irregular entry, and since it tends to sort near the front within the dictionary, this can happen even with `skkserv_candidate_limit` set low. As an additional safeguard, `"1"` is no longer sent, even for a reading in `from_skkserv`, if the reading contains `(` `)` `"` `\` or control characters (`looks_safe_for_skkserv_lookup()` in `blink_source.lua`). More fundamentally, this fallback itself can also be disabled via yaskkserv2's own `google-japanese-input = disable` setting (default is `notfound`).

**Prefix-match completion with okurigana is not currently offered** (`dict.lookup_prefix()` is limited to okuri-nasi only, for protocol and practical reasons).

#### Real-hardware verification status

In an isolated sandbox environment ([nvim-skk-sandbox](https://github.com/nabehan/nvim-skk-sandbox)), for both ordinary buffers and command-line mode, the display and updating of live completion (including Phase 2's display of actual conversion candidates — kanji), selection via `<C-n>`/`<C-p>`, confirmation, and the transition to skk.nvim's own conversion via `<SPC>` have all been verified working, response speed included. `skkserv_candidate_limit` (default 20) has been confirmed "very smooth" on real hardware, with room to increase it further. `tests/blink_source_spec.lua` (including Phase 2's tests) also passes entirely under a real-hardware run of `test.sh` with blink.cmp included in the runtime path. Actually wiring this into the day-to-day real-hardware configuration ([nvim-config-blink-skkeleton](https://github.com/nabehan/nvim-config-blink-skkeleton)) has not been done yet.

### The mode indicator (`mode_indicator.lua`)

The moment the mode switches (via `<C-j>`, or `l`/`q`/`L`), a glyph (`ひら`/`カタ`/`latn`/`ＬＡ`) is shown in a floating window at the cursor position. It disappears as soon as the next key input actually arrives (handled by `mode_indicator.hide()`, called every time from `capture.lua`'s `on_key()`).

The `<C-j>` mode transition doesn't go through `vim.on_key()`'s `on_key()` — it's a separate path where `init.lua` calls `capture.transition()` directly via `vim.keymap.set()` — so the indicator display for it is also handled individually there (in the past, this was missed, causing a bug where the indicator failed to appear only for `<C-j>`).

## License

[MIT License](LICENSE)

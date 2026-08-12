-- skk_debug_float.lua
--
-- コマンドラインモード「編集中」（Enterを押す前）にフローティングウィンドウが
-- 実際に画面に見えるかどうかを切り分けるための、使い捨てのデバッグ用スクリプト。
-- skk.nvim 本体には含めない。
--
-- 使い方:
--   nvim -u skk_test_init.lua -c "source skk_debug_float.lua"
-- または、起動後に:
--   :source skk_debug_float.lua
--
-- そのあと、通常モードで ":" か "/" を押してコマンドラインに入り、
-- Enterを押す【前】に、まだコマンドライン編集中の状態のまま
--   <C-t> ... 画面「左上」に赤いフロートを試す（コマンドライン行とは無関係な位置）
--   <C-b> ... 画面「右下」にフロートを試す（今回 mode_indicator.lua で使った位置）
-- を押してみてください。それぞれ見えたかどうかを教えてください。
-- （<C-t>/<C-b> はどちらも文字を確定させず、フロートを出すだけです）

local function make_buf(text, hl)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { text })
  vim.api.nvim_buf_add_highlight(buf, -1, hl, 0, 0, -1)
  return buf
end

local top_win, bottom_win

vim.keymap.set("c", "<C-t>", function()
  if top_win and vim.api.nvim_win_is_valid(top_win) then
    vim.api.nvim_win_close(top_win, true)
    top_win = nil
    return
  end
  local buf = make_buf(" TOP-TEST (C-t) ", "ErrorMsg")
  top_win = vim.api.nvim_open_win(buf, false, {
    relative = "editor",
    row = 0,
    col = 0,
    width = 18,
    height = 1,
    style = "minimal",
    border = "none",
    focusable = false,
    zindex = 300,
    noautocmd = true,
  })
end, { desc = "skk_debug_float: toggle top-left test float" })

vim.keymap.set("c", "<C-b>", function()
  if bottom_win and vim.api.nvim_win_is_valid(bottom_win) then
    vim.api.nvim_win_close(bottom_win, true)
    bottom_win = nil
    return
  end
  local buf = make_buf(" BOTTOM-TEST ", "DiffAdd")
  bottom_win = vim.api.nvim_open_win(buf, false, {
    relative = "editor",
    row = math.max(vim.o.lines - vim.o.cmdheight, 0),
    col = math.max(vim.o.columns - 16, 0),
    width = 16,
    height = 1,
    style = "minimal",
    border = "none",
    focusable = false,
    zindex = 300,
    noautocmd = true,
  })
end, { desc = "skk_debug_float: toggle bottom-right test float" })

-- <C-r>: <C-t>と同じ左上フロートだが、開いた直後に明示的に redraw を
-- 強制する。もしこれで即座に見えるようになるなら、
-- 「コマンドライン編集中は新規フロートの再描画が抑制される」が原因で、
-- 対策は open 直後に redraw を挟むだけで済むことになる。
vim.keymap.set("c", "<C-r>", function()
  if top_win and vim.api.nvim_win_is_valid(top_win) then
    vim.api.nvim_win_close(top_win, true)
    top_win = nil
    return
  end
  local buf = make_buf(" REDRAW-TEST (C-r) ", "WarningMsg")
  top_win = vim.api.nvim_open_win(buf, false, {
    relative = "editor",
    row = 0,
    col = 0,
    width = 22,
    height = 1,
    style = "minimal",
    border = "none",
    focusable = false,
    zindex = 300,
    noautocmd = true,
  })
  local ok, err = pcall(vim.cmd, "redraw")
  vim.api.nvim_echo({ { string.format("redraw: ok=%s err=%s", tostring(ok), tostring(err)), "MoreMsg" } }, false, {})
end, { desc = "skk_debug_float: top-left float + explicit redraw" })

vim.api.nvim_echo({
  {
    "skk_debug_float loaded: cmdline中に <C-t> (左上/redrawなし) <C-r> (左上/redrawあり) <C-b> (右下) でフロートを試せます",
    "MoreMsg",
  },
}, false, {})

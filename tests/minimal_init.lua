-- テスト実行専用の最小 init。plenary.nvim と自分自身の lua/ を runtimepath に追加するだけ。
local root = vim.fn.fnamemodify(vim.fn.expand("<sfile>"), ":p:h:h")

vim.opt.runtimepath:append(root)
vim.opt.runtimepath:append(root .. "/.tests/site/pack/deps/start/plenary.nvim")

vim.cmd("runtime plugin/plenary.vim")

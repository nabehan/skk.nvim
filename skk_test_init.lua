-- このディレクトリ（skk.nvim）だけを runtimepath に追加する
vim.opt.runtimepath:append(vim.fn.getcwd())

require("skk").setup()

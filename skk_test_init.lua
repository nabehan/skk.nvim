-- このディレクトリ（skk.nvim）だけを runtimepath に追加する
vim.opt.runtimepath:append(vim.fn.getcwd())

-- require("skk").setup()
require("skk").setup({
  candidate_window = { border = "single" },
})
-- ===================================================================
-- 動作確認用の辞書読み込み
-- ===================================================================
-- 実際の SKK-JISYO.L 等を読み込みたい場合は、環境変数で指定する:
--   SKK_JISYO_PATH=~/.skk/SKK-JISYO.L nvim -u ./skk_test_init.lua
--   SKK_JISYO_ENCODING=euc-jp   (省略時は euc-jp がデフォルト)
--
-- 指定が無ければ、動作確認用の小さな組み込み辞書を使う。
local dict = require("skk.dict")
local file_source = require("skk.dict.file_source")
local parser = require("skk.dict.jisyo_parser")

local jisyo_path = os.getenv("SKK_JISYO_PATH")

if jisyo_path then
  local loaded, err = file_source.load(jisyo_path, os.getenv("SKK_JISYO_ENCODING"))
  if loaded then
    dict.set_dict(loaded)
    vim.schedule(function()
      vim.notify("skk.nvim: dictionary loaded from " .. jisyo_path)
    end)
  else
    vim.schedule(function()
      vim.notify("skk.nvim: " .. tostring(err), vim.log.levels.WARN)
    end)
  end
else
  -- 動作確認用の小さな組み込み辞書（送りなし・送りあり両方のサンプルを含む）
  local mini_jisyo = table.concat({
    ";; okuri-ari entries.",
    "うごk /動/",
    "あかk /赤/",
    ";; okuri-nasi entries.",
    "かんじ /漢字/幹事/監事/",
    "うごく /動く/",
    "あい /愛/",
    "にほん /日本/",
  }, "\n")
  dict.set_dict(parser.parse(mini_jisyo))
  vim.schedule(function()
    vim.notify(
      "skk.nvim: using built-in mini dictionary (SKK_JISYO_PATH で実際の辞書ファイルを指定できます)"
    )
  end)
end

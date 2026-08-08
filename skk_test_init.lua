-- このディレクトリ（skk.nvim）だけを runtimepath に追加する
vim.opt.runtimepath:append(vim.fn.getcwd())

require("skk").setup({
  enter_key = "<C-j>",
  -- 半角英数/全角英数 -> ひらがな。henkan 中は <CR> 相当（確定）。省略時 "<C-j>"

  sticky_shift_enabled = true,
  -- Sticky-shift の有効/無効。省略時 true

  sticky_shift_key = ";",
  -- Sticky-shift のトリガーキー。省略時 ";"（sticky_shift_enabled=false なら無視される）

  egg_like_newline = true,
  -- true: ▼状態での<CR>は確定のみ（改行しない、skk.nvimのデフォルト）
  -- false: 確定に加えて改行も挿入する（SKK本来の動作）

  candidate_window = {
    border = "rounded",
    -- "rounded"/"single"/"double"/"none"/自前の文字配列。省略時 "rounded"
    annotation = true,
    -- 候補一覧に辞書の注釈（;注釈）を表示するか。省略時 true
    page_indicator = true,
    -- false にすると最下行のページ表示（"2/3"など）を出さない
  },

  -- 実装試験中は、個人辞書をこのリポジトリ直下（README.md と同じ階層）に
  -- 作る。本番の既定値は "~/.local/share/skk/SKK-JISYO.user"
  -- （lua/skk/init.lua 参照）。
  user_dictionary = vim.fn.getcwd() .. "/SKK-JISYO.user",
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

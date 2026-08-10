-- このディレクトリ（skk.nvim）だけを runtimepath に追加する
vim.opt.runtimepath:append(vim.fn.getcwd())

-- ===================================================================
-- 環境変数での動作確認オプション
-- ===================================================================
-- 単一のメイン辞書（従来通り）:
--   SKK_JISYO_PATH=/usr/share/skk/SKK-JISYO.L
--   SKK_JISYO_ENCODING=euc-jp        (省略時 euc-jp)
--
-- 追加の辞書（複数可、":" 区切り。SKK_JISYO_PATH と併用できる。
-- 実機の skkeleton globalDictionaries 相当）:
--   SKK_JISYO_PATHS=/usr/local/share/skk/SKK-JISYO.edict2:/usr/local/share/skk/SKK-JISYO.emoji
--   SKK_JISYO_PATHS_ENCODING=utf-8   (省略時 utf-8。SKK_JISYO_PATHS の全ファイルに一律適用)
--
-- SKKサーバー（skkserv/dbskkd-cdb/yaskkserv2 等）:
--   SKK_SKKSERV_HOST=127.0.0.1
--   SKK_SKKSERV_PORT=1178            (省略時 1178)
--   SKK_SKKSERV_ENCODING=euc-jp      (省略時 euc-jp)
--
-- 例（実機の skkeleton 設定と同等の構成で試す場合）:
--   SKK_SKKSERV_HOST=127.0.0.1 \
--   SKK_JISYO_PATHS=/usr/local/share/skk/SKK-JISYO.edict2:/usr/local/share/skk/SKK-JISYO.emoji:/usr/local/share/skk/SKK-JISYO.emoji-ja \
--   SKK_JISYO_PATHS_ENCODING=utf-8 \
--   nvim -u ./skk_test_init.lua

local setup_opts = {
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
    threshold = 2,
    -- 省略時のデフォルト。1にすると、これまで通り最初の<SPC>で即ウィンドウ表示
  },

  -- 実装試験中は、個人辞書をこのリポジトリ直下（README.md と同じ階層）に
  -- 作る。本番の既定値は "~/.local/share/skk/SKK-JISYO.user"
  -- （lua/skk/init.lua 参照）。
  user_dictionary = vim.fn.getcwd() .. "/SKK-JISYO.user",
}

local skkserv_host = os.getenv("SKK_SKKSERV_HOST")
if skkserv_host then
  setup_opts.skkserv = {
    host = skkserv_host,
    port = tonumber(os.getenv("SKK_SKKSERV_PORT")) or 1178,
    encoding = os.getenv("SKK_SKKSERV_ENCODING") or "euc-jp",
  }
end

require("skk").setup(setup_opts)

-- ===================================================================
-- 動作確認用の辞書読み込み
-- ===================================================================
local dict = require("skk.dict")
local parser = require("skk.dict.jisyo_parser")

local jisyo_path = os.getenv("SKK_JISYO_PATH")
local jisyo_paths_raw = os.getenv("SKK_JISYO_PATHS")
local jisyo_paths_encoding = os.getenv("SKK_JISYO_PATHS_ENCODING") or "utf-8"

local pending = 0
local any_requested = false

local function notify_done(label, ok, err)
  vim.schedule(function()
    if ok then
      vim.notify("skk.nvim: dictionary loaded: " .. label)
    else
      vim.notify("skk.nvim: failed to load " .. label .. ": " .. tostring(err), vim.log.levels.WARN)
    end
  end)
end

if jisyo_path then
  any_requested = true
  pending = pending + 1
  dict.add_dictionary_async(jisyo_path, os.getenv("SKK_JISYO_ENCODING"), function(ok, err)
    notify_done(jisyo_path, ok, err)
    pending = pending - 1
  end, nil, jisyo_path)
end

if jisyo_paths_raw then
  for path in jisyo_paths_raw:gmatch("[^:]+") do
    any_requested = true
    pending = pending + 1
    dict.add_dictionary_async(path, jisyo_paths_encoding, function(ok, err)
      notify_done(path, ok, err)
      pending = pending - 1
    end, nil, path)
  end
end

if not any_requested then
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
      "skk.nvim: using built-in mini dictionary "
        .. "(SKK_JISYO_PATH / SKK_JISYO_PATHS で実際の辞書ファイルを指定できます)"
    )
  end)
end

-- このディレクトリ（skk.nvim）だけを runtimepath に追加する
vim.opt.runtimepath:append(vim.fn.getcwd())

-- ===================================================================
-- ここを編集して実機の構成に合わせる
-- ===================================================================

local setup_opts = {
  -- SKKサーバー（skkserv/dbskkd-cdb/yaskkserv2 等）。使わないなら nil にする。
  -- 【yaskkserv2 で候補が引けない場合】まず encoding = "utf-8" を試す。
  -- yaskkserv2 のような比較的新しいサーバーは EUC-JP ではなく UTF-8 が
  -- デフォルトのことがある。debug = true にすると、送受信の生データが
  -- vim.notify() で見えるので、通信自体はできているか（timeout/connect_failed
  -- ではないか）、返ってきた文字列が化けていないか、を切り分けられる。
  skkserv = {
    host = "127.0.0.1",
    port = 1178,
    encoding = "euc-jp", -- yaskkserv2 なら "utf-8" も試す
    debug = false,
  },

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

  -- 読み込む辞書ファイル。上から順に優先順位が高い（先に登録したものが
  -- 優先され、word が重複する候補は後のファイルの分は無視される）。
  -- 実機の skkeleton globalDictionaries 相当。空にすると、下でこの
  -- ファイル自身が組み込みの小さな確認用辞書を代わりに読み込む。
  ---@type { path: string, encoding: string }[]
  dictionaries = {
    -- { path = "/usr/share/skk/SKK-JISYO.L", encoding = "euc-jp" },
    -- { path = "/usr/share/skk/SKK-JISYO.mazegaki", encoding = "euc-jp" },
    -- { path = "/usr/share/skk/SKK-JISYO.requested", encoding = "euc-jp" },
    -- { path = "/usr/share/skk/SKK-JISYO.pubdic+", encoding = "euc-jp" },
    -- { path = "/usr/share/skk/SKK-JISYO.law", encoding = "euc-jp" },
    -- { path = "/usr/share/skk/SKK-JISYO.assoc", encoding = "euc-jp" },
    -- { path = "/usr/share/skk/SKK-JISYO.propernoun", encoding = "euc-jp" },
    -- { path = "/usr/share/skk/SKK-JISYO.station", encoding = "euc-jp" },
    -- { path = "/usr/share/skk/SKK-JISYO.geo", encoding = "euc-jp" },
    -- { path = "/usr/share/skk/SKK-JISYO.fullname", encoding = "euc-jp" },
    -- { path = "/usr/share/skk/SKK-JISYO.JIS2", encoding = "euc-jp" },
    -- { path = "/usr/share/skk/SKK-JISYO.itaiji", encoding = "euc-jp" },
    -- { path = "/usr/share/skk/SKK-JISYO.okinawa", encoding = "euc-jp" },
    -- { path = "/usr/share/skk/SKK-JISYO.china_taiwan", encoding = "euc-jp" },
    -- { path = "/usr/local/share/skk/SKK-JISYO.LL.utf8", encoding = "utf-8" },
    { path = "/usr/local/share/skk/SKK-JISYO.edict2", encoding = "utf-8" },
    { path = "/usr/local/share/skk/SKK-JISYO.emoji", encoding = "utf-8" },
    { path = "/usr/local/share/skk/SKK-JISYO.emoji-ja", encoding = "utf-8" },
  },

  -- dictionaries の各エントリの読み込みが完了するたびに呼ばれる。
  on_dictionary_loaded = function(path, ok, err)
    vim.schedule(function()
      if ok then
        vim.notify("skk.nvim: dictionary loaded: " .. path)
      else
        vim.notify("skk.nvim: failed to load " .. path .. ": " .. tostring(err), vim.log.levels.WARN)
      end
    end)
  end,
}

-- ===================================================================
-- 環境変数でも上書きできる（ファイルを編集したくない場合）
-- ===================================================================
--   SKK_SKKSERV_HOST=... / SKK_SKKSERV_PORT=... / SKK_SKKSERV_ENCODING=...
--     -> setup_opts.skkserv を上書き（SKK_SKKSERV_HOST が空なら skkserv 無効）
--   SKK_JISYO_PATH=... / SKK_JISYO_ENCODING=...
--     -> dictionaries の先頭に1件追加
--   SKK_JISYO_PATHS=path1:path2:...  / SKK_JISYO_PATHS_ENCODING=...
--     -> dictionaries に追加（":" 区切り）

do
  local env_host = os.getenv("SKK_SKKSERV_HOST")
  if env_host then
    setup_opts.skkserv = {
      host = env_host,
      port = tonumber(os.getenv("SKK_SKKSERV_PORT")) or 1178,
      encoding = os.getenv("SKK_SKKSERV_ENCODING") or "euc-jp",
      debug = os.getenv("SKK_SKKSERV_DEBUG") == "1",
    }
  end

  local env_path = os.getenv("SKK_JISYO_PATH")
  if env_path then
    table.insert(setup_opts.dictionaries, { path = env_path, encoding = os.getenv("SKK_JISYO_ENCODING") or "euc-jp" })
  end

  local env_paths = os.getenv("SKK_JISYO_PATHS")
  if env_paths then
    local enc = os.getenv("SKK_JISYO_PATHS_ENCODING") or "utf-8"
    for path in env_paths:gmatch("[^:]+") do
      table.insert(setup_opts.dictionaries, { path = path, encoding = enc })
    end
  end
end

-- dictionaries が空なら、setup() には渡さず組み込みの小さな確認用辞書を
-- 代わりに読み込む（skk.nvim 本体の setup() には無い、この試験スクリプト
-- だけの便宜機能）。
local use_mini_jisyo = #setup_opts.dictionaries == 0
if use_mini_jisyo then
  setup_opts.dictionaries = nil
end

require("skk").setup(setup_opts)

if use_mini_jisyo then
  local dict = require("skk.dict")
  local parser = require("skk.dict.jisyo_parser")
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
      "skk.nvim: using built-in mini dictionary (skk_test_init.lua の dictionaries を編集してください)"
    )
  end)
end

-- SKKサーバーの疎通確認（設定されていれば、バージョン文字列を表示する）。
if setup_opts.skkserv then
  local dict = require("skk.dict")
  vim.schedule(function()
    local version = dict.skkserv_version()
    if version then
      vim.notify("skk.nvim: skkserv version: " .. version)
    else
      local detail = dict.skkserv_last_connect_error()
      vim.notify(
        "skk.nvim: skkserv に接続できませんでした ("
          .. setup_opts.skkserv.host
          .. ":"
          .. setup_opts.skkserv.port
          .. ")。status="
          .. dict.skkserv_status()
          .. (detail and (" error=" .. tostring(detail)) or "")
          .. "。ホスト/ポート、サーバーの起動状態を確認してください。",
        vim.log.levels.WARN
      )
    end
  end)
end

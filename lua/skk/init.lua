-- lua/skk/init.lua
--
-- プラグインのエントリーポイント。
-- require("skk").setup() を呼ぶと vim.on_key() のリスナーが登録され、
-- <C-j>（挿入モード）でひらがなモードに入れるようになる。
-- ▽/▼ (henkan) がアクティブな間は、<C-j> は <CR> と同じく確定として扱う。
-- l/q/L によるモード切替は lua/skk/capture.lua の vim.on_key() 側で処理する。

local capture = require("skk.capture")
local henkan_state = require("skk.henkan.state")
local candidate_window = require("skk.henkan.candidate_window")
local dict = require("skk.dict")

local M = {}

---@class SkkSetupOpts
---@field enter_key string? 半角英数/全角英数 -> ひらがな。henkan 中は確定。デフォルト "<C-j>"
---@field sticky_shift_enabled boolean? Sticky-shift（大文字キーを使わずに ▽開始・送り開始点を
---  指示する操作）の有効/無効。デフォルト true。
---@field sticky_shift_key string? Sticky-shift のトリガーキー。デフォルト ";"。
---  sticky_shift_enabled=false のときは無視される。
---@field egg_like_newline boolean? true: ▼状態での <CR> は確定のみ行い、改行は挿入しない
---  （skk.nvimのデフォルト）。false: 確定に加えて改行も挿入する（SKK本来の動作）。デフォルト true。
---@field candidate_window { border: string|string[], annotation: boolean, page_indicator: boolean, threshold: integer }? 候補一覧ウィンドウの見た目・表示タイミング。
---  border は nvim_open_win() の "border" と同じ形式（"rounded"/"single"/"double"/
---  "none"/自前の文字配列 等）。デフォルト "rounded"。
---  annotation: 辞書の注釈（";注釈"）を候補一覧に表示するか。デフォルト true。
---  page_indicator: 最下行に "現在ページ/全ページ数"（例: "2/3"）を表示するか。デフォルト true。
---  threshold: ▼開始後、<SPC> を何回打鍵した時点で候補一覧ウィンドウを表示するか。
---  それまでは inline の ▼候補 表示で1件ずつ候補を送るだけでウィンドウは出さない
---  （個人辞書の学習で先頭候補が当たりやすくなったことを踏まえた設定。1にすると
---  従来通り最初の <SPC> でウィンドウも同時に表示する）。デフォルト 2。
---@field user_dictionary string? 個人辞書（学習結果）ファイルのパス。文字コードは常にUTF-8固定
---  （skkeleton の userDictionary の慣習に合わせている）。ファイルが無ければ自動的に作られる。
---  デフォルト "~/.local/share/skk/SKK-JISYO.user"（skkeleton と同じ慣習のパス）。
---@field skkserv { host: string, port: integer?, encoding: string?, timeout_ms: integer?, debug: boolean? }? SKKサーバー
---  （skkserv/dbskkd-cdb/yaskkserv2 等）への接続設定。省略時は無効（skkserv を使わない）。
---  host は必須。port は省略時 1178。encoding は省略時 "euc-jp"（サーバーとの通信に使う
---  文字コード。伝統的な skkserv は EUC-JP が主流）。timeout_ms は1回の検索の待ち時間上限
---  （省略時 300）。debug は送受信の生データを vim.notify() で出力するか（省略時 false）。
---  個人辞書の次、ローカル辞書より先にマージされる。
---@field blink { max_items: integer }? blink.cmp ネイティブソース（lua/skk/blink_source.lua）の
---  設定。`▽` 見出し語入力中の前方一致ライブ補完で、1回の検索あたり何件までアイテムを
---  出すか。デフォルト 50。ソース自体の登録（blink.cmp の setup() の sources.providers）は
---  ユーザーの設定側で行う必要がある（README.md の「blink.cmp 連携」参照）。

--- ▽/▼ 表示用のハイライトグループのデフォルトを定義する。
--- 既にユーザーやカラースキームが定義済みなら上書きしない (default = true)。
local function setup_highlights()
  vim.api.nvim_set_hl(0, "SkkHenkanMidashi", { default = true, link = "Comment" })
  vim.api.nvim_set_hl(0, "SkkHenkanCandidate", { default = true, link = "IncSearch" })
end

---@param opts SkkSetupOpts|nil
function M.setup(opts)
  opts = opts or {}
  local enter_key = opts.enter_key or "<C-j>"
  local user_dictionary = opts.user_dictionary or vim.fn.expand("~/.local/share/skk/SKK-JISYO.user")

  setup_highlights()
  capture.setup({
    sticky_shift_enabled = opts.sticky_shift_enabled,
    sticky_shift_key = opts.sticky_shift_key,
    egg_like_newline = opts.egg_like_newline,
  })
  candidate_window.setup(opts.candidate_window or {})
  henkan_state.setup({
    candidate_window_threshold = opts.candidate_window and opts.candidate_window.threshold or nil,
  })
  dict.set_user_dict_path(user_dictionary)
  if opts.skkserv then
    dict.set_skkserv(opts.skkserv)
  end

  -- blink.cmp ネイティブソースの設定だけここで受け取る（ソース自体の
  -- require はしない。blink.cmp が入っていない環境でも require("skk").setup()
  -- がエラーにならないようにするため。実際の require は blink.cmp が
  -- ソースを呼び出す時点、つまり blink_source.lua 自身の中で遅延して行う）。
  if opts.blink then
    local ok, blink_source = pcall(require, "skk.blink_source")
    if ok then
      blink_source.setup(opts.blink)
    end
  end

  local function notify_mode()
    vim.notify("skk.nvim: " .. capture.mode_label())
  end

  vim.keymap.set({ "i", "c" }, enter_key, function()
    -- henkan (▽/▼) がアクティブな間は、<C-j> も <CR> と同じ「確定」として扱う。
    -- （現時点では henkan はバッファ限定なので、コマンドラインでは常に
    -- capture.transition() 側のモード切替のみが働く）
    if henkan_state.is_active() then
      henkan_state.confirm()
      return
    end
    if capture.transition(enter_key) then
      notify_mode()
    end
  end, { desc = "skk.nvim: enter hiragana mode / confirm henkan" })

  vim.api.nvim_create_user_command("SkkMode", function()
    notify_mode()
  end, {})
end

return M

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

--- setup({ skkserv = {...} }) で渡された設定を覚えておく（:SkkCheckSkkserv
--- コマンドから再利用するため）。skkserv 未設定なら nil のまま。
---@type { host: string, port: integer? }|nil
local last_skkserv_opts = nil

---@class SkkSetupOpts
---@field enter_key string? 半角英数/全角英数 -> ひらがな。henkan 中は確定。デフォルト "<C-j>"
---@field sticky_shift_enabled boolean? Sticky-shift（大文字キーを使わずに ▽開始・送り開始点を
---  指示する操作）の有効/無効。デフォルト true。
---@field sticky_shift_key string? Sticky-shift のトリガーキー。デフォルト ";"。
---  sticky_shift_enabled=false のときは無視される。
---@field egg_like_newline boolean? true: ▼状態での <CR> は確定のみ行い、改行は挿入しない
---  （skk.nvimのデフォルト）。false: 確定に加えて改行も挿入する（SKK本来の動作）。デフォルト true。
---@field candidate_window { border: string|string[], annotation: boolean, page_indicator: boolean, threshold: integer, fg: string?, bg: string?, border_fg: string?, border_bg: string?, alt_fg: string?, alt_bg: string? }? 候補一覧ウィンドウの見た目・表示タイミング。
---  border は nvim_open_win() の "border" と同じ形式（"rounded"/"single"/"double"/
---  "none"/自前の文字配列 等）。デフォルト "rounded"。
---  annotation: 辞書の注釈（";注釈"）を候補一覧に表示するか。デフォルト true。
---  page_indicator: 最下行に "現在ページ/全ページ数"（例: "2/3"）を表示するか。デフォルト true。
---  threshold: ▼開始後、<SPC> を何回打鍵した時点で候補一覧ウィンドウを表示するか。
---  それまでは inline の ▼候補 表示で1件ずつ候補を送るだけでウィンドウは出さない
---  （個人辞書の学習で先頭候補が当たりやすくなったことを踏まえた設定。1にすると
---  従来通り最初の <SPC> でウィンドウも同時に表示する）。デフォルト 2。
---  fg/bg: 非選択の候補行の文字色・背景色（ハイライトグループ SkkCandidateWindowNormal）。
---  省略時はカラースキームの NormalFloat のまま（＝現状と同じ）。
---  border_fg/border_bg: 枠線の色（ハイライトグループ SkkCandidateWindowBorder）。
---  省略時はカラースキームの FloatBorder のまま（＝現状と同じ）。
---  alt_fg/alt_bg: 非選択の候補行を1行おきに変える色（可読性向上のための縞模様。
---  ハイライトグループ SkkCandidateWindowNormalAlt）。省略時は fg/bg と同じ（＝縞なし、現状と同じ）。
---  選択中の行の色は候補window固有ではなく、下記 candidate_fg/candidate_bg（SkkHenkanCandidate、
---  ▼インライン表示と共通）で指定する。
---@field midashi_fg string? ▽（見出し語入力中）のインライン表示の文字色（ハイライトグループ
---  SkkHenkanMidashi。abbrev モードの表示にも使われる）。省略時はカラースキームの Comment
---  のまま（＝現状と同じ）。
---@field midashi_bg string? 同上の背景色。省略時は現状と同じ。
---@field candidate_fg string? ▼（変換候補）のインライン表示の文字色（ハイライトグループ
---  SkkHenkanCandidate）。候補一覧ウィンドウの選択中の行のハイライトにも同じグループが
---  使われるため、両方に効く。省略時はカラースキームの IncSearch のまま（＝現状と同じ）。
---@field candidate_bg string? 同上の背景色。省略時は現状と同じ。
---@field user_dictionary string? 個人辞書（学習結果）ファイルのパス。文字コードは常にUTF-8固定
---  （skkeleton の userDictionary の慣習に合わせている）。ファイルが無ければ自動的に作られる。
---  デフォルト "~/.local/share/skk/SKK-JISYO.user"（skkeleton と同じ慣習のパス）。
---@field skkserv { host: string, port: integer?, encoding: string?, timeout_ms: integer?, debug: boolean?, check_connection: boolean?, check_connection_timeout_ms: integer? }? SKKサーバー
---  （skkserv/dbskkd-cdb/yaskkserv2 等）への接続設定。省略時は無効（skkserv を使わない）。
---  host は必須。port は省略時 1178。encoding は省略時 "euc-jp"（サーバーとの通信に使う
---  文字コード。伝統的な skkserv は EUC-JP が主流）。timeout_ms は1回の検索の待ち時間上限
---  （省略時 300）。debug は送受信の生データを vim.notify() で出力するか（省略時 false）。
---  個人辞書の次、ローカル辞書より先にマージされる。
---  check_connection: true（既定）だと、setup() 完了後（起動直後のイベントループの混雑を
---  避けるため少し遅らせてから、vim.defer_fn 越しに実行。setup() 自体は従来通り
---  ネットワークI/Oを行わない）に一度だけ疎通確認を行い、接続できなければ
---  vim.notify()（WARN）で host:port・status・エラー詳細を知らせる（正常なら何も表示しない）。
---  1回失敗しても即座に警告は出さず、少し待ってもう1回だけ試してから最終判断する
---  （大きな辞書ファイルの読み込み中等、健全な接続でも一過性に間に合わないことがあるため）。
---  false にすると疎通確認自体を行わない。手動で再確認したい場合は :SkkCheckSkkserv コマンドも使える。
---  check_connection_timeout_ms: この疎通確認1回あたりのタイムアウト（省略時 2000。通常の
---  検索が使う timeout_ms とは別。起動直後は余裕を持たせている）。
---@field blink { max_items: integer?, skip_skkserv: boolean?, skkserv_candidates: boolean?, skkserv_candidate_limit: integer?, debug_timing: boolean? }?
---  blink.cmp ネイティブソース（lua/skk/blink_source.lua）の設定。`▽`/`▼` 見出し語入力中の
---  前方一致ライブ補完（実際の変換候補=漢字まで表示する。Phase 2）で使う。
---  - max_items: 前方一致で取得する読みの上限件数（デフォルト 50）
---  - skip_skkserv: 読み一覧の取得（"4"コマンド）にSKKサーバーを含めるか（デフォルト false。
---    含める。skkeleton と同様）
---  - skkserv_candidates: 実際の変換候補の取得（"1"コマンド）にSKKサーバーを含めるか
---    （デフォルト true）。false にすると個人辞書・ローカル辞書の候補のみになる
---  - skkserv_candidate_limit: SKKサーバーへ実際に"1"を投げる読みの上限件数（デフォルト 20。
---    skkserv_candidates=true のときのみ意味を持つ。増やすほどライブ補完メニューの下の方まで
---    漢字候補が出る代わりにキー入力ごとの直列往復が増える。SKKサーバー自身の "4" 応答に
---    含まれていた読みにしか"1"を投げない設計だが、これだけではnotfoundフォールバックを完全には
---    防げないことが実機で判明した（下記参照）。追加の防御として、SKKのプログラム候補構文で
---    使われる文字（"(" ")" '"' "\\"）を含む読みへは、from_skkservに入っていてもSKKサーバーへの
---    "1"を送らない（詳細はlua/skk/blink_source.luaのlooks_safe_for_skkserv_lookup()、および
---    README.md「SKKサーバーとの通信の信頼性」参照）
---  - debug_timing: get_completions() 1回あたりの所要時間（SKKサーバーへの実際の呼び出し回数
---    skkserv_calls も含む）を vim.notify() に出す調査用オプション（デフォルト false）
---
---  ソース自体の登録（blink.cmp の setup() の sources.providers）はユーザーの設定側で行う
---  必要がある（README.md の「blink.cmp ネイティブソース統合」参照）。
---@field dictionaries { path: string, encoding: string?, name: string? }[]? ローカル辞書ファイルの
---  一覧。登録順が優先順位になる（先に書いたものが優先される。個人辞書・skkserv の次に
---  マージされる）。各エントリの encoding は省略時 "euc-jp"。name は省略時 path
---  （dict.add_dictionary_async() のソース名にそのまま渡る）。読み込みは M.setup() を
---  呼んだ時点で非同期に開始され、起動をブロックしない。結果は on_dictionary_loaded
---  で受け取れる。
---@field on_dictionary_loaded fun(path: string, ok: boolean, err: string|nil)? dictionaries の
---  各エントリの読み込みが完了するたびに呼ばれる（成功・失敗いずれも）。vim.notify() 等で
---  進捗を表示したい場合に使う（省略可）。

--- ▽/▼ 表示用のハイライトグループのデフォルトを定義する。
--- opts.midashi_fg/midashi_bg/candidate_fg/candidate_bg のいずれかが
--- 指定されていれば、そのグループはリンクではなく直接その色で定義する
--- （明示的に指定した色を優先する）。指定が無いグループは、これまで通り
--- 既にユーザーやカラースキームが定義済みなら上書きしない (default = true)
--- リンクのままにする。
---@param opts { midashi_fg: string?, midashi_bg: string?, candidate_fg: string?, candidate_bg: string? }
local function setup_highlights(opts)
  if opts.midashi_fg or opts.midashi_bg then
    vim.api.nvim_set_hl(0, "SkkHenkanMidashi", { fg = opts.midashi_fg, bg = opts.midashi_bg })
  else
    vim.api.nvim_set_hl(0, "SkkHenkanMidashi", { default = true, link = "Comment" })
  end
  if opts.candidate_fg or opts.candidate_bg then
    vim.api.nvim_set_hl(0, "SkkHenkanCandidate", { fg = opts.candidate_fg, bg = opts.candidate_bg })
  else
    vim.api.nvim_set_hl(0, "SkkHenkanCandidate", { default = true, link = "IncSearch" })
  end
end

--- 疎通確認のデフォルトタイムアウト（ミリ秒）。通常のライブ補完等が使う
--- config.timeout_ms（既定300ms）とは別に、こちらは長めに取っている
--- （【実機で発見】Neovim起動直後・大きな辞書ファイルの読み込み中は
--- イベントループが混み合っており、実際には健全な接続でも300msでは
--- 間に合わずタイムアウトしてしまうことがあった。ライブ補完やskkservで
--- の変換自体は普通に成功するのに、起動直後の疎通確認だけ
--- "接続できませんでした" と誤って警告してしまう不具合として発現した）。
local DEFAULT_CHECK_CONNECTION_TIMEOUT_MS = 2000
--- 上記と同じ理由で、1回目が失敗しても即座に警告を出さず、これだけ
--- 待ってからもう1回だけ試す（それでも失敗したら本当に繋がっていない
--- と判断する）。
local CHECK_CONNECTION_RETRY_DELAY_MS = 300

--- SKKサーバーへの疎通確認を行い、接続できなければ vim.notify()（WARN）で
--- 知らせる。正常に接続できたときの挙動は silent_on_success で切り替える
--- （setup() からの自動チェックは既存の nvim-skk-sandbox の
--- check_skkserv() に合わせて成功時は何も表示しない。:SkkCheckSkkserv
--- コマンドからの手動実行では、成功したことも分かるようにバージョン
--- 文字列を表示する）。ネットワークI/Oを伴い、失敗時は最大で
--- タイムアウト2回分+再試行の待ち時間だけ Neovim をブロックしうるため、
--- 呼び出し側で vim.schedule()/vim.defer_fn() 越しに呼ぶこと（setup()
--- 自体はネットワークI/Oを行わない設計を崩さないため）。
--- last_skkserv_opts が nil（skkserv 未設定）なら何もしない。
---@param silent_on_success boolean|nil 省略時 true
local function check_skkserv_connection(silent_on_success)
  if silent_on_success == nil then
    silent_on_success = true
  end
  if not last_skkserv_opts then
    return
  end
  local timeout_ms = last_skkserv_opts.check_connection_timeout_ms or DEFAULT_CHECK_CONNECTION_TIMEOUT_MS
  local version = dict.skkserv_version(timeout_ms)
  if not version then
    -- 起動直後の一過性の混雑を疑い、少し待ってもう1回だけ試す。
    vim.wait(CHECK_CONNECTION_RETRY_DELAY_MS)
    version = dict.skkserv_version(timeout_ms)
  end
  if version then
    if not silent_on_success then
      vim.notify("skk.nvim: skkserv version: " .. version)
    end
    return
  end
  local detail = dict.skkserv_last_connect_error()
  vim.notify(
    string.format(
      "skk.nvim: skkserv に接続できませんでした (%s:%s)。status=%s%s。"
        .. "ホスト/ポート、サーバーの起動状態を確認してください。",
      last_skkserv_opts.host,
      tostring(last_skkserv_opts.port or 1178),
      dict.skkserv_status(),
      detail and (" error=" .. tostring(detail)) or ""
    ),
    vim.log.levels.WARN
  )
end

---@param opts SkkSetupOpts|nil
function M.setup(opts)
  opts = opts or {}
  local enter_key = opts.enter_key or "<C-j>"
  local user_dictionary = opts.user_dictionary or vim.fn.expand("~/.local/share/skk/SKK-JISYO.user")

  setup_highlights(opts)
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
    last_skkserv_opts = opts.skkserv
    local check_connection = opts.skkserv.check_connection
    if check_connection == nil then
      check_connection = true
    end
    if check_connection then
      -- setup() 自体はネットワークI/Oを行わない設計（dict/skkserv.lua の
      -- M.setup() のコメント参照）を崩さないよう、実際の疎通確認は
      -- vim.schedule() で1フレーム遅らせる（Neovim起動をブロックしない）。
      -- pcall で包み、疎通確認自体で予期しないエラーが起きても setup()
      -- 全体には影響させない（nvim-skk-sandbox の check_skkserv() を
      -- 本体に取り込んだもの。元は開発用サンドボックス限定の機能だった）。
      -- 【実機で発見】即座（vim.schedule、実質次フレーム）に投げると、
      -- Neovim起動直後・大きな辞書ファイルの読み込み中でイベントループが
      -- 混み合っている場合があり、健全な接続でも誤ってタイムアウト扱い
      -- してしまうことがあった。少し起動が落ち着くのを待ってから投げる
      -- （それでも駄目なら check_skkserv_connection() 内部でさらに1回
      -- 再試行する。上記コメント参照）。
      vim.defer_fn(function()
        pcall(check_skkserv_connection)
      end, 300)
    end
  end

  -- ローカル辞書ファイルの読み込み。登録順（呼んだ順）が優先順位になる
  -- （add_dictionary_async() 自体がその保証をしている。詳細は
  -- lua/skk/dict/init.lua の add_dictionary_async() のコメント参照）。
  if opts.dictionaries then
    for _, entry in ipairs(opts.dictionaries) do
      dict.add_dictionary_async(entry.path, entry.encoding, function(ok, err)
        if opts.on_dictionary_loaded then
          opts.on_dictionary_loaded(entry.path, ok, err)
        end
      end, nil, entry.name)
    end
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

  vim.api.nvim_create_user_command("SkkCheckSkkserv", function()
    if not last_skkserv_opts then
      vim.notify("skk.nvim: skkserv は設定されていません（setup({ skkserv = {...} }) 参照）")
      return
    end
    check_skkserv_connection(false)
  end, { desc = "skk.nvim: SKKサーバーへの疎通確認を手動で実行する" })
end

return M

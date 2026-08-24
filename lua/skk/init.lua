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
local candidate_nav = require("skk.candidate_nav")
local mode_indicator = require("skk.mode_indicator")
local dict = require("skk.dict")

local M = {}

--- setup({ skkserv = {...} }) で渡された設定を覚えておく（:SkkCheckSkkserv
--- コマンドから再利用するため）。skkserv 未設定なら nil のまま。
---@type { host: string, port: integer? }|nil
local last_skkserv_opts = nil

---@class SkkSetupOpts
---@field enter_key string? 半角英数/全角英数 -> ひらがな。henkan 中は確定。デフォルト "<C-j>"
---  buffer_enter_key/cmdline_enter_key を省略した場合の既定値としても使われる
---  （バッファ・コマンドラインどちらも変えなくてよい場合はこれだけ指定すればよい）。
---@field buffer_enter_key string? 通常バッファでの enter_key。省略時は enter_key の値
---  （さらに省略時 "<C-j>"）。他プラグイン（skkeleton 等）と揃えたい・キーが競合する
---  場合等、バッファとコマンドラインで別のキーにしたいときに指定する。
---@field cmdline_enter_key string? コマンドラインモードでの enter_key。省略時は
---  enter_key の値（さらに省略時 "<C-j>"）。
---@field char_key_to_ascii string? ひらがな/カタカナ -> 半角英数。デフォルト "l"。
---@field char_key_to_kata_or_hira string? ひらがな<->カタカナの相互遷移。デフォルト "q"。
---@field char_key_to_zenei string? ひらがな/カタカナ -> 全角英数。デフォルト "L"。
---  この3つは l/q/L と同様、未確定のローマ字バッファが空のときに限り
---  モード切替キーとして扱われる（バッファが空でなければ通常のローマ字/
---  全角変換入力として処理される。全角英数モードでは常にモード切替
---  キーとしては扱われず、そのまま全角文字に変換される）。
---@field abbrev_key string? abbrevモード（ASCII文字列そのものを見出しにする変換）を
---  開始するキー。デフォルト "/"。
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
---@field candidate_navigation { enabled: boolean?, next_key: string?, prev_key: string? }? 候補一覧
---  ウィンドウ表示中の <C-n>/<C-p> によるフォーカス移動。
---  【なぜ必要か】この移動は元々 vim.on_key() だけで処理していたが、blink.cmp 等の補完
---  プラグインが挿入モードに <C-n>/<C-p> の実キーマップ（nvim_buf_set_keymap /
---  nvim_set_keymap）を張っている環境では、そちらが vim.on_key() より先にキーを
---  消費してしまい、henkan の ▼(select) フェーズ中でもフォーカスが動かない不具合が
---  実機で確認された。そのため enter_key（<C-j> 等）と同様、ここだけ実際の
---  vim.keymap.set() を使う。
---  setup() を呼んだ時点で next_key/prev_key に既に張られているマッピング（他プラグイン
---  のもの）を読み取って保存しておき、▼(select) フェーズ以外のときはそのまま委譲する
---  （blink.cmp の補完メニュー選択などを壊さない）。そのため、blink.cmp 等の setup() は
---  require("skk").setup() より前に呼んでおく必要がある。
---  enabled: false にするとこのキーマップ自体を張らない（従来通り vim.on_key() のみに
---  委ねる）。デフォルト true。
---  next_key/prev_key: デフォルト "<C-n>"/"<C-p>"。
---@field midashi_fg string? ▽（見出し語入力中）のインライン表示の文字色（ハイライトグループ
---  SkkHenkanMidashi。abbrev モードの表示にも使われる）。省略時はカラースキームの Comment
---  のまま（＝現状と同じ）。
---@field midashi_bg string? 同上の背景色。省略時は現状と同じ。
---@field candidate_fg string? ▼（変換候補）のインライン表示の文字色（ハイライトグループ
---  SkkHenkanCandidate）。候補一覧ウィンドウの選択中の行のハイライトにも同じグループが
---  使われるため、両方に効く。省略時はカラースキームの IncSearch のまま（＝現状と同じ）。
---@field candidate_bg string? 同上の背景色。省略時は現状と同じ。
---@field indicator_fg string? モード切替時にカーソル位置へ一瞬表示するインジケーター
---  （ひら/カタ/latn/ＬＡ、mode_indicator.lua）の文字色（ハイライトグループ
---  SkkModeIndicator）。省略時はカラースキームの NormalFloat のまま（＝現状と同じ）。
---@field indicator_bg string? 同上の背景色。省略時は現状と同じ。
---@field notify_mode_change boolean? モード切替・henkan確定のたびに vim.notify("skk.nvim: <モード名>")
---  を呼ぶかどうか。デフォルト true（現状の挙動）。noice.nvim 等の通知UIを使っている場合、
---  <C-j> の度に通知ウィンドウが開いて煩わしいことがあるため false で無効化できる。
---  カーソル位置に一瞬表示されるインジケーター（indicator_fg/indicator_bg）はこのオプションと
---  独立しており、false にしても表示され続ける。
---@field user_dictionary string? 個人辞書（学習結果）ファイルのパス。文字コードは常にUTF-8固定
---  （skkeleton の userDictionary の慣習に合わせている）。ファイルが無ければ自動的に作られる。
---  デフォルト "~/.local/share/skk/SKK-JISYO.user"（skkeleton と同じ慣習のパス）。
---@field skkserv { host: string, port: integer?, encoding: string?, timeout_ms: integer?, debug: boolean?, check_connection: boolean?, check_connection_timeout_ms: integer? }? SKKサーバー
---  （skkserv/dbskkd-cdb/yaskkserv2 等）への接続設定。省略時は無効（skkserv を使わない）。
---  host は必須。port は省略時 1178。encoding は省略時 "euc-jp"（サーバーとの通信に使う
---  文字コード。伝統的な skkserv は EUC-JP が主流）。timeout_ms は1回の検索の待ち時間上限
---  （省略時 300）。debug は送受信の生データを vim.notify() で出力するか（省略時 false）。
---  個人辞書の次、ローカル辞書より先にマージされる。
---  check_connection: false（既定）だと起動時の自動疎通確認を行わない。
---  true にすると、setup() 完了後（起動直後のイベントループの混雑を
---  避けるため少し遅らせてから、vim.defer_fn 越しに実行。setup() 自体は従来通り
---  ネットワークI/Oを行わない）に一度だけ疎通確認を行い、接続できなければ
---  vim.notify()（WARN）で host:port・status・エラー詳細を知らせる（正常なら何も表示しない）。
---  1回失敗しても即座に警告は出さず、少し待ってもう1回だけ試してから最終判断する
---  （大きな辞書ファイルの読み込み中等、健全な接続でも一過性に間に合わないことがあるため）。
---  【実機で発見】この自動疎通確認は vim.defer_fn 越し・ネットワークI/Oも非同期なので、
---  Neovim自体の起動完了（インタラクティブになるまでの時間）を直接ブロックすることは無い。
---  ただし失敗時の再試行等でしばらく裏でイベントループを回し続けるため、体感の"落ち着くまでの
---  時間"が気になる場合や、接続が安定していて手動確認（:SkkCheckSkkserv）で十分な場合は
---  既定の false のままにしておくとよい。
---  check_connection_timeout_ms: この疎通確認1回あたりのタイムアウト（省略時 2000。通常の
---  検索が使う timeout_ms とは別。起動直後は余裕を持たせている）。check_connection=false
---  のときは意味を持たない。
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

-- 【実機からの要望】他プラグインとの連携（外部から SKK の有効/無効を
-- 制御したい場合）を見込んで、skkeleton の <Plug>(skkeleton-enable) 等に
-- 相当する API を用意する。skk.nvim には skkeleton のような「本体ごと
-- 無効化する」独立したON/OFFスイッチは無く、代わりに ascii モード
-- （キー入力を完全パススルーする、"SKKが事実上OFF"の状態）がその役割を
-- 果たす設計になっている。そのため:
--   enable()  = ひらがなモードへ遷移する（enter_key相当。skkeleton-enable）
--   disable() = 半角英数モードへ遷移する。henkanが進行中なら先に
--               キャンセルする（skkeleton-disable。中途半端な▽/▼状態の
--               まま無効化しない）
--   toggle()  = 現在 ascii モードなら enable()、それ以外なら disable()
--               （skkeleton-toggle）
-- capture.set_mode() を使い、l/q/L・enter_key の遷移テーブル定義とは
-- 独立に、直接モードを指定して切り替える。

--- ひらがなモードへ遷移する（skkeleton の <Plug>(skkeleton-enable) 相当）。
function M.enable()
  capture.set_mode("hira")
  vim.notify("skk.nvim: " .. capture.mode_label())
end

--- 半角英数モードへ遷移する（skkeleton の <Plug>(skkeleton-disable) 相当）。
--- henkan（▽/▼）が進行中であれば、中途半端な状態を残さないよう先に
--- キャンセルする。
function M.disable()
  if henkan_state.is_active() then
    henkan_state.cancel()
  end
  capture.set_mode("ascii")
  vim.notify("skk.nvim: " .. capture.mode_label())
end

--- 現在 ascii モード（SKKが事実上OFFの状態）なら M.enable()、そうでなければ
--- M.disable() を呼ぶ（skkeleton の <Plug>(skkeleton-toggle) 相当）。
function M.toggle()
  if capture.get_mode() == "ascii" then
    M.enable()
  else
    M.disable()
  end
end

--- 現在 ascii モード（SKKが事実上OFFの状態）でなければ true を返す。
--- 他プラグインが現在の有効/無効状態を問い合わせたい場合向け。
---@return boolean
function M.is_enabled()
  return capture.get_mode() ~= "ascii"
end

--- henkan（▽/▼/abbrev）がアクティブなら <CR> 相当の確定処理を行い、true を
--- 返す。非アクティブなら何もせず false を返す。blink.cmp 等、外部の補完UI
--- が自身の <CR> キーマップ（accept/fallback 等）から、henkan確定を
--- 同期的・確実にトリガーしたい場合に使う（vim.on_key() のタイミングに
--- 依存せずに済む）。詳細・使用例は lua/skk/capture.lua の
--- M.confirm_henkan_if_active() のコメントを参照。
---@return boolean confirmed
function M.confirm_henkan()
  return capture.confirm_henkan_if_active()
end

--- setup({ skkserv = {...} }) に渡された設定のコピーを返す（診断用。
--- lua/skk/health.lua の :checkhealth skk から使う）。フィールドは
--- SkkSetupOpts の skkserv と同じ（本ファイル冒頭参照）。skkserv 未設定なら nil。
---@return table|nil
function M.get_skkserv_opts()
  if not last_skkserv_opts then
    return nil
  end
  return vim.deepcopy(last_skkserv_opts)
end

---@param opts SkkSetupOpts|nil
function M.setup(opts)
  opts = opts or {}
  local default_enter_key = opts.enter_key or "<C-j>"
  local buffer_enter_key = opts.buffer_enter_key or default_enter_key
  local cmdline_enter_key = opts.cmdline_enter_key or default_enter_key
  -- mode.lua に登録する制御キーの一覧（重複は除く）。バッファ用・
  -- コマンドライン用が同じキーなら1件だけになる。
  local ctrl_keys = { buffer_enter_key }
  if cmdline_enter_key ~= buffer_enter_key then
    table.insert(ctrl_keys, cmdline_enter_key)
  end
  local user_dictionary = opts.user_dictionary or vim.fn.expand("~/.local/share/skk/SKK-JISYO.user")

  setup_highlights(opts)
  capture.setup({
    sticky_shift_enabled = opts.sticky_shift_enabled,
    sticky_shift_key = opts.sticky_shift_key,
    egg_like_newline = opts.egg_like_newline,
    char_key_to_ascii = opts.char_key_to_ascii,
    char_key_to_kata_or_hira = opts.char_key_to_kata_or_hira,
    char_key_to_zenei = opts.char_key_to_zenei,
    abbrev_key = opts.abbrev_key,
    ctrl_keys = ctrl_keys,
    period = opts.period,
    comma = opts.comma,
  })
  candidate_window.setup(opts.candidate_window or {})
  mode_indicator.setup({ fg = opts.indicator_fg, bg = opts.indicator_bg })
  henkan_state.setup({
    candidate_window_threshold = opts.candidate_window and opts.candidate_window.threshold or nil,
  })
  dict.set_user_dict_path(user_dictionary)
  if opts.skkserv then
    dict.set_skkserv(opts.skkserv)
    last_skkserv_opts = opts.skkserv
    local check_connection = opts.skkserv.check_connection
    if check_connection == nil then
      check_connection = false
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

  -- デフォルト true（現状の挙動を維持）。false ならモード切替・henkan確定
  -- 時の vim.notify() を出さない。
  local notify_mode_change = opts.notify_mode_change
  if notify_mode_change == nil then
    notify_mode_change = true
  end

  local function notify_mode()
    if not notify_mode_change then
      return
    end
    vim.notify("skk.nvim: " .. capture.mode_label())
  end

  -- 【実機で発見】候補一覧ウィンドウ表示中に <C-n>/<C-p> でフォーカスが動かない
  -- 不具合の原因は、blink.cmp 等が挿入モードに <C-n>/<C-p> の実キーマップを
  -- 張っており、vim.on_key() より先にキーを消費してしまうこと。
  -- 判定ロジック本体は lua/skk/candidate_nav.lua（vim.* 非依存、単体テスト対象）
  -- に切り出してあり、ここでは setup() 時点で既存マッピングを1回だけ捕捉し、
  -- 実際の副作用（feedkeys 等）だけを行う。
  ---@param key string
  ---@param candidate_action fun()
  local function setup_candidate_nav_key(key, candidate_action)
    -- vim.fn.maparg(..., dict=true) は無ければ空 table を返す（エラーにはならない）。
    local existing = vim.fn.maparg(key, "i", false, true)

    vim.keymap.set("i", key, function()
      local result = candidate_nav.resolve(henkan_state.get_phase(), existing)

      if result.kind == "candidate" then
        candidate_action()
      elseif result.kind == "callback" then
        result.callback()
      elseif result.kind == "expr_callback" then
        local ok, expr_result = pcall(result.callback)
        if ok and type(expr_result) == "string" and expr_result ~= "" then
          local keys = result.replace_keycodes and vim.api.nvim_replace_termcodes(expr_result, true, false, true)
            or expr_result
          vim.api.nvim_feedkeys(keys, result.noremap and "n" or "m", false)
        end
      elseif result.kind == "rhs" then
        local keys = vim.api.nvim_replace_termcodes(result.rhs, true, false, true)
        vim.api.nvim_feedkeys(keys, result.noremap and "n" or "m", false)
      elseif result.kind == "expr_rhs" then
        local ok, expr_result = pcall(vim.fn.eval, result.rhs)
        if ok and type(expr_result) == "string" and expr_result ~= "" then
          local keys = vim.api.nvim_replace_termcodes(expr_result, true, false, true)
          vim.api.nvim_feedkeys(keys, result.noremap and "n" or "m", false)
        end
      else -- "passthrough"
        local raw = vim.api.nvim_replace_termcodes(key, true, false, true)
        vim.api.nvim_feedkeys(raw, "n", false)
      end
    end, { desc = "skk.nvim: henkan候補選択(" .. key .. ") / 非選択中は元のマッピングへ委譲" })
  end

  local candidate_nav_opts = opts.candidate_navigation or {}
  local candidate_nav_enabled = candidate_nav_opts.enabled
  if candidate_nav_enabled == nil then
    candidate_nav_enabled = true
  end
  if candidate_nav_enabled then
    setup_candidate_nav_key(candidate_nav_opts.next_key or "<C-n>", henkan_state.focus_next)
    setup_candidate_nav_key(candidate_nav_opts.prev_key or "<C-p>", henkan_state.focus_prev)
  end

  -- enter_key（henkan中の確定 / ascii・zenei -> hira への遷移）。バッファと
  -- コマンドラインで別キーを設定できるよう、2つに分けて登録する
  -- （buffer_enter_key/cmdline_enter_key が同じキーの場合も、単に同じ
  -- キーへ2回登録されるだけで害はない）。henkan (▽/▼) は現在バッファ・
  -- コマンドラインどちらでもアクティブになりうるので、どちらの登録でも
  -- 同じ判定（henkan中なら確定、そうでなければモード遷移）を行う。
  ---@param key string
  local function make_enter_key_handler(key)
    return function()
      if henkan_state.is_active() then
        henkan_state.confirm()
        return
      end
      if capture.transition(key) then
        notify_mode()
      end
    end
  end

  vim.keymap.set("i", buffer_enter_key, make_enter_key_handler(buffer_enter_key), {
    desc = "skk.nvim: enter hiragana mode / confirm henkan (buffer)",
  })
  vim.keymap.set("c", cmdline_enter_key, make_enter_key_handler(cmdline_enter_key), {
    desc = "skk.nvim: enter hiragana mode / confirm henkan (cmdline)",
  })

  vim.api.nvim_create_user_command("SkkMode", function()
    notify_mode()
  end, {})

  vim.api.nvim_create_user_command("SkkEnable", function()
    M.enable()
  end, { desc = "skk.nvim: ひらがなモードへ遷移する" })

  vim.api.nvim_create_user_command("SkkDisable", function()
    M.disable()
  end, { desc = "skk.nvim: 半角英数モードへ遷移する（henkan中なら先にキャンセル）" })

  vim.api.nvim_create_user_command("SkkToggle", function()
    M.toggle()
  end, { desc = "skk.nvim: 現在asciiモードならSkkEnable、そうでなければSkkDisable相当" })

  vim.api.nvim_create_user_command("SkkCheckSkkserv", function()
    if not last_skkserv_opts then
      vim.notify("skk.nvim: skkserv は設定されていません（setup({ skkserv = {...} }) 参照）")
      return
    end
    check_skkserv_connection(false)
  end, { desc = "skk.nvim: SKKサーバーへの疎通確認を手動で実行する" })

  vim.api.nvim_create_user_command("SkkDictionaries", function()
    local loaded = dict.loaded_dictionaries()
    if #loaded == 0 then
      vim.notify(
        "skk.nvim: 読み込まれたローカル辞書はありません（setup({ dictionaries = {...} }) 等を参照）"
      )
      return
    end
    local lines = {}
    for _, info in ipairs(loaded) do
      local label = info.path or info.name
      if info.ok then
        table.insert(
          lines,
          string.format("[%s] OK   %s%s", info.loaded_at, label, info.encoding and (" (" .. info.encoding .. ")") or "")
        )
      else
        table.insert(lines, string.format("[%s] FAIL %s: %s", info.loaded_at, label, tostring(info.err)))
      end
    end
    vim.notify("skk.nvim: 読み込み済みのローカル辞書\n" .. table.concat(lines, "\n"))
  end, {
    desc = "skk.nvim: setup({ dictionaries = {...} }) 等で読み込んだローカル辞書の一覧を表示する",
  })
end

return M

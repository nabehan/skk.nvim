-- lua/skk/capture.lua
--
-- vim.on_key() を使って挿入モードのキー入力を横取りし、モードに応じて
-- ローマ字→かな/カタカナ変換・全角変換を行うキャプチャ層。
--
-- 【モードとキー遷移】
--   半角英数 --<C-j>--> ひらがな
--   全角英数 --<C-j>--> ひらがな
--   ひらがな --l-->     半角英数
--   ひらがな --q-->     カタカナ
--   ひらがな --L-->     全角英数
--   カタカナ --l-->     半角英数
--   カタカナ --q-->     ひらがな
--   カタカナ --L-->     全角英数
--
-- `l`/`q`/`L` は印字可能文字なので vim.on_key() のコールバック内で
-- 特別扱いする。`<C-j>` は制御キーなので lua/skk/init.lua が
-- 通常の vim.keymap.set 経由で M.transition() を呼び出す。
--
-- 【設計上の制約】
-- - `l`/`q`/`L` によるモード切替は、未確定のローマ字バッファが空の
--   ときだけ有効にする（ローマ字入力の途中に紛れ込んだ場合は通常の
--   ローマ字入力として処理する）。
-- - 全角英数モードでは `l`/`q`/`L` を含む全ての印字可能ASCII文字を
--   そのまま全角に変換する（モード切替キーとしては扱わない。
--   「全角英数モードで q を打ったら ｑ にならないといけない」という
--   指摘のとおり）。
-- - 半角カナモードは検討したが、ターミナルエミュレーターの動作が
--   不安定になる事例が確認されたため実装しない方針とした。
--
-- 【henkan（▽/▼、漢字変換）との連携】
-- ひらがな/カタカナモードで、未確定バッファが空の状態で大文字キーが
-- 来ると lua/skk/henkan/state.lua の ▽ を開始する。henkan がアクティブな
-- 間は、直接入力の処理には一切進まず handle_henkan_key() へ全キーを
-- 委譲する（<CR>=確定 / <BS>=読み取り消し / <C-g>=キャンセル / space=
-- 検索・次候補 / ▼状態のみ x=前候補 / ▽状態のみ q=かな変換確定 /
-- ▽状態での大文字キー=送り開始点トリガー）。
-- ▼状態で space/x 以外のキーが来た場合は、選択中の候補を自動確定した
-- うえで、そのキー自体を新しい入力として直接入力へ引き継ぐ
-- （"Kanji<SPC>t" -> "漢字"確定+"t"から継続入力、
--  "Kanji<SPC>T" -> "漢字"確定+"T"で新しい▽開始）。
-- Sticky-shift（`;`）は、▽開始・送り開始点トリガーの両方で大文字キーと
-- 同様に扱う（`;` 自体は文字を持たないマーカーとしてのみ働く）。
-- 候補選択ウィンドウ（ホームポジション a s d f j k l で選択・即確定、
-- <SPC>/x でページ送り）は lua/skk/henkan/candidate_window.lua が担当する。
-- abbrev モード（"/" 開始、ASCII文字列そのものを見出しにする変換。
-- 例: "/Emacs" -> "いーまっくす" のような辞書エントリを引く）にも対応する。

local Context = require("skk.context")
local Input = require("skk.input")
local kana_util = require("skk.kana_util")
local kana_table = require("skk.kana_table")
local mode_util = require("skk.mode")
local henkan_state = require("skk.henkan.state")
local mode_indicator = require("skk.mode_indicator")
local target = require("skk.target")

local M = {}

local context = Context.new()
local ns_id = nil

--- 「今このキーは外部UI（blink.cmp等）に委ねるべきか」を判定する関数。
--- blink_source.lua 等、外部UI連携を提供する側が M.set_passthrough_guard()
--- で登録する。未登録（nil）ならこれまで通りの挙動（常にSKK自身が
--- <CR>・未対応キーを確定処理する）。
---@type (fun(key: string): boolean)|nil
local passthrough_guard = nil

--- 外部UI連携用のフック。fn(key) が true を返す間、▽/abbrev の
--- <CR>・catch-all による自動確定を行わない（handle_henkan_key 内の
--- defer_to_external_ui 参照）。nil を渡すと解除する。
---@param fn (fun(key: string): boolean)|nil
function M.set_passthrough_guard(fn)
  passthrough_guard = fn
end

--- lua/skk/init.lua の M.setup() から差し込まれるオプション。
--- モジュールのトップレベルでは vim.* に触れないプレーンな値のみ
--- 保持する（この設計方針は他のモジュールと同様）。
---@type { sticky_shift_enabled: boolean, sticky_shift_key: string, egg_like_newline: boolean, cmdline_start_mode: SkkMode,
---  extra_candidate_next_key: string|nil, extra_candidate_prev_key: string|nil }
local config = {
  sticky_shift_enabled = true,
  sticky_shift_key = ";",
  egg_like_newline = true,
  -- l/q/L・abbrev開始（"/"）の物理キー。他プラグイン（skkeleton等）との
  -- 共存や、キーボード配列の都合で変えたい場合を考慮して設定可能にした
  -- （実機からの要望）。デフォルトはこれまで通り。
  char_key_to_ascii = "l",
  char_key_to_kata_or_hira = "q",
  char_key_to_zenei = "L",
  abbrev_key = "/",
  -- コマンドラインモードに入った瞬間の入力モード。バッファ側で直前に
  -- 何のモードを使っていたかに関わらず、常にこの値から始める（バッファの
  -- モードとコマンドラインのモードは独立に管理する。下記の
  -- setup_cmdline_mode_isolation() を参照）。デフォルトは半角英数
  -- （SKK実質OFF）。ddskk/skkeleton 等でも一般的な既定動作。
  -- 将来、コマンドライン上でのシームレスな単語登録（henkan）に対応する際、
  -- ここを "hira" 等に変えたい場面が出てくる可能性を見込んで設定項目にして
  -- ある（現時点では setup() からは未公開、コード上のデフォルト変更のみ）。
  cmdline_start_mode = "ascii",
  -- ▼状態での候補フォーカス移動（CTRL_N/CTRL_P相当）に、追加のキーを
  -- 割り当てたい場合に使う（例: "<C-Up>"/"<C-Down>"）。Vim key notation の
  -- 文字列で指定する。nil（既定）なら CTRL_N/CTRL_P のみ。
  --
  -- 【なぜ必要か・実機で発見】Telescope 等、自身が <C-n>/<C-p> を実
  -- キーマップとして占有する外部UIのプロンプト（buftype="prompt"）内では、
  -- skk.nvim 本体の <C-n>/<C-p>（lua/skk/init.lua の candidate_navigation）
  -- は事実上機能しない。統合先（外部UI）の設定側で、対象バッファに
  -- <C-n>/<C-p> をバッファローカルに上書きし、henkanアクティブ時は
  -- M.focus_next_candidate() 等を呼ぶ、という統合層だけの対処も試みたが、
  -- ▼状態のキー処理は CTRL_N/CTRL_P/space/x/ホームポジション選択 以外の
  -- キーをすべて「未対応のキー」とみなし、defer_to_external_ui のガードなし
  -- に無条件でその場の候補を自動確定してしまう（handle_henkan_key 内の
  -- catch-all分岐）。これは vim.on_key() が実キーマップの解決より先に発火
  -- するため、外部UI側のバッファローカルな上書きキーマップが実行される前に
  -- 確定が起きてしまい、統合層だけでは解決できない（実機で確認）。
  -- そのため、CTRL_N/CTRL_P と同格の追加キーとして本体側の vim.on_key()
  -- 処理自体に認識させる必要がある。
  extra_candidate_next_key = nil,
  extra_candidate_prev_key = nil,
}

-- 制御キーの raw keycode。vim.api.nvim_replace_termcodes は使わない
-- （preedit.lua の namespace 生成で踏んだのと同じ「モジュールのトップ
-- レベルで vim.api を呼んでしまい、vim グローバルの無い環境で require
-- するだけでクラッシュする」ミスを避けるため。これらは全て固定の
-- ASCII 制御バイトなので string.char で十分）。
local BS = string.char(8) -- <C-h> はこの生バイトで届く
-- 物理的な Backspace キーは、ターミナルによって 0x08 (BS) ではなく
-- 0x7F (DEL) を送ってくることがある（よくある終端エミュレータの差異）。
-- 直接入力モード側は is_target_key に該当しないキーを汎用的に
-- リセットする設計なのでこの差異を意識せずに済むが、henkan 側は
-- <BS> を明示的に検知する必要があるため、両方のバイト値を受け付ける。
local BS_ALT = string.char(127) -- 一部の環境で Backspace が送る DEL
-- 実機で確認したところ、物理 Backspace キーは上記どちらの生バイトでもなく
-- termcap 由来の内部キーコード K_SPECIAL(0x80) + "kb" (0x80,0x6b,0x62)
-- として vim.on_key() に届くケースがあった（<C-h> は素の 0x08 で届くのに
-- 対し、物理 <BS> は Neovim 側で termcap の t_kb を経由して特別な内部表現に
-- 正規化される）。決め打ちのバイト値ではなく Neovim 自身に問い合わせて
-- 取得する。モジュールのトップレベルで vim.api を呼ぶと vim グローバルの
-- 無い環境で require するだけでクラッシュするため、M.setup() 内で遅延評価する。
local BS_TERMCODE = nil
-- 【実機で発見】物理 <Del>（Backspaceではなく前方削除キー）も内部キーコード
-- K_SPECIAL(0x80) + "kD"（termcap の t_kD 由来）として届く。これ自体は
-- BS_TERMCODE と同様「文字列全体としては #key ~= 1 なので is_target_key /
-- is_midashi_trigger_key のどちらにも該当しない」はずだったが、
-- is_midashi_trigger_key に #key==1 のガードが無かった旧実装では、この
-- 3バイト列に含まれる大文字 'D' を拾って誤って ▽ 変換開始と誤認していた
-- （#key==1 ガード追加により解消。以下の DEL_TERMCODE 検知・合成キー読み
-- 飛ばし処理は、それとは別に必要な「Neovimが<Del>の未マッピング時に内部で
-- 合成する'd','l'相当のキー」対策）。BS_TERMCODE 同様、決め打ちのバイト値
-- ではなく Neovim 自身に問い合わせて取得する（M.setup() 内で遅延評価）。
local DEL_TERMCODE = nil
-- 上記 <Del> の内部キーコードを検知した直後、Neovim が内部的に合成する
-- 'd','l' 相当の2キー（実機・ヘッドレステスト双方で確認した固定個数。
-- Neovimの挿入モードにおける <Del> 未マッピング時のデフォルト動作の
-- 実装詳細に由来する）を、通常の文字入力として再解釈しないよう
-- 読み飛ばすためのカウンタ。
local pending_del_swallow_count = 0
-- カーソル位置ずれ修正（hira_kata_batch / zenei_batch のカーソルオフセット
-- 機構）で使う、<Left>/<Right> の内部キーコード。DEL_TERMCODE 同様、
-- 決め打ちのバイト値ではなく Neovim 自身に問い合わせて取得する
-- （M.setup() 内で遅延評価。使用箇所のコメント参照）。
---@type string|nil
local LEFT_TERMCODE = nil
---@type string|nil
local RIGHT_TERMCODE = nil
-- ▼状態での候補フォーカス移動に使う追加キー（config.extra_candidate_next_key/
-- extra_candidate_prev_key）の内部キーコード表現。上記 LEFT_TERMCODE 等と
-- 同様、決め打ちにはできない（ユーザー設定かつ環境依存の内部表現になり
-- うる）ため、Neovim 自身に問い合わせて取得する（M.setup() 内で遅延評価）。
-- 未設定なら nil のまま。
---@type string|nil
local EXTRA_CANDIDATE_NEXT_TERMCODE = nil
---@type string|nil
local EXTRA_CANDIDATE_PREV_TERMCODE = nil
local CR = string.char(13) -- <CR> (Enter)
local CTRL_G = string.char(7) -- <C-g>
local CTRL_Q = string.char(17) -- <C-q>（abbrevモード専用: 全角変換して確定）
local CTRL_N = string.char(14) -- <C-n>（▼状態専用: 候補一覧ウィンドウ内でフォーカスを次の候補へ）
local CTRL_P = string.char(16) -- <C-p>（▼状態専用: フォーカスを前の候補へ）
-- 【実機で発見】<C-r>（式レジスタ。挿入モードの i_CTRL-R、Vim標準機能）
-- 起点の内部処理も、vim.on_key() には「文字列全体」ではなく「1文字ずつ」
-- 個別に観測される。他プラグインの <CR> マッピング内部が
-- `<C-r>=関数呼び出し()<CR>` というVim標準のイディオム（式を評価して
-- 結果をバッファへ挿入する）を使っている場合、その式の文字列そのものと
-- 評価結果の文字列の両方が、通常のタイプ入力と区別なく vim.on_key() に
-- 渡ってきてしまう（実機・ヘッドレステスト双方で確認）。全角英数モードの
-- ように「観測した印字可能ASCII文字を無条件に変換・挿入する」実装は、
-- これを本物の入力と誤認して全角変換・挿入してしまう
-- （実機で発見した不具合：全角英数モードで<CR>したときに他プラグインの
-- <C-r>=...<CR>由来の内部文字列が全角変換されて紛れ込む）。
-- ユーザー自身が意図的に <C-r>" 等でレジスタ貼り付けする場合も同じ経路を
-- 通るため、この対策はひらがな/カタカナモードでのレジスタ貼り付け時の
-- 誤ったローマ字再解釈も副次的に防ぐ。
local CTRL_R = string.char(18) -- <C-r>
-- <C-r> を検知した後、式の評価・結果挿入が完了する（＝Neovimが次の本物の
-- キー入力を待つ状態に戻る）までの間、on_key() 側の再解釈を止めるための
-- フラグ。式の評価結果の長さは可変で、事前に何文字読み飛ばせばよいか
-- 予測できないため、<Del> のような固定回数のカウンタ方式は使えない。
-- 代わりに、<C-r> 起点の内部処理はすべて「元のキー入力1回の同期的な
-- 処理」の中で完結する（Neovimがイベントループに制御を返す前に完結する）
-- という性質を利用し、vim.schedule() でフラグ解除を次のティックへ
-- 遅延させることで、内部処理中に発生する一連のキーだけを確実に覆う
-- （textlock対策で vim.schedule を使っている他の箇所と同じ考え方）。
local suppress_until_next_tick = false
-- 直前に観測したキーが <C-g>（CTRL_G）だったかどうか。次のキーが
-- 'u'/'U' ならセットで <C-g>u/<C-g>U のマーカーとみなして無視する
-- （CTRL_G 定義箇所およびその使用箇所のコメント参照）。
local pending_ctrl_g_marker = false

-- 【実機で発見】"z(" によって "（"（全角開き括弧）に変換された直後、
-- オートペアが自動追加する対になる ")" は、"z" の効果が及ばない独立した
-- キーとして処理されるため、そのままでは半角の ")" になってしまい、
-- 全角の開き括弧と半角の閉じ括弧が不揃いになる（実機で報告：
-- "z(" と打つと "（)" になる。カーソル位置自体は正しく括弧の間に来る）。
-- kana_table.lua が "z(" → "（" のみを定義しており、"z)" → "）" は
-- 独立したキー入力としてのみ定義されているため（"(" を打つと自動的に
-- 対になる ")" が来る、という関係を kana_table 自身は関知しない）。
--
-- process_romaji() で "z(" の変換（buffer が "z" だった状態で "(" を
-- 受け取り "（" が確定した）を検知した直後の1回に限り、続く ")" を
-- 全角 "）" に読み替えるワンショットフラグ。pending_ctrl_g_marker と
-- 同じ「直前の1キーだけを見る」発想。バッチ（同一ティック内の複数
-- キーのまとまり）をまたいでも安全に働くよう、フラグはバッチの生死とは
-- 独立して管理する（"z" と "(" が別バッチになるケースを想定。
-- process_romaji() 内、Input.kanaInput() 呼び出し前後のコメント参照）。
local pending_z_paren_open = false

-- ひらがな/カタカナモードで、確定したかなをどう表示するか。
---@type table<SkkMode, fun(s: string): string>
local RENDERERS = {
  hira = function(s)
    return s
  end,
  kata = kana_util.to_katakana,
}

--- 変換対象にする1文字かどうか（半角小文字アルファベット + 一部記号）
--- ひらがな/カタカナモードでの romaji 入力用。
---@type table<string, boolean>
local EXTRA_TARGET_CHARS = {
  ["-"] = true,
  ["."] = true,
  [","] = true,
  ["["] = true,
  ["]"] = true,
  ["("] = true,
  [")"] = true,
  [" "] = true,
}

--- ▽ 開始・送り開始点トリガーとして扱うキーかどうか。
--- 大文字キー（Shift+文字、トリガーと1文字目を1打鍵で兼ねる）と
--- Sticky-shift のキー（デフォルト `;`。トリガー専用で、文字は次の
--- 打鍵から別に入力する。config.sticky_shift_enabled=false なら
--- Sticky-shift 自体を無効化する）の両方を受け付ける。
---@param key string
---@return boolean
--- 【実機で発見・修正】以前はこのガードが無く、`key:match("%u")` が
--- 文字列全体のどこかに大文字ASCII文字が含まれていれば true を返す
--- 挙動を利用してしまっていた。`<Del>`（内部キーコード 0x80,'k','D'）や
--- `<F11>`（内部キーコード 0x80,'F','1'）等、termcap由来の3バイト特殊
--- キーコードにたまたま大文字が含まれるケースで、1文字の大文字キー入力
--- （Shift+文字によるトリガー）と誤認し、意図せず▽変換を開始してしまう
--- 不具合があった（is_target_key・is_printable_ascii は元々 #key==1 の
--- ガードを持っており、この関数だけ抜けていた）。
local function is_midashi_trigger_key(key)
  if #key == 1 and key:match("%u") ~= nil then
    return true
  end
  return config.sticky_shift_enabled and key == config.sticky_shift_key
end

--- 大文字キーは「小文字化した1文字」がそのまま最初の読みになるが、
--- Sticky-shift のキーはトリガー専用で文字を持たないので "" を返す。
---@param key string
---@return string
local function midashi_trigger_first_char(key)
  if config.sticky_shift_enabled and key == config.sticky_shift_key then
    return ""
  end
  return key:lower()
end

---@param key string
---@return boolean
local function is_target_key(key)
  if #key ~= 1 then
    return false
  end
  if key:match("%l") then
    return true
  end
  return EXTRA_TARGET_CHARS[key] == true
end

--- 半角の印字可能ASCII文字か（全角英数モード用。制御キー・特殊キーは除外する）
---@param key string
---@return boolean
local function is_printable_ascii(key)
  if #key ~= 1 then
    return false
  end
  local b = key:byte(1)
  return b >= 0x20 and b <= 0x7E
end

--- 現在のカーソル位置の直前から `byte_len` バイトを削除し、
--- 続けて `text` を挿入する。カーソルは挿入後のテキストの末尾に置く。
--- 実際の書き込み先（挿入モードのバッファ / コマンドライン）の違いは
--- lua/skk/target.lua が吸収する。
---@param byte_len integer
---@param text string
---@param start_pos { row: integer, col: integer }|nil
local function replace_before_cursor(byte_len, text, start_pos)
  target.replace_before_cursor(byte_len, text, start_pos)
end

-- 【実機で発見】直接入力（ひらがな/カタカナモード、henkan非アクティブ）
-- でのローマ字プレエディット表示は、これまで「今回のキーで新たに増えた
-- 未確定バイト数」を素朴に数えて『カーソル直前からその分だけ削除して
-- 置き換える』方式（バイト数の逆算）で実装していた。これは、次のキー
-- 入力までの間（vim.schedule() による1ティックの遅延の間）に、
-- nvim-autopairs 等バッファへ実際に書き込む他プラグインが「今回打った
-- キーの直後」にさらに文字を挿入すると（例: "(" に対する自動 ")"
-- 挿入）、削除すべき範囲の想定がずれてしまい、確定したかなの文字化けや
-- カーソル位置のずれを引き起こしていた（実機で報告された不具合）。
--
-- henkan（▽/▼）中のプレエディットは元々 extmark の virt_text のみで
-- 表示し、実バッファには一切書き込まない設計（lua/skk/henkan/preedit.lua
-- 参照）のためこの問題が起きない。直接入力のローマ字プレエディットは
-- 「打った端から実バッファに反映される」体験を保つため同じ方式は
-- 採れないが、代わりに「未確定シーケンスの先頭位置」を extmark で
-- 記録しておき、削除範囲を『バイト数の逆算』ではなく『その extmark の
-- （バッファ編集に追従して自動補正された）現在位置からカーソンまで』に
-- することで、間に他プラグインが何文字挿入していても正しく追従できる
-- ようにする。
---@type integer|nil
local pending_ns = nil

---@return integer
local function get_pending_ns()
  if not pending_ns then
    pending_ns = vim.api.nvim_create_namespace("skk_direct_pending")
  end
  return pending_ns
end

-- 【根本原因・ヘッドレスNeovim(実機と同一のv0.12.4)でのRPC経由キー入力
-- 再現により判明】nvim-autopairs 等が返す合成キー列（例:
-- `<C-g>u()<C-g>U<Left><C-g>u`）の中に、開き文字・閉じ文字の両方が
-- process_romaji() の変換対象キー（EXTRA_TARGET_CHARS）である場合
-- （ひらがな/カタカナの `(`/`[` や、全角英数モードの全記号）、
-- 同一ティック内で process_romaji() が複数回連続して呼ばれる。
--
-- 以前の実装は「1回の process_romaji() 呼び出しごとに、独立して
-- extmark を作成し、独立して vim.schedule() で書き込みを予約する」
-- 設計だった。しかし extmark の識別子（旧 pending_mark_id）はモジュール
-- レベルの単一変数だったため、2回目の呼び出しが1回目の extmark を
-- clear_pending_mark() で消して自分の extmark に差し替えてしまい、
-- さらに先に実行される1回目の vim.schedule() クロージャが（クロージャは
-- その変数を参照で捕捉するため）本来2回目のものである extmark を誤って
-- 使用したうえ、自分の pending=="" 判定でそれを消してしまう、という
-- 競合が起きていた。加えて、合成キー列に含まれる `<Left>` は
-- process_romaji() を経由せずNeovimネイティブの処理へそのまま渡るため、
-- まだ何も書き込まれていない（extmarkが指す位置に到達する前の）
-- タイミングでカーソルを動かしてしまい、2回目の書き込みが
-- extmark ではなく「その時点のズレたカーソル位置」にフォールバックして
-- しまっていた。結果として、確定済みだった文字列の途中に新しい文字が
-- 割り込む不具合になっていた（詳細な発生順序は process_romaji() と
-- target.lua の M.replace_before_cursor() のコメントを参照）。
--
-- 根本対応として、「同一ティック内に蓄積された、まだ1回も flush
-- されていないキー入力のまとまり」をバッチとして扱う。バッチの最初の
-- キーでのみ extmark 作成・vim.schedule() の予約を行い、そのバッチに
-- 属する後続のキーは単に蓄積するだけにする。flush が実際に実行された
-- ときに初めて、蓄積された内容を「1回のバッファ編集」としてまとめて
-- 書き込む。これにより、同一ティック内で何回 process_romaji() が
-- 呼ばれても、書き込みそのものは必ず1回になり、複数の extmark 同士が
-- 競合する余地自体がなくなる。通常の（1キーずつ間隔をおいた）typing
-- では、次のキーが来る前に前のバッチの flush が実行され終わっているため、
-- 実質的に「バッチサイズ1」となり、これまでと全く同じ挙動になる
-- （新規追加した tests/capture_batch_spec.lua 参照）。
---@type { active: boolean, mark_id: integer|nil, old_len: integer, confirmed: string, cursor_offset_chars: integer }
local hira_kata_batch = { active = false, mark_id = nil, old_len = 0, confirmed = "", cursor_offset_chars = 0 }

--- hira_kata_batch.mark_id の extmark を無条件に削除する（バッチの
--- flush 処理自身からのみ呼ぶ内部用）。他の箇所からは、下の
--- ガード付き clear_pending_mark() を使うこと。
local function clear_pending_mark_unchecked()
  if hira_kata_batch.mark_id == nil then
    return
  end
  pcall(vim.api.nvim_buf_del_extmark, vim.api.nvim_get_current_buf(), get_pending_ns(), hira_kata_batch.mark_id)
  hira_kata_batch.mark_id = nil
end

--- 未確定ローマ字シーケンスの先頭位置を示す extmark を削除する
--- （シーケンスが確定・中断・破棄されたとき、直接入力モードから離れる
--- ときなどに呼ぶ）。
---
--- 【重要・バッチ化対応】hira_kata_batch がまだ flush されていない間
--- （= vim.schedule() 済みだが未実行の書き込みが残っている間）は、
--- ここで extmark を消してはならない。消してしまうと、その flush が
--- 実行されるときに anchor を失い、旧実装で踏んでいた「<Left> 等の
--- 合間の実カーソル移動に巻き込まれて挿入位置がずれる」不具合が
--- 再発する。実際のクリア・再配置は flush_hira_kata_batch() 自身が
--- 責任を持って行う（hira_kata_batch 定義箇所のコメント参照）。
local function clear_pending_mark()
  if hira_kata_batch.active then
    return
  end
  clear_pending_mark_unchecked()
end

-- 【実機で発見・カーソル位置のずれ修正】nvim-autopairs 等が生成する
-- ペア文字列の直後の <Left>（開き文字と閉じ文字の間へカーソルを戻す
-- ためのもの）は、process_romaji()/process_zenei() の書き込みがまだ
-- 実行されていない間（バッチが flush 待ちの間）に届く。この時点で
-- <Left> をそのままNeovimネイティブに処理させると、まだ何も書き込まれて
-- いない（古い）バッファ状態に対してカーソルを動かすことになり、
-- 結果的に「開き文字・閉じ文字の間」ではなく「ペア全体の末尾」に
-- カーソルが残ってしまっていた（実機で報告：`いろは(` の直後に
-- 自動挿入される `)` との間ではなく、`いろは()` の末尾にカーソルが
-- 来てしまう）。
--
-- 対応として、バッチが flush 待ちの間だけ on_key() 側で <Left>/<Right>
-- を横取りし（LEFT_TERMCODE/RIGHT_TERMCODE 使用箇所のコメント参照）、
-- 実際にカーソルを動かす代わりに hira_kata_batch.cursor_offset_chars /
-- zenei_batch.cursor_offset_chars へ「flush 後、何文字分ずらすか」を
-- 積んでおく。flush 側（この関数）が、書き込み完了後の自然な
-- カーソル位置（挿入したテキストの末尾）からこの文字数分だけ
-- ずらすことで、「即座に書き込まれていたら本来こうなっていたはず」の
-- 位置を再現する。
--
-- 文字数（バイト数ではない）で管理しているのは、全角記号のような
-- マルチバイト文字の途中に着地してしまわないようにするため。
-- `vim.fn.strcharpart()` で文字境界を尊重して該当バイト数を求める。
---@param win integer
---@param inserted_text string 直前に replace_before_cursor() で挿入したテキスト
---@param offset_chars integer 負なら左（挿入したテキストの内部へ）、正なら右
local function apply_batch_cursor_offset(win, inserted_text, offset_chars)
  if offset_chars == 0 or inserted_text == "" then
    return
  end
  local cursor = vim.api.nvim_win_get_cursor(win)
  local end_col = cursor[2] -- replace_before_cursor() 直後なので、挿入テキストの末尾のはず
  local start_col = end_col - #inserted_text
  local total_chars = vim.fn.strchars(inserted_text)
  local target_chars = total_chars + offset_chars
  if target_chars < 0 then
    target_chars = 0
  elseif target_chars > total_chars then
    target_chars = total_chars
  end
  local prefix = vim.fn.strcharpart(inserted_text, 0, target_chars)
  vim.api.nvim_win_set_cursor(win, { cursor[1], start_col + #prefix })
end

--- hira_kata_batch を実際にバッファへ反映する。process_romaji() から
--- vim.schedule() 経由で（バッチの最初のキーのときだけ）呼ばれる。
--- バッチ化の詳細・経緯は hira_kata_batch 定義箇所のコメント参照。
local function flush_hira_kata_batch()
  local old_len = hira_kata_batch.old_len
  local display = hira_kata_batch.confirmed .. context.buffer
  local pending = context.buffer

  -- blink.cmp との統合作業で踏んだ textlock (E565) と同じ問題を避けるため、
  -- 実際のバッファ書き換えは1ティック遅らせている（vim.schedule 経由で
  -- ここが呼ばれる時点で、既に「1ティック遅れた後」）。
  local start_pos = nil
  if hira_kata_batch.mark_id ~= nil and target.kind() == "buffer" then
    local bufnr = vim.api.nvim_get_current_buf()
    local ok, mark = pcall(vim.api.nvim_buf_get_extmark_by_id, bufnr, get_pending_ns(), hira_kata_batch.mark_id, {})
    if ok and mark and mark[1] ~= nil then
      start_pos = { row = mark[1], col = mark[2] }
    end
  end
  replace_before_cursor(old_len, display, start_pos)

  -- 次のキー入力から新しいバッチを開始できるようにする。
  hira_kata_batch.active = false

  if pending == "" then
    clear_pending_mark_unchecked()
  elseif hira_kata_batch.mark_id ~= nil and target.kind() == "buffer" then
    -- 【実機で発見・重大なリグレッション修正、バッチ化後も同じ理由で必要】
    -- ここでマークを動かさずに元の位置（未確定シーケンス全体の先頭）へ
    -- 置いたままにしていると、促音（「っ」）のように「今回のバッチで
    -- 確定して書き込んだ文字と、なお続く未確定の pending」が同時に
    -- 発生するケースで、次のバッチがこのマークを起点として削除する範囲が、
    -- 今回すでに確定してバッファへ書き込んだ文字（「っ」等）まで
    -- 巻き込んでしまい、二度と復元できずに消えてしまう不具合があった
    -- （実機で発見："tta" と打つと「った」ではなく「た」になる）。
    -- 書き込み後のカーソルは「確定分＋pending」の末尾にあるので、
    -- そこから pending のバイト数だけ戻った位置＝「確定分の直後、
    -- pending の先頭」へマークを付け直す。これにより次のバッチの削除
    -- 範囲は常に「まだ確定していない部分」だけに限定される。
    local win = vim.api.nvim_get_current_win()
    local cursor = vim.api.nvim_win_get_cursor(win)
    local new_col = math.max(cursor[2] - #pending, 0)
    local bufnr = vim.api.nvim_get_current_buf()
    pcall(vim.api.nvim_buf_del_extmark, bufnr, get_pending_ns(), hira_kata_batch.mark_id)
    hira_kata_batch.mark_id =
      vim.api.nvim_buf_set_extmark(bufnr, get_pending_ns(), cursor[1] - 1, new_col, { right_gravity = false })
  end

  -- 【カーソル位置のずれ修正】on_key() 側で <Left>/<Right> の代わりに
  -- 積んでおいたオフセットを、ここで初めて実際のカーソル移動として
  -- 適用する（apply_batch_cursor_offset 定義箇所のコメント参照）。
  -- 必ず最後に行う：マーク再配置（上のブロック）は「書き込み直後の
  -- 自然なカーソル位置」を前提にしているため、オフセット適用より先に
  -- 済ませておく必要がある。
  if target.kind() == "buffer" and hira_kata_batch.cursor_offset_chars ~= 0 then
    apply_batch_cursor_offset(vim.api.nvim_get_current_win(), display, hira_kata_batch.cursor_offset_chars)
  end
  hira_kata_batch.cursor_offset_chars = 0
end

--- ローマ字入力を処理し、確定したかな（モードに応じてカタカナに
--- 変換済み）と未確定バッファをバッファへ反映する。
---
--- 【バッチ化】同一ティック内で複数回呼ばれても、実際のバッファ書き込み
--- （vim.schedule 経由）は最初の呼び出しの分だけ予約され、後続の呼び出しは
--- hira_kata_batch.confirmed に蓄積されるだけになる。詳細は
--- hira_kata_batch 定義箇所・flush_hira_kata_batch() のコメント参照。
---@param key string
local function process_romaji(key)
  if not hira_kata_batch.active then
    hira_kata_batch.active = true
    hira_kata_batch.old_len = #context.buffer
    hira_kata_batch.confirmed = ""

    -- 新しい未確定シーケンスの先頭（直前まで context.buffer が空だった）
    -- なら、ネイティブ文字挿入が起きる前の「今の」カーソル位置を extmark
    -- で記録しておく。continuation（old_len > 0、多打鍵ローマ字の途中）
    -- の場合は、以前のバッチから引き継いだ既存の mark_id をそのまま使う
    -- （先頭位置は変わっていないため）。
    --
    -- 【実機で発見・緊急修正】right_gravity を明示しておらずデフォルトの
    -- true のままだったため、extmark 作成直後にちょうどそのバイト位置へ
    -- ネイティブ文字（例: "k"）が挿入されると、extmark 自身が「挿入された
    -- 文字の直後」へ押し出されてしまっていた（Neovimのextmarkのデフォルト
    -- 挙動: right_gravity=true は「挿入位置に文字が入るとマークは
    -- その文字の後ろへ移動する」）。これにより「未確定シーケンスの先頭
    -- （削除開始位置）」のつもりが実質「現在のカーソルと常に同じ位置」に
    -- なってしまい、削除すべき範囲が常に空になって、ネイティブ挿入された
    -- 先頭の子音字（"k" 等）が消されないまま残ってしまう不具合を招いた
    -- （"ka" と打っても "kか" になってしまう等）。right_gravity=false を
    -- 明示し、「マーク作成位置に文字が挿入されてもマーク自身は動かない
    -- （新しい文字はマークの後ろに追加されたものとして扱う）」動作にする
    -- ことで解消する。
    if hira_kata_batch.old_len == 0 and target.kind() == "buffer" then
      clear_pending_mark_unchecked()
      local win = vim.api.nvim_get_current_win()
      local cursor = vim.api.nvim_win_get_cursor(win)
      local bufnr = vim.api.nvim_get_current_buf()
      hira_kata_batch.mark_id =
        vim.api.nvim_buf_set_extmark(bufnr, get_pending_ns(), cursor[1] - 1, cursor[2], { right_gravity = false })
    end

    vim.schedule(flush_hira_kata_batch)
  end

  -- 【実機で発見・z( の非対称修正】"z(" による全角括弧変換の検知・
  -- 読み替えのため、Input.kanaInput() で書き換わる前の buffer を見ておく
  -- （pending_z_paren_open 定義箇所のコメント参照）。
  local buffer_before = context.buffer

  Input.kanaInput(context, key)
  local confirmed = context:flush()

  if pending_z_paren_open and key == ")" and confirmed == ")" then
    -- 直前のキーで "z(" → "（" の変換が起きており、かつ今回のキーが
    -- （z の効果が及ばない独立入力として）そのまま ")" に変換された
    -- 場合に限り、対になる全角 "）" へ読み替える。
    confirmed = "）"
  end
  -- 一回限りのフラグなので、使ったかどうかに関わらず必ずここで
  -- 次回の状態へ更新する（今回のキーが新たに "z(" 変換を起こした場合の
  -- み true、それ以外は false）。
  pending_z_paren_open = (buffer_before == "z" and key == "(" and confirmed == "（")

  local render = RENDERERS[context.mode] or function(s)
    return s
  end
  hira_kata_batch.confirmed = hira_kata_batch.confirmed .. render(confirmed)
end

-- 【実機で発見・バッチ化】全角英数モードは常に1文字→1文字の変換で、
-- ひらがな/カタカナモードの「未確定ローマ字」に相当する概念が無い
-- （ローマ字の複数文字を待つ状態が存在しない）。そのため以前の実装は
-- extmark による位置追跡を一切行わず、「vim.schedule() 実行時点の
-- カーソル位置」だけを頼りに書き込んでいた。これは、開き文字・閉じ文字
-- 両方が印字可能ASCII文字であるオートペアの合成キー列では常に成立し
-- （全角英数モードは全ASCII文字が変換対象のため）、同一ティック内で
-- 複数回 vim.schedule() されると常に位置がずれる、最も脆弱な実装だった。
-- hira_kata_batch と同じ考え方でバッチ化する（old_len に相当する概念が
-- 無い分、hira_kata_batch よりも単純）。
---@type { active: boolean, mark_id: integer|nil, text: string, cursor_offset_chars: integer }
local zenei_batch = { active = false, mark_id = nil, text = "", cursor_offset_chars = 0 }

--- zenei_batch.mark_id の extmark を無条件に削除する。
local function clear_zenei_pending_mark()
  if zenei_batch.mark_id == nil then
    return
  end
  pcall(vim.api.nvim_buf_del_extmark, vim.api.nvim_get_current_buf(), get_pending_ns(), zenei_batch.mark_id)
  zenei_batch.mark_id = nil
end

--- zenei_batch を実際にバッファへ反映する。process_zenei() から
--- vim.schedule() 経由で（バッチの最初のキーのときだけ）呼ばれる。
local function flush_zenei_batch()
  local text = zenei_batch.text
  local start_pos = nil
  if zenei_batch.mark_id ~= nil and target.kind() == "buffer" then
    local bufnr = vim.api.nvim_get_current_buf()
    local ok, mark = pcall(vim.api.nvim_buf_get_extmark_by_id, bufnr, get_pending_ns(), zenei_batch.mark_id, {})
    if ok and mark and mark[1] ~= nil then
      start_pos = { row = mark[1], col = mark[2] }
    end
  end
  replace_before_cursor(0, text, start_pos)

  -- 【カーソル位置のずれ修正】hira_kata_batch と同じ理由・同じ仕組み
  -- （apply_batch_cursor_offset 定義箇所のコメント参照）。
  if target.kind() == "buffer" and zenei_batch.cursor_offset_chars ~= 0 then
    apply_batch_cursor_offset(vim.api.nvim_get_current_win(), text, zenei_batch.cursor_offset_chars)
  end
  zenei_batch.cursor_offset_chars = 0

  zenei_batch.active = false
  zenei_batch.text = ""
  clear_zenei_pending_mark()
end

--- 全角英数モードでの印字可能ASCII文字入力を処理する。
--- process_romaji() と同じ理由でバッチ化する（hira_kata_batch・
--- zenei_batch 定義箇所のコメント参照）。全角英数モードには
--- 「未確定ローマ字の継続」という概念が無いため、バッチは常に
--- 新規に extmark を作り直す（continuation の考慮は不要）。
---@param key string
local function process_zenei(key)
  if not zenei_batch.active then
    zenei_batch.active = true
    zenei_batch.text = ""

    if target.kind() == "buffer" then
      clear_zenei_pending_mark()
      local win = vim.api.nvim_get_current_win()
      local cursor = vim.api.nvim_win_get_cursor(win)
      local bufnr = vim.api.nvim_get_current_buf()
      zenei_batch.mark_id =
        vim.api.nvim_buf_set_extmark(bufnr, get_pending_ns(), cursor[1] - 1, cursor[2], { right_gravity = false })
    end

    vim.schedule(flush_zenei_batch)
  end

  zenei_batch.text = zenei_batch.text .. kana_util.to_zenkaku_char(key)
end

--- <CR> 相当の確定処理の本体（henkan_state.confirm() + egg_like_newline
--- オプション対応の改行フォローアップ）。on_key() 側の通常の <CR> 処理と、
--- 下記 M.confirm_henkan_if_active()（外部UIから同期的に呼ばれる公開API）の
--- 両方から共通して使う。呼び出し前提として henkan が実際にアクティブで
--- あること（呼び出し側で確認済みであること）。
local function do_confirm_and_maybe_newline()
  henkan_state.confirm()
  if not config.egg_like_newline then
    -- SKK本来の動作: 確定に加えて改行も行う。henkan_state.confirm() の
    -- バッファ挿入は vim.schedule で1ティック遅延しているので、それより
    -- 後に <CR> を「本物のキー入力」として再度 feedkeys で送り込むことで、
    -- FIFO順序（確定 -> 改行）を保証しつつ、改行そのものはNeovim
    -- ネイティブの処理に委ねる（自前で行分割を実装しない）。
    -- この時点で henkan は既に非アクティブになっているので、再入力された
    -- <CR> は on_key の henkan 分岐を通らず、通常の直接入力パス
    -- （is_target_key に該当しない印字可能ASCII外のキー）としてそのまま
    -- Neovim に素通しされる。
    vim.schedule(function()
      vim.api.nvim_feedkeys(CR, "n", false)
    end)
  end
end

--- henkan（▽/▼/abbrev）がアクティブなら <CR> 相当の確定処理を行い、true を
--- 返す。非アクティブなら何もせず false を返す。
---
--- 【なぜ必要か】blink.cmp 等の外部UIは、自身の <CR> キーマップ（accept/
--- fallback 等）を Neovim の実キーマップとして持っており、skk.nvim の
--- vim.on_key()（観測専用、他プラグインのキーマップ発火そのものは止め
--- られない）だけでは「skk.nvim側の確定」と「外部UI側の<CR>処理（fallback
--- による生の<CR> feedkeys、つまり素の改行挿入）」の実行順序を制御できず、
--- henkan確定と改行挿入が二重に起きてしまう不具合があった（実機で発見）。
---
--- このAPIを外部UI側の <CR> キーマップ関数から同期的に呼び出してもらうことで、
--- 「henkanが確定していれば、その結果を返してこのAPI呼び出しだけで完結させ、
--- 外部UI側のfallbackへは進ませない」という制御を、UI側自身に委ねられる形に
--- する。例（blink.cmp、lua/skk/init.lua の M.confirm_henkan() 経由）:
---   ["<CR>"] = {
---     "accept",
---     function()
---       if require("skk").confirm_henkan() then
---         return true
---       end
---     end,
---     "fallback",
---   },
---
--- 【重要】このAPI経由での確定を機能させるには、上記 handle_henkan_key() の
--- defer_to_external_ui が true になっている必要がある（passthrough_guard が
--- 「今まさに外部UIが見えている」と判定している間は、vim.on_key() 側の
--- 自動確定を行わない設計。詳細は defer_to_external_ui 定義箇所のコメント
--- 参照）。passthrough_guard が未登録、または false を返す状況（例:
--- blink.cmp 未使用、あるいは blink.cmp のメニューが表示されていない）では、
--- 従来通り on_key() 側が <CR> を捕まえて確定するため、このAPIを呼んでも
--- 二重確定にはならない（henkan_state.confirm() は多重呼び出しに対して
--- 安全ではないため、呼び出し側は必ず一度だけ・実際に必要なときだけ呼ぶこと。
--- このAPI自身は is_active() を確認してから確定するので、既に確定済み
--- （phase=="idle"）の状態で呼んでも何もせず false を返すだけで安全）。
---@return boolean confirmed henkan を確定したら true。もともとhenkan非
---  アクティブだった場合は false（呼び出し側は通常通りfallback等へ進めばよい）。
function M.confirm_henkan_if_active()
  if not henkan_state.is_active() then
    return false
  end
  do_confirm_and_maybe_newline()
  return true
end

--- 候補一覧（▼）のフォーカスを次の候補へ進める（<C-n> 相当）。henkanが
--- 非アクティブ、またはフェーズが "select"（▼）でなければ何もせず false を
--- 返す（henkan_state.focus_next() 自身が phase による no-op ガードを
--- 持っているため、このAPIは単なる橋渡し）。
---
--- 【なぜ必要か】Telescope 等、自身が <C-n>/<C-p> を実キーマップとして
--- バッファローカルに占有している外部UIのプロンプト（buftype="prompt"）
--- 内では、skk.nvim 本体の候補フォーカス移動キーマップ（lua/skk/init.lua
--- の candidate_navigation、既定 <C-n>/<C-p>）はグローバルな
--- vim.keymap.set() であり、バッファローカルな外部UI側のマッピングに
--- 優先順位で負けて発火しない（Neovimの仕様上、バッファローカルは常に
--- グローバルより優先される）。
---
--- このAPIは統合先（外部UI）の設定側で、対象バッファに同じキー
--- （<C-n>/<C-p>）をバッファローカルに上書きし、henkanアクティブ時はこちらを
--- 呼び、そうでなければ外部UI本来のアクション（結果一覧の移動等）に委譲する
--- 形での利用を想定している。例:
---   vim.keymap.set("i", "<C-n>", function()
---     if not require("skk").focus_next_candidate() then
---       -- henkan非アクティブ時は外部UI本来の動作にフォールバック
---       require("telescope.actions").move_selection_next(bufnr)
---     end
---   end, { buffer = bufnr })
---@return boolean moved 実際にフォーカスを動かせたら true。henkan非アクティブ
---  なら false（呼び出し側で本来の動作にフォールバックしてよい、という意味）。
function M.focus_next_candidate_if_active()
  if not henkan_state.is_active() then
    return false
  end
  henkan_state.focus_next()
  return true
end

--- 候補一覧（▼）のフォーカスを前の候補へ戻す（<C-p> 相当）。詳細は
--- M.focus_next_candidate_if_active() を参照。
---@return boolean moved
function M.focus_prev_candidate_if_active()
  if not henkan_state.is_active() then
    return false
  end
  henkan_state.focus_prev()
  return true
end

--- henkan（▽/▼）がアクティブな間のキー処理。
--- <CR>/<BS>/<C-g> はフェーズに関係なく共通、それ以外はフェーズごとに
--- 意味が変わる（▼状態の space/x は候補送り、▽状態の q はかな変換確定、等）。
---@param key string
---@return boolean reprocess true なら、このキーは確定処理のうえで
---  通常の直接入力として再処理してほしい、という意味（on_key 側が続けて処理する）
local function handle_henkan_key(key)
  local phase = henkan_state.get_phase()

  -- 【重要・実機で発見】blink.cmp 等、外部の補完UIが▽/abbrevの読み一覧を
  -- 表示している間、そのUIのどのキーが accept/next/hide 等に割り当て
  -- られているかは、ユーザーの keymap 設定次第で全く異なる（実機では
  -- keymap.preset="none" で全面カスタムしており、既定の <C-y> ではなく
  -- <CR> が accept に割り当てられていた）。個別のキーを決め打ちで
  -- 「外部UI用に予約」する方式は、こうした環境では機能しない。
  --
  -- そこで「特定のキー」ではなく「外部UIが今まさに見えているか」を
  -- passthrough_guard(key) で判定する方式にする。true が返る間は、
  -- ▽/abbrev 側の「<CR>／未対応キーは確定して抜ける」という自動確定
  -- ロジックを丸ごと止め、そのキーの解釈をNeovimのキーマップ解決
  -- （＝外部UI側の設定）に完全に委ねる。なお vim.on_key() はキーマップの
  -- 発火そのものを止められない（観測専用）ため、ここで skk.nvim 側の
  -- 処理を止めても外部UI側のキーマップの実行は妨げない・妨げられない。
  -- 目的はあくまで「skk.nvim 側が重複して確定処理をしてしまう」ことを
  -- 防ぐことにある。
  --
  -- ローマ字の読み入力そのもの（is_target_key に該当する文字。この関数の
  -- 後段で処理する）は、外部UI表示中でも従来通り継続できないと困るため、
  -- ここでは対象にしない（<CR>・両catch-allの「未対応キー」判定のみを
  -- 対象にする）。
  -- 【実機で発見・追加】従来は phase=="midashi"/"abbrev"（▽/abbrev状態）
  -- のみを対象にしていたが、実際に <CR> の二重確定（henkan確定+改行の
  -- 二重挿入）が起きていたのは phase=="select"（▼状態）だった。
  -- blink.lua 側の SkkHenkanChanged ハンドラは phase=="idle" のとき以外
  -- （select を含む）blink.show({ providers = { "skk" } }) でメニュー表示を
  -- 継続する実装になっているため、既存の passthrough_guard（blink.cmp の
  -- is_visible() ベース）はそのまま select 状態でも有効に使える。
  -- select をここに含めることで、外部UIが見えている間は <CR> による
  -- 自動確定を vim.on_key() 側では行わず、下記 M.confirm_henkan_if_active()
  -- を外部UI（blink.cmp等）の <CR> キーマップから同期的に呼んでもらう形に
  -- 一本化できる（二重確定の根本的な解消）。
  local defer_to_external_ui = (phase == "midashi" or phase == "abbrev" or phase == "select")
    and passthrough_guard ~= nil
    and passthrough_guard(key)

  if key == CR then
    if defer_to_external_ui then
      -- <CR> はここでは何もしない。外部UI側のマッピング（accept等）に
      -- そのまま委ねる。SKK独自の「読みをそのまま確定」は行わない。
      return false
    end
    do_confirm_and_maybe_newline()
    return false
  end
  if key == BS or key == BS_ALT or (BS_TERMCODE and key == BS_TERMCODE) then
    henkan_state.backspace()
    return false
  end
  if key == CTRL_G then
    henkan_state.cancel()
    return false
  end
  if key == " " then
    henkan_state.space()
    return false
  end

  if phase == "select" then
    if key == "x" then
      henkan_state.prev_page()
      return false
    end
    if key == CTRL_N then
      -- 候補一覧ウィンドウ内でフォーカスを次の候補へ（ページ境界は折り返す）。
      -- <SPC> のしきい値設定に関わらず、常に候補一覧ウィンドウを表示する。
      henkan_state.focus_next()
      return false
    end
    if key == CTRL_P then
      henkan_state.focus_prev()
      return false
    end
    if EXTRA_CANDIDATE_NEXT_TERMCODE and key == EXTRA_CANDIDATE_NEXT_TERMCODE then
      -- config.extra_candidate_next_key で指定された追加キー。CTRL_N と
      -- 全く同じ扱い（詳細は config 定義箇所のコメント参照）。
      henkan_state.focus_next()
      return false
    end
    if EXTRA_CANDIDATE_PREV_TERMCODE and key == EXTRA_CANDIDATE_PREV_TERMCODE then
      henkan_state.focus_prev()
      return false
    end
    -- ホームポジションキー（a s d f j k l）は、候補一覧ウィンドウが
    -- 実際に表示されている場合に限り、そのページ内の位置に対応する候補を
    -- 選択・即確定する。ウィンドウがまだ表示されていない段階（インライン
    -- ▼プレビューのみで1件ずつ送っている途中）では、ユーザーには
    -- どのキーがどの候補に対応するか見えていないため、候補選択としては
    -- 扱わない（見えない選択肢を選ばせる形になり、typoでの誤確定に
    -- つながる。実際に報告のあった問題）。この場合は下の「空以外のキー」
    -- 共通処理にフォールバックし、インライン表示中の候補を確定したうえで
    -- このキー自体を新しい入力として引き継ぐ。
    if henkan_state.is_candidate_window_visible() and henkan_state.select_by_key(key) then
      henkan_state.confirm()
      return false
    end
    -- space/x/ホームポジション選択 以外のキーが来たら、選択中の候補を
    -- 確定したうえで、このキー自体は「確定後の新しい入力」として通常の
    -- 直接入力に引き継ぐ（例: "Kanji<SPC>t" -> "漢字" 確定 + "t" から
    -- 入力継続、"Kanji<SPC>T" -> "漢字" 確定 + "T" で新しい ▽ 開始）。
    -- 矢印キー等の特殊キー（印字可能ASCIIでないもの）は再処理の対象外
    -- とし、確定だけ行う（literal 挿入すると壊れるため）。
    henkan_state.confirm()
    return is_printable_ascii(key)
  end

  -- ここから phase == "midashi" / "abbrev"

  if phase == "abbrev" then
    -- abbrev（"/" 開始）は ASCII 文字列そのものを見出しにするモードなので、
    -- ローマ字変換や大文字トリガー（送り開始点）の解釈をせず、印字可能
    -- ASCII文字はすべてそのまま見出しに追加する（大文字・記号・数字を含む。
    -- 例: "Bug", "Emacs" のような見出しをそのまま打てる）。
    if key == CTRL_Q then
      -- ddskk の「全角変換」相当。見出しのASCII文字列を全角に変換して
      -- 確定する（例: "manager" -> "ｍａｎａｇｅｒ"）。
      henkan_state.confirm_abbrev_zenkaku()
      return false
    end
    if is_printable_ascii(key) then
      henkan_state.input_abbrev(key)
      return false
    end
    -- 矢印キー等、印字可能ASCIIでないキーが来たら、ここまでの見出しを
    -- 確定する（▽状態の「未対応のキー」と同じ考え方）。ただし外部UIが
    -- 見えている間はそちらに委ねる（defer_to_external_ui 参照）。
    if defer_to_external_ui then
      return false
    end
    henkan_state.confirm()
    return false
  end

  -- ここから phase == "midashi"
  if key == "q" then
    henkan_state.convert_and_confirm_kana()
    return false
  end

  if key:match("%u") then
    -- 送り開始点トリガー: ▽ の中でもう一度大文字キーが来たら、そこから
    -- 送り仮名の入力が始まる（例: "Ugokasu" の2番目の "K"）。
    henkan_state.start_okuri()
    henkan_state.input(key:lower())
    return false
  end

  if config.sticky_shift_enabled and key == config.sticky_shift_key then
    -- Sticky-shift の送り開始点トリガー。大文字キーと違い、このキー自体は
    -- 文字を持たないのでマーカーとしてだけ扱う（次の打鍵から送り仮名の
    -- 子音入力が始まる。デフォルトのキー（;）なら例: ";oku;ri" の2番目の ";"）。
    henkan_state.start_okuri()
    return false
  end

  if is_target_key(key) then
    henkan_state.input(key)
    return false
  end

  -- 未対応のキー（数字・記号等）。以前はセッションを丸ごと中断していたが、
  -- それだと「▽かん」に続けて "1" や ";" を打っただけで読みが全部消えて
  -- しまい、使い勝手が悪かった（実際に報告された不具合）。▼状態の
  -- space/x 以外のキーと同じく、ここまでの読みを確定したうえで、
  -- このキー自体は新しい入力として直接入力に引き継ぐ。
  -- 矢印キー等の特殊キー（印字可能ASCIIでないもの）は再処理の対象外
  -- とし、確定だけ行う（literal 挿入すると壊れるため）。
  --
  -- 【重要・実機で発見】ただし外部UI（blink.cmp等）が見えている間は
  -- この自動確定を行わない（defer_to_external_ui 参照）。ここで確定＋
  -- 実バッファへの挿入をしてしまうと、外部UI側のキーマップ（例:
  -- <C-y>=accept、<C-n>/<C-p>=次候補/前候補 等、ユーザーの設定次第）が
  -- 同じキー入力に対して独立に反応した結果と二重に実行され、確定済みの
  -- 読みが実バッファへ本当に挿入されたうえで▽状態も終了してしまう
  -- （実機で確認した不具合そのもの。vim.on_key() は他プラグインの
  -- キーマップの発火を止められないため、片方だけ止めても両方止まる
  -- わけではないが、少なくとも skk.nvim 側の重複動作は防げる）。
  if defer_to_external_ui then
    return false
  end
  henkan_state.confirm()
  return is_printable_ascii(key)
end

--- henkan 確定直後に「このキーを新しい直接入力として再処理してほしい」
--- と言われた場合の処理。handle_henkan_key が reprocess=true を返すのは
--- is_printable_ascii(key) が真の場合に限定してあるので、ここではその
--- 前提で常に literal に処理しきる。
--- 【重要】この時点で元の物理キー入力は既に消費済み（on_key が "" を
--- 返している）なので、通常の直接入力パスと違って Neovim のネイティブ
--- 処理に頼ることはできない（"" 未対応キーは自分で literal 挿入する）。
---@param key string
local function reprocess_direct_key(key)
  -- 判定順序の理由は on_key() 側の同種のコメントを参照（モード切替 (l/q/L)
  -- を ▽開始/abbrev より先に判定しないと `L` がモード切替に到達できない）。
  if context.buffer == "" then
    local target = mode_util.char_transition(key, context.mode)
    if target then
      context.mode = target
      mode_indicator.show(target)
      return
    end
  end

  if context.buffer == "" and is_midashi_trigger_key(key) then
    henkan_state.start_midashi(context.mode, midashi_trigger_first_char(key))
    return
  end

  if context.buffer == "" and key == config.abbrev_key then
    -- abbrev モード開始（ASCII文字列そのものを見出しにする変換）。
    henkan_state.start_abbrev(context.mode)
    return
  end

  if is_target_key(key) then
    process_romaji(key)
    return
  end

  -- ローマ字にもモード切替にも該当しない印字可能文字（数字・記号等）を
  -- そのまま literal に挿入する。
  replace_before_cursor(0, key)
end

---@param key string 実際に処理されるキー（マッピング適用後）
---@param _typed string マッピング適用前に打鍵されたキー（未使用）
---@return string|nil
local function on_key(key, _typed)
  -- 実際のキー入力があったので、直前のモード切替インジケーターが
  -- 残っていれば消す（ascii モードの完全パススルーより前に置く必要が
  -- ある。そうしないと ascii モードで入力してもインジケーターが
  -- 消えないままになる）。
  mode_indicator.hide()

  -- 【実機で発見】<C-r> 抑制（CTRL_R 定義箇所のコメント参照）。<Del> と
  -- 同様、ascii/zenei モードにも一律で適用する（zenei モードで実害が
  -- 確認された不具合そのもの）。
  if suppress_until_next_tick then
    return
  end
  if key == CTRL_R then
    suppress_until_next_tick = true
    vim.schedule(function()
      suppress_until_next_tick = false
    end)
    return
  end

  -- 【実機で発見・改訂】nvim-autopairs 等、対応する閉じ括弧・引用符を
  -- 自動挿入するプラグインは、Vim標準のアンドゥ境界制御イディオム
  -- `<C-g>u`（新しい変更としてアンドゥ境界を作る）と
  -- `<C-g>U`（直後の1回のカーソル移動でアンドゥを分断しない）を組み合わせ、
  -- ペア文字＋カーソル移動を <expr> マッピングの返り値として一括で
  -- キー入力に再投入する実装が広く使われている（実機の on_key() ログで
  -- 実際に `<C-g>u""<C-g>U<Left><C-g>u` 相当の並びを確認済み）。
  -- この並びに含まれる大文字 'U'（0x55）は、1文字単独の文字列としては
  -- is_midashi_trigger_key の #key==1 ガードをすり抜けてしまい、
  -- 本物の Shift+U 押下と区別がつかず、意図せず ▽ 変換を開始してしまう
  -- 不具合があった。
  --
  -- 【当初の実装の問題点・実機で発見】最初は「<C-g> を見たら次のティック
  -- まで一律で抑制する」という広い対策にしていたが、これだと
  -- `<C-g>u""<C-g>U<Left><C-g>u` の中に埋まっている「本当にユーザーが
  -- 打ちたかった文字そのもの」（開き引用符・開き括弧などの実体、上の例の
  -- 2つの `"`）まで一緒に抑制してしまい、ひらがな/カタカナモードでの
  -- "[" → "「" 変換や全角英数モードでのゼンカク変換が一切効かなくなる
  -- 別の不具合を招いた（実機で確認）。
  --
  -- そこで対策を絞り込む：<C-g> 自体は（henkan中のキャンセル等）従来通り
  -- 通常の処理へ進める。抑制するのは「直前のキーが <C-g> であり、かつ
  -- 今回のキーが 'u' または 'U' である」場合、その1キーだけに限定する
  -- （<C-g>u/<C-g>U のマーカー文字そのものだけを無視する）。
  -- これにより、間に挟まる本物の文字（引用符・括弧等）や、その後の
  -- カーソル移動キー（<Left> 等。もともと #key~=1 で is_target_key /
  -- is_midashi_trigger_key のどちらにも該当せず無害）はそのまま通常の
  -- 処理経路を通り、skk.nvim 本来の変換が正しく機能する。
  if pending_ctrl_g_marker then
    pending_ctrl_g_marker = false
    if key == "u" or key == "U" then
      return
    end
    -- 'u'/'U' 以外が続いた場合は <C-g>u/<C-g>U パターンではなかった
    -- ということなので、このキーは下へそのまま読み進めて通常通り
    -- 処理する。
  end
  -- 【実機で発見・追加修正】<C-g> 自体は、これまで「マーカーを立てたあと
  -- 通常の処理へ読み進める」実装にしていた。henkan（▽/▼）非アクティブ時、
  -- これは大抵の場合 is_target_key(<C-g>) が false になり「未知キーによる
  -- リセット」（下記、is_target_key 判定のコメント参照）に落ちるだけなので
  -- 無害に見えたが、"z(" のような複数キーからなるローマ字プレフィックス
  -- 入力（"z" だけでは確定せず、次のキーで初めて全角記号等が確定する）の
  -- 「z」を打った直後に、たまたま次の実キーがオートペア対象の開き文字
  -- （"(" 等）だった場合に限って問題が表面化した：オートペアの合成キー列
  -- `<C-g>u()<C-g>U<Left><C-g>u` の先頭の <C-g> が「未知キーによる
  -- リセット」を発火させ、"z" が確定を待っていた未確定バッファ
  -- （context.buffer=="z"）を、本来の続き（"("）が処理される前に
  -- 破棄してしまっていた（実機で発見："z(" と打つと "z()"（"z" のゴミが
  -- 残ったうえ、全角にもならない半角の "()"）になってしまう）。
  -- 対応する 'u'/'U' の消費（上のブロック）と同様、<C-g> 自体も
  -- ここで return して、以降の「未知キーによるリセット」を含む処理へ
  -- 進めないようにする。<C-g> はアンドゥ境界制御のための合成キー列の
  -- 一部としてのみ意味を持ち、それ自体が持つべき「かな入力としての
  -- 意味」は無いため、握りつぶしても副作用は無い。
  if key == CTRL_G then
    pending_ctrl_g_marker = true
    return
  end

  -- 【実機で発見・カーソル位置のずれ修正】バッチが flush 待ちの間だけ
  -- <Left>/<Right> を横取りする（apply_batch_cursor_offset 定義箇所の
  -- コメント参照）。バッチが flush 待ちでない（＝通常のカーソル移動の）
  -- 間は一切介入せず、従来通りそのままNeovimネイティブの処理に委ねる。
  -- コマンドラインモード（target.kind()=="cmdline"）は対象外
  -- （nvim_win_get_cursor が意味を持たないため。cmdline編集中に
  -- nvim-autopairs のようなペア自動挿入を使う実用上のケースは想定しない）。
  if (key == LEFT_TERMCODE or key == RIGHT_TERMCODE) and target.kind() == "buffer" then
    local delta = (key == LEFT_TERMCODE) and -1 or 1
    local intercepted = false
    if hira_kata_batch.active then
      hira_kata_batch.cursor_offset_chars = hira_kata_batch.cursor_offset_chars + delta
      intercepted = true
    end
    if zenei_batch.active then
      zenei_batch.cursor_offset_chars = zenei_batch.cursor_offset_chars + delta
      intercepted = true
    end
    if intercepted then
      return ""
    end
  end

  -- 【実機で発見】<Del> 検知・合成キー読み飛ばし（DEL_TERMCODE 定義箇所の
  -- コメント参照）。ascii/zenei モードでは元々このキーも合成キーも
  -- 何も処理せず素通ししていたので影響なし。hira/kata モードおよび
  -- henkan 中（読み入力中に誤って 'd','l' が紛れ込むのを防ぐ）双方に
  -- 一律で適用する。<Del> 自体の削除動作はNeovimネイティブの処理に
  -- そのまま委ねる（自前で実装しない。ここでは何もせず return するのみ）。
  if DEL_TERMCODE and key == DEL_TERMCODE then
    context.buffer = "" -- 未確定のローマ字断片が残っていたら破棄する
    clear_pending_mark()
    pending_del_swallow_count = 2
    return
  end
  if pending_del_swallow_count > 0 then
    pending_del_swallow_count = pending_del_swallow_count - 1
    return
  end

  if context.mode == "ascii" then
    return -- 完全パススルー。<C-j> は init.lua 側のキーマップで処理する
  end

  -- 対応対象は挿入モード（バッファ）とコマンドラインモード。
  -- henkan（▽/▼、漢字変換）もコマンドラインで動く。preedit.lua が
  -- コマンドラインでは extmark ではなくコマンドライン文字列への直接
  -- 書き込みで表示する（lua/skk/henkan/preedit.lua 参照）。
  local target_kind = target.kind()
  if target_kind == nil then
    return
  end

  if context.mode == "zenei" then
    if not is_printable_ascii(key) then
      return
    end
    process_zenei(key)
    return ""
  end

  -- ここから hira / kata 共通

  -- henkan (▽/▼) がアクティブなら、まずそちらにキーを渡す。
  -- 確定のうえで「このキーは新しい入力として続けて処理してほしい」
  -- (reprocess=true) と言われた場合は、直接入力の処理へフォールスルーする
  -- （▼状態で space/x 以外のキーが来たときの自動確定 + 継続入力）。
  --
  -- 【重要】henkan_state.confirm() 自体のバッファ挿入は vim.schedule で
  -- 1ティック遅延している（textlock 対策）。もしここで再処理を同期的に
  -- 実行してしまうと、確定テキストがまだ挿入される前のカーソル位置を
  -- 新しい ▽ の anchor() が記録してしまい、カーソル位置がずれる
  -- 不具合になる（実際に発生した）。再処理も同じく vim.schedule で
  -- 遅延させることで、Neovim の FIFO 実行順序により「確定の挿入 ->
  -- 再処理」の順序を保証する。
  if henkan_state.is_active() then
    local reprocess = handle_henkan_key(key)
    if not reprocess then
      return ""
    end
    vim.schedule(function()
      reprocess_direct_key(key)
    end)
    return ""
  end

  -- ▽ 開始トリガー: 未確定バッファが空の状態での大文字キー、または
  -- Sticky-shift の `;`（Shift を使わずに大文字キー相当の操作をする方法。
  -- `;` 自体は文字を持たないマーカーなので、最初の読みは "" になる）。
  -- （▽ の中での送り開始点トリガーは handle_henkan_key 側で処理する）。
  --
  -- 【重要】判定順序は「モード切替 (l/q/L) -> ▽開始 -> abbrev」でなければ
  -- ならない。is_midashi_trigger_key() は大文字キー全般にマッチするため、
  -- モード切替より先に判定すると `L`（全角英数への切替キー）が常に
  -- ▽開始トリガーとして食われてしまい、ひらがな/カタカナモードで `L` を
  -- 打っても全角英数モードに遷移できなくなる不具合になる（実際に発生した）。
  -- `l`/`q` は小文字なので is_midashi_trigger_key() にはそもそもマッチせず
  -- 問題にならないが、`L` だけはこの順序を守る必要がある。
  if context.buffer == "" then
    local target = mode_util.char_transition(key, context.mode)
    if target then
      context.mode = target
      mode_indicator.show(target)
      return "" -- 切り替えキー自体は破棄する（挿入しない）
    end
  end

  -- henkan（▽/▼）・abbrev の開始は、コマンドラインモードにも対応済み
  -- （preedit.lua がコマンドラインでは extmark ではなくコマンドライン
  -- 文字列への直接書き込みで表示する。lua/skk/henkan/preedit.lua 参照）。
  if context.buffer == "" and is_midashi_trigger_key(key) then
    henkan_state.start_midashi(context.mode, midashi_trigger_first_char(key))
    return ""
  end

  if context.buffer == "" and key == config.abbrev_key then
    -- abbrev モード開始（ASCII文字列そのものを見出しにする変換）。
    henkan_state.start_abbrev(context.mode)
    return ""
  end

  if not is_target_key(key) then
    -- 未確定のローマ字が画面に literal 表示されている状態で、ローマ字
    -- 入力の続きとして認識できないキー（<BS>/<Delete>/カーソル移動キー等）
    -- が来た場合は、内部の追跡を諦めてリセットする。以降その文字列は
    -- Neovim から見て「ただのプレーンテキスト」になり、ネイティブの
    -- 処理（削除・カーソル移動）にそのまま委ねられる。
    --
    -- 【これが無いとどうなるか（実際に踏んだバグ）】
    -- <BS> も <Delete> も is_target_key に該当しないため、素通しすると
    -- Neovim ネイティブの処理に委ねられる。画面上の未確定ローマ字
    -- （例: "t"）は正しく消えても、内部の context.buffer は "t" のまま
    -- 更新されずに残ってしまう。次のキー入力時、capture.lua は
    -- 「まだ1バイト分の未確定文字が画面に残っているはず」という
    -- 古い情報を元にカーソル直前のバイトを削除してしまい、実際にそこに
    -- ある確定済みのマルチバイト文字（かな）の末尾バイトだけを削って
    -- しまい、不正なバイト列（例: "か<e3><81>k"）に破壊してしまっていた。
    -- 個別のキーごとに対処するのではなく、この汎用的なリセットで
    -- <BS>/<Delete>、そして今後遭遇する未知のキーもまとめて防ぐ。
    context.buffer = ""
    clear_pending_mark()
    return
  end

  process_romaji(key)
  return ""
end

--- コマンドラインモードに入る直前のバッファ側の入力モードを退避しておく変数。
--- コマンドラインを抜けたときに、コマンドライン中に何のモードを使っていたかに
--- 関わらずこの値へ復元する（バッファのモードとコマンドラインのモードを
--- 独立に保つ）。
---@type SkkMode|nil
local saved_buffer_mode = nil

--- 次に開くコマンドラインモードの開始モードを、1回だけ上書きする予約値。
--- 通常の `:`/`/` では nil のままで、config.cmdline_start_mode（既定は
--- "ascii"）から始まる。単語登録UI（henkan/state.lua の
--- M._trigger_registration()）が vim.fn.input() を呼ぶ前に
--- M.reserve_next_cmdline_mode("hira") で予約しておくと、その次に開く
--- コマンドライン（＝登録UIの入力欄そのもの）だけがひらがなモードで
--- 始まる。単語登録では変換操作を行う機会が圧倒的に多く、毎回 <C-j> で
--- 切り替える手間を省くため（実機での要望）。一度使ったら即座に消費して
--- nil に戻すので、次の通常のコマンドラインには影響しない。
---@type SkkMode|nil
local next_cmdline_mode_override = nil

--- コマンドラインモードに入った/出た瞬間の処理。
--- 【なぜ必要か】context.mode は capture.lua 内で単一の値として管理して
--- おり、バッファとコマンドラインで自動的には分離されない。何もしないと
--- 「コマンドラインに入っても直前のバッファのモードのまま」
--- 「コマンドラインで最後に使ったモードがバッファ側に漏れて残る」という
--- 2つの問題が起きる（実機で報告された不具合）。CmdlineEnter/CmdlineLeave
--- でモードを退避・復元することでこれを防ぐ。
local function on_cmdline_enter()
  saved_buffer_mode = context.mode
  if next_cmdline_mode_override then
    context.mode = next_cmdline_mode_override
    next_cmdline_mode_override = nil
  else
    context.mode = config.cmdline_start_mode
  end
  context.buffer = ""
  clear_pending_mark()
  mode_indicator.hide()
end

local function on_cmdline_leave()
  if saved_buffer_mode then
    context.mode = saved_buffer_mode
  end
  saved_buffer_mode = nil
  context.buffer = ""
  clear_pending_mark()
  mode_indicator.hide()
end

--- 次に開くコマンドラインモードの開始モードを1回だけ上書きする。
--- 上の next_cmdline_mode_override のコメントを参照。
---@param mode SkkMode
function M.reserve_next_cmdline_mode(mode)
  next_cmdline_mode_override = mode
end

--- <C-j> などの制御キーによるモード遷移を試みる。
--- 現在のモードから見て遷移先が定義されていなければ何もしない。
--- 【注意】この関数は init.lua が vim.keymap.set() 経由で直接呼ぶルートで、
--- vim.on_key() の on_key() を通らない。そのためモードインジケーターの
--- 表示もここで明示的に行う必要がある（on_key() 側の l/q/L 遷移とは
--- 別経路なので、うっかり忘れると <C-j> だけインジケーターが出ない、
--- という不具合になる。実際に発生した）。
---@param ctrl_key string 例: "<C-j>"
---@return SkkMode|nil 遷移後のモード（遷移しなかった場合は nil）
function M.transition(ctrl_key)
  local target = mode_util.ctrl_transition(ctrl_key, context.mode)
  if not target then
    return nil
  end
  context.mode = target
  context.buffer = "" -- 未確定のローマ字断片が残っていたら破棄する
  clear_pending_mark()
  mode_indicator.show(target)
  return context.mode
end

---@return SkkMode
function M.get_mode()
  return context.mode
end

--- モードを直接指定して切り替える。l/q/L・<C-j> 相当のキー入力を経由せず、
--- 外部（M.enable()/M.disable()/M.toggle()、あるいは他プラグインからの
--- 直接呼び出し）から強制的にモードを変更したい場合に使う。
--- M.transition()/l/q/L による遷移と同様、未確定のローマ字断片は破棄し、
--- モードインジケーターを表示する。
---@param mode SkkMode
function M.set_mode(mode)
  context.mode = mode
  context.buffer = ""
  clear_pending_mark()
  mode_indicator.show(mode)
end

---@return string
function M.mode_label()
  return mode_util.label(context.mode)
end

--- vim.on_key() のリスナーを登録する。init 時に一度だけ呼ぶ。
---@param opts { sticky_shift_enabled: boolean?, sticky_shift_key: string?, egg_like_newline: boolean?, char_key_to_ascii: string?, char_key_to_kata_or_hira: string?, char_key_to_zenei: string?, abbrev_key: string?, ctrl_keys: string[]?, period: string?, comma: string? }|nil
function M.setup(opts)
  opts = opts or {}
  if opts.sticky_shift_enabled ~= nil then
    config.sticky_shift_enabled = opts.sticky_shift_enabled
  end
  if opts.sticky_shift_key ~= nil then
    config.sticky_shift_key = opts.sticky_shift_key
  end
  if opts.egg_like_newline ~= nil then
    config.egg_like_newline = opts.egg_like_newline
  end
  if opts.char_key_to_ascii ~= nil then
    config.char_key_to_ascii = opts.char_key_to_ascii
  end
  if opts.char_key_to_kata_or_hira ~= nil then
    config.char_key_to_kata_or_hira = opts.char_key_to_kata_or_hira
  end
  if opts.char_key_to_zenei ~= nil then
    config.char_key_to_zenei = opts.char_key_to_zenei
  end
  if opts.abbrev_key ~= nil then
    config.abbrev_key = opts.abbrev_key
  end
  if opts.extra_candidate_next_key ~= nil then
    config.extra_candidate_next_key = opts.extra_candidate_next_key
  end
  if opts.extra_candidate_prev_key ~= nil then
    config.extra_candidate_prev_key = opts.extra_candidate_prev_key
  end
  -- 句読点（ひらがな/カタカナモードでのローマ字 "." "," の変換結果）。
  -- kana_table は module-level のプレーンな Lua テーブル（require ごとの
  -- 使い回し）なので、ここで直接上書きすれば以降の変換すべてに反映される。
  if opts.period ~= nil then
    kana_table["."] = opts.period
  end
  if opts.comma ~= nil then
    kana_table[","] = opts.comma
  end

  -- 【重要】l/q/L・<C-j>相当（ctrl_keys）の物理キー割り当てを、mode.lua
  -- （vim.* 非依存の純粋ロジック層）側にも反映する。config テーブルを
  -- 唯一の正とし、setup() を呼ぶたびに（このキーに関するオプションが
  -- 今回渡されたかどうかに関わらず）常に作り直す。lua/skk/init.lua は
  -- ctrl_keys（バッファ用・コマンドライン用のenter_keyをまとめた配列。
  -- 両者が同じキーなら1件だけになる）をここに渡す。
  mode_util.set_char_keys({
    to_ascii = config.char_key_to_ascii,
    to_kata_or_hira = config.char_key_to_kata_or_hira,
    to_zenei = config.char_key_to_zenei,
  })
  mode_util.set_ctrl_keys(opts.ctrl_keys)

  -- 物理 <BS> キーが termcap 経由の特殊な内部キーコードとして届く環境が
  -- あるため、Neovim 自身に問い合わせて実際の表現を取得しておく。
  BS_TERMCODE = vim.api.nvim_replace_termcodes("<BS>", true, true, true)
  -- 物理 <Del> キーも同様（DEL_TERMCODE 定義箇所のコメント参照）。
  DEL_TERMCODE = vim.api.nvim_replace_termcodes("<Del>", true, true, true)
  -- カーソル位置ずれ修正で使う <Left>/<Right>（LEFT_TERMCODE/RIGHT_TERMCODE
  -- 定義箇所のコメント参照）。
  LEFT_TERMCODE = vim.api.nvim_replace_termcodes("<Left>", true, true, true)
  RIGHT_TERMCODE = vim.api.nvim_replace_termcodes("<Right>", true, true, true)
  -- ▼状態での候補フォーカス移動の追加キー（config参照）。未設定（nil）なら
  -- 何もしない（EXTRA_CANDIDATE_*_TERMCODE は nil のままとなり、後述の
  -- phase=="select" 分岐は素通りする）。
  EXTRA_CANDIDATE_NEXT_TERMCODE = config.extra_candidate_next_key
      and vim.api.nvim_replace_termcodes(config.extra_candidate_next_key, true, true, true)
    or nil
  EXTRA_CANDIDATE_PREV_TERMCODE = config.extra_candidate_prev_key
      and vim.api.nvim_replace_termcodes(config.extra_candidate_prev_key, true, true, true)
    or nil
  ns_id = vim.on_key(on_key, ns_id)

  -- バッファのモードとコマンドラインのモードを独立に保つための
  -- 退避・復元（on_cmdline_enter/on_cmdline_leave のコメントを参照）。
  local augroup = vim.api.nvim_create_augroup("skk_cmdline_mode_isolation", { clear = true })
  vim.api.nvim_create_autocmd("CmdlineEnter", { group = augroup, callback = on_cmdline_enter })
  vim.api.nvim_create_autocmd("CmdlineLeave", { group = augroup, callback = on_cmdline_leave })
end

return M

-- lua/skk/henkan/state.lua
--
-- ▽/▼ の状態機械本体。lua/skk/capture.lua から呼ばれる。
--
-- 送りなし変換に加えて、送りあり変換（okuri-ari）にも対応する。
-- ▽の中でもう一度大文字キー（capture.lua が検知して M.start_okuri() を
-- 呼ぶ）が来ると、以降のローマ字入力は送り仮名側（Session:input_okuri）
-- に切り替わり、子音+母音が確定した瞬間に自動的に辞書検索（▼へ遷移）する。
--
-- 状態:
--   "idle"    -- 変換していない（直接入力モード）
--   "midashi" -- ▽ 読み入力中
--   "select"  -- ▼ 候補選択中
--
-- 変換セッション中は実バッファに一切書き込まない
-- (lua/skk/henkan/preedit.lua の設計方針を参照)。確定して初めて
-- 実バッファへ挿入する。

local Session = require("skk.henkan.session")
local preedit = require("skk.henkan.preedit")
local candidate_window = require("skk.henkan.candidate_window")
local dict = require("skk.dict")
local kana_util = require("skk.kana_util")
local target = require("skk.target")

local M = {}

---@alias SkkHenkanPhase "idle"|"midashi"|"select"|"abbrev"

---@type SkkHenkanPhase
local phase = "idle"
---@type SkkHenkanSession|nil
local session = nil

--- 候補一覧ウィンドウをいつ表示するかの設定。lua/skk/init.lua の
--- M.setup({ candidate_window = { threshold = ... } }) から差し込む。
--- <SPC> を押した回数がこの値に達した時点で初めてウィンドウを表示する
--- （それまではインラインの ▼ プレビューで1件ずつ候補を送るだけ）。
--- 個人辞書の学習で先頭候補が当たりやすくなったことを踏まえた仕様。
---@type { candidate_window_threshold: integer }
local config = { candidate_window_threshold = 2 }

---@param opts { candidate_window_threshold: integer? }|nil
function M.setup(opts)
  opts = opts or {}
  if opts.candidate_window_threshold ~= nil then
    config.candidate_window_threshold = opts.candidate_window_threshold
  end
end

---@return boolean
function M.is_active()
  return phase ~= "idle"
end

---@return SkkHenkanPhase
function M.get_phase()
  return phase
end

--- 現在の（確定済み部分の）読みを返す。phase=="idle" なら nil。
--- blink.cmp ネイティブソース（lua/skk/blink_source.lua）が、ライブ補完
--- 検索のキーとして使う。
---@return string|nil
function M.current_reading()
  if not session then
    return nil
  end
  return session.reading
end

--- 表示・確定用のレンダリング: source_mode がカタカナならカタカナに
--- 変換し、ひらがなならそのまま返す。
--- 【設計】① 内部の読み（session.reading）は常にひらがなで保持する。
--- ② ▽ の表示（画面に見えるもの）は source_mode に連動させる
--- （カタカナモードで▽に入ったら▽の表示もカタカナにする）。
--- ③ 確定動作は別ルール: <CR> は常にひらがな確定、q は常にカタカナ確定
--- （source_mode に関係なく固定。convert_and_confirm_kana を参照）。
---@param text string
---@param mode "hira"|"kata"
---@return string
local function render_for_mode(text, mode)
  if mode == "kata" then
    return kana_util.to_katakana(text)
  end
  return text
end
M._render_for_mode = render_for_mode -- テスト用に公開

--- ▽/▼ の状態変化を User autocmd で通知する。skkeleton の
--- "skkeleton-mode-changed"/"skkeleton-handled" 相当の仕組みで、
--- blink.cmp ネイティブソース（lua/skk/blink_source.lua）や、その他
--- 外部の設定側が、変換中かどうか・現在の読み・送りありかどうかを見て
--- 補完メニューの表示/非表示を切り替えるためのフック。
--- 【設計】ここでは通知するだけで、何を表示するかの判断は一切しない
--- （すべて受け手側の責務）。data.phase が "idle" になったことをもって
--- 「非表示にしてよい」と判断できる。
--- pcall で保護しているのは、テスト環境（フェイクの vim.api）で
--- nvim_exec_autocmds が無くても落ちないようにするため。
local function notify_changed()
  local data = { phase = phase }
  if session then
    data.reading = session.reading
    data.has_okuri = session.search_has_okuri or false
    data.source_mode = session.source_mode
  end
  pcall(vim.api.nvim_exec_autocmds, "User", {
    pattern = "SkkHenkanChanged",
    data = data,
  })
end

--- ▽ 表示用に、確定済みの読み（source_mode でレンダリング済み）と
--- 未確定のローマ字断片を連結する。
--- 【重要】これが抜けていると "K"→"▽"、"Kan"→"▽か"（"n" が消える）
--- のように、打鍵と表示が一致しない不具合になる（実際に報告されたバグ）。
--- 未確定断片は常に半角ASCIIなので、レンダリングせずそのまま連結する。
---@return string
local function midashi_display()
  return render_for_mode(session.reading, session.source_mode) .. session:reading_pending()
end

--- ▽ を開始する。capture.lua が大文字キー検知時に呼ぶ。
---@param mode "hira"|"kata" ▽を開始したモード（表示・送り仮名の変換先に使う）
---@param first_char string 大文字キーを小文字化した、最初のローマ字1文字
function M.start_midashi(mode, first_char)
  phase = "midashi"
  session = Session.new(mode)
  preedit.anchor()
  session:input_reading(first_char)
  preedit.show_midashi(midashi_display(), session.okuri_consonant)
  notify_changed()
end

--- 送り開始点を設定する。▽の中でもう一度大文字キー（送りあり変換の
--- トリガー）が来たときに capture.lua から呼ばれる。この時点ではまだ
--- 子音は不明で、直後に呼ばれる M.input() の1文字目が
--- session.okuri_consonant として記録される。
function M.start_okuri()
  if phase ~= "midashi" or not session then
    return
  end
  session:start_okuri()
end

--- abbrev モード（"/" 開始）を始める。capture.lua が "/" キー検知時に呼ぶ。
--- 通常の ▽（ローマ字→かな変換）と違い、入力した ASCII 文字をそのまま
--- 見出しとして積む（辞書検索キーも ASCII 文字列そのもの）。
---@param mode "hira"|"kata" 開始したモード（表示・確定後の入力継続に使う）
function M.start_abbrev(mode)
  phase = "abbrev"
  session = Session.new(mode)
  preedit.anchor()
  preedit.show_abbrev(session.reading)
  notify_changed()
end

--- abbrev モードの間に ASCII 文字を1文字追加する。
---@param char string
function M.input_abbrev(char)
  if phase ~= "abbrev" or not session then
    return
  end
  session:input_abbrev(char)
  preedit.show_abbrev(session.reading)
  notify_changed()
end

--- abbrev モード専用: <C-q> 相当。ここまでの見出し（ASCII文字列）を
--- 半角→全角変換してそのまま確定する（ddskk の「全角変換」相当）。
--- 例: "manager" -> "ｍａｎａｇｅｒ"。
function M.confirm_abbrev_zenkaku()
  if phase ~= "abbrev" or not session then
    return
  end
  local zenkaku = {}
  for i = 1, #session.reading do
    table.insert(zenkaku, kana_util.to_zenkaku_char(session.reading:sub(i, i)))
  end
  M.confirm_text(table.concat(zenkaku))
end

--- ▽の間にローマ字を1文字追加する。送り開始点が設定済みなら
--- 送り仮名側の入力として扱い、子音+母音が確定した瞬間に
--- 自動的に辞書検索（▼への遷移）を行う。
---@param char string
function M.input(char)
  if phase ~= "midashi" or not session then
    return
  end

  if session:is_okuri_pending() then
    local confirmed = session:input_okuri(char)
    preedit.show_midashi(midashi_display(), session.okuri_consonant)
    notify_changed()
    if confirmed then
      M.search()
    end
    return
  end

  session:input_reading(char)
  preedit.show_midashi(midashi_display(), session.okuri_consonant)
  notify_changed()
end

--- <BS> 相当。読みを1文字消す。空になったらセッションごと中断する。
function M.backspace()
  if phase == "idle" or not session then
    return
  end
  if phase == "select" then
    -- ▼状態での <BS> は ▽ に戻して読みの末尾を消す、という設計もあるが、
    -- phase 3 では単純化し、▼状態の <BS> はセッション中断として扱う。
    M.cancel()
    return
  end

  if phase == "abbrev" then
    local has_more = session:backspace_abbrev()
    if not has_more then
      M.cancel()
      return
    end
    preedit.show_abbrev(session.reading)
    notify_changed()
    return
  end

  local has_more = session:backspace_reading()
  if not has_more then
    M.cancel()
    return
  end
  preedit.show_midashi(midashi_display(), session.okuri_consonant)
  notify_changed()
end

--- ▼ 状態の表示を更新する（inline の ▼候補 表示 + 候補一覧ウィンドウ）。
--- 候補一覧ウィンドウは、現在ページの候補（Session:page_candidates()）を
--- ホームポジションキー（a s d f j k l ;）と対応させて表示する。
local function show_select_ui()
  local candidate = session:current_candidate()
  preedit.show_henkan(
    candidate and candidate.word or nil,
    render_for_mode(session.okuri_kana or "", session.source_mode)
  )
  local selected_offset = session.index - session.page * Session.PAGE_SIZE

  if target.kind() == "cmdline" then
    -- コマンドラインには「アンカーウィンドウのバッファ位置」という概念が
    -- 無い（bufpos基準のrelative="win"が使えない）ため、専用の表示関数
    -- （画面下部・コマンドライン行の直上に固定表示）を使う。
    candidate_window.show_cmdline(session:page_candidates(), session.page + 1, session:page_count(), selected_offset)
    notify_changed()
    return
  end

  local anchor_win = preedit.anchor_win()
  local _, row, col = preedit.anchor_position()
  if anchor_win and row ~= nil and col ~= nil then
    -- 現在選択中の候補が、表示するページの中で何番目（ホームポジションの
    -- どのキーの位置）に当たるかを求め、候補一覧ウィンドウ側でも同じ
    -- 候補をハイライトできるようにする（インライン ▼ 表示との整合性のため）。
    candidate_window.show(
      anchor_win,
      row,
      col,
      session:page_candidates(),
      session.page + 1,
      session:page_count(),
      selected_offset
    )
  end
  notify_changed()
end

--- 候補一覧ウィンドウを表示する前段階（<SPC> を押した回数が
--- config.candidate_window_threshold に達するまで）の表示更新。
--- inline の ▼候補 表示だけを更新し、ウィンドウは一切触らない。
local function show_inline_preview_only()
  local candidate = session:current_candidate()
  preedit.show_henkan(
    candidate and candidate.word or nil,
    render_for_mode(session.okuri_kana or "", session.source_mode)
  )
  notify_changed()
end

--- スペース。▽/abbrev 状態なら辞書検索して▼へ、▼状態なら次の1候補
--- （ウィンドウ表示前）または次ページ（ウィンドウ表示後）へ。
function M.space()
  if phase == "midashi" or phase == "abbrev" then
    M.search()
  elseif phase == "select" then
    M.next_page()
  end
end

--- 辞書検索して▼へ遷移する。
--- ▽状態（phase=="midashi"）: 送りなし/送りありの通常変換（Session:dict_key() が
--- 送り仮名の有無を判定する）。
--- abbrev状態（phase=="abbrev"）: 見出しの ASCII 文字列そのものを検索キーにする
--- （送りありという概念が無いので常に has_okuri=false）。
--- この <SPC> が1回目の打鍵になる。config.candidate_window_threshold が
--- 1 なら（デフォルトの前の挙動と同じく）この時点で候補ウィンドウも表示する。
function M.search()
  if (phase ~= "midashi" and phase ~= "abbrev") or not session or session.reading == "" then
    return
  end

  local key, has_okuri
  if phase == "abbrev" then
    key, has_okuri = session.reading, false
  else
    key, has_okuri = session:dict_key()
  end
  session.search_key = key
  session.search_has_okuri = has_okuri

  local candidates = dict.lookup(key, has_okuri)
  session:set_candidates(candidates)
  session.space_count = 1
  phase = "select"

  if #candidates == 0 then
    M._fallback_no_candidates()
    return
  end

  if session.space_count >= config.candidate_window_threshold then
    show_select_ui()
  else
    show_inline_preview_only()
  end
end

--- 単語登録UIへ遷移する際に「キャンセルされたら確定すべきテキスト」を
--- 求める。候補が1件も無い場合（current_candidate() が nil）は
--- 読み+送り仮名（従来のフォールバックと同じ）、候補はあるが末尾から
--- 次に送ろうとした場合は、その時点で画面に▼表示されていた候補+送り仮名。
---@return string
local function current_fallback_text()
  local okuri = render_for_mode(session.okuri_kana or "", session.source_mode)
  local candidate = session:current_candidate()
  if candidate then
    return candidate.word .. okuri
  end
  return render_for_mode(session.reading, session.source_mode) .. okuri
end

--- 単語登録UIを開いても安全に使えるよう、Esc/C-g を「本当にキャンセル
--- されたか」判定する際に使う（Neovim組み込みの vim.fn.input() は
--- <C-g> を特別扱いしない＝ただの制御文字として無視されてしまい、
--- <Esc> と挙動を統一できないため）。
---
--- 【この登録UIはひらがなモードから始まる】ため（M._trigger_registration()
--- 内の capture.reserve_next_cmdline_mode("hira") 参照）、この input()
--- の中で打鍵される文字は capture.lua の vim.on_key() リスナーによって
--- 常にローマ字→かな変換の対象になる。そのため、以前はキャンセル判定に
--- 「センチネル文字列を実際にタイプさせて、input() の戻り値にその文字列が
--- 含まれるか調べる」方式（skkeleton の "__skkeleton_return__" と同じ発想）
--- を使っていたが、そのセンチネル文字列自身の英字部分までローマ字かな
--- 変換されてしまい、(1) コマンドラインが文字化けし、(2) 変換後の文字列は
--- 元のセンチネルと一致しなくなるため「キャンセルではなく確定された」と
--- 誤判定し、化けた文字列がそのまま個人辞書に書き込まれる、という不具合が
--- あった（実機で発見）。
---
--- そのため今は、<Esc>/<C-g> を `<expr>` マッピングにして、実際に
--- 打鍵させるキーは `<CR>`（input() を閉じるだけ）に限定し、
--- 「キャンセルされたか」はコマンドラインのテキストではなく
--- Lua のクロージャ変数（M._trigger_registration() 内の local
--- cancelled）で直接管理する。これなら英字が一切タイプされないので、
--- ローマ字かな変換エンジンを通ることがない。

--- 候補が見つからない、または候補送りで末尾から次へ進もうとしたときに
--- 呼ぶ。単語登録UIを開き、確定すれば個人辞書に書き込んでその単語を、
--- キャンセルすれば current_fallback_text() をそのまま確定する。
---
--- 【設計】Neovim組み込みの vim.fn.input() は、コマンドラインモード
--- （mode()=="c"）を再帰的に開く機能で、呼び出し中も mode()=="c" を
--- 保ち続け、終了後は呼び出し元（挿入モードなら挿入モード、コマンドライン
--- 編集中ならその続き）へ自動的に復帰する。この性質のおかげで、既存の
--- target.lua/capture.lua/preedit.lua のコマンドラインモード対応
--- （ローマ字→かな変換・henkan）が、専用のUIコードを書かなくてもこの中で
--- そのまま動く（RPC経由の検証・実機の両方で確認済み）。denops版の
--- skkeleton（vim-skk/skkeleton）の registerWord() と基本的に同じ設計。
---
--- 【状態管理】この関数を呼ぶ時点の module-level な phase/session
--- （＝これから登録するに至った変換セッション）は、確定・キャンセルの
--- いずれであれ、ここで完全に終了させる（「呼び出し元へ戻る」概念は無い）。
--- vim.fn.input() を呼ぶ前に phase/session をクリアしておくことで、
--- input() の中でユーザーがさらに変換（ネストしたSKK変換。SKKの本領とも
--- 言える「再帰的な単語登録」）をしても、同じ state.lua を安全に再利用
--- できる。
---
--- 【コマンドライン用 preedit の後始末について】input() の中でネストした
--- 変換が行われると、preedit.lua のコマンドライン用追跡状態（module単位の
--- シングルトン）が上書きされる。そのため、この関数はその状態には頼らず、
--- input() を呼ぶ前に確保しておいたローカル変数（バッファ位置 or
--- コマンドラインの削除バイト数）を直接使って最終テキストを書き込む
--- （state.lua の confirm_text() と同じ書き込み経路）。
function M._trigger_registration()
  if not session then
    return
  end

  local fallback_text = current_fallback_text()
  local reading_display = render_for_mode(session.reading, session.source_mode)
  local okuri_display = render_for_mode(session.okuri_kana or "", session.source_mode)
  local search_key = session.search_key
  local search_has_okuri = session.search_has_okuri

  local target_kind = target.kind()

  candidate_window.hide()

  -- 【重要】▽/▼ のマーカー表示は、vim.fn.input() を呼ぶ前にここで
  -- 即座に消す（あとで消すのではなく）。
  --
  -- 理由: preedit.lua の M.anchor() は、コマンドラインモード用の状態を
  -- 設定する際にバッファモード用の状態（anchor_bufnr/anchor_row/
  -- anchor_col）を nil にクリアする実装になっている。これは通常の
  -- （ネストしない）利用では正しいが、単語登録UIでは「バッファで変換→
  -- 登録UI（vim.fn.input()）を開く→その中でさらに変換」という流れに
  -- なるため、ネストした変換が preedit.anchor() を呼んだ瞬間、外側
  -- （バッファ）の anchor 情報が消えてしまう。vim.fn.input() が終わった
  -- "あとで" preedit.hide() を呼ぶと、この時点で anchor_bufnr が
  -- 既に nil になっており、古い extmark が削除されずに残ってしまう
  -- （実機で発見された不具合）。マーカーが消えた後の挿入位置は
  -- バッファ側はカーソル位置（バッファのマーカーは extmark 表示のみで
  -- 実バッファには影響しないため、消してもカーソル位置は動かない）、
  -- コマンドライン側は preedit.hide() が返す新しいカーソル位置
  -- （setcmdline の第2引数）にそのまま追従するので、ここで先に消して
  -- おけば、確定時は「今のカーソル位置に挿入するだけ」でよくなり、
  -- ネストした変換による preedit.lua のシングルトン状態上書きの影響を
  -- 受けなくなる。
  local buf_bufnr, buf_row, buf_col
  if target_kind ~= "cmdline" then
    buf_bufnr, buf_row, buf_col = preedit.anchor_position()
  end
  preedit.hide()

  -- ここでこの変換セッションは終了させる（input() から戻ってきたときに
  -- 「続きから再開」はしない。上のコメント参照）。
  phase = "idle"
  session = nil
  notify_changed() -- 単語登録UI（vim.fn.input()）を開く前に「非アクティブ」を通知する

  local prompt = "[単語登録] " .. reading_display .. (search_has_okuri and ("*" .. okuri_display) or "") .. ": "

  -- 単語登録では変換操作を行う機会が圧倒的に多いため、登録UIの入力欄
  -- （これから開く vim.fn.input()、内部的には次のコマンドラインモード）
  -- はひらがなモードから始まるようにする（実機での要望。再帰的な単語
  -- 登録のたびに毎回 <C-j> するのは煩わしいため）。capture.lua を
  -- state.lua の先頭で require すると循環require（capture.lua が
  -- 起動時に state.lua を require している）になるため、この関数の中で
  -- 実行時に遅延requireする。
  local ok_capture, capture = pcall(require, "skk.capture")
  if ok_capture and capture.reserve_next_cmdline_mode then
    capture.reserve_next_cmdline_mode("hira")
  end

  local cancelled = false
  vim.keymap.set("c", "<Esc>", function()
    cancelled = true
    return "<CR>"
  end, { noremap = true, expr = true })
  vim.keymap.set("c", "<C-g>", function()
    cancelled = true
    return "<CR>"
  end, { noremap = true, expr = true })

  vim.schedule(function()
    local ok, result = pcall(vim.fn.input, prompt)
    pcall(vim.keymap.del, "c", "<Esc>")
    pcall(vim.keymap.del, "c", "<C-g>")

    local final_text
    if not ok or cancelled or result == "" then
      final_text = fallback_text
    else
      if search_key then
        dict.record_selection(search_key, search_has_okuri or false, result, nil)
      end
      final_text = result .. okuri_display
    end

    if target_kind == "cmdline" then
      -- preedit.hide() が既にマーカー分を削除し終えているので、
      -- 削除バイト数は 0（今のカーソル位置に挿入するだけ）でよい。
      target.replace_before_cursor(0, final_text)
    elseif buf_bufnr and buf_row ~= nil and buf_col ~= nil then
      vim.api.nvim_buf_set_text(buf_bufnr, buf_row, buf_col, buf_row, buf_col, { final_text })
      vim.api.nvim_win_set_cursor(0, { buf_row + 1, buf_col + #final_text })
    end
  end)
end

--- 候補ゼロ件のときのフォールバック。単語登録UIを開く。
function M._fallback_no_candidates()
  M._trigger_registration()
end

--- 次の候補（▼状態のみ）。<SPC> に割り当てる。
--- <SPC> を押した回数（session.space_count）が config.candidate_window_threshold
--- に達するまでは、1件ずつ候補を進めてインライン表示するだけで候補一覧
--- ウィンドウは出さない。閾値に達したその打鍵で（1件進めたうえで）
--- 初めてウィンドウを表示する。それ以降の <SPC> は通常どおりページ送り
--- （7候補ずつ）になる。
function M.next_page()
  if phase ~= "select" or not session then
    return
  end

  session.space_count = (session.space_count or 0) + 1

  if session.space_count < config.candidate_window_threshold then
    if session.index >= #session.candidates then
      M._trigger_registration()
      return
    end
    session:advance_single()
    show_inline_preview_only()
    return
  end

  if session.space_count == config.candidate_window_threshold then
    if session.index >= #session.candidates then
      M._trigger_registration()
      return
    end
    session:advance_single()
    show_select_ui()
    return
  end

  if session.page >= session:page_count() - 1 then
    M._trigger_registration()
    return
  end
  session:next_page()
  show_select_ui()
end

--- 前の候補・前ページ（x キー、▼状態のみ）。M.next_page() と対称的に、
--- 候補一覧ウィンドウがまだ表示されていない段階では1件ずつ戻すだけに
--- とどめ、ウィンドウは表示しない（<SPC> の打鍵回数はここでは消費しない。
--- 「戻る」操作なので、ウィンドウ表示までの前進をカウントし直す必要は無い）。
function M.prev_page()
  if phase ~= "select" or not session then
    return
  end

  if (session.space_count or 0) < config.candidate_window_threshold then
    session:retreat_single()
    show_inline_preview_only()
    return
  end

  session:prev_page()
  show_select_ui()
end

--- <C-n> 相当。候補一覧ウィンドウの中で、フォーカスを次の1候補へ移す
--- （末尾候補の次は次ページの先頭へ折り返す。Session:advance_single() が
--- ページ境界の折り返しも含めて面倒を見る）。<SPC> のしきい値設定とは
--- 独立した、明示的に一覧をブラウズする操作なので、呼ばれた時点で必ず
--- 候補一覧ウィンドウを表示する。
function M.focus_next()
  if phase ~= "select" or not session then
    return
  end
  if session.index >= #session.candidates then
    M._trigger_registration()
    return
  end
  session:advance_single()
  show_select_ui()
end

--- <C-p> 相当。M.focus_next() の逆方向（先頭候補での <C-p> は前ページの
--- 末尾候補へ折り返す）。
function M.focus_prev()
  if phase ~= "select" or not session then
    return
  end
  session:retreat_single()
  show_select_ui()
end

--- 候補一覧ウィンドウが（このセッション中に）既に表示されているかどうか。
--- capture.lua が、ホームポジションキー（a s d f j k l）を「候補選択」
--- として扱うか「直接入力」として扱うかの判定に使う。ウィンドウが
--- 見えていない段階（<SPC> の打鍵回数が candidate_window_threshold に
--- 達する前）でホームポジションキーを候補選択として食ってしまうと、
--- 見えない選択肢を選ばされる形になり、typoでの誤確定につながる
--- （実際に報告のあった問題）。
---@return boolean
function M.is_candidate_window_visible()
  return phase == "select" and session ~= nil and (session.space_count or 0) >= config.candidate_window_threshold
end

--- ホームポジションキー（a s d f j k l）による候補選択。
--- 現在ページの該当する位置に候補が無ければ何もせず nil を返す
--- （呼び出し側の capture.lua は、nil の場合は従来通り
--- 「確定して新しい入力として再処理」にフォールバックする）。
--- 【注意】候補一覧ウィンドウが表示されているかどうかの判定は
--- M.is_candidate_window_visible() 側の責務で、この関数自体は行わない
--- （呼び出し側が先にチェックする設計）。
---@param key string
---@return SkkDictCandidate|nil selected_candidate
function M.select_by_key(key)
  if phase ~= "select" or not session then
    return nil
  end
  local offset = nil
  for i, k in ipairs(candidate_window.HOME_ROW_KEYS) do
    if k == key then
      offset = i
      break
    end
  end
  if not offset then
    return nil
  end
  local selected = session:select_on_page(offset)
  return selected
end

--- ▽の間の q: 読みをカタカナに変換して即確定する。
--- 【設計ルール③】source_mode に関係なく、q は常にカタカナ確定で固定する
--- （<CR> が常にひらがな確定なのと対になる、モード非依存のルール）。
--- （▼状態では q に特別な意味を持たせない。phase 3 時点では未定義のため無視する）
function M.convert_and_confirm_kana()
  if phase ~= "midashi" or not session then
    return
  end
  M.confirm_text(kana_util.to_katakana(session.reading))
end

--- 外部UI（blink.cmp ネイティブソース等）から、特定の候補が選ばれたときに
--- 呼ぶ。通常の M.confirm()（現在フォーカス中の候補を確定）と違い、
--- 呼び出し側が指定した任意の reading/word をそのまま確定する。
---
--- 【なぜ必要か】blink.cmp のライブ補完（`▽` 見出し語入力中の前方一致
--- 候補、lua/skk/blink_source.lua）では、必ずしも現在の session が
--- 指している候補・読みとは限らない（例: `session.reading` が "かん" の
--- 時点で、前方一致した "かんじ"（漢字）を直接選ぶ、といったことが起きる）。
--- そのため reading/has_okuri/word を明示的に受け取る形にしてある。
---
--- 送りありの前方一致補完は現時点で提供していない（dict.lookup_prefix()
--- の設計を参照）ため、送り仮名の付与はしない。phase=="idle"（変換して
--- いない）なら何もしない。
---@param reading string
---@param has_okuri boolean
---@param word string
---@param annotation string|nil
function M.confirm_external(reading, has_okuri, word, annotation)
  if phase == "idle" then
    return
  end
  dict.record_selection(reading, has_okuri, word, annotation)
  M.confirm_text(word)
end

--- 確定操作（Enter 等）。▼状態なら選択中の候補+送り仮名、▽/abbrev状態なら
--- 見出しをそのまま確定する（▽は常にひらがな、ルール③。abbrevはASCIIそのもの）。
function M.confirm()
  if phase == "select" and session then
    local okurigana = render_for_mode(session.okuri_kana or "", session.source_mode)
    local candidate = session:current_candidate()
    if candidate and session.search_key then
      -- 個人辞書への学習。次回同じ読みを検索したとき、この候補が
      -- 先頭に来るようにする（本家SKKと同じ recency-based の学習）。
      dict.record_selection(session.search_key, session.search_has_okuri, candidate.word, candidate.annotation)
    end
    M.confirm_text((candidate and candidate.word or "") .. okurigana)
  elseif (phase == "midashi" or phase == "abbrev") and session then
    -- <CR> は常にひらがな確定。session.reading は元々ひらがなの内部表現
    -- なので、そのまま使えばよい（source_mode に関係なく変換しない）。
    -- abbrev の場合、session.reading は元々ASCII文字列なのでそのまま。
    M.confirm_text(session.reading)
  end
end

--- 実際に確定テキストを書き込んで、セッションを終了する。
--- バッファモードでは実バッファへ挿入（従来通り、textlock対策で
--- vim.schedule）。コマンドラインモードでは、preedit が表示していた
--- マーカーテキストの範囲を確定テキストで置き換える
--- （target.replace_before_cursor() に委譲。cmdline側のカーソルは
--- 常にマーカーの直後にあるので、その長さぶん削って確定テキストを
--- 挿入すればよい。target.lua のコマンドライン実装は、これまでの
--- ローマ字→かな変換で使っているのと同じ経路で、実機でも動作確認済み）。
---@param text string
function M.confirm_text(text)
  if target.kind() == "cmdline" then
    local byte_len = preedit.pending_cmdline_byte_len()
    preedit.clear_cmdline_tracking()
    candidate_window.hide()
    target.replace_before_cursor(byte_len, text)
    phase = "idle"
    session = nil
    notify_changed()
    return
  end

  local bufnr, row, col = preedit.anchor_position()
  preedit.hide()
  candidate_window.hide()
  if bufnr and row ~= nil and col ~= nil then
    vim.schedule(function()
      vim.api.nvim_buf_set_text(bufnr, row, col, row, col, { text })
      vim.api.nvim_win_set_cursor(0, { row + 1, col + #text })
    end)
  end
  phase = "idle"
  session = nil
  notify_changed()
end

--- <C-g> 相当。変換を中断し、何も挿入せずに破棄する。
function M.cancel()
  preedit.hide()
  candidate_window.hide()
  phase = "idle"
  session = nil
  notify_changed()
end

return M

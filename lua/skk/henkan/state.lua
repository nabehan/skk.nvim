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
end

--- abbrev モードの間に ASCII 文字を1文字追加する。
---@param char string
function M.input_abbrev(char)
  if phase ~= "abbrev" or not session then
    return
  end
  session:input_abbrev(char)
  preedit.show_abbrev(session.reading)
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
    if confirmed then
      M.search()
    end
    return
  end

  session:input_reading(char)
  preedit.show_midashi(midashi_display(), session.okuri_consonant)
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
    return
  end

  local has_more = session:backspace_reading()
  if not has_more then
    M.cancel()
    return
  end
  preedit.show_midashi(midashi_display(), session.okuri_consonant)
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
  local anchor_win = preedit.anchor_win()
  local _, row, col = preedit.anchor_position()
  if anchor_win and row ~= nil and col ~= nil then
    -- 現在選択中の候補が、表示するページの中で何番目（ホームポジションの
    -- どのキーの位置）に当たるかを求め、候補一覧ウィンドウ側でも同じ
    -- 候補をハイライトできるようにする（インライン ▼ 表示との整合性のため）。
    local selected_offset = session.index - session.page * Session.PAGE_SIZE
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

--- 候補ゼロ件のときのフォールバック。
--- 画面に表示していた（source_mode でレンダリング済みの）読み + 送り仮名を
--- そのままプレーンテキストで確定し、通知を出す。
--- 本家 SKK のシームレスな単語登録は今後実装予定。
function M._fallback_no_candidates()
  local text = render_for_mode(session.reading, session.source_mode)
    .. render_for_mode(session.okuri_kana or "", session.source_mode)
  M.confirm_text(text)
  vim.notify(
    "skk.nvim: 候補が見つかりませんでした（シームレスな単語登録は今後実装予定です）",
    vim.log.levels.INFO
  )
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
    session:advance_single()
    show_inline_preview_only()
    return
  end

  if session.space_count == config.candidate_window_threshold then
    session:advance_single()
    show_select_ui()
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

--- 実際にバッファへテキストを挿入して、セッションを終了する。
---@param text string
function M.confirm_text(text)
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
end

--- <C-g> 相当。変換を中断し、何も挿入せずに破棄する。
function M.cancel()
  preedit.hide()
  candidate_window.hide()
  phase = "idle"
  session = nil
end

return M

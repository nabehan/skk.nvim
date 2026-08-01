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
local dict = require("skk.dict")
local kana_util = require("skk.kana_util")

local M = {}

---@alias SkkHenkanPhase "idle"|"midashi"|"select"

---@type SkkHenkanPhase
local phase = "idle"
---@type SkkHenkanSession|nil
local session = nil

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
  local has_more = session:backspace_reading()
  if not has_more then
    M.cancel()
    return
  end
  preedit.show_midashi(midashi_display(), session.okuri_consonant)
end

--- スペース。▽状態なら辞書検索して▼へ、▼状態なら次候補へ。
function M.space()
  if phase == "midashi" then
    M.search()
  elseif phase == "select" then
    M.next_candidate()
  end
end

--- 辞書検索して▼へ遷移する（phase 3: 送りなしのみ）。
function M.search()
  if phase ~= "midashi" or not session or session.reading == "" then
    return
  end

  local key, has_okuri = session:dict_key()
  local candidates = dict.lookup(key, has_okuri)
  session:set_candidates(candidates)
  phase = "select"

  if #candidates == 0 then
    M._fallback_no_candidates()
    return
  end

  preedit.show_henkan(session:current_candidate(), render_for_mode(session.okuri_kana or "", session.source_mode))
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

--- 次候補（▼状態のみ）。
function M.next_candidate()
  if phase ~= "select" or not session then
    return
  end
  session:next_candidate()
  preedit.show_henkan(session:current_candidate(), render_for_mode(session.okuri_kana or "", session.source_mode))
end

--- 前候補、x キー相当（▼状態のみ）。
function M.prev_candidate()
  if phase ~= "select" or not session then
    return
  end
  session:prev_candidate()
  preedit.show_henkan(session:current_candidate(), render_for_mode(session.okuri_kana or "", session.source_mode))
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

--- 確定操作（Enter 等）。▼状態なら選択中の候補+送り仮名、▽状態なら
--- 読みをそのまま（常にひらがな、ルール③）確定する。
function M.confirm()
  if phase == "select" and session then
    local okurigana = render_for_mode(session.okuri_kana or "", session.source_mode)
    M.confirm_text((session:current_candidate() or "") .. okurigana)
  elseif phase == "midashi" and session then
    -- <CR> は常にひらがな確定。session.reading は元々ひらがなの内部表現
    -- なので、そのまま使えばよい（source_mode に関係なく変換しない）。
    M.confirm_text(session.reading)
  end
end

--- 実際にバッファへテキストを挿入して、セッションを終了する。
---@param text string
function M.confirm_text(text)
  local bufnr, row, col = preedit.anchor_position()
  preedit.hide()
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
  phase = "idle"
  session = nil
end

return M

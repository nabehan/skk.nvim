-- lua/skk/henkan/state.lua
--
-- ▽/▼ の状態機械本体。lua/skk/capture.lua から呼ばれる。
--
-- 【phase 3 時点のスコープ】送りなし変換のみ対応する。送りあり関連の
-- メソッド（Session:start_okuri 等）は既に用意されているが、ここから
-- はまだ呼ばない（実装順序4で配線する）。
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

--- ▽ を開始する。capture.lua が大文字キー検知時に呼ぶ。
---@param mode "hira"|"kata" ▽を開始したモード（送り仮名や q の変換先に使う）
---@param first_char string 大文字キーを小文字化した、最初のローマ字1文字
function M.start_midashi(mode, first_char)
  phase = "midashi"
  session = Session.new(mode)
  preedit.anchor()
  session:input_reading(first_char)
  preedit.show_midashi(session.reading, session.okuri_consonant)
end

--- ▽の間にローマ字を1文字追加する。
---@param char string
function M.input(char)
  if phase ~= "midashi" or not session then
    return
  end
  session:input_reading(char)
  preedit.show_midashi(session.reading, session.okuri_consonant)
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
  preedit.show_midashi(session.reading, session.okuri_consonant)
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

  preedit.show_henkan(session:current_candidate(), session.okuri_kana)
end

--- 候補ゼロ件のときのフォールバック。
--- 読みをそのままプレーンテキストで確定し、通知を出す。
--- 本家 SKK のシームレスな単語登録は今後実装予定。
function M._fallback_no_candidates()
  local reading = session.reading
  M.confirm_text(reading)
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
  preedit.show_henkan(session:current_candidate(), session.okuri_kana)
end

--- 前候補、x キー相当（▼状態のみ）。
function M.prev_candidate()
  if phase ~= "select" or not session then
    return
  end
  session:prev_candidate()
  preedit.show_henkan(session:current_candidate(), session.okuri_kana)
end

--- ▽の間の q: 読みをカタカナ/ひらがなに変換して即確定する。
--- （▼状態では q に特別な意味を持たせない。phase 3 時点では未定義のため無視する）
function M.convert_and_confirm_kana()
  if phase ~= "midashi" or not session then
    return
  end
  local text
  if session.source_mode == "hira" then
    text = kana_util.to_katakana(session.reading)
  else
    text = katakana_to_hiragana(session.reading)
  end
  M.confirm_text(text)
end

--- 確定操作（Enter 等）。▼状態なら選択中の候補、▽状態なら読みをそのまま確定する。
function M.confirm()
  if phase == "select" and session then
    M.confirm_text((session:current_candidate() or "") .. (session.okuri_kana or ""))
  elseif phase == "midashi" and session then
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

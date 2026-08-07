-- lua/skk/henkan/session.lua
--
-- 1回の変換セッション（▽読み入力〜▼候補選択）のデータを保持する。
--
-- 【phase 3 時点のスコープ】送りなし変換のみを対象とする。送りあり関連の
-- フィールド・メソッド（okuri_consonant 等）は将来のフェーズ（実装順序4）
-- のために用意してあるが、まだ capture.lua からは呼ばれない。
--
-- 読み自体のローマ字→かな変換には、直接入力（lua/skk/context.lua +
-- lua/skk/input.lua）と全く同じ部品をそのまま再利用する。実バッファには
-- 一切書き込まず、変換結果は session.reading に文字列として積むだけ。

local Context = require("skk.context")
local Input = require("skk.input")
local kana_util = require("skk.kana_util")

---@class SkkHenkanSession
---@field reading string 確定済みの読み（ひらがな）。辞書検索キーの本体。
---@field okuri_consonant string|nil 送り開始点のローマ字子音。nil なら送りなし。
---@field okuri_kana string|nil 確定した送り仮名（ひらがな）。
---@field source_mode "hira"|"kata" このセッションを開始したモード
---@field candidates string[] 辞書検索結果の候補一覧
---@field index integer 現在選択中の候補（1-indexed）。0 は未検索。
---@field page integer 候補一覧ウィンドウの現在ページ（0-indexed）
---@field reading_input SkkContext 読み入力用の変換エンジン状態（内部専用）
---@field okuri_input SkkContext 送り仮名入力用の変換エンジン状態（内部専用）
local Session = {}
Session.__index = Session

--- 候補一覧ウィンドウ1ページあたりの候補数。ホームポジション
--- （a s d f j k l）の7キーに対応する。
--- 【注意】`;` は Sticky-shift のトリガーキーと衝突するため、
--- ホームポジションの選択キーには含めない（8キーではなく7キー）。
Session.PAGE_SIZE = 7

---@param source_mode "hira"|"kata"
---@return SkkHenkanSession
function Session.new(source_mode)
  return setmetatable({
    reading = "",
    okuri_consonant = nil,
    okuri_kana = nil,
    source_mode = source_mode,
    candidates = {},
    index = 0,
    page = 0,
    reading_input = Context.new(),
    okuri_input = Context.new(),
  }, Session)
end

--- 読み入力中（▽、送り未開始）にローマ字を1文字追加する。
--- 確定したかなは session.reading に積まれる。
---@param char string
function Session:input_reading(char)
  Input.kanaInput(self.reading_input, char)
  self.reading = self.reading .. self.reading_input:flush()
end

--- 読みの未確定ローマ字断片（例: "k" だけ打った直後）を返す。
---@return string
function Session:reading_pending()
  return self.reading_input.buffer
end

--- 読みを1文字分削除する（<BS>相当）。
--- 未確定のローマ字断片があればそちらを優先して1文字削る。
--- reading 自体を削る場合は UTF-8 の文字境界を考慮する。
---@return boolean has_more 削除後もセッションを継続すべきか
--- （false ならもう読みが完全に空になったので、呼び出し側はセッションを終了させる）
function Session:backspace_reading()
  if self.reading_input.buffer ~= "" then
    self.reading_input.buffer = self.reading_input.buffer:sub(1, -2)
    return true
  end

  if self.reading == "" then
    return false
  end

  local codepoints = kana_util._utf8_decode(self.reading)
  table.remove(codepoints)
  local out = {}
  for _, cp in ipairs(codepoints) do
    table.insert(out, kana_util._utf8_encode(cp))
  end
  self.reading = table.concat(out)

  return self.reading ~= "" or self:reading_pending() ~= ""
end

--- 送り開始点を設定する（大文字/;を検知したときに呼ぶ）。
--- この時点ではまだ子音は不明。次の input_okuri() の1文字目が子音になる。
--- 直前の読み入力に未確定のローマ字断片が残っていた場合は破棄する
--- （送り開始点以降は okuri_input 側の変換エンジンに切り替わるため、
--- 中途半端な断片を表示に残さないようにするための後始末）。
function Session:start_okuri()
  self.reading_input.buffer = ""
  self.okuri_consonant = ""
end

---@return boolean
function Session:is_okuri_pending()
  return self.okuri_consonant ~= nil
end

--- 送り仮名のローマ字を1文字追加する。
---@param char string
---@return boolean confirmed 送り仮名（子音+母音）が確定したかどうか
function Session:input_okuri(char)
  if self.okuri_consonant == "" then
    -- 最初の1文字は子音として記録しておく（辞書検索キーに使うため）
    self.okuri_consonant = char
  end
  Input.kanaInput(self.okuri_input, char)
  local confirmed = self.okuri_input:flush()
  if confirmed ~= "" then
    self.okuri_kana = confirmed
    return true
  end
  return false
end

--- 辞書検索用のキーを返す。
--- 送りありの場合は reading .. okuri_consonant（例: "うご" .. "k" = "うごk"）。
---@return string key
---@return boolean has_okuri
function Session:dict_key()
  if self.okuri_consonant and self.okuri_consonant ~= "" then
    return self.reading .. self.okuri_consonant, true
  end
  return self.reading, false
end

--- 検索結果の候補をセットし、先頭候補を選択状態にする（1ページ目）。
---@param candidates string[]
function Session:set_candidates(candidates)
  self.candidates = candidates
  self.index = (#candidates > 0) and 1 or 0
  self.page = 0
end

---@return string|nil
function Session:current_candidate()
  if self.index >= 1 and self.index <= #self.candidates then
    return self.candidates[self.index]
  end
  return nil
end

--- 現在のページ数（候補が0件なら0）。
---@return integer
function Session:page_count()
  if #self.candidates == 0 then
    return 0
  end
  return math.ceil(#self.candidates / Session.PAGE_SIZE)
end

--- 現在のページに含まれる候補（最大 PAGE_SIZE 件）を先頭から順に返す。
--- 候補選択ウィンドウの表示に使う（ホームポジションキーとの対応は
--- 返り値の配列インデックス = a,s,d,f,j,k,l,; の順）。
---@return string[]
function Session:page_candidates()
  local out = {}
  if #self.candidates == 0 then
    return out
  end
  local start = self.page * Session.PAGE_SIZE + 1
  local stop = math.min(start + Session.PAGE_SIZE - 1, #self.candidates)
  for i = start, stop do
    table.insert(out, self.candidates[i])
  end
  return out
end

--- 次のページ（次の7候補）へ切り替える（末尾ページの次は先頭ページに循環する）。
--- 選択状態はそのページの先頭候補になる。
function Session:next_page()
  local count = self:page_count()
  if count == 0 then
    return
  end
  self.page = (self.page + 1) % count
  self.index = self.page * Session.PAGE_SIZE + 1
end

--- 前のページ（前の7候補）へ戻す（先頭ページの前は末尾ページに循環する）。
--- 選択状態はそのページの先頭候補になる。
function Session:prev_page()
  local count = self:page_count()
  if count == 0 then
    return
  end
  self.page = (self.page - 1) % count
  self.index = self.page * Session.PAGE_SIZE + 1
end

--- 現在のページ内で、ホームポジションキーの位置（1〜7）を指定して
--- 候補を選択状態にする。その位置に候補が無ければ何もせず nil を返す。
---@param offset integer 1〜7（a=1, s=2, d=3, f=4, j=5, k=6, l=7）
---@return string|nil selected_candidate
function Session:select_on_page(offset)
  local idx = self.page * Session.PAGE_SIZE + offset
  if idx < 1 or idx > #self.candidates then
    return nil
  end
  self.index = idx
  return self.candidates[idx]
end

return Session

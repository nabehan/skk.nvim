-- lua/skk/context.lua
--
-- SKK の入力状態を保持するオブジェクト。
-- 1つの Context が「今カーソル位置で何を入力中か」を表す。
--
-- fixed:  確定済みの出力（かな）。output() が呼ばれるまでここに積まれる。
-- buffer: まだかなに変換しきれていないローマ字の断片（例: "k" だけ打った直後）。
-- mode:   将来 かな/カナ/変換待ち(▽/▼) 等を切り替えるためのモード。
--         現時点では "hira"（ひらがな直接入力）のみ実装する。

---@class SkkContext
---@field fixed string 確定済みの出力
---@field buffer string 未確定のローマ字断片
---@field mode "hira"|"kata"
local Context = {}
Context.__index = Context

---@return SkkContext
function Context.new()
  return setmetatable({
    fixed = "",
    buffer = "",
    mode = "hira",
  }, Context)
end

--- 確定済み出力を取り出し、内部バッファをクリアする。
--- （実際にバッファへ挿入する処理は呼び出し側が行う）
---@return string
function Context:flush()
  local out = self.fixed
  self.fixed = ""
  return out
end

--- 確定済み出力にかなを追加する。
---@param kana string
function Context:doKakutei(kana)
  self.fixed = self.fixed .. kana
end

--- 現在の表示用テキスト（確定済み + 未確定バッファ）。
--- pre-edit 表示（▽ 相当）に使う想定。
---@return string
function Context:display()
  return self.fixed .. self.buffer
end

return Context

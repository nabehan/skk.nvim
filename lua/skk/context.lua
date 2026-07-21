--- SKK の入力状態を保持するコンテキスト。
--- 参考: uga-rosa/skk-learning.nvim の Context 設計。
---
--- TODO: 次のステップでローマ字→かな変換の実装と合わせて詳細を詰める。
---@class skk.Context
---@field fixed string 確定済みの出力（呼び出し側が output() で受け取って消費する想定）
---@field tmpResult string 変換途中のローマ字断片（例: "k" だけ打った状態）
local Context = {}
Context.__index = Context

---@return skk.Context
function Context.new()
  return setmetatable({
    fixed = "",
    tmpResult = "",
  }, Context)
end

return Context

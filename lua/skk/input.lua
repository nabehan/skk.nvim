--- ローマ字 -> かな変換のステートマシン。
---
--- TODO: これから実装する。参考:
--- - uga-rosa/skk-learning.nvim
--- - Zenn「SKK実装入門」シリーズ (uga_rosa)
---@class skk.Input
local Input = {}

---@param context skk.Context
---@param char string 1文字（マルチバイト文字1つ分の文字列）
function Input.kanaInput(context, char)
  -- TODO: ローマ字テーブルを引いて context.fixed / context.tmpResult を更新する
  error("not implemented yet")
end

return Input

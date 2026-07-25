-- lua/skk/mode.lua
--
-- SKK の入力モード状態機械。vim.* API に依存しない純粋なロジックのみを持つ
-- （lua5.4 等、素の Lua だけでもテストできるようにするため capture.lua から
-- 分離している）。

local M = {}

---@type table<SkkMode, string>
M.LABELS = {
  ascii = "半角英数",
  hira = "ひらがな",
  kata = "カタカナ",
  zenei = "全角英数",
}

-- l/q/L による印字可能キーでのモード切替（未確定バッファが空のときのみ有効。
-- 呼び出し側 (capture.lua) が判定する）。
---@type table<string, table<SkkMode, SkkMode>>
M.CHAR_TRANSITIONS = {
  l = { hira = "ascii", kata = "ascii" },
  q = { hira = "kata", kata = "hira" },
  L = { hira = "zenei", kata = "zenei" },
}

-- <C-j> による制御キーでのモード切替。
-- （半角カナモード検討時は <C-q> も使っていたが、半角カナは実装しない
--  方針としたため、制御キーによる遷移は <C-j> のみになった）
---@type table<string, table<SkkMode, SkkMode>>
M.CTRL_TRANSITIONS = {
  ["<C-j>"] = { ascii = "hira", zenei = "hira" },
}

---@param transitions table<string, table<SkkMode, SkkMode>>
---@param key string
---@param current SkkMode
---@return SkkMode|nil
local function lookup(transitions, key, current)
  local t = transitions[key]
  return t and t[current] or nil
end

--- l/q/L による、印字可能キーでのモード遷移先を調べる。
--- 遷移先が定義されていなければ nil を返す（= 通常のローマ字入力として扱う）。
---@param key string
---@param current SkkMode
---@return SkkMode|nil
function M.char_transition(key, current)
  return lookup(M.CHAR_TRANSITIONS, key, current)
end

--- <C-j> など、制御キーでのモード遷移先を調べる。
---@param ctrl_key string 例: "<C-j>"
---@param current SkkMode
---@return SkkMode|nil
function M.ctrl_transition(ctrl_key, current)
  return lookup(M.CTRL_TRANSITIONS, ctrl_key, current)
end

--- モードの日本語表示名を返す。
---@param mode SkkMode
---@return string
function M.label(mode)
  return M.LABELS[mode] or mode
end

return M

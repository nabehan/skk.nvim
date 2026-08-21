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
-- キー自体は set_char_keys() で差し替え可能（デフォルトは l/q/L）。
-- 遷移の意味（物理キーとは独立）:
--   to_ascii         ひらがな/カタカナ -> 半角英数
--   to_kata_or_hira  ひらがな -> カタカナ / カタカナ -> ひらがな（相互遷移）
--   to_zenei         ひらがな/カタカナ -> 全角英数
---@type table<string, table<SkkMode, SkkMode>>
local CHAR_TRANSITION_RULES = {
  to_ascii = { hira = "ascii", kata = "ascii" },
  to_kata_or_hira = { hira = "kata", kata = "hira" },
  to_zenei = { hira = "zenei", kata = "zenei" },
}

---@type table<string, table<SkkMode, SkkMode>>
M.CHAR_TRANSITIONS = {
  l = CHAR_TRANSITION_RULES.to_ascii,
  q = CHAR_TRANSITION_RULES.to_kata_or_hira,
  L = CHAR_TRANSITION_RULES.to_zenei,
}

--- l/q/L に割り当てる物理キーを差し替える（lua/skk/init.lua の setup() から
--- capture.lua 経由で呼ばれる）。省略した項目はデフォルト（l/q/L）を使う。
---@param keys { to_ascii: string?, to_kata_or_hira: string?, to_zenei: string? }|nil
function M.set_char_keys(keys)
  keys = keys or {}
  -- 前回のキー割り当てが残らないよう、毎回作り直す。
  M.CHAR_TRANSITIONS = {
    [keys.to_ascii or "l"] = CHAR_TRANSITION_RULES.to_ascii,
    [keys.to_kata_or_hira or "q"] = CHAR_TRANSITION_RULES.to_kata_or_hira,
    [keys.to_zenei or "L"] = CHAR_TRANSITION_RULES.to_zenei,
  }
end

-- <C-j> による制御キーでのモード切替。
-- （半角カナモード検討時は <C-q> も使っていたが、半角カナは実装しない
--  方針としたため、制御キーによる遷移は <C-j> のみになった）
-- 複数キーを同時に有効にできる（バッファ用とコマンドライン用で異なる
-- enter_key を設定した場合、両方をここに登録する。set_ctrl_keys() 参照）。
---@type table<string, table<SkkMode, SkkMode>>
local CTRL_TRANSITION_RULE = { ascii = "hira", zenei = "hira" }

---@type table<string, table<SkkMode, SkkMode>>
M.CTRL_TRANSITIONS = { ["<C-j>"] = CTRL_TRANSITION_RULE }

--- 制御キー（enter_key 相当）でのモード遷移（ascii/zenei -> hira）に割り当てる
--- 物理キーを差し替える。バッファ用・コマンドライン用に異なるキーを設定した
--- 場合等、複数キーをまとめて有効にできる。
---@param keys string[]|nil 省略時は ["<C-j>"]
function M.set_ctrl_keys(keys)
  keys = keys or { "<C-j>" }
  M.CTRL_TRANSITIONS = {}
  for _, key in ipairs(keys) do
    M.CTRL_TRANSITIONS[key] = CTRL_TRANSITION_RULE
  end
end

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

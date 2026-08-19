-- lua/skk/candidate_nav.lua
--
-- <C-n>/<C-p>（候補一覧ウィンドウのフォーカス移動）押下時に、henkan の
-- フェーズと「setup() 時点で既にそのキーに張られていたマッピング」から
-- 実際に何をすべきかを決定する、vim.* API に依存しない純粋ロジック。
--
-- 【背景・実機で発見】この移動は元々 vim.on_key() だけで処理していたが、
-- blink.cmp 等の補完プラグインが挿入モードに <C-n>/<C-p> の実キーマップ
-- （nvim_buf_set_keymap / nvim_set_keymap）を張っている環境では、そちらが
-- vim.on_key() より先にキーを消費してしまい、henkan の ▼(select) フェーズ
-- 中でもフォーカスが動かない不具合があった。
-- lua/skk/init.lua 側は setup() 時点で vim.fn.maparg() を使い、その時点で
-- 既に張られていたマッピング（他プラグインのもの）を1回だけ読み取って
-- 保存し、以後 <C-n>/<C-p> 押下のたびにこのモジュールの resolve() を呼んで
-- 「候補選択として奪うか / 委譲するか / そのまま通すか」を判定する。
-- 実際の vim.api 呼び出し（feedkeys 等の副作用）は init.lua 側が担当する
-- （このモジュールは判定結果を表す table を返すだけ）。

local M = {}

---@alias SkkCandidateNavResultKind
---| "candidate" # henkan_state.focus_next()/focus_prev() 相当を実行すべき
---| "callback" # 既存マッピングの callback をそのまま呼ぶ
---| "expr_callback" # 既存マッピングが <expr> 付き callback。戻り値を feedkeys する
---| "rhs" # 既存マッピングの rhs をそのまま feedkeys する
---| "expr_rhs" # 既存マッピングが <expr> 付き rhs。vim.fn.eval() した結果を feedkeys する
---| "passthrough" # 既存マッピングが無い。キー自体を feedkeys で素通りさせる

---@class SkkCandidateNavResult
---@field kind SkkCandidateNavResultKind
---@field callback function? kind=="callback"|"expr_callback" のときの既存 callback
---@field rhs string? kind=="rhs"|"expr_rhs" のときの既存 rhs
---@field noremap boolean? 既存マッピングの noremap（true なら feedkeys の "n"、false なら "m"）
---@field replace_keycodes boolean? kind=="expr_callback" のときの既存 replace_keycodes

--- henkan のフェーズと、setup() 時点で捕捉しておいた既存マッピング
--- （vim.fn.maparg(key, "i", false, true) の戻り値。マッピングが無ければ
--- nil または空 table）から、今回の <C-n>/<C-p> 押下で何をすべきかを返す。
---@param phase SkkHenkanPhase henkan_state.get_phase() の返り値
---@param existing table|nil vim.fn.maparg() の戻り値相当
---@return SkkCandidateNavResult
function M.resolve(phase, existing)
  if phase == "select" then
    return { kind = "candidate" }
  end

  if existing == nil or next(existing) == nil then
    return { kind = "passthrough" }
  end

  if type(existing.callback) == "function" then
    if existing.expr == 1 then
      return {
        kind = "expr_callback",
        callback = existing.callback,
        noremap = existing.noremap == 1,
        replace_keycodes = existing.replace_keycodes == 1,
      }
    end
    return { kind = "callback", callback = existing.callback }
  end

  if existing.rhs and existing.rhs ~= "" then
    if existing.expr == 1 then
      return { kind = "expr_rhs", rhs = existing.rhs, noremap = existing.noremap == 1 }
    end
    return { kind = "rhs", rhs = existing.rhs, noremap = existing.noremap == 1 }
  end

  return { kind = "passthrough" }
end

return M

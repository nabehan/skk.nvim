-- tests/candidate_nav_spec.lua
--
-- lua/skk/candidate_nav.lua のテスト。vim.* に依存しないので素の Lua だけで
-- 検証できる。
--
-- 【再発防止】実機で報告された不具合：候補一覧ウィンドウ表示中
-- （henkan フェーズ "select"）に <C-n>/<C-p> を押しても候補選択のフォーカスが
-- 動かない。原因は blink.cmp が挿入モードに <C-n>/<C-p> の実キーマップ
-- （nvim_buf_set_keymap 経由の callback）を張っており、vim.on_key() より
-- 先にキーを消費していたこと。lua/skk/init.lua は setup() 時点で
-- vim.fn.maparg() を使って既存マッピングを捕捉し、以後は
-- candidate_nav.resolve(phase, existing) の判定結果に従って
-- 「候補選択として奪うか」「既存マッピングへ委譲するか」を決める。

local candidate_nav = require("skk.candidate_nav")

describe("candidate_nav.resolve", function()
  it(
    "phase が select なら、既存マッピングの有無に関わらず候補選択を返す（本題の再発防止）",
    function()
      -- blink.cmp 相当の callback マッピングが存在していても、
      -- henkan が ▼(select) フェーズ中は候補選択が最優先される。
      local existing = {
        callback = function() end,
        expr = 0,
        noremap = 1,
      }
      local result = candidate_nav.resolve("select", existing)
      assert.are.equal("candidate", result.kind)
    end
  )

  it("phase が select なら、既存マッピングが無くても候補選択を返す", function()
    local result = candidate_nav.resolve("select", nil)
    assert.are.equal("candidate", result.kind)
  end)

  it(
    "phase が select 以外（idle）で、callback 形式の既存マッピングがあれば委譲する",
    function()
      local dummy_callback = function() end
      local existing = {
        callback = dummy_callback,
        expr = 0,
        noremap = 1,
      }
      local result = candidate_nav.resolve("idle", existing)
      assert.are.equal("callback", result.kind)
      assert.are.equal(dummy_callback, result.callback)
    end
  )

  it(
    "phase が select 以外（midashi）で、<expr> 付き callback マッピングなら expr_callback を返す",
    function()
      local dummy_callback = function()
        return "<Something>"
      end
      local existing = {
        callback = dummy_callback,
        expr = 1,
        noremap = 1,
        replace_keycodes = 1,
      }
      local result = candidate_nav.resolve("midashi", existing)
      assert.are.equal("expr_callback", result.kind)
      assert.are.equal(dummy_callback, result.callback)
      assert.is_true(result.noremap)
      assert.is_true(result.replace_keycodes)
    end
  )

  it("phase が select 以外で、rhs 形式の既存マッピングなら rhs を返す", function()
    local existing = {
      rhs = "<Plug>(something)",
      expr = 0,
      noremap = 0,
    }
    local result = candidate_nav.resolve("abbrev", existing)
    assert.are.equal("rhs", result.kind)
    assert.are.equal("<Plug>(something)", result.rhs)
    assert.is_false(result.noremap)
  end)

  it("phase が select 以外で、<expr> 付き rhs マッピングなら expr_rhs を返す", function()
    local existing = {
      rhs = "SomeExprFunc()",
      expr = 1,
      noremap = 1,
    }
    local result = candidate_nav.resolve("idle", existing)
    assert.are.equal("expr_rhs", result.kind)
    assert.are.equal("SomeExprFunc()", result.rhs)
  end)

  it("phase が select 以外で、既存マッピングが無ければ passthrough を返す", function()
    local result = candidate_nav.resolve("idle", nil)
    assert.are.equal("passthrough", result.kind)
  end)

  it("phase が select 以外で、既存マッピングが空 table でも passthrough を返す", function()
    -- vim.fn.maparg(key, mode, false, true) はマッピングが無い場合に
    -- 空 table を返す（nil ではない）ため、これも明示的に確認する。
    local result = candidate_nav.resolve("idle", {})
    assert.are.equal("passthrough", result.kind)
  end)

  it(
    "phase が select 以外で、callback も rhs も無い既存マッピングなら passthrough を返す",
    function()
      local existing = { buffer = 1 }
      local result = candidate_nav.resolve("idle", existing)
      assert.are.equal("passthrough", result.kind)
    end
  )
end)

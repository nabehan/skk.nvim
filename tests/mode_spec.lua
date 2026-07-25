-- tests/mode_spec.lua
--
-- lua/skk/mode.lua（vim.* に依存しない純粋なモード遷移ロジック）のテスト。

local mode_util = require("skk.mode")

describe("mode.char_transition (l/q/L)", function()
  it("hira -l-> ascii", function()
    assert.are.equal("ascii", mode_util.char_transition("l", "hira"))
  end)

  it("hira -q-> kata", function()
    assert.are.equal("kata", mode_util.char_transition("q", "hira"))
  end)

  it("hira -L-> zenei", function()
    assert.are.equal("zenei", mode_util.char_transition("L", "hira"))
  end)

  it("kata -l-> ascii", function()
    assert.are.equal("ascii", mode_util.char_transition("l", "kata"))
  end)

  it("kata -q-> hira", function()
    assert.are.equal("hira", mode_util.char_transition("q", "kata"))
  end)

  it("kata -L-> zenei", function()
    assert.are.equal("zenei", mode_util.char_transition("L", "kata"))
  end)

  it("ascii/zenei では l/q/L に遷移先が定義されていない", function()
    assert.is_nil(mode_util.char_transition("l", "ascii"))
    assert.is_nil(mode_util.char_transition("q", "ascii"))
    assert.is_nil(mode_util.char_transition("L", "ascii"))
    assert.is_nil(mode_util.char_transition("l", "zenei"))
    assert.is_nil(mode_util.char_transition("q", "zenei"))
    assert.is_nil(mode_util.char_transition("L", "zenei"))
  end)

  it("l/q/L 以外のキーには遷移先がない", function()
    assert.is_nil(mode_util.char_transition("a", "hira"))
    assert.is_nil(mode_util.char_transition("k", "hira"))
  end)
end)

describe("mode.ctrl_transition (<C-j>)", function()
  it("<C-j>: ascii -> hira", function()
    assert.are.equal("hira", mode_util.ctrl_transition("<C-j>", "ascii"))
  end)

  it("<C-j>: zenei -> hira", function()
    assert.are.equal("hira", mode_util.ctrl_transition("<C-j>", "zenei"))
  end)

  it("<C-j>: hira/kata では未定義", function()
    assert.is_nil(mode_util.ctrl_transition("<C-j>", "hira"))
    assert.is_nil(mode_util.ctrl_transition("<C-j>", "kata"))
  end)

  it("<C-q> はもう遷移を持たない（半角カナモード廃止のため）", function()
    assert.is_nil(mode_util.ctrl_transition("<C-q>", "hira"))
    assert.is_nil(mode_util.ctrl_transition("<C-q>", "kata"))
    assert.is_nil(mode_util.ctrl_transition("<C-q>", "ascii"))
    assert.is_nil(mode_util.ctrl_transition("<C-q>", "zenei"))
  end)
end)

describe("mode.label", function()
  it("4モードすべてに日本語ラベルがある", function()
    assert.are.equal("半角英数", mode_util.label("ascii"))
    assert.are.equal("ひらがな", mode_util.label("hira"))
    assert.are.equal("カタカナ", mode_util.label("kata"))
    assert.are.equal("全角英数", mode_util.label("zenei"))
  end)
end)

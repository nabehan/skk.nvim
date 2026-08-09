-- tests/mode_indicator_spec.lua
--
-- lua/skk/mode_indicator.lua と、それを呼び出す capture.lua の統合を検証する。
-- vim.api（フローティングウィンドウ）を実際に使うため、実 headless Neovim
-- 上でのみ意味のあるテスト（plenary は各specファイルを独立した headless
-- Neovim プロセスで実行するので、通常通り動く）。

local mode_indicator = require("skk.mode_indicator")
local capture = require("skk.capture")

describe("mode_indicator.GLYPHS", function()
  it("4モードすべてにグリフが定義されている", function()
    assert.are.equal("ひら", mode_indicator.GLYPHS.hira)
    assert.are.equal("カタ", mode_indicator.GLYPHS.kata)
    assert.are.equal("latn", mode_indicator.GLYPHS.ascii)
    assert.are.equal("ＬＡ", mode_indicator.GLYPHS.zenei)
  end)
end)

describe("mode_indicator.show/hide", function()
  before_each(function()
    mode_indicator.hide()
  end)

  it("show() すると、そのモードのグリフが表示される", function()
    mode_indicator.show("hira")
    assert.are.equal("ひら", mode_indicator._current_glyph())
  end)

  it("hide() すると表示が消える", function()
    mode_indicator.show("kata")
    mode_indicator.hide()
    assert.is_nil(mode_indicator._current_glyph())
  end)

  it("対応するグリフの無いモードを渡しても何も起きない", function()
    assert.has_no.errors(function()
      mode_indicator.show("nosuchmode")
    end)
    assert.is_nil(mode_indicator._current_glyph())
  end)
end)

describe("capture.transition() とモードインジケーターの統合", function()
  before_each(function()
    mode_indicator.hide()
  end)

  it("回帰テスト: <C-j> でモードが変わったとき、インジケーターも表示される", function()
    -- 過去、<C-j> は vim.on_key() の on_key() を通らず、
    -- init.lua が vim.keymap.set() 経由で capture.transition() を直接
    -- 呼ぶ別ルートだったため、インジケーター表示（本来 on_key() 側の
    -- l/q/L 遷移でしか呼んでいなかった）が漏れていた不具合があった。
    local target = capture.transition("<C-j>")
    assert.are.equal("hira", target)
    assert.are.equal("ひら", mode_indicator._current_glyph())
  end)

  it("遷移先が無い場合は nil を返し、インジケーターも表示しない", function()
    -- capture.lua の context はこのファイル内でモジュール単位の
    -- シングルトンなので、直前のテストで <C-j> により既に hira に
    -- 遷移済みのはず。ctrl_transition は hira/kata からの <C-j> 遷移先を
    -- 定義していない（ascii/zenei -> hira のみ）ので、ここでは
    -- 未定義の遷移になることを確認する。
    mode_indicator.hide()
    local target = capture.transition("<C-j>")
    assert.is_nil(target)
    assert.is_nil(mode_indicator._current_glyph())
  end)
end)

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

-- 【実機からの要望・再発防止】l/q/L・<C-j> それぞれの物理キーを、
-- 他プラグイン（skkeleton 等）との共存を考慮してユーザーが差し替え
-- られるようにした（lua/skk/init.lua の setup() オプション経由）。
-- set_char_keys()/set_ctrl_keys() はテスト間の状態が残らないよう、
-- 各 it() の最後に必ずデフォルトへ戻す。
describe("mode.set_char_keys（l/q/L の物理キーの差し替え）", function()
  after_each(function()
    mode_util.set_char_keys() -- デフォルト（l/q/L）に戻す
  end)

  it("差し替えたキーで遷移が効き、デフォルトのl/q/Lはもう効かなくなる", function()
    mode_util.set_char_keys({ to_ascii = "j", to_kata_or_hira = "k", to_zenei = "h" })

    assert.are.equal("ascii", mode_util.char_transition("j", "hira"))
    assert.are.equal("kata", mode_util.char_transition("k", "hira"))
    assert.are.equal("zenei", mode_util.char_transition("h", "hira"))

    assert.is_nil(mode_util.char_transition("l", "hira"))
    assert.is_nil(mode_util.char_transition("q", "hira"))
    assert.is_nil(mode_util.char_transition("L", "hira"))
  end)

  it("一部だけ差し替えても、残りはデフォルトのまま使える", function()
    mode_util.set_char_keys({ to_ascii = "j" })

    assert.are.equal("ascii", mode_util.char_transition("j", "hira"))
    assert.are.equal("kata", mode_util.char_transition("q", "hira")) -- デフォルトのまま
    assert.are.equal("zenei", mode_util.char_transition("L", "hira")) -- デフォルトのまま
    assert.is_nil(mode_util.char_transition("l", "hira")) -- 差し替えられて消えている
  end)

  it("引数無しで呼ぶとデフォルト（l/q/L）に戻る", function()
    mode_util.set_char_keys({ to_ascii = "j" })
    mode_util.set_char_keys()

    assert.are.equal("ascii", mode_util.char_transition("l", "hira"))
    assert.is_nil(mode_util.char_transition("j", "hira"))
  end)
end)

describe("mode.set_ctrl_keys（<C-j> 相当の物理キーの差し替え）", function()
  after_each(function()
    mode_util.set_ctrl_keys() -- デフォルト（<C-j>）に戻す
  end)

  it(
    "複数キーを同時に有効化できる（バッファ用・コマンドライン用で異なる enter_key を想定）",
    function()
      mode_util.set_ctrl_keys({ "<C-j>", "<C-CR>" })

      assert.are.equal("hira", mode_util.ctrl_transition("<C-j>", "ascii"))
      assert.are.equal("hira", mode_util.ctrl_transition("<C-CR>", "ascii"))
    end
  )

  it("差し替えると、デフォルトの<C-j>だけを渡さない限りもう効かない", function()
    mode_util.set_ctrl_keys({ "<C-CR>" })

    assert.is_nil(mode_util.ctrl_transition("<C-j>", "ascii"))
    assert.are.equal("hira", mode_util.ctrl_transition("<C-CR>", "ascii"))
  end)

  it("引数無しで呼ぶとデフォルト（<C-j>のみ）に戻る", function()
    mode_util.set_ctrl_keys({ "<C-CR>" })
    mode_util.set_ctrl_keys()

    assert.are.equal("hira", mode_util.ctrl_transition("<C-j>", "ascii"))
    assert.is_nil(mode_util.ctrl_transition("<C-CR>", "ascii"))
  end)
end)

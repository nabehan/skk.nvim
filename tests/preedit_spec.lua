-- tests/preedit_spec.lua
--
-- lua/skk/henkan/preedit.lua のうち、vim.* に依存しないテキスト整形部分
-- （_midashi_text / _henkan_text / _abbrev_text）だけを検証する。
--
-- 【注意】実際の extmark 表示（M.show_midashi 等、vim.api を呼ぶ部分）は
-- このサンドボックスに実 Neovim が無いため検証できない。plenary/nvim
-- 上での動作確認が別途必要。

local preedit = require("skk.henkan.preedit")

describe("preedit._midashi_text (▽表示)", function()
  it("送り開始点が無い場合は ▽よみ のみ", function()
    assert.are.equal("▽うご", preedit._midashi_text("うご", nil))
  end)

  it("送り開始点の子音が指定されていれば ▽よみ*子音 になる", function()
    assert.are.equal("▽うご*k", preedit._midashi_text("うご", "k"))
  end)

  it("送り開始点の子音が空文字列なら付与しない", function()
    assert.are.equal("▽うご", preedit._midashi_text("うご", ""))
  end)
end)

describe("preedit._henkan_text (▼表示)", function()
  it("送り仮名が無い場合は ▼候補 のみ", function()
    assert.are.equal("▼愛", preedit._henkan_text("愛", nil))
  end)

  it("送り仮名があれば ▼候補送り仮名 になる", function()
    assert.are.equal("▼動か", preedit._henkan_text("動", "か"))
  end)

  it("カタカナモードの送り仮名もそのまま結合される（変換自体は呼び出し側の責務）", function()
    assert.are.equal("▼動カ", preedit._henkan_text("動", "カ"))
  end)
end)

describe("preedit._abbrev_text (abbrev表示)", function()
  it("▽読み の形式になる", function()
    assert.are.equal("▽neovim", preedit._abbrev_text("neovim"))
  end)
end)

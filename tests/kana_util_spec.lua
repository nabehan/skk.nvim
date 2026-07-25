-- tests/kana_util_spec.lua
--
-- lua/skk/kana_util.lua（ひらがな⇔カタカナ⇔全角英数の変換）のテスト。

local U = require("skk.kana_util")

describe("utf8 decode/encode roundtrip", function()
  it("ASCII / ひらがな / 漢字 / 記号 を往復できる", function()
    for _, s in ipairs({ "a", "ー", "あ", "亜", "、", "「", "」", "がっこう" }) do
      local out = {}
      for _, cp in ipairs(U._utf8_decode(s)) do
        table.insert(out, U._utf8_encode(cp))
      end
      assert.are.equal(s, table.concat(out))
    end
  end)
end)

describe("to_katakana", function()
  it("基本のひらがなをカタカナに変換する", function()
    assert.are.equal("ア", U.to_katakana("あ"))
    assert.are.equal("ガッコウ", U.to_katakana("がっこう"))
    assert.are.equal("キョウ", U.to_katakana("きょう"))
  end)

  it("小書き文字も変換する", function()
    assert.are.equal("ァィゥェォ", U.to_katakana("ぁぃぅぇぉ"))
    assert.are.equal("ャュョ", U.to_katakana("ゃゅょ"))
  end)

  it("ひらがな範囲外の文字（ー・、。「」）はそのまま素通りする", function()
    assert.are.equal("ー", U.to_katakana("ー"))
    assert.are.equal("、。「」", U.to_katakana("、。「」"))
  end)
end)

describe("to_zenkaku_char", function()
  it("英字・数字を全角にする", function()
    assert.are.equal("ｑ", U.to_zenkaku_char("q"))
    assert.are.equal("Ｑ", U.to_zenkaku_char("Q"))
    assert.are.equal("１", U.to_zenkaku_char("1"))
  end)

  it("半角スペースは全角スペース(U+3000)にする", function()
    assert.are.equal("　", U.to_zenkaku_char(" "))
  end)

  it("記号も全角にする", function()
    assert.are.equal("！", U.to_zenkaku_char("!"))
    assert.are.equal("～", U.to_zenkaku_char("~"))
  end)
end)

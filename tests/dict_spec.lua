-- tests/dict_spec.lua
--
-- lua/skk/dict/init.lua のテスト。vim.* に依存しないので
-- 素の Lua だけで検証できる。

local dict = require("skk.dict")
local parser = require("skk.dict.jisyo_parser")

describe("dict (phase 3: 単一辞書, okuri-nasi のみ)", function()
  before_each(function()
    -- テストごとに辞書を積み直す（他のテストの set_dict の影響を受けないように）
    local text = table.concat({
      ";; okuri-ari entries.",
      "うごk /動/",
      ";; okuri-nasi entries.",
      "かんじ /漢字/幹事/",
    }, "\n")
    dict.set_dict(parser.parse(text))
  end)

  it("is_ready", function()
    assert.is_true(dict.is_ready())
  end)

  it("okuri-nasi の検索", function()
    local candidates = dict.lookup("かんじ", false)
    assert.are.equal(2, #candidates)
    assert.are.equal("漢字", candidates[1].word)
    assert.are.equal("幹事", candidates[2].word)
  end)

  it("okuri-ari の検索", function()
    local candidates = dict.lookup("うごk", true)
    assert.are.equal(1, #candidates)
    assert.are.equal("動", candidates[1].word)
  end)

  it("見つからない場合は空配列", function()
    local candidates = dict.lookup("そんざいしない", false)
    assert.are.equal(0, #candidates)
  end)

  it(
    "has_okuri を間違えると見つからない（okuri-ari のキーを okuri-nasi として引かない）",
    function()
      local candidates = dict.lookup("うごk", false)
      assert.are.equal(0, #candidates)
    end
  )
end)

describe("dict (空の辞書)", function()
  it("空の辞書を登録すると lookup は空配列を返す", function()
    dict.set_dict({ okuri_ari = {}, okuri_nasi = {} })
    assert.are.equal(0, #dict.lookup("かんじ", false))
  end)
end)

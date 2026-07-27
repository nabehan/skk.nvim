-- tests/session_spec.lua
--
-- lua/skk/henkan/session.lua のテスト。vim.* に依存しないので
-- 素の Lua だけで検証できる。

local Session = require("skk.henkan.session")

describe("Session.new", function()
  it("初期状態", function()
    local s = Session.new("hira")
    assert.are.equal("", s.reading)
    assert.is_nil(s.okuri_consonant)
    assert.are.equal("hira", s.source_mode)
    assert.are.equal(0, s.index)
    assert.are.equal(0, #s.candidates)
  end)
end)

describe("Session:input_reading", function()
  it("ローマ字をひらがなに変換して reading に積む", function()
    local s = Session.new("hira")
    for ch in ("ugoku"):gmatch(".") do
      s:input_reading(ch)
    end
    assert.are.equal("うごく", s.reading)
    assert.are.equal("", s:reading_pending())
  end)

  it("未確定のローマ字断片は reading_pending() で見える", function()
    local s = Session.new("hira")
    s:input_reading("k")
    assert.are.equal("", s.reading)
    assert.are.equal("k", s:reading_pending())
  end)
end)

describe("Session:backspace_reading", function()
  it("未確定のローマ字断片があれば、そちらを優先して1文字消す", function()
    local s = Session.new("hira")
    s:input_reading("u")
    s:input_reading("g")
    s:input_reading("o")
    s:input_reading("k") -- pending "k"
    assert.are.equal("うご", s.reading)
    assert.are.equal("k", s:reading_pending())

    local has_more = s:backspace_reading()
    assert.is_true(has_more)
    assert.are.equal("うご", s.reading)
    assert.are.equal("", s:reading_pending())
  end)

  it("未確定バッファが空なら reading 自体をUTF-8境界で1文字消す", function()
    local s = Session.new("hira")
    for ch in ("ugo"):gmatch(".") do
      s:input_reading(ch)
    end
    assert.are.equal("うご", s.reading)

    local has_more = s:backspace_reading()
    assert.is_true(has_more)
    assert.are.equal("う", s.reading)

    has_more = s:backspace_reading()
    assert.is_false(has_more) -- 最後の1文字を消したので reading は空になる
    assert.are.equal("", s.reading)
  end)
end)

describe("Session:dict_key", function()
  it("送りなしの場合は reading そのもの", function()
    local s = Session.new("hira")
    for ch in ("kanji"):gmatch(".") do
      s:input_reading(ch)
    end
    local key, has_okuri = s:dict_key()
    assert.are.equal("かんじ", key)
    assert.is_false(has_okuri)
  end)

  it("送りありの場合は reading .. okuri_consonant", function()
    local s = Session.new("hira")
    for ch in ("ugo"):gmatch(".") do
      s:input_reading(ch)
    end
    s:start_okuri()
    s:input_okuri("k")
    local key, has_okuri = s:dict_key()
    assert.are.equal("うごk", key)
    assert.is_true(has_okuri)
  end)
end)

describe("Session:input_okuri", function()
  it("子音+母音が確定した瞬間に true を返し、okuri_kana が設定される", function()
    local s = Session.new("hira")
    s:start_okuri()
    local confirmed1 = s:input_okuri("k") -- 子音のみ、まだ未確定
    assert.is_false(confirmed1)
    assert.are.equal("k", s.okuri_consonant)

    local confirmed2 = s:input_okuri("u") -- "ku" -> "く" 確定
    assert.is_true(confirmed2)
    assert.are.equal("く", s.okuri_kana)
  end)
end)

describe("Session candidate navigation", function()
  it("set_candidates は先頭候補を選択状態にする", function()
    local s = Session.new("hira")
    s:set_candidates({ "動", "働", "慟" })
    assert.are.equal("動", s:current_candidate())
  end)

  it("next_candidate は循環する", function()
    local s = Session.new("hira")
    s:set_candidates({ "動", "働", "慟" })
    s:next_candidate()
    assert.are.equal("働", s:current_candidate())
    s:next_candidate()
    assert.are.equal("慟", s:current_candidate())
    s:next_candidate() -- 末尾の次は先頭に戻る
    assert.are.equal("動", s:current_candidate())
  end)

  it("prev_candidate は循環する", function()
    local s = Session.new("hira")
    s:set_candidates({ "動", "働", "慟" })
    s:prev_candidate() -- 先頭の前は末尾に戻る
    assert.are.equal("慟", s:current_candidate())
    s:prev_candidate()
    assert.are.equal("働", s:current_candidate())
  end)

  it("候補が無い場合 current_candidate は nil", function()
    local s = Session.new("hira")
    s:set_candidates({})
    assert.is_nil(s:current_candidate())
  end)
end)

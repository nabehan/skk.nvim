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

describe("Session:start_okuri", function()
  it("直前の未確定ローマ字断片が残っていた場合は破棄する", function()
    local s = Session.new("hira")
    s:input_reading("u")
    s:input_reading("g")
    s:input_reading("o") -- reading = "うご"
    s:input_reading("k") -- pending "k"（まだ確定していない）
    assert.are.equal("k", s:reading_pending())

    s:start_okuri()
    assert.are.equal("", s:reading_pending())
    assert.are.equal("うご", s.reading) -- 確定済みの読みは影響を受けない
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

describe("Session candidate navigation (ページング, PAGE_SIZE=7)", function()
  it("set_candidates は先頭候補を選択状態にし、1ページ目を表示する", function()
    local s = Session.new("hira")
    s:set_candidates({ "動", "働", "慟" })
    assert.are.equal("動", s:current_candidate())
    assert.are.equal(0, s.page)
  end)

  it("page_candidates は現在ページの候補（最大7件）だけを返す", function()
    local s = Session.new("hira")
    -- 9件 -> 1ページ目7件、2ページ目2件
    local candidates = { "1", "2", "3", "4", "5", "6", "7", "8", "9" }
    s:set_candidates(candidates)
    assert.are.same({ "1", "2", "3", "4", "5", "6", "7" }, s:page_candidates())
    assert.are.equal(2, s:page_count())
  end)

  it("next_page で次の7候補に切り替わり、選択はそのページの先頭になる", function()
    local candidates = { "1", "2", "3", "4", "5", "6", "7", "8", "9" }
    local s = Session.new("hira")
    s:set_candidates(candidates)
    s:next_page()
    assert.are.equal(1, s.page)
    assert.are.same({ "8", "9" }, s:page_candidates())
    assert.are.equal("8", s:current_candidate())
    s:next_page() -- 末尾ページの次は先頭ページに戻る
    assert.are.equal(0, s.page)
    assert.are.equal("1", s:current_candidate())
  end)

  it("prev_page で前の7候補に戻る（先頭ページの前は末尾ページに循環する）", function()
    local candidates = { "1", "2", "3", "4", "5", "6", "7", "8", "9" }
    local s = Session.new("hira")
    s:set_candidates(candidates)
    s:prev_page()
    assert.are.equal(1, s.page)
    assert.are.same({ "8", "9" }, s:page_candidates())
  end)

  it("select_on_page は指定位置の候補を選択する（1=a, 2=s, ...）", function()
    local candidates = { "動", "働", "慟" }
    local s = Session.new("hira")
    s:set_candidates(candidates)
    local selected = s:select_on_page(2) -- s キー相当
    assert.are.equal("働", selected)
    assert.are.equal("働", s:current_candidate())
  end)

  it(
    "select_on_page は、そのページに候補が無い位置なら nil を返し、選択状態は変えない",
    function()
      local candidates = { "動", "働", "慟" } -- 3件しかない
      local s = Session.new("hira")
      s:set_candidates(candidates)
      local selected = s:select_on_page(5) -- j キー相当、候補なし
      assert.is_nil(selected)
      assert.are.equal("動", s:current_candidate()) -- 選択状態は変わらない
    end
  )

  it("候補が無い場合 current_candidate は nil、page_count は0", function()
    local s = Session.new("hira")
    s:set_candidates({})
    assert.is_nil(s:current_candidate())
    assert.are.equal(0, s:page_count())
    assert.are.same({}, s:page_candidates())
  end)
end)

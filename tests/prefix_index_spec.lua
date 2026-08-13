-- tests/prefix_index_spec.lua
--
-- lua/skk/dict/prefix_index.lua のテスト（vim.* 非依存の純粋なロジックのみ）。

local prefix_index = require("skk.dict.prefix_index")

describe("prefix_index.build_sorted_keys", function()
  it("テーブルのキーを昇順ソートして返す", function()
    local tbl = { ["う"] = 1, ["あ"] = 1, ["い"] = 1 }
    assert.are.same({ "あ", "い", "う" }, prefix_index.build_sorted_keys(tbl))
  end)

  it("空テーブルなら空配列を返す", function()
    assert.are.same({}, prefix_index.build_sorted_keys({}))
  end)
end)

describe("prefix_index.prefix_range", function()
  local sorted

  before_each(function()
    sorted = prefix_index.build_sorted_keys({
      ["あい"] = 1,
      ["かんこう"] = 1,
      ["かんじ"] = 1,
      ["かんたん"] = 1,
      ["かんぺき"] = 1,
      ["き"] = 1,
    })
  end)

  it("前方一致するキーを昇順で返す", function()
    local result = prefix_index.prefix_range(sorted, "かん", nil)
    assert.are.same({ "かんこう", "かんじ", "かんたん", "かんぺき" }, result)
  end)

  it("前方一致するキーが無ければ空配列を返す", function()
    assert.are.same({}, prefix_index.prefix_range(sorted, "ん", nil))
  end)

  it("prefix が空文字列なら常に空配列を返す（辞書全件を返さない）", function()
    assert.are.same({}, prefix_index.prefix_range(sorted, "", nil))
  end)

  it("max_results を指定すると件数で打ち切る", function()
    local result = prefix_index.prefix_range(sorted, "かん", 2)
    assert.are.same({ "かんこう", "かんじ" }, result)
  end)

  it("prefix そのものが完全一致するキーも含む", function()
    local result = prefix_index.prefix_range(sorted, "き", nil)
    assert.are.same({ "き" }, result)
  end)

  it("辞書の最後の要素が prefix にマッチする場合も正しく返す（境界値）", function()
    local result = prefix_index.prefix_range(sorted, "かんぺ", nil)
    assert.are.same({ "かんぺき" }, result)
  end)
end)

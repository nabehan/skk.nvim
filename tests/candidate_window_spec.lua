-- tests/candidate_window_spec.lua
--
-- lua/skk/henkan/candidate_window.lua のうち、vim.* に依存しない
-- テキスト整形部分（_format_lines）だけを検証する。
-- フローティングウィンドウの実際の表示・配置（アンカー行の上下切り替え等）は
-- plenary/nvim 上での目視確認が必要（このテストではカバーしない）。

local candidate_window = require("skk.henkan.candidate_window")

describe("candidate_window._format_lines", function()
  it("ホームポジションキー a s d f j k l を候補に順番に対応させる", function()
    local lines = candidate_window._format_lines({
      { word = "木" },
      { word = "期" },
      { word = "喜" },
      { word = "祺" },
      { word = "棊" },
      { word = "己" },
      { word = "棘" },
    })
    assert.are.same({
      "a: 木",
      "s: 期",
      "d: 喜",
      "f: 祺",
      "j: 棊",
      "k: 己",
      "l: 棘",
    }, lines)
  end)

  it("アノテーションがあれば ';注釈' の形式で末尾に付ける", function()
    local lines = candidate_window._format_lines({
      { word = "木", annotation = "き。植物" },
      { word = "期" }, -- アノテーション無し
    })
    assert.are.same({
      "a: 木 ;き。植物",
      "s: 期",
    }, lines)
  end)

  it("候補が7件未満なら、その分だけ行を作る（余ったキーの行は作らない）", function()
    local lines = candidate_window._format_lines({
      { word = "動" },
      { word = "働" },
      { word = "慟" },
    })
    assert.are.same({ "a: 動", "s: 働", "d: 慟" }, lines)
  end)

  it("候補が空なら空配列を返す", function()
    local lines = candidate_window._format_lines({})
    assert.are.same({}, lines)
  end)

  it("HOME_ROW_KEYS は Sticky-shift と衝突する ; を含まない、7キーである", function()
    assert.are.equal(7, #candidate_window.HOME_ROW_KEYS)
    for _, key in ipairs(candidate_window.HOME_ROW_KEYS) do
      assert.is_not.equal(";", key)
    end
  end)
end)

describe("candidate_window.setup", function()
  it("border オプションを指定しなければデフォルト（rounded）のまま", function()
    -- 直接 config を覗く public API が無いので、setup({}) が
    -- エラーなく呼べることだけを確認する（実際の見た目は plenary/nvim 上で確認）。
    assert.has_no.errors(function()
      candidate_window.setup({})
      candidate_window.setup({ border = "single" })
      candidate_window.setup(nil)
    end)
  end)

  it("annotation=false にすると _format_lines がアノテーションを表示しなくなる", function()
    candidate_window.setup({ annotation = false })
    local lines = candidate_window._format_lines({
      { word = "木", annotation = "き。植物" },
    })
    assert.are.same({ "a: 木" }, lines) -- アノテーションが付かない
    candidate_window.setup({ annotation = true }) -- 他のテストに影響しないよう元に戻す
  end)
end)

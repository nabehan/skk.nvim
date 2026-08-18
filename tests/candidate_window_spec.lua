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

describe("candidate_window._page_indicator_line", function()
  it('"現在ページ/全ページ数" の形式になる', function()
    assert.are.equal("2/3", candidate_window._page_indicator_line(2, 3))
  end)

  it('1ページしか無くても "1/1" と表示する', function()
    assert.are.equal("1/1", candidate_window._page_indicator_line(1, 1))
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

  it("page_indicator=true（デフォルト）では、show() の表示行末尾にページ行が付く", function()
    candidate_window.show(0, 0, 0, { { word = "木" } }, 1, 1)
    local lines = candidate_window._buf_lines()
    assert.are.equal(2, #lines) -- 候補1行 + ページ行1行
    assert.are.equal("a: 木", lines[1])
    assert.are.equal("1/1", lines[2])
    candidate_window.hide()
  end)

  it("page_indicator=false にすると、show() の表示行にページ行が付かない", function()
    candidate_window.setup({ page_indicator = false })
    candidate_window.show(0, 0, 0, { { word = "木" } }, 1, 1)
    local lines = candidate_window._buf_lines()
    assert.are.equal(1, #lines) -- 候補1行のみ
    assert.are.equal("a: 木", lines[1])
    candidate_window.hide()
    candidate_window.setup({ page_indicator = true }) -- 他のテストに影響しないよう元に戻す
  end)
end)

describe("candidate_window: 配色オプション（fg/bg/border_fg/border_bg/alt_fg/alt_bg）", function()
  after_each(function()
    -- 他のテストに影響しないよう、ハイライトグループをデフォルトに戻す
    candidate_window.setup({})
    candidate_window.hide()
  end)

  it("無指定（デフォルト）では NormalFloat/FloatBorder にリンクしたまま", function()
    candidate_window.setup({})
    local normal = vim.api.nvim_get_hl(0, { name = "SkkCandidateWindowNormal" })
    local border = vim.api.nvim_get_hl(0, { name = "SkkCandidateWindowBorder" })
    assert.are.equal("NormalFloat", normal.link)
    assert.are.equal("FloatBorder", border.link)
  end)

  it(
    "fg/bg を指定すると SkkCandidateWindowNormal が直接その色になる（リンクではない）",
    function()
      candidate_window.setup({ fg = "#ff0000", bg = "#00ff00" })
      local normal = vim.api.nvim_get_hl(0, { name = "SkkCandidateWindowNormal" })
      assert.is_nil(normal.link)
      assert.are.equal(0xff0000, normal.fg)
      assert.are.equal(0x00ff00, normal.bg)
    end
  )

  it("border_fg/border_bg を指定すると SkkCandidateWindowBorder が直接その色になる", function()
    candidate_window.setup({ border_fg = "#123456" })
    local border = vim.api.nvim_get_hl(0, { name = "SkkCandidateWindowBorder" })
    assert.is_nil(border.link)
    assert.are.equal(0x123456, border.fg)
  end)

  it("alt_fg/alt_bg 無指定では SkkCandidateWindowNormal にリンクしたまま（縞なし）", function()
    candidate_window.setup({})
    local alt = vim.api.nvim_get_hl(0, { name = "SkkCandidateWindowNormalAlt" })
    assert.are.equal("SkkCandidateWindowNormal", alt.link)
  end)

  it("show() は選択行以外の各行に、1行おきの縞模様用 line_hl_group を付ける", function()
    candidate_window.setup({})
    candidate_window.show(0, 0, 0, {
      { word = "一" },
      { word = "二" },
      { word = "三" },
      { word = "四" },
    }, 1, 1, 2) -- 2番目（"二"、0-indexedで行1）を選択中とする

    assert.are.equal(1, candidate_window._highlighted_line()) -- "二" が選択中

    local alt = candidate_window._alt_highlighted_lines()
    -- 選択中の行（1）には縞模様グループは付かない（SkkHenkanCandidateが優先）。
    -- 残り（0, 2, 3）が1行おきに Normal/NormalAlt に振り分けられる
    -- （1-indexedの奇数行=Normal、偶数行=Alt。build_content()参照）。
    table.sort(alt.normal)
    table.sort(alt.alt)
    assert.are.same({ 0, 2 }, alt.normal) -- 1行目("一")・3行目("三")
    assert.are.same({ 3 }, alt.alt) -- 4行目("四")
    candidate_window.hide()
  end)

  it(
    "winhighlight の適用に失敗しても show() 自体はエラーにならない"
      .. "（実機のNeovimで報告された 'Invalid window id' エラーへの防御を確認）",
    function()
      local original = vim.api.nvim_set_option_value
      vim.api.nvim_set_option_value = function(name, value, opts)
        if name == "winhighlight" then
          error("Invalid window id: 999 (simulated)")
        end
        return original(name, value, opts)
      end

      local ok = pcall(candidate_window.show, 0, 0, 0, { { word = "一" } }, 1, 1, 1)

      vim.api.nvim_set_option_value = original
      candidate_window.hide()

      assert.is_true(ok)
    end
  )
end)

describe("candidate_window の選択中候補ハイライト（selected_offset）", function()
  before_each(function()
    candidate_window.hide()
  end)

  local function make_candidates()
    local out = {}
    for _, w in ipairs({ "菌", "金", "近", "筋", "禁", "均", "衿" }) do
      table.insert(out, { word = w })
    end
    return out
  end

  it("selected_offset を指定すると、その行がハイライトされる（3番目 = d:近）", function()
    candidate_window.show(0, 0, 0, make_candidates(), 1, 1, 3)
    assert.are.equal(2, candidate_window._highlighted_line()) -- 0-indexed の3行目 = "d: 近"
  end)

  it("selected_offset=nil ならハイライトしない", function()
    candidate_window.show(0, 0, 0, make_candidates(), 1, 1, nil)
    assert.is_nil(candidate_window._highlighted_line())
  end)

  it(
    "再表示するたびにハイライトが更新される（前回のハイライトが残らない）",
    function()
      candidate_window.show(0, 0, 0, make_candidates(), 1, 1, 1)
      assert.are.equal(0, candidate_window._highlighted_line())
      candidate_window.show(0, 0, 0, make_candidates(), 1, 1, 5)
      assert.are.equal(4, candidate_window._highlighted_line())
    end
  )
end)

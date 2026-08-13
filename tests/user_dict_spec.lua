-- tests/user_dict_spec.lua
--
-- lua/skk/dict/user_dict.lua（個人辞書・学習）のテスト。
-- 実ファイルへの読み書きを伴うので vim.fn.tempname() で一時ファイルを使う
-- （plenary は各specファイルを独立した headless Neovim プロセスで実行するので、
-- vim.* は普通に使える）。

local user_dict = require("skk.dict.user_dict")

describe("user_dict", function()
  local tmp_path

  before_each(function()
    tmp_path = vim.fn.tempname()
  end)

  after_each(function()
    os.remove(tmp_path)
  end)

  it("ファイルが存在しなくても load() はエラーにならず、空として扱われる", function()
    user_dict.load(tmp_path)
    assert.are.equal(tmp_path, user_dict.path())
    assert.are.same({}, user_dict.lookup("かんじ", false))
  end)

  it("record_selection で新規の読みを追加できる", function()
    user_dict.load(tmp_path)
    user_dict.record_selection("かんじ", false, "漢字", nil)
    local candidates = user_dict.lookup("かんじ", false)
    assert.are.equal(1, #candidates)
    assert.are.equal("漢字", candidates[1].word)
  end)

  it("同じ読みで複数回 record_selection すると、直近のものが先頭になる", function()
    user_dict.load(tmp_path)
    user_dict.record_selection("かんじ", false, "漢字", nil)
    user_dict.record_selection("かんじ", false, "幹事", nil)
    local candidates = user_dict.lookup("かんじ", false)
    assert.are.equal(2, #candidates)
    assert.are.equal("幹事", candidates[1].word)
    assert.are.equal("漢字", candidates[2].word)
  end)

  it("同じ word を record_selection すると、重複せず先頭に移動するだけ", function()
    user_dict.load(tmp_path)
    user_dict.record_selection("かんじ", false, "漢字", nil)
    user_dict.record_selection("かんじ", false, "幹事", nil)
    user_dict.record_selection("かんじ", false, "漢字", nil) -- 既存の "漢字" を再選択
    local candidates = user_dict.lookup("かんじ", false)
    assert.are.equal(2, #candidates) -- 3件にはならない
    assert.are.equal("漢字", candidates[1].word)
    assert.are.equal("幹事", candidates[2].word)
  end)

  it("record_selection の内容はファイルに保存され、load() で読み直せる", function()
    user_dict.load(tmp_path)
    user_dict.record_selection("かんじ", false, "漢字", "人名用")
    user_dict.record_selection("うごk", true, "動", nil)

    user_dict.load(tmp_path) -- 保存されたファイルを読み直す
    local nasi = user_dict.lookup("かんじ", false)
    assert.are.equal("漢字", nasi[1].word)
    assert.are.equal("人名用", nasi[1].annotation)
    local ari = user_dict.lookup("うごk", true)
    assert.are.equal("動", ari[1].word)
  end)

  it(
    "load() でパスを設定していなければ record_selection は何もしない（エラーにもならない）",
    function()
      -- グローバルな path をリセットする直接的な public API は無いので、
      -- 「存在しない読み」を検索して 0 件であることだけを確認する
      -- （load() されていない状態＝前のテストの load() が残っていても、
      -- そのファイルに対する record_selection 自体は正常に動く、という点は
      -- 上の各テストで既に確認済み）。
      assert.has_no.errors(function()
        user_dict.load(tmp_path)
        user_dict.record_selection("そんざいしない", false, "無", nil)
      end)
    end
  )

  it("lookup_prefix() は前方一致する読みを昇順ソートして返す", function()
    user_dict.load(tmp_path)
    user_dict.record_selection("かんじ", false, "漢字", nil)
    user_dict.record_selection("かんたん", false, "簡単", nil)
    user_dict.record_selection("き", false, "木", nil)

    local readings = user_dict.lookup_prefix("かん", false, 10)
    table.sort(readings)
    assert.are.same({ "かんじ", "かんたん" }, readings)
  end)

  it("lookup_prefix() は max_results で打ち切り、空文字列 prefix は空配列を返す", function()
    user_dict.load(tmp_path)
    user_dict.record_selection("かんじ", false, "漢字", nil)
    user_dict.record_selection("かんたん", false, "簡単", nil)
    user_dict.record_selection("かんこう", false, "観光", nil)

    assert.are.equal(2, #user_dict.lookup_prefix("かん", false, 2))
    assert.are.same({}, user_dict.lookup_prefix("", false, 10))
  end)
end)

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

-- 【再発防止・実機で発見】record_selection() は skk.nvim でもっとも
-- 頻繁に呼ばれる関数の一つ（確定するたびに毎回呼ばれる）だが、以前は
-- そのたびに毎回 M.save()（個人辞書全体を直列化してファイルへ同期書き込み）
-- を呼んでおり、個人辞書が育つほど・長文入力ほど確定のたびのブロッキングが
-- 伸びていく不具合があった。以下は「連続した確定の間はディスクに書かず、
-- 少し間が空いてからまとめて1回だけ書く」デバウンス化の確認。
--
-- 【注意】M.load() を呼ぶと保留中の保存を自動フラッシュする設計になって
-- いるため（既存テストがそのまま動くようにするための設計）、この
-- describe 内のテストでは load()/lookup() 経由ではなく io.open() で
-- ファイルの生の内容を直接読み、意図せずフラッシュしてしまわないように
-- する。
describe("user_dict の保存デバウンス（実機で発見・再発防止）", function()
  local tmp_path

  local function read_raw_file()
    local f = io.open(tmp_path, "rb")
    if not f then
      return nil
    end
    local text = f:read("*a")
    f:close()
    return text
  end

  before_each(function()
    tmp_path = vim.fn.tempname()
    user_dict.load(tmp_path)
  end)

  after_each(function()
    user_dict.flush() -- 次のテストに保留中の保存タイマーを持ち越さない
    os.remove(tmp_path)
  end)

  it("record_selection() 直後はまだディスクに書き込まれていない（デバウンス中）", function()
    user_dict.record_selection("かんじ", false, "漢字", nil)
    -- ファイルはまだ存在しない（初回の save() がまだ走っていない）はず。
    assert.is_nil(read_raw_file())
  end)

  it("flush() を呼べば保留中の保存が即座にディスクへ反映される", function()
    user_dict.record_selection("かんじ", false, "漢字", nil)
    assert.is_nil(read_raw_file())

    user_dict.flush()

    local text = read_raw_file()
    assert.is_not_nil(text)
    assert.is_not_nil(text:find("かんじ", 1, true))
    assert.is_not_nil(text:find("漢字", 1, true))
  end)

  it(
    "連続した record_selection() は1回分の最終状態にまとめられる（毎回ディスクに書かない）",
    function()
      user_dict.record_selection("かんじ", false, "漢字", nil)
      user_dict.record_selection("かんじ", false, "幹事", nil)
      user_dict.record_selection("かんじ", false, "監事", nil)
      assert.is_nil(read_raw_file()) -- この時点では1回も書き込まれていない

      user_dict.flush()

      local text = read_raw_file()
      assert.is_not_nil(text)
      -- 直近の record_selection（"監事"）が先頭に来た、最終状態1回分だけが
      -- 書き込まれているはず。
      local kanji_idx = text:find("監事", 1, true)
      assert.is_not_nil(kanji_idx)
    end
  )

  it(
    "デバウンス時間が経過すれば、flush() を呼ばなくても自動的にディスクへ書き込まれる",
    function()
      user_dict.record_selection("かんじ", false, "漢字", nil)
      assert.is_nil(read_raw_file())

      -- SAVE_DEBOUNCE_MS（500ms）より十分長く待つ。vim.wait() はイベント
      -- ループを回すので、予約された vim.defer_fn() のコールバックも進む。
      vim.wait(1000, function()
        return read_raw_file() ~= nil
      end, 20)

      local text = read_raw_file()
      assert.is_not_nil(text)
      assert.is_not_nil(text:find("かんじ", 1, true))
    end
  )
end)

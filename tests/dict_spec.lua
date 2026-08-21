-- tests/dict_spec.lua
--
-- lua/skk/dict/init.lua のテスト。
-- 【注意】M.load_dictionary_async() のテストは vim.schedule()/vim.wait() を
-- 使うため実際の headless Neovim 上で動かす必要がある（他のテストは
-- 素の Lua だけで検証できる）。plenary は各specファイルを独立した
-- headless Neovim プロセスで実行するので、通常通り動く。

local dict = require("skk.dict")
local parser = require("skk.dict.jisyo_parser")
local skkserv = require("skk.dict.skkserv")

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

describe("dict 複数辞書のマージ（add_dict / clear_dicts）", function()
  before_each(function()
    dict.clear_dicts()
  end)

  it("add_dict は既存のソースを消さずに追加する（優先順位は登録順）", function()
    dict.add_dict(parser.parse("かんじ /漢字/幹事/"), "primary")
    dict.add_dict(parser.parse("かんじ /監事/慣事/"), "secondary")
    local candidates = dict.lookup("かんじ", false)
    -- 先に追加した primary の候補が先に来て、secondary の重複しない分が続く
    assert.are.equal(4, #candidates)
    assert.are.equal("漢字", candidates[1].word)
    assert.are.equal("幹事", candidates[2].word)
    assert.are.equal("監事", candidates[3].word)
    assert.are.equal("慣事", candidates[4].word)
  end)

  it("word が重複する候補は、優先順位が高い（先に登録した）方だけ残す", function()
    dict.add_dict(parser.parse("かんじ /漢字;先に登録/"), "primary")
    dict.add_dict(parser.parse("かんじ /漢字;後から登録/"), "secondary")
    local candidates = dict.lookup("かんじ", false)
    assert.are.equal(1, #candidates)
    assert.are.equal("先に登録", candidates[1].annotation)
  end)

  it("set_dict は既存のソースを全て置き換える（add_dict とは違う）", function()
    dict.add_dict(parser.parse("かんじ /漢字/"), "a")
    dict.add_dict(parser.parse("べつ /別/"), "b")
    dict.set_dict(parser.parse("あたらしい /新しい/"))
    assert.are.equal(0, #dict.lookup("かんじ", false))
    assert.are.equal(0, #dict.lookup("べつ", false))
    assert.are.equal("新しい", dict.lookup("あたらしい", false)[1].word)
  end)

  it("clear_dicts で全てのローカル辞書ソースが消える（is_ready も false になる）", function()
    dict.add_dict(parser.parse("かんじ /漢字/"), "a")
    dict.clear_dicts()
    assert.is_false(dict.is_ready())
    assert.are.equal(0, #dict.lookup("かんじ", false))
  end)
end)

describe("dict + 個人辞書のマージ", function()
  local tmp_path

  before_each(function()
    local text = table.concat({
      ";; okuri-ari entries.",
      "うごk /動/",
      ";; okuri-nasi entries.",
      "かんじ /漢字/幹事/監事/",
    }, "\n")
    dict.set_dict(parser.parse(text))

    tmp_path = vim.fn.tempname()
    dict.set_user_dict_path(tmp_path)
  end)

  after_each(function()
    os.remove(tmp_path)
  end)

  it("個人辞書に学習が無ければ、メイン辞書の順序そのまま", function()
    local candidates = dict.lookup("かんじ", false)
    assert.are.equal("漢字", candidates[1].word)
    assert.are.equal("幹事", candidates[2].word)
    assert.are.equal("監事", candidates[3].word)
  end)

  it("record_selection した候補が次回の検索で先頭に来る", function()
    dict.record_selection("かんじ", false, "監事", nil)
    local candidates = dict.lookup("かんじ", false)
    assert.are.equal(3, #candidates)
    assert.are.equal("監事", candidates[1].word)
    assert.are.equal("漢字", candidates[2].word)
    assert.are.equal("幹事", candidates[3].word)
  end)

  it("record_selection はディスクにも保存され、次回 set_user_dict_path で読み直せる", function()
    dict.record_selection("かんじ", false, "幹事", nil)
    dict.set_user_dict_path(tmp_path) -- 保存したファイルを読み直す
    local candidates = dict.lookup("かんじ", false)
    assert.are.equal("幹事", candidates[1].word)
  end)
end)

describe("dict.load_dictionary_async（遅延パース）", function()
  local tmp_path

  before_each(function()
    tmp_path = vim.fn.tempname()
    local f = io.open(tmp_path, "w")
    f:write(table.concat({
      ";; okuri-ari entries.",
      "うごk /動/",
      ";; okuri-nasi entries.",
      "かんじ /漢字;人名用/幹事/監事/",
    }, "\n"))
    f:close()

    -- user_dict はモジュール単位のシングルトン状態を持つため、他の
    -- describe ブロックで記録された学習内容が残らないよう、ここでも
    -- 毎回フレッシュな個人辞書パスに切り替えておく。
    dict.set_user_dict_path(vim.fn.tempname())
  end)

  after_each(function()
    os.remove(tmp_path)
  end)

  it("完了後、set_dict() を使った場合と同じ結果を lookup できる", function()
    local done = false
    local ok_result = nil
    dict.load_dictionary_async(tmp_path, "utf-8", function(ok)
      done = true
      ok_result = ok
    end)

    vim.wait(2000, function()
      return done
    end)

    assert.is_true(done)
    assert.is_true(ok_result)
    assert.is_true(dict.is_ready())

    local nasi = dict.lookup("かんじ", false)
    assert.are.equal(3, #nasi)
    assert.are.equal("漢字", nasi[1].word)
    assert.are.equal("人名用", nasi[1].annotation)
    assert.are.equal("幹事", nasi[2].word)
    assert.are.equal("監事", nasi[3].word)

    local ari = dict.lookup("うごk", true)
    assert.are.equal("動", ari[1].word)

    -- 存在しない読みは空配列
    assert.are.equal(0, #dict.lookup("そんざいしない", false))
  end)

  it("存在しないファイルはコールバックに ok=false と err を渡す", function()
    local done = false
    local ok_result, err_result = nil, nil
    dict.load_dictionary_async("/tmp/skk_nvim_test_does_not_exist.txt", "utf-8", function(ok, err)
      done = true
      ok_result = ok
      err_result = err
    end)
    vim.wait(2000, function()
      return done
    end)
    assert.is_true(done)
    assert.is_false(ok_result)
    assert.is_not_nil(err_result)
  end)

  it("M.loaded_dictionaries() に読み込み結果（成功・失敗とも）が記録される", function()
    dict.clear_dicts() -- 他テストの記録を持ち越さない

    local done = false
    dict.load_dictionary_async(tmp_path, "utf-8", function()
      done = true
    end)
    vim.wait(2000, function()
      return done
    end)

    local loaded = dict.loaded_dictionaries()
    assert.are.equal(1, #loaded)
    assert.are.equal(tmp_path, loaded[1].path)
    assert.are.equal("utf-8", loaded[1].encoding)
    assert.is_true(loaded[1].ok)
    assert.is_not_nil(loaded[1].loaded_at)

    -- 失敗した読み込みも記録される（失敗時は既存ソースを置き換えない
    -- ため、成功時の記録は消えず、失敗の記録が追加される）。
    done = false
    dict.load_dictionary_async("/tmp/skk_nvim_test_does_not_exist.txt", "utf-8", function()
      done = true
    end)
    vim.wait(2000, function()
      return done
    end)

    loaded = dict.loaded_dictionaries()
    assert.are.equal(2, #loaded)
    assert.is_false(loaded[2].ok)
    assert.is_not_nil(loaded[2].err)
  end)

  it("非同期で読み込んだ辞書も、個人辞書とのマージが機能する", function()
    local user_tmp = vim.fn.tempname()
    dict.set_user_dict_path(user_tmp)

    local done = false
    dict.load_dictionary_async(tmp_path, "utf-8", function()
      done = true
    end)
    vim.wait(2000, function()
      return done
    end)

    dict.record_selection("かんじ", false, "監事", nil)
    local candidates = dict.lookup("かんじ", false)
    assert.are.equal("監事", candidates[1].word) -- 学習した候補が先頭に来る
    assert.are.equal(3, #candidates)

    os.remove(user_tmp)
  end)
end)

describe("dict.add_dictionary_async（複数辞書を非同期で追加）", function()
  local tmp_path_a, tmp_path_b

  before_each(function()
    dict.clear_dicts()
    dict.set_user_dict_path(vim.fn.tempname())

    tmp_path_a = vim.fn.tempname()
    local fa = io.open(tmp_path_a, "w")
    fa:write("かんじ /漢字/幹事/")
    fa:close()

    tmp_path_b = vim.fn.tempname()
    local fb = io.open(tmp_path_b, "w")
    fb:write("かんじ /監事/慣事/")
    fb:close()
  end)

  after_each(function()
    os.remove(tmp_path_a)
    os.remove(tmp_path_b)
  end)

  it("2つの辞書を追加すると、両方の候補が登録順優先でマージされる", function()
    local done_a, done_b = false, false
    dict.add_dictionary_async(tmp_path_a, "utf-8", function()
      done_a = true
    end, nil, "a")
    dict.add_dictionary_async(tmp_path_b, "utf-8", function()
      done_b = true
    end, nil, "b")

    vim.wait(2000, function()
      return done_a and done_b
    end)

    assert.is_true(done_a)
    assert.is_true(done_b)

    local candidates = dict.lookup("かんじ", false)
    assert.are.equal(4, #candidates)
    assert.are.equal("漢字", candidates[1].word)
    assert.are.equal("幹事", candidates[2].word)
    assert.are.equal("監事", candidates[3].word)
    assert.are.equal("慣事", candidates[4].word)
  end)

  it("M.loaded_dictionaries() に、呼んだ順（name付き）で記録される", function()
    local done_a, done_b = false, false
    dict.add_dictionary_async(tmp_path_a, "utf-8", function()
      done_a = true
    end, nil, "a")
    dict.add_dictionary_async(tmp_path_b, "utf-8", function()
      done_b = true
    end, nil, "b")

    vim.wait(2000, function()
      return done_a and done_b
    end)

    local loaded = dict.loaded_dictionaries()
    assert.are.equal(2, #loaded)
    assert.are.equal("a", loaded[1].name)
    assert.are.equal(tmp_path_a, loaded[1].path)
    assert.is_true(loaded[1].ok)
    assert.are.equal("b", loaded[2].name)
    assert.are.equal(tmp_path_b, loaded[2].path)
    assert.is_true(loaded[2].ok)
  end)

  it("load_dictionary_async と add_dictionary_async を混ぜても、load の方が全て置き換える", function()
    local done = false
    dict.add_dictionary_async(tmp_path_a, "utf-8", function() end, nil, "a")
    dict.load_dictionary_async(tmp_path_b, "utf-8", function()
      done = true
    end)
    vim.wait(2000, function()
      return done
    end)
    local candidates = dict.lookup("かんじ", false)
    -- tmp_path_a（漢字/幹事）は置き換えられ、tmp_path_b（監事/慣事）だけが残る
    assert.are.equal(2, #candidates)
    assert.are.equal("監事", candidates[1].word)
    assert.are.equal("慣事", candidates[2].word)
  end)
end)

describe("dict: 前方一致検索 (M.lookup_prefix、blink.cmp ネイティブソース用)", function()
  before_each(function()
    dict.set_dict(parser.parse(table.concat({
      "うごk /動/",
      "かんじ /漢字/幹事/",
      "かんたん /簡単/",
      "かんこう /観光/",
      "き /木/",
    }, "\n")))
    dict.set_user_dict_path(vim.fn.tempname())
  end)

  it("前方一致する読みを昇順ソートして返す", function()
    local readings = dict.lookup_prefix("かん", false, 10)
    table.sort(readings)
    assert.are.same({ "かんこう", "かんじ", "かんたん" }, readings)
  end)

  it("前方一致しない prefix は空配列を返す", function()
    assert.are.same({}, dict.lookup_prefix("ん", false, 10))
  end)

  it("空文字列の prefix は空配列を返す（辞書全件を返さない）", function()
    assert.are.same({}, dict.lookup_prefix("", false, 10))
  end)

  it("max_results で件数を打ち切る", function()
    local readings = dict.lookup_prefix("かん", false, 2)
    assert.are.equal(2, #readings)
  end)

  it("個人辞書で新規に学習した読みも前方一致検索に含まれる", function()
    dict.record_selection("かんぺき", false, "完璧", nil)
    local readings = dict.lookup_prefix("かん", false, 10)
    table.sort(readings)
    assert.are.same({ "かんこう", "かんじ", "かんたん", "かんぺき" }, readings)
  end)

  it("送りありの prefix 検索は okuri_ari セクションだけを見る", function()
    dict.set_dict(parser.parse(table.concat({
      ";; okuri-ari entries.",
      "うごk /動/",
      "うつk /打/移/",
      ";; okuri-nasi entries.",
      "き /木/",
    }, "\n")))
    local readings = dict.lookup_prefix("う", true, 10)
    table.sort(readings)
    assert.are.same({ "うごk", "うつk" }, readings)
    -- 送りなし側の "き" は含まれない
    assert.are.same({}, dict.lookup_prefix("き", true, 10))
  end)
end)

-- --- from_skkserv（第2戻り値）のテスト ---
-- 【注意】tests/fixtures/fake_skkserv.py（Python3が必要）を使った統合
-- テスト。DICT = {"かんじ": [...], "てすと": [...]} のみを知っている
-- フェイクサーバーに対して、ローカル辞書だけが知っている読み（かんたん・
-- かんこう）が from_skkserv に紛れ込まないことを確認する
-- （lua/skk/blink_source.lua が notfound フォールバックの地雷を踏まない
-- ために依拠している性質そのもの）。Python3 が無い環境では自動でスキップ
-- する。
describe("dict: M.lookup_prefix の第2戻り値 from_skkserv（フェイクサーバー統合テスト）", function()
  local job_id
  local PORT = 12790

  local function start_fake_server(port)
    local script = debug.getinfo(1, "S").source:sub(2):match("(.*/)") .. "fixtures/fake_skkserv.py"
    if vim.fn.executable("python3") ~= 1 then
      return nil
    end
    local id = vim.fn.jobstart({ "python3", script, tostring(port) })
    if id <= 0 then
      return nil
    end
    vim.wait(500)
    return id
  end

  before_each(function()
    dict.set_dict(parser.parse(table.concat({
      "かんじ /漢字/幹事/",
      "かんたん /簡単/",
      "かんこう /観光/",
    }, "\n")))
    dict.set_user_dict_path(vim.fn.tempname())
    job_id = start_fake_server(PORT)
  end)

  after_each(function()
    if job_id then
      vim.fn.jobstop(job_id)
    end
    skkserv.setup(nil)
  end)

  it('SKKサーバー自身の"4"応答に含まれる読みだけ from_skkserv=true になる', function()
    if not job_id then
      pending("python3 が無いのでスキップ")
      return
    end
    skkserv.setup({ host = "127.0.0.1", port = PORT, encoding = "euc-jp", timeout_ms = 1000 })
    local readings, from_skkserv = dict.lookup_prefix("かん", false, 10, false)
    table.sort(readings)
    assert.are.same({ "かんこう", "かんじ", "かんたん" }, readings)
    -- フェイクサーバーの DICT には「かんじ」しか無いので、from_skkserv には
    -- かんじ だけが立ち、ローカル辞書にしかない かんたん/かんこう は
    -- 立たない。
    assert.is_true(from_skkserv["かんじ"])
    assert.is_nil(from_skkserv["かんたん"])
    assert.is_nil(from_skkserv["かんこう"])
  end)

  it("skip_skkserv=true なら from_skkserv は空", function()
    if not job_id then
      pending("python3 が無いのでスキップ")
      return
    end
    skkserv.setup({ host = "127.0.0.1", port = PORT, encoding = "euc-jp", timeout_ms = 1000 })
    local _, from_skkserv = dict.lookup_prefix("かん", false, 10, true)
    assert.are.same({}, from_skkserv)
  end)

  it("空文字列の prefix は readings・from_skkserv とも空", function()
    local readings, from_skkserv = dict.lookup_prefix("", false, 10, false)
    assert.are.same({}, readings)
    assert.are.same({}, from_skkserv)
  end)
end)

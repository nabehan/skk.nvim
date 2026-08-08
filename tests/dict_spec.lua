-- tests/dict_spec.lua
--
-- lua/skk/dict/init.lua のテスト。
-- 【注意】M.load_dictionary_async() のテストは vim.schedule()/vim.wait() を
-- 使うため実際の headless Neovim 上で動かす必要がある（他のテストは
-- 素の Lua だけで検証できる）。plenary は各specファイルを独立した
-- headless Neovim プロセスで実行するので、通常通り動く。

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

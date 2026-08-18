-- tests/skkserv_spec.lua
--
-- lua/skk/dict/skkserv.lua のテスト。
--
-- 【注意】実サーバーへの接続を伴うテストは、このリポジトリ同梱の
-- tests/fixtures/fake_skkserv.py（簡易な自作サーバー、Python3が必要）を
-- 使う。CI や Python3 の無い環境でも壊れないよう、起動できなければ
-- そのテストはスキップする。プロトコル自体の細部は実サーバー
-- （skkserv/dbskkd-cdb/yaskkserv2 等）で別途確認が必要。

local skkserv = require("skk.dict.skkserv")

describe("skkserv.setup / is_enabled", function()
  after_each(function()
    skkserv.setup(nil) -- 他のテストに影響しないよう毎回無効化して終わる
  end)

  it("setup() 前は無効", function()
    assert.is_false(skkserv.is_enabled())
  end)

  it("setup({host=...}) すると有効になる", function()
    skkserv.setup({ host = "127.0.0.1" })
    assert.is_true(skkserv.is_enabled())
  end)

  it("setup(nil) すると無効になる", function()
    skkserv.setup({ host = "127.0.0.1" })
    skkserv.setup(nil)
    assert.is_false(skkserv.is_enabled())
  end)
end)

describe("skkserv._parse_response", function()
  before_each(function()
    -- _parse_response は config.encoding を参照するので、setup が必要。
    skkserv.setup({ host = "127.0.0.1", encoding = "utf-8" }) -- utf-8にして変換無しで確認する
  end)

  after_each(function()
    skkserv.setup(nil)
  end)

  it('"1/候補1/候補2/\\n" 形式を候補配列にパースする', function()
    local candidates = skkserv._parse_response("1/漢字/幹事/\n")
    assert.are.equal(2, #candidates)
    assert.are.equal("漢字", candidates[1].word)
    assert.are.equal("幹事", candidates[2].word)
  end)

  it("アノテーションを分離する", function()
    local candidates = skkserv._parse_response("1/漢字;人名用/幹事/\n")
    assert.are.equal("漢字", candidates[1].word)
    assert.are.equal("人名用", candidates[1].annotation)
  end)

  it('"4...\\n"（見つからない）は空配列を返す', function()
    local candidates = skkserv._parse_response("4そんざいしない\n")
    assert.are.same({}, candidates)
  end)
end)

-- --- 実サーバー（フェイク）を使った統合テスト ---
-- Python3 が使える環境でのみ実行する。無ければ静かにスキップする。

local function start_fake_server(port)
  local script = debug.getinfo(1, "S").source:sub(2):match("(.*/)") .. "fixtures/fake_skkserv.py"
  local ok = vim.fn.executable("python3") == 1
  if not ok then
    return nil
  end
  local job_id = vim.fn.jobstart({ "python3", script, tostring(port) })
  if job_id <= 0 then
    return nil
  end
  -- サーバーが listen するまで少し待つ
  vim.wait(500)
  return job_id
end

describe("skkserv.lookup（フェイクサーバーとの統合テスト、Python3が必要）", function()
  local job_id
  local PORT = 12780

  before_each(function()
    job_id = start_fake_server(PORT)
  end)

  after_each(function()
    if job_id then
      vim.fn.jobstop(job_id)
    end
    skkserv.setup(nil)
  end)

  it("見つかる読みは候補を返す", function()
    if not job_id then
      pending("python3 が無いのでスキップ")
      return
    end
    skkserv.setup({ host = "127.0.0.1", port = PORT, encoding = "euc-jp", timeout_ms = 1000 })
    local candidates = skkserv.lookup("かんじ", false)
    assert.are.equal(3, #candidates)
    assert.are.equal("漢字", candidates[1].word)
    assert.are.equal("幹事", candidates[2].word)
    assert.are.equal("manager", candidates[2].annotation)
    assert.are.equal("監事", candidates[3].word)
  end)

  it("見つからない読みは空配列を返す", function()
    if not job_id then
      pending("python3 が無いのでスキップ")
      return
    end
    skkserv.setup({ host = "127.0.0.1", port = PORT, encoding = "euc-jp", timeout_ms = 1000 })
    local candidates = skkserv.lookup("そんざいしない", false)
    assert.are.same({}, candidates)
  end)

  it("サーバーが応答しない場合は timeout_ms 程度で諦めて空配列を返す", function()
    skkserv.setup({ host = "10.255.255.1", port = 1, encoding = "euc-jp", timeout_ms = 300 })
    local t0 = vim.loop.now()
    local candidates = skkserv.lookup("かんじ", false)
    local elapsed = vim.loop.now() - t0
    assert.are.same({}, candidates)
    assert.is_true(elapsed < 2000) -- フリーズせずタイムアウトすることの確認（余裕を見て2秒）
  end)
end)

describe("skkserv.get_version(timeout_ms_override)", function()
  local job_id
  local PORT = 12781

  before_each(function()
    job_id = start_fake_server(PORT)
  end)

  after_each(function()
    if job_id then
      vim.fn.jobstop(job_id)
    end
    skkserv.setup(nil)
  end)

  it(
    "省略時は通常のconfig.timeout_msで動作する（フェイクサーバーからバージョンが取れる）",
    function()
      if not job_id then
        pending("python3 が無いのでスキップ")
        return
      end
      skkserv.setup({ host = "127.0.0.1", port = PORT, encoding = "euc-jp", timeout_ms = 1000 })
      local version = skkserv.get_version()
      assert.is_not_nil(version)
    end
  )

  it(
    "timeout_ms_override を指定すると、config.timeout_ms より短く（あるいは長く）諦められる"
      .. "（skk.nvim起動直後の疎通確認が、通常の検索用timeout_msに引きずられないことの確認）",
    function()
      -- config.timeout_ms をわざと長め(5000ms)にしておき、override で短く
      -- (300ms) 指定した場合にそちらが優先されることを、到達不能ホストへの
      -- 実測時間で確認する（config.timeout_msに引きずられれば5000ms近く
      -- かかるはず）。
      skkserv.setup({ host = "10.255.255.1", port = 1, encoding = "euc-jp", timeout_ms = 5000 })
      local t0 = vim.loop.now()
      local version = skkserv.get_version(300)
      local elapsed = vim.loop.now() - t0
      assert.is_nil(version)
      assert.is_true(elapsed < 2000) -- 5000msのconfig.timeout_msに引きずられていない
    end
  )
end)

describe(
  'skkserv.lookup_prefix（"4"コマンド、フェイクサーバーとの統合テスト、Python3が必要）',
  function()
    local job_id
    local PORT = 12781

    before_each(function()
      job_id = start_fake_server(PORT)
    end)

    after_each(function()
      if job_id then
        vim.fn.jobstop(job_id)
      end
      skkserv.setup(nil)
    end)

    it("前方一致する読みの一覧を返す（辞書の単語ではなく読みそのもの）", function()
      if not job_id then
        pending("python3 が無いのでスキップ")
        return
      end
      skkserv.setup({ host = "127.0.0.1", port = PORT, encoding = "euc-jp", timeout_ms = 1000 })
      local readings = skkserv.lookup_prefix("か")
      table.sort(readings)
      assert.are.same({ "かんじ" }, readings)
    end)

    it("前方一致しない prefix は空配列を返す", function()
      if not job_id then
        pending("python3 が無いのでスキップ")
        return
      end
      skkserv.setup({ host = "127.0.0.1", port = PORT, encoding = "euc-jp", timeout_ms = 1000 })
      assert.are.same({}, skkserv.lookup_prefix("そんざいしない"))
    end)
  end
)

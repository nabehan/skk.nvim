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

---@param port integer
---@param version_delay_ms integer|nil 省略時0。"2"（バージョン確認）応答を
---  意図的に遅延させる（tests/fixtures/fake_skkserv.py 参照）。
local function start_fake_server(port, version_delay_ms)
  local script = debug.getinfo(1, "S").source:sub(2):match("(.*/)") .. "fixtures/fake_skkserv.py"
  local ok = vim.fn.executable("python3") == 1
  if not ok then
    return nil
  end
  local cmd = { "python3", script, tostring(port) }
  if version_delay_ms then
    cmd[4] = tostring(version_delay_ms)
  end
  local job_id = vim.fn.jobstart(cmd)
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

-- 【再発防止・実機で発見】単語登録UI（vim.fn.input()の再帰）のように
-- イベントループが長く回る状況で、直列キュー（enqueue()）に順番待ちの
-- まま一度もソケットに触れずタイムアウトするジョブが発生すると、
-- そのジョブがキューから取り除かれずに残り続け（ゾンビジョブ化）、
-- 以降の全リクエストがそのゾンビの順番待ちで無駄に待たされて
-- 「極めて遅い」状態になっていた不具合。
--
-- get_version(timeout_ms_override) の長いタイムアウトで「応答が遅い
-- ジョブ（A）」を作り、その応答待ち中（vim.wait()がイベントループを
-- 回している間）に vim.defer_fn() で別の lookup()（B、config.timeout_ms
-- 由来の短いタイムアウト）を割り込ませることで、Bが一度も実行開始
-- できないままタイムアウトする状況を実際のイベントループ経由で再現する。
describe(
  "skkserv の直列キュー（enqueue）: 順番待ち中にタイムアウトしたジョブの後始末（実機で発見・再発防止）",
  function()
    local job_id
    local PORT = 12782
    local VERSION_DELAY_MS = 400

    before_each(function()
      job_id = start_fake_server(PORT, VERSION_DELAY_MS)
    end)

    after_each(function()
      if job_id then
        vim.fn.jobstop(job_id)
      end
      skkserv.setup(nil)
    end)

    it(
      "順番待ちのままタイムアウトしたジョブは queue に残らない（ゾンビ化しない）",
      function()
        if not job_id then
          pending("python3 が無いのでスキップ")
          return
        end
        -- config.timeout_ms は短く: B（割り込む方の lookup()）がすぐタイムアウトする
        skkserv.setup({ host = "127.0.0.1", port = PORT, encoding = "euc-jp", timeout_ms = 80 })

        local b_done = false
        local b_result = nil
        -- A（get_version、長いタイムアウト）の vim.wait() がイベントループを
        -- 回している間に、B を割り込ませる。
        vim.defer_fn(function()
          b_result = skkserv.lookup("かんじ", false)
          b_done = true
        end, 20)

        -- A: サーバー側が VERSION_DELAY_MS だけ応答を遅らせるので、Bが自分の
        -- 80ms でタイムアウトした後、Aはまだキューを占有し続けている状態を
        -- 経由してから、最終的に正常応答を受け取る（2000msなら十分間に合う）。
        local a_version = skkserv.get_version(2000)

        assert.is_not_nil(a_version) -- Aは最終的に正常完了する

        vim.wait(200, function()
          return b_done
        end, 5)
        assert.is_true(b_done)
        assert.are.same({}, b_result) -- Bは自分のタイムアウトで諦めて空配列を返す

        -- 本題: Bのジョブが「実行開始前のままキューに残り続けるゾンビ」に
        -- なっていないこと（Aの完了で queue が正しく空に戻ること）を確認する。
        assert.are.equal(0, skkserv._queue_length())
      end
    )

    it(
      "ゾンビジョブが残らないため、後続のlookup()は素早く完了する（体感速度の再発防止）",
      function()
        if not job_id then
          pending("python3 が無いのでスキップ")
          return
        end
        skkserv.setup({ host = "127.0.0.1", port = PORT, encoding = "euc-jp", timeout_ms = 80 })

        local b_done = false
        vim.defer_fn(function()
          skkserv.lookup("かんじ", false)
          b_done = true
        end, 20)

        skkserv.get_version(2000)
        vim.wait(200, function()
          return b_done
        end, 5)

        -- ゾンビジョブが残っていれば、この3つ目のリクエストがゾンビの
        -- 順番待ちに巻き込まれて余計な待ち時間（最大 timeout_ms 相当）が
        -- 発生するはず。残っていなければ、フェイクサーバーは即応答するので
        -- 数十ms程度で完了する。
        local t0 = vim.loop.now()
        local candidates = skkserv.lookup("かんじ", false)
        local elapsed = vim.loop.now() - t0
        assert.are.equal(3, #candidates)
        assert.is_true(elapsed < 80) -- ゾンビが無ければ timeout_ms(80ms) 未満で完了するはず
      end
    )
  end
)

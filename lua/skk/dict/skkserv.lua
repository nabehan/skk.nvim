-- lua/skk/dict/skkserv.lua
--
-- SKKサーバー（skkserv/dbskkd-cdb/yaskkserv2 等、伝統的な SKK server
-- protocol を話すサーバー）への TCP クライアント。
--
-- 【プロトコル】yaskkserv2 の README（"SKK protocol memo" セクション。
-- skkserv/README, skkserv/skkserv.c 等を出典とする）に基づく。
-- コマンドごとに終端記号が異なる点に注意（実装時に見落としやすく、
-- 実際にこの実装も最初は "1"/"2" とも "\n" 終端だと誤解して書いており、
-- 自作のテスト用フェイクサーバーも同じ誤解で書いていたためテストでは
-- 発覚しなかった）。
--
--   "1" (検索):    client -> server は "1" .. reading .. " "（スペース終端。
--                  改行ではない）。
--                  成功時 server -> client は "1/候補1/候補2/.../\n"（改行終端）。
--                  失敗時は "4" .. reading .. "\n"（先頭の "1" を "4" に
--                  変えて改行付きで返す）。
--   "4" (前方一致検索): client -> server は "4" .. prefix .. " "（"1"と同じく
--                  スペース終端）。成功時は "1/読み1/読み2/.../\n"（改行終端、
--                  中身は候補ではなく「読み」の一覧）。実装していない
--                  サーバーもある（未対応の場合の応答はサーバー依存）。
--                  okuri-ari/okuri-nasi の区別はプロトコル上存在しない。
--   "2" (バージョン確認): client -> server は "2" のみ（終端記号なし）。
--                  server -> client は "A.B "（スペース終端。改行ではない）。
--   "3" (ホスト名):  "2" と同じ終端規則（未実装のサーバーも多い。
--                  yaskkserv2 もダミー文字列を返すのみ）。
--   "0" (切断):    終端記号なし。応答も無い。
--
-- reading はサーバーのエンコーディング（伝統的には EUC-JP）で送る。
-- `debug = true` を設定すると、送受信の生データを vim.notify() で
-- 出力できる（接続はできるのに変換されない、という場合の切り分け用）。
--
-- dict.lookup() は henkan/state.lua から同期APIとして呼ばれるため、
-- 内部では非同期TCP通信を vim.wait() でポーリングして待つラッパーに
-- している。サーバーが応答しない・落ちている場合は timeout_ms で
-- 諦めて空配列を返す（Neovimがフリーズしないようにするため）。

local encoding = require("skk.encoding")
local jisyo_parser = require("skk.dict.jisyo_parser")

local M = {}

local uv = vim.uv or vim.loop

---@type { host: string, port: integer, encoding: string, timeout_ms: integer, debug: boolean }|nil
local config = nil

---@type uv_tcp_t|nil
local client = nil
local connecting = false
--- 【重要・実機で発見】このクライアントは接続を1本だけ使い回す設計で、
--- かつ send_request_and_wait() は「次に届いた1行 = 今送ったリクエストへの
--- 応答」という前提でレスポンスを待つ。send_request_and_wait() は内部で
--- vim.wait() を使うが、vim.wait() は待っている間もイベントループを回す
--- （タイマー・autocmd・キー入力処理が普通に進む）。そのため、応答待ち中に
--- ユーザーが次のキーを叩くと、そのキー入力が SkkHenkanChanged を発火させ、
--- blink.cmp 側が新たな get_completions() を呼び、そこから再び
--- send_request_and_wait() が「再入」して同じ client ソケットに
--- read_start()/write() をかけてしまうことがある。すると応答の行が
--- どちらのリクエストに対応するのか分からなくなり、片方（あるいは両方）が
--- タイムアウトするまで固まる。実機で観測された「同じ読みなのに数ms〜
--- 数千msまで大きくばらつく」「連続する呼び出しの一部だけ極端に遅い」と
--- いう挙動は、この再入による衝突と整合する。
--- そのため in_flight で多重実行を検出し、既に別のリクエストが
--- 進行中なら新しいリクエストは即座に諦める（ソケットには一切触れない）。
local in_flight = false
--- 直近の接続失敗時刻（uv.now() のミリ秒）。しばらく再試行しない
--- （サーバーが落ちているたびに毎回タイムアウトを待つと henkan の
--- 反応が悪くなるため）。
---@type integer|nil
local last_connect_failure = nil
local RECONNECT_COOLDOWN_MS = 5000

--- 直近の lookup()/get_version() が何で終わったか（診断用）。
--- "ok" | "not_configured" | "connect_failed" | "timeout" | "error"
---@type string
local last_status = "not_configured"

---@param label string
---@param ... any
local function debug_notify(label, ...)
  if not (config and config.debug) then
    return
  end
  local parts = { "skkserv debug: " .. label }
  for _, v in ipairs({ ... }) do
    table.insert(parts, tostring(v))
  end
  vim.schedule(function()
    vim.notify(table.concat(parts, " "))
  end)
end

--- 直近の通信結果（診断用）。"ok" | "not_configured" | "connect_failed" |
--- "timeout" | "error"
---@return string
function M.last_status()
  return last_status
end

--- SKKサーバーへの接続を設定する。実際の接続は初回 lookup() 時に行う
--- （setup() 自体はネットワークI/Oを行わない）。
---@param opts { host: string, port: integer?, encoding: string?, timeout_ms: integer?, debug: boolean? }|nil
--- nil を渡すと無効化する。
function M.setup(opts)
  if opts == nil then
    config = nil
    last_status = "not_configured"
  else
    config = {
      host = opts.host,
      port = opts.port or 1178,
      encoding = opts.encoding or "euc-jp",
      timeout_ms = opts.timeout_ms or 300,
      debug = opts.debug or false,
    }
    last_status = "ok" -- まだ何も通信していないが、"not_configured" は抜ける
  end
  if client then
    pcall(function()
      client:close()
    end)
  end
  client = nil
  connecting = false
  last_connect_failure = nil
end

---@return boolean
function M.is_enabled()
  return config ~= nil
end

--- 直近の接続失敗の詳細（診断用。ECONNREFUSED 等の libuv エラー文字列、
--- または getaddrinfo に失敗した場合はその内容）。
---@type string|nil
local last_connect_error = nil

--- "1.2.3.4" 形式の文字列かどうか（雑な判定でよい。違えば getaddrinfo で
--- 名前解決する）。
---@param host string
---@return boolean
local function looks_like_ipv4(host)
  return host:match("^%d+%.%d+%.%d+%.%d+$") ~= nil
end

---@param ip string
---@param on_ready fun(ok: boolean)
local function connect_to_ip(ip, on_ready)
  local sock = uv.new_tcp()
  -- 【重要・実機で発見】TCP_NODELAY を有効にする。これが無いと、
  -- Nagle のアルゴリズム（小さいパケットをまとめて送ろうと少し待つ）と
  -- 受信側の遅延ACK（すぐACKを返さず、送るデータがあれば相乗りさせようと
  -- 少し待つ）が組み合わさり、"1<reading> " のような小さいリクエストの
  -- 往復のたびに ~40ms 前後の人為的な遅延が発生する（ローカルホストでも
  -- 発生する、TCPの典型的な落とし穴）。1回の見出し語入力につき最大
  -- max_items+1 回もこの往復が発生しうる設計（M.lookup_prefix() 参照）の
  -- ため、これが積み重なって数秒単位の遅延として体感された。
  pcall(function()
    sock:nodelay(true)
  end)
  local done = false
  local ok_connect_call, connect_err = pcall(function()
    sock:connect(ip, config.port, function(err)
      if done then
        return
      end
      done = true
      connecting = false
      if err then
        last_connect_error = err
        debug_notify("connect error:", err)
        pcall(function()
          sock:close()
        end)
        last_connect_failure = uv.now()
        on_ready(false)
        return
      end
      client = sock
      on_ready(true)
    end)
  end)
  if not ok_connect_call then
    done = true
    connecting = false
    last_connect_error = tostring(connect_err)
    debug_notify("connect() call failed:", connect_err)
    last_connect_failure = uv.now()
    on_ready(false)
  end
end

--- 直近の接続失敗の詳細（診断用）。接続に一度も失敗していなければ nil。
---@return string|nil
function M.last_connect_error()
  return last_connect_error
end

---@param on_ready fun(ok: boolean)
local function ensure_connected(on_ready)
  if client then
    on_ready(true)
    return
  end
  if connecting then
    debug_notify("already connecting, skip")
    on_ready(false)
    return
  end
  if last_connect_failure and (uv.now() - last_connect_failure) < RECONNECT_COOLDOWN_MS then
    -- 直近で接続に失敗したばかりなので、クールダウン中は再試行しない
    -- （サーバーが落ちているたびに毎回タイムアウト待ちすると henkan の
    -- 反応が悪くなるため）。
    debug_notify("in reconnect cooldown, skip (last error:", last_connect_error, ")")
    on_ready(false)
    return
  end

  connecting = true

  if looks_like_ipv4(config.host) then
    debug_notify("connecting to", config.host .. ":" .. config.port)
    connect_to_ip(config.host, on_ready)
    return
  end

  debug_notify("resolving hostname", config.host)
  uv.getaddrinfo(config.host, nil, { family = "inet" }, function(err, res)
    if err or not res or not res[1] then
      connecting = false
      last_connect_error = err or "getaddrinfo: no result"
      last_connect_failure = uv.now()
      debug_notify("getaddrinfo failed:", last_connect_error)
      vim.schedule(function()
        on_ready(false)
      end)
      return
    end
    vim.schedule(function()
      connect_to_ip(res[1].addr, on_ready)
    end)
  end)
end

--- サーバーからの1行分のレスポンス（"1/.../\n" または "4...\n"）を
--- 候補配列にパースする。サーバーのエンコーディングから UTF-8 へも
--- ここで変換する。
---@param response string 末尾の "\n" を含む生のレスポンス
---@return SkkDictCandidate[]
function M._parse_response(response)
  if response:sub(1, 1) ~= "1" then
    return {}
  end

  local body = response:sub(2):gsub("\n$", "")

  -- 【重要・実機で発見】候補1件ごとに vim.fn.iconv() を呼ぶと
  -- （以前の実装。単語＋注釈で最大候補数×2回）、候補数の多い読み
  -- （「じ」のようなよくある1文字の読みだと数百件になることがある）で
  -- vim.fn.iconv() の呼び出し自体のオーバーヘッド（VimLの関数ディス
  -- パッチを経由するコスト）が積み重なり、体感できるレベルで重くなる。
  -- 対策として、応答本体（body）をまず1回だけ丸ごと UTF-8 に変換して
  -- から候補に分割する（候補1件ごとの変換は不要になる）。
  --
  -- 【分割前に変換して安全か】"/" は EUC-JP・UTF-8 いずれの多バイト文字の
  -- 続きバイトにもならない（EUC-JPの2バイト目以降は 0xA1-0xFE、UTF-8の
  -- 続きバイトは 0x80-0xBF の範囲で、"/" の 0x2F と重ならない）ので、
  -- 変換してから "/" で分割しても、変換前に分割してから個別に変換しても
  -- 結果は同じ。処理順序を入れ替えただけで、パース結果自体は変わらない。
  local utf8_body = encoding.convert(body, config.encoding, "utf-8") or body
  local candidates = jisyo_parser._parse_candidates_string(utf8_body)

  return candidates
end

--- "1"（検索）/ "4"（前方一致検索）共通の、コマンド送信〜応答待ちの
--- 実装。command_body はコマンド文字も含めた送信文字列そのもの
--- （例: "1" .. query .. " "、"4" .. query .. " "）。どちらの応答も
--- "\n" で終端されるので、待ち方は共通化できる。
--- 戻り値: "\n" 終端まで受信できた生の応答文字列。config 未設定・
--- 接続失敗・タイムアウトのいずれかなら nil（last_status に理由を残す）。
---@param command_body string
---@return string|nil response
local function send_request_and_wait(command_body)
  if in_flight then
    -- 既に別のリクエストが進行中。ソケットには一切触れず即座に諦める
    -- （上の in_flight のコメント参照。ここで手を出すと応答の行が
    -- どちらのリクエストのものか分からなくなり、両方が壊れる）。
    last_status = "timeout"
    debug_notify("skipped: another request already in flight")
    return nil
  end
  in_flight = true

  local response = nil
  local connect_ok = nil
  local done = false

  ensure_connected(function(ok)
    connect_ok = ok
    if not ok then
      done = true
      return
    end

    local chunks = {}
    local ok_read = pcall(function()
      client:read_start(function(err, chunk)
        if err or not chunk then
          pcall(function()
            client:read_stop()
          end)
          if not response then
            -- 接続が切れた。次回また ensure_connected() させる。
            pcall(function()
              client:close()
            end)
            client = nil
          end
          done = true
          return
        end
        table.insert(chunks, chunk)
        local full = table.concat(chunks)
        if full:find("\n", 1, true) then
          pcall(function()
            client:read_stop()
          end)
          response = full
          done = true
        end
      end)
    end)

    if not ok_read then
      done = true
      return
    end

    debug_notify("send:", command_body)
    local ok_write = pcall(function()
      client:write(command_body)
    end)
    if not ok_write then
      done = true
    end
  end)

  vim.wait(config.timeout_ms, function()
    return done
  end, 5)

  in_flight = false

  if connect_ok == false then
    last_status = "connect_failed"
    debug_notify("connect failed to", config.host .. ":" .. config.port)
    return nil
  end

  if not response then
    last_status = "timeout"
    debug_notify("timeout waiting for response (timeout_ms=" .. config.timeout_ms .. ")")
    return nil
  end

  debug_notify("recv:", response:gsub("\n$", ""))
  last_status = "ok"
  return response
end

--- SKKサーバーへ読みを検索する（同期的な見た目のAPI）。
--- setup() されていない、接続できない、タイムアウトした場合は
--- いずれも空配列を返す（henkan の変換フロー自体は止めない）。
--- 結果の詳細は M.last_status() で確認できる（診断用）。
---@param reading string
---@param has_okuri boolean 送りありの場合、reading は既に送り仮名の
---  子音を含む形（例: "うごk"）。メイン辞書と同じ規約でそのまま送る。
---@return SkkDictCandidate[]
function M.lookup(reading, has_okuri)
  if not config then
    last_status = "not_configured"
    return {}
  end

  local query, conv_err = encoding.convert(reading, "utf-8", config.encoding)
  if not query then
    last_status = "error"
    debug_notify("encode failed:", conv_err)
    return {}
  end

  -- 【重要】"1" コマンドのリクエストはスペース終端（改行ではない）。
  -- yaskkserv2 の README「SKK protocol memo」参照。
  local response = send_request_and_wait("1" .. query .. " ")
  if not response then
    return {}
  end
  return M._parse_response(response)
end

--- SKKサーバーへ前方一致検索する（"4" コマンド）。伝統的な SKK server
--- protocol の一部だが、実装していないサーバーも多い
--- （yaskkserv2・skkserv 本家等は対応。dbskkd-cdb 等は未検証）。
--- 未対応サーバーの場合は "1" で始まらない応答、または想定外の応答が
--- 返るだけなので、そのまま空配列を返す（henkan フローは止めない）。
---@param prefix string
---@return string[] readings （UTF-8変換済み）
function M.lookup_prefix(prefix)
  if not config then
    last_status = "not_configured"
    return {}
  end

  local query, conv_err = encoding.convert(prefix, "utf-8", config.encoding)
  if not query then
    last_status = "error"
    debug_notify("encode failed:", conv_err)
    return {}
  end

  local response = send_request_and_wait("4" .. query .. " ")
  if not response then
    return {}
  end
  return M._parse_prefix_response(response)
end

--- "4" コマンドの応答文字列 "1/reading1/reading2/.../\n" を
--- 読みの配列にパースする（"1" で始まらなければ空配列）。
--- （_parse_response() 同様、候補ごとではなく応答全体を1回だけ変換する。
--- 理由は _parse_response() のコメント参照。）
---@param response string
---@return string[]
function M._parse_prefix_response(response)
  if response:sub(1, 1) ~= "1" then
    return {}
  end
  local body = response:sub(2):gsub("\n$", "")
  local utf8_body = encoding.convert(body, config.encoding, "utf-8") or body
  local readings = {}
  for part in utf8_body:gmatch("[^/%s]+") do
    readings[#readings + 1] = part
  end
  return readings
end

--- サーバーのバージョン文字列を取得する（"2" コマンド）。エンコーディングに
--- 依存しない単純な接続確認として使える（かな漢字変換の候補が
--- 見つからない場合、まずこれで TCP レベルの疎通を切り分けるとよい）。
---@return string|nil version サーバーが応答しなければ nil
function M.get_version()
  if not config then
    last_status = "not_configured"
    return nil
  end

  local response = nil
  local connect_ok = nil
  local done = false

  ensure_connected(function(ok)
    connect_ok = ok
    if not ok then
      done = true
      return
    end
    local chunks = {}
    debug_notify("send:", "2 (no terminator)")
    pcall(function()
      client:read_start(function(err, chunk)
        if err or not chunk then
          done = true
          return
        end
        table.insert(chunks, chunk)
        local full = table.concat(chunks)
        -- 【重要】"2" コマンドのレスポンスはスペース終端（改行ではない）。
        -- yaskkserv2 の README「SKK protocol memo」参照。
        if full:find(" ", 1, true) then
          pcall(function()
            client:read_stop()
          end)
          response = full
          done = true
        end
      end)
    end)
    pcall(function()
      -- 【重要】"2" コマンドのリクエストは終端記号なし（改行すら不要）。
      client:write("2")
    end)
  end)

  vim.wait(config.timeout_ms, function()
    return done
  end, 5)

  if connect_ok == false then
    last_status = "connect_failed"
    return nil
  end
  if not response then
    last_status = "timeout"
    debug_notify("timeout waiting for version response (timeout_ms=" .. config.timeout_ms .. ")")
    return nil
  end

  debug_notify("recv:", response)
  last_status = "ok"
  return (response:gsub("%s+$", ""))
end

return M

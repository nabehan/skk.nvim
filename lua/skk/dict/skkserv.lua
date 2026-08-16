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

--- 【重要・実機で発見、v3で直列キューに置き換え】このクライアントは
--- 接続を1本だけ使い回す設計で、かつ send_request_and_wait() は
--- 「次に届いた1行 = 今送ったリクエストへの応答」という前提で応答を
--- 待つ。send_request_and_wait() は内部で vim.wait() を使うが、
--- vim.wait() は待っている間もイベントループを回す（タイマー・
--- autocmd・キー入力処理が普通に進む）。そのため、応答待ち中に
--- ユーザーが次のキーを叩くと、そのキー入力が SkkHenkanChanged を
--- 発火させ、blink.cmp 側が新たな get_completions() を呼び、そこから
--- 再び send_request_and_wait() が「再入」して同じ client ソケットに
--- read_start()/write() をかけてしまうことがある。すると応答の行が
--- どちらのリクエストに対応するのか分からなくなり、片方（あるいは
--- 両方）がタイムアウトするまで固まる。
---
--- v2まではこれを in_flight という単純なフラグで検出し、既に別の
--- リクエストが進行中なら新しいリクエストは即座に諦めていた（ソケット
--- には一切触れない）。これで衝突自体は防げていたが、「諦める」＝
--- 「そのリクエストの結果を黙って捨てる」ため、早打ち時に一部の
--- 読みの補完結果が理由なく欠落する副作用があった。また、"2"
--- （バージョン確認）のように、このフラグを見ずに独自にソケットを
--- 直接叩くコードが後から追加されると、同じ穴に落ちる（実際に
--- get_version() がこの穴を踏んでいたため、send_request_and_wait()
--- 経由に修正済み）。
---
--- v3では、衝突したリクエストを「捨てる」のではなく「順番待ちの
--- キューに積む」方式に変更する。ソケットに触れるのは常にキューの
--- 先頭のジョブ1つだけで、そのジョブが完了（応答受信・タイムアウト・
--- エラーのいずれか）してから次のジョブが実行される。これにより、
--- 衝突そのものは従来通り起きず、かつリクエストが失われることもない。
--- "1"/"4"/"2" のいずれの経路も、必ずこのキューを経由する。
---@type (fun(finish: fun()))[]
local queue = {}
local queue_running = false

--- キュー先頭のジョブを1つ実行する。既に実行中なら何もしない
--- （そのジョブの finish() 呼び出しから再度呼ばれるのを待つ）。
local function run_next_in_queue()
  if queue_running then
    return
  end
  local job = table.remove(queue, 1)
  if not job then
    return
  end
  queue_running = true
  job(function()
    queue_running = false
    run_next_in_queue()
  end)
end

--- ジョブをキューの末尾に積む。キューが空でジョブが1つも実行中でなければ
--- 即座に実行される。job は完了時に必ず（一度だけ）finish() を呼ぶこと。
---@param job fun(finish: fun())
local function enqueue(job)
  table.insert(queue, job)
  run_next_in_queue()
end

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
  -- 【重要】setup() の呼び直し（テスト等）で、待機中のジョブが
  -- 残ったまま新しい config に切り替わらないよう、キューも空にする。
  -- 実行中のジョブが既にあれば、それは finish() が呼ばれるまで
  -- queue_running=true のまま残るが、そのジョブ自身は自分の client
  -- 参照で完結するため実害はない。
  queue = {}
  queue_running = false
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

--- "1"（検索）/ "4"（前方一致検索）/ "2"（バージョン確認）共通の、
--- コマンド送信〜応答待ちの実装。command_body はコマンド文字も含めた
--- 送信文字列そのもの（例: "1" .. query .. " "、"2"）。
--- is_terminated は「ここまで受信すれば応答は完結している」と判定する
--- 関数（既定は "\n" 終端。"2" のようにスペース終端のコマンドは
--- 呼び出し側から渡す）。
---
--- 【v3】実際の送受信は enqueue() に積んだジョブの中で行う。同じ接続を
--- 使い回す都合上、ソケットに触れるのは常にキューの先頭ジョブ1つだけ。
--- この関数自体は、自分のジョブが完了する（response が埋まるか
--- タイムアウトする）まで vim.wait() で待ってから返る、従来通りの
--- 同期的な見た目のAPIのまま。
--- 戻り値: 終端条件を満たすまで受信できた生の応答文字列。config
--- 未設定・接続失敗・タイムアウトのいずれかなら nil（last_status に
--- 理由を残す）。
---@param command_body string
---@param is_terminated (fun(full: string): boolean)|nil
---@return string|nil response
local function send_request_and_wait(command_body, is_terminated)
  is_terminated = is_terminated or function(full)
    return full:find("\n", 1, true) ~= nil
  end

  local response = nil
  local connect_ok = nil
  local done = false

  -- タイムアウト時に、キューの先頭を占有したままにしないよう強制的に
  -- 進めるための finish。ジョブ内から自然に呼ばれた場合との二重呼び出し
  -- を防ぐため finished フラグでガードする（enqueue() の契約上、
  -- finish() は一度しか呼んではいけない）。
  local finished = false
  local finish_fn = nil
  local function finish_once()
    if finished then
      return
    end
    finished = true
    if finish_fn then
      finish_fn()
    end
  end

  enqueue(function(finish)
    finish_fn = finish

    ensure_connected(function(ok)
      connect_ok = ok
      if not ok then
        done = true
        finish_once()
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
            finish_once()
            return
          end
          table.insert(chunks, chunk)
          local full = table.concat(chunks)
          if is_terminated(full) then
            pcall(function()
              client:read_stop()
            end)
            response = full
            done = true
            finish_once()
          end
        end)
      end)

      if not ok_read then
        done = true
        finish_once()
        return
      end

      debug_notify("send:", command_body)
      local ok_write = pcall(function()
        client:write(command_body)
      end)
      if not ok_write then
        done = true
        finish_once()
      end
    end)
  end)

  vim.wait(config.timeout_ms, function()
    return done
  end, 5)

  if not done then
    -- 【重要】タイムアウトしても、それだけでは終わらせない。
    -- client:read_stop() だけでは不十分（libuv/Lua側のコールバック配送を
    -- 止めるだけで、OS のソケット受信バッファに溜まった「遅れて届いた
    -- 応答」のバイト列そのものは消えない）。そのまま次のリクエストが
    -- 同じ接続で read_start() すると、その残っていたバイト列を「次の
    -- リクエストへの応答」として誤って受け取ってしまう（実機で発見・
    -- 確認：1つ前のリクエストへの "4...\n"（該当なし応答）が、数リクエスト
    -- 後の応答として誤配送され、そこから連鎖的にズレていった）。
    -- 確実に切り分けるには接続そのものを閉じて capture し直すしかないため、
    -- ここで client を閉じて nil にし、次回の ensure_connected() で
    -- 新しい接続を張らせる（ローカルホストなら再接続のコストは軽微）。
    if client then
      pcall(function()
        client:read_stop()
      end)
      pcall(function()
        client:close()
      end)
      client = nil
    end
    done = true
    -- 【重要】キューの先頭を占有したままだと、以降の全リクエストが
    -- 永久に詰まる。まだジョブ側の非同期コールバックが finish_once()
    -- を呼んでいない可能性があるので、ここで明示的に進める
    -- （finished フラグにより、後から本来のコールバックが遅れて
    -- 発火しても二重には進まない）。
    finish_once()
    last_status = "timeout"
    debug_notify("timeout waiting for response (timeout_ms=" .. config.timeout_ms .. ")")
    return nil
  end

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
  local t0 = config.debug and vim.loop.hrtime() or nil
  local response = send_request_and_wait("1" .. query .. " ")
  local t1 = t0 and vim.loop.hrtime() or nil
  if not response then
    return {}
  end
  local result = M._parse_response(response)
  if t0 then
    debug_notify(
      "lookup timing:",
      string.format("send_and_wait=%.1fms parse=%.1fms", (t1 - t0) / 1e6, (vim.loop.hrtime() - t1) / 1e6)
    )
  end
  return result
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
---
--- 【重要・実機で発見】区切りは "/" のみとする（空白では区切らない）。
--- プロトコル上、応答は "/" 区切りの読み一覧のはずだが、辞書によっては
--- （実機では jawiki 由来の "t(concat "\057")c" のような、SKKの
--- プログラム候補構文がそのまま読みとして紛れ込んでいるエントリで発見）
--- 読みの中に空白を含むものが存在する。以前は "[^/%s]+" で空白でも
--- 区切っていたため、こうしたエントリが誤って複数の読みに分割され、
--- 分割された断片（例 "\"\057\")c"）をサーバーに問い合わせて見つからず、
--- それがきっかけでタイムアウト・応答の取り違えの連鎖を引き起こした
--- （詳細は send_request_and_wait() のタイムアウト処理のコメント参照）。
---@param response string
---@return string[]
function M._parse_prefix_response(response)
  if response:sub(1, 1) ~= "1" then
    return {}
  end
  local body = response:sub(2):gsub("\n$", "")
  local utf8_body = encoding.convert(body, config.encoding, "utf-8") or body
  local readings = {}
  for part in utf8_body:gmatch("[^/]+") do
    readings[#readings + 1] = part
  end
  return readings
end

--- サーバーのバージョン文字列を取得する（"2" コマンド）。エンコーディングに
--- 依存しない単純な接続確認として使える（かな漢字変換の候補が
--- 見つからない場合、まずこれで TCP レベルの疎通を切り分けるとよい）。
---
--- 【重要・v3】以前は in_flight フラグを見ない独自実装だったため、
--- check_skkserv() 由来の "2" と、ライブ補完由来の "1"/"4" が同じ
--- ソケット上でタイミング的に重なると応答が混線する不具合があった。
--- send_request_and_wait() 経由に統一し、他のコマンドと同じキューを
--- 共有することで解消している。
---@return string|nil version サーバーが応答しなければ nil
function M.get_version()
  if not config then
    last_status = "not_configured"
    return nil
  end

  -- 【重要】"2" コマンドのレスポンスはスペース終端（改行ではない）。
  local response = send_request_and_wait("2", function(full)
    return full:find(" ", 1, true) ~= nil
  end)
  if not response then
    return nil
  end
  return (response:gsub("%s+$", ""))
end

return M

-- lua/skk/dict/skkserv.lua
--
-- SKKサーバー（skkserv/dbskkd-cdb/yaskkserv2 等、伝統的な SKK server
-- protocol を話すサーバー）への TCP クライアント。
--
-- 【プロトコル（実装した範囲）】
--   検索リクエスト: "1" .. reading .. "\n"（reading はサーバーの
--     エンコーディング、伝統的には EUC-JP、で送る。ただし yaskkserv2 の
--     ような比較的新しいサーバーは UTF-8 がデフォルトのことがあるので、
--     `encoding = "utf-8"` を試す価値がある。設定は setup() で行う）
--   検索成功レスポンス: "1/候補1/候補2/.../\n"
--   検索失敗レスポンス: "4" .. reading .. "\n"（reading をそのまま返す）
--   バージョン確認: "2\n" -> バージョン文字列
-- 【注意】プロトコルの細部（サーバー実装によって微妙な差異が起こりうる）
-- は tests/fixtures/fake_skkserv.py という自作の簡易サーバーで検証した
-- 範囲に限られる。実際の skkserv/dbskkd-cdb/yaskkserv2 での動作確認が
-- 必要。`debug = true` を設定すると、送受信の生データを vim.notify() で
-- 出力できる（接続はできるのに変換されない、という場合の切り分け用。
-- 典型的な原因はエンコーディングの不一致）。
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
  -- "/" は EUC-JP の多バイト文字の続きバイトにはならない
  -- （EUC-JPの2バイト目以降は 0xA1-0xFE の範囲）ので、
  -- エンコーディング変換前に候補部分文字列へ分割しても安全。
  local candidates = jisyo_parser._parse_candidates_string(body)

  for _, c in ipairs(candidates) do
    c.word = encoding.convert(c.word, config.encoding, "utf-8") or c.word
    if c.annotation then
      c.annotation = encoding.convert(c.annotation, config.encoding, "utf-8") or c.annotation
    end
  end

  return candidates
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

    debug_notify("send:", "1" .. query)
    local ok_write = pcall(function()
      client:write("1" .. query .. "\n")
    end)
    if not ok_write then
      done = true
    end
  end)

  vim.wait(config.timeout_ms, function()
    return done
  end, 5)

  if connect_ok == false then
    last_status = "connect_failed"
    debug_notify("connect failed to", config.host .. ":" .. config.port)
    return {}
  end

  if not response then
    last_status = "timeout"
    debug_notify("timeout waiting for response (timeout_ms=" .. config.timeout_ms .. ")")
    return {}
  end

  debug_notify("recv:", response:gsub("\n$", ""))
  last_status = "ok"
  return M._parse_response(response)
end

--- サーバーのバージョン文字列を取得する（"2" コマンド）。エンコーディングに
--- 依存しない単純な接続確認として使える（かな漢字変換の候補が
--- 見つからない場合、まずこれで TCP レベルの疎通を切り分けるとよい）。
---@return string|nil version サーバーが応答しなければ nil
function M.get_version()
  if not config then
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
    pcall(function()
      client:read_start(function(err, chunk)
        if err or not chunk then
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
    pcall(function()
      client:write("2\n")
    end)
  end)

  vim.wait(config.timeout_ms, function()
    return done
  end, 5)

  if connect_ok == false or not response then
    return nil
  end
  return (response:gsub("\n$", ""))
end

return M

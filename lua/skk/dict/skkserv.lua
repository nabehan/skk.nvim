-- lua/skk/dict/skkserv.lua
--
-- SKKサーバー（skkserv/dbskkd-cdb 等、伝統的な SKK server protocol を
-- 話すサーバー）への TCP クライアント。
--
-- 【プロトコル（実装した範囲）】
--   検索リクエスト: "1" .. reading .. "\n"（reading はサーバーの
--     エンコーディング、伝統的には EUC-JP、で送る）
--   検索成功レスポンス: "1/候補1/候補2/.../\n"
--   検索失敗レスポンス: "4" .. reading .. "\n"（reading をそのまま返す）
--   バージョン確認: "2\n" -> バージョン文字列
-- 【注意】プロトコルの細部（サーバー実装によって微妙な差異が起こりうる）
-- は tests/fixtures/fake_skkserv.py という自作の簡易サーバーで検証した
-- 範囲に限られる。実際の skkserv/dbskkd-cdb での動作確認が必要。
--
-- dict.lookup() は henkan/state.lua から同期APIとして呼ばれるため、
-- 内部では非同期TCP通信を vim.wait() でポーリングして待つラッパーに
-- している。サーバーが応答しない・落ちている場合は timeout_ms で
-- 諦めて空配列を返す（Neovimがフリーズしないようにするため）。

local encoding = require("skk.encoding")
local jisyo_parser = require("skk.dict.jisyo_parser")

local M = {}

local uv = vim.uv or vim.loop

---@type { host: string, port: integer, encoding: string, timeout_ms: integer }|nil
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

--- SKKサーバーへの接続を設定する。実際の接続は初回 lookup() 時に行う
--- （setup() 自体はネットワークI/Oを行わない）。
---@param opts { host: string, port: integer?, encoding: string?, timeout_ms: integer? }|nil
--- nil を渡すと無効化する。
function M.setup(opts)
  if opts == nil then
    config = nil
  else
    config = {
      host = opts.host,
      port = opts.port or 1178,
      encoding = opts.encoding or "euc-jp",
      timeout_ms = opts.timeout_ms or 300,
    }
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
  sock:connect(ip, config.port, function(err)
    if done then
      return
    end
    done = true
    connecting = false
    if err then
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
end

---@param on_ready fun(ok: boolean)
local function ensure_connected(on_ready)
  if client then
    on_ready(true)
    return
  end
  if connecting then
    on_ready(false)
    return
  end
  if last_connect_failure and (uv.now() - last_connect_failure) < RECONNECT_COOLDOWN_MS then
    -- 直近で接続に失敗したばかりなので、クールダウン中は再試行しない
    -- （サーバーが落ちているたびに毎回タイムアウト待ちすると henkan の
    -- 反応が悪くなるため）。
    on_ready(false)
    return
  end

  connecting = true

  if looks_like_ipv4(config.host) then
    connect_to_ip(config.host, on_ready)
    return
  end

  uv.getaddrinfo(config.host, nil, { family = "inet" }, function(err, res)
    if err or not res or not res[1] then
      connecting = false
      last_connect_failure = uv.now()
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
---@param reading string
---@param has_okuri boolean 送りありの場合、reading は既に送り仮名の
---  子音を含む形（例: "うごk"）。メイン辞書と同じ規約でそのまま送る。
---@return SkkDictCandidate[]
function M.lookup(reading, has_okuri)
  if not config then
    return {}
  end

  local query, conv_err = encoding.convert(reading, "utf-8", config.encoding)
  if not query then
    return {}
  end

  local response = nil
  local done = false

  ensure_connected(function(ok)
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

  if not response then
    return {}
  end

  return M._parse_response(response)
end

return M

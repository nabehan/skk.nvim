#!/usr/bin/env python3
"""Minimal fake skkserv for testing skk.nvim's client against the classic
SKK server protocol. EUC-JP encoded on the wire, matching real skkserv.

Protocol (per yaskkserv2's README "SKK protocol memo", which documents the
classic skkserv/skkserv.c behaviour). Note the terminators differ per
command -- this is the actual real-world protocol, not a guess:

  "1<reading> "  (SPACE terminated, NOT newline)  -> exact lookup request
    -> success response: "1/cand1/cand2/.../\n"   (newline terminated)
    -> not-found response: "4<reading>\n"         (newline terminated)
  "4<prefix> "   (SPACE terminated, same as "1")  -> completion (prefix
                 search) request. Distinct from the "4..." NOT-FOUND
                 response above -- same leading byte, but this one is
                 client-initiated. Real servers (yaskkserv2, skk_server.c)
                 support this; skkeleton's skk_server.ts source documents
                 it as `4<prefix> ` -> `1/reading1/reading2/.../\n`.
    -> success response: "1/reading1/reading2/.../\n" (readings, not words)
    -> not-found response: "4<prefix>\n"
  "2"            (no terminator at all)            -> version request
    -> response: "A.B "                            (SPACE terminated)
  "0"            (no terminator)                   -> disconnect, no response
"""
import socket
import sys
import threading
import time

# 【テスト用】"2"（バージョン確認）コマンドへの応答を意図的に遅延させる
# ためのオプション（第2引数、ミリ秒。省略時0=遅延なし）。skkserv.lua の
# 直列キュー（enqueue()）が、あるジョブの応答待ちが長引いている間に別の
# リクエストが割り込んだ場合の挙動をテストするために使う
# （tests/skkserv_spec.lua 参照）。
VERSION_DELAY_MS = int(sys.argv[2]) if len(sys.argv) > 2 else 0

DICT = {
    "かんじ": ["漢字", "幹事;manager", "監事"],
    "てすと": ["テスト"],
    # 実機で確認された、SKKのプログラム候補構文がそのまま読みとして
    # 紛れ込んだ変則エントリの再現用（例: jawiki辞書由来の
    # "a(concat ...)" 系）。"4"（前方一致）では見つかるが、
    # skk.nvim 側は "(" を含む読みへは "1" を送らない設計になっている
    # ため、このエントリが実際に問い合わせられることは無いはず
    # （tests/blink_source_spec.lua 参照）。
    "a(concat": ["ダミー候補（このテストでは選ばれないはず）"],
}

HOST = "127.0.0.1"
PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 11780


def handle(conn):
    with conn:
        buf = b""
        while True:
            chunk = conn.recv(4096)
            if not chunk:
                return
            buf += chunk

            # "1"（完全一致検索）/ "4"（前方一致検索）はどちらもスペース
            # 終端、"2"/"3" はコマンド文字1文字のみ（終端記号なし）、
            # "0" も終端記号なし。
            if buf[:1] == b"1":
                if b" " not in buf:
                    continue  # まだ全体を受信していない
                line, buf = buf.split(b" ", 1)
                reading = line[1:].decode("euc-jp", errors="replace")
                if reading in DICT:
                    body = "/".join(DICT[reading])
                    resp = ("1/" + body + "/\n").encode("euc-jp")
                else:
                    resp = ("4" + reading + "\n").encode("euc-jp")
                conn.sendall(resp)
            elif buf[:1] == b"4":
                if b" " not in buf:
                    continue
                line, buf = buf.split(b" ", 1)
                prefix = line[1:].decode("euc-jp", errors="replace")
                matches = sorted(k for k in DICT if k.startswith(prefix)) if prefix else []
                if matches:
                    resp = ("1/" + "/".join(matches) + "/\n").encode("euc-jp")
                else:
                    resp = ("4" + prefix + "\n").encode("euc-jp")
                conn.sendall(resp)
            elif buf[:1] == b"2":
                buf = buf[1:]
                if VERSION_DELAY_MS > 0:
                    time.sleep(VERSION_DELAY_MS / 1000.0)
                conn.sendall(b"fake-skkserv-1.0 ")  # スペース終端、改行なし
            elif buf[:1] == b"3":
                buf = buf[1:]
                conn.sendall(b"fake-host:127.0.0.1: ")
            elif buf[:1] == b"0":
                return
            else:
                buf = b""  # 未知のコマンドは読み捨てる


def main():
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind((HOST, PORT))
    srv.listen(5)
    print(f"fake skkserv listening on {HOST}:{PORT}", flush=True)
    while True:
        conn, _ = srv.accept()
        threading.Thread(target=handle, args=(conn,), daemon=True).start()


if __name__ == "__main__":
    main()

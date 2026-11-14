#!/usr/bin/env python3
# ===========================================================================
# Minecraft（Java 版）状态查询 / 登录探针（手工工具，不进 CI gate）
#
# 用途：验收时确认「玩家入口 → 代理 → 后端」这条链路在协议层是通的。
#   - 不带 --login：只做 Server List Ping，打印版本/人数（等价服务器列表里的显示）
#   - 带 --login  ：完成握手 + Login Start，打印 LOGIN SUCCESS 或断线原因
#                   （被白名单/登录插件拦下也算链路通——能看到原因就说明链路通）
#
# 用法：
#   python3 tests/mc_status.py --host 127.0.0.1 --port 25565
#   python3 tests/mc_status.py --host 127.0.0.1 --port 25565 --login AcceptJava
#
# 只依赖标准库。
# ===========================================================================
import argparse
import json
import socket
import struct
import sys
import uuid
import zlib


def varint(n):
    out = b""
    n &= 0xFFFFFFFF
    while True:
        b = n & 0x7F
        n >>= 7
        out += bytes([b | (0x80 if n else 0)])
        if not n:
            return out


def read_varint_sock(sock):
    n = 0
    shift = 0
    while True:
        b = sock.recv(1)
        if not b:
            raise EOFError("连接已关闭")
        b = b[0]
        n |= (b & 0x7F) << shift
        shift += 7
        if not b & 0x80:
            return n


def read_varint_buf(data, i):
    n = 0
    shift = 0
    while True:
        b = data[i]
        i += 1
        n |= (b & 0x7F) << shift
        shift += 7
        if not b & 0x80:
            return n, i


def mc_string(s):
    b = s.encode()
    return varint(len(b)) + b


def send_packet(sock, payload):
    sock.sendall(varint(len(payload)) + payload)


def recv_packet(sock, compression):
    length = read_varint_sock(sock)
    data = b""
    while len(data) < length:
        chunk = sock.recv(length - len(data))
        if not chunk:
            raise EOFError("连接已关闭")
        data += chunk
    if compression:
        data_len, i = read_varint_buf(data, 0)
        data = zlib.decompress(data[i:]) if data_len > 0 else data[i:]
    pid, i = read_varint_buf(data, 0)
    return pid, data[i:]


def cmd_status(args):
    sock = socket.create_connection((args.host, args.port), timeout=args.timeout)
    try:
        payload = (varint(0) + varint(args.protocol) + mc_string(args.host)
                   + struct.pack(">H", args.port) + varint(1))
        send_packet(sock, payload)
        send_packet(sock, varint(0))   # status request：长度 1，负载只有包 ID
        pid, body = recv_packet(sock, False)
        if pid != 0x00:
            print("-> 未预期的状态包 0x%02x" % pid)
            return 2
        str_len, i = read_varint_buf(body, 0)
        info = json.loads(body[i:i + str_len].decode("utf-8"))
        print("-> STATUS version=%s protocol=%s players=%s/%s motd=%s" % (
            info.get("version", {}).get("name"),
            info.get("version", {}).get("protocol"),
            info.get("players", {}).get("online"),
            info.get("players", {}).get("max"),
            str(info.get("description"))[:60].replace("\n", " ")))
        return 0
    finally:
        sock.close()


def cmd_login(args, compression=False):
    sock = socket.create_connection((args.host, args.port), timeout=args.timeout)
    try:
        payload = (varint(0) + varint(args.protocol) + mc_string(args.host)
                   + struct.pack(">H", args.port) + varint(2))
        send_packet(sock, payload)
        body = varint(0) + mc_string(args.login) + uuid.uuid5(
            uuid.NAMESPACE_DNS, "orzmc-probe:" + args.login).bytes
        send_packet(sock, body)
        for _ in range(4):
            pid, body = recv_packet(sock, compression)
            if pid == 0x03:          # Set Compression
                compression = True
                continue
            if pid == 0x02:          # Login Success
                n, i = read_varint_buf(body, 16)
                print("-> LOGIN SUCCESS name=%s" % body[i:i + n].decode())
                return 0
            if pid == 0x00:          # Disconnect（被白名单/登录插件拦下，链路仍是通的）
                n, i = read_varint_buf(body, 0)
                print("-> DISCONNECT %s" % body[i:i + n].decode("utf-8", "replace"))
                return 0
        print("-> 未预期的登录回包")
        return 2
    finally:
        sock.close()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=25565)
    ap.add_argument("--protocol", type=int, default=777, help="MC 协议号（26.3 = 777）")
    ap.add_argument("--login", help="走登录流程，打印 LOGIN SUCCESS 或断线原因")
    ap.add_argument("--timeout", type=int, default=10)
    args = ap.parse_args()
    try:
        return cmd_login(args) if args.login else cmd_status(args)
    except Exception as exc:  # noqa: BLE001 - 手工工具，直接把原因打出来
        print("-> 失败: %s: %s" % (type(exc).__name__, exc))
        return 2


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
# ===========================================================================
# Eaglercraft 握手探针（手工执行，不进 CI；CI 只跑 bash -n / shellcheck / 文档校验）
#
# 用途：
#   1) 验证 Eaglercraft 服务端（EaglerXServer / EaglerXPaper）是否接受指定版本的
#      Eaglercraft 握手协议，并确认协商出的 Minecraft 协议号；
#   2) 走完 LOGIN 请求，拿回允许登录的用户名与 UUID（验证离线 UUID 是否稳定）；
#   3) --sniff：起假 WebSocket 服务器，抓**真客户端**首帧，打印它声明的
#      eagler / minecraft 协议表（调研用，见 docs/eaglercraft.md §2.4）。
#
# 用法：
#   python3 tests/eaglercraft_probe.py --host <host> --port <port> [--tls]
#   python3 tests/eaglercraft_probe.py --host <host> --port <port> --tls --login TestUser
#   python3 tests/eaglercraft_probe.py --sniff --port 9500
#
# 只依赖标准库（socket / ssl / struct）。
# ===========================================================================

import argparse
import base64
import hashlib
import os
import socket
import ssl
import struct
import sys
import threading
import time
import uuid

WS_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"


def ws_connect(host, port, path="/", use_tls=False, timeout=15, real_ip=None):
    """建立裸 WebSocket 连接（Eaglercraft 客户端不发 Sec-WebSocket-Protocol）。

    real_ip：EaglerXServer 的 forward_ip=true 时，HTTP/WS 连接必须带 X-Real-IP，
    否则会被 "Connected without a X-Real-IP header, disconnecting" 拒绝——经反代
    （Caddy 的 header_up X-Real-IP）由反代注入；直连代理调试时要自己带。
    """
    raw = socket.create_connection((host, port), timeout=timeout)
    if use_tls:
        context = ssl._create_unverified_context()
        raw = context.wrap_socket(raw, server_hostname=host)
    key = base64.b64encode(os.urandom(16)).decode()
    request = (
        "GET %s HTTP/1.1\r\nHost: %s:%d\r\n"
        "Upgrade: websocket\r\nConnection: Upgrade\r\n"
        "Sec-WebSocket-Key: %s\r\nSec-WebSocket-Version: 13\r\n"
        % (path, host, port, key)
    )
    if real_ip:
        request += "X-Real-IP: %s\r\n" % real_ip
    request += "\r\n"
    raw.sendall(request.encode())
    buf = b""
    while b"\r\n\r\n" not in buf:
        chunk = raw.recv(4096)
        if not chunk:
            raise RuntimeError("连接在 WebSocket 握手阶段被关闭：%r" % buf)
        buf += chunk
    head, _, rest = buf.partition(b"\r\n\r\n")
    status = head.split(b"\r\n")[0].decode(errors="replace")
    if "101" not in status:
        raise RuntimeError("WebSocket 升级失败：%s" % status)
    return raw, rest


def send_frame(sock, payload):
    mask = os.urandom(4)
    size = len(payload)
    header = b"\x82"
    if size < 126:
        header += bytes([0x80 | size])
    elif size < 65536:
        header += bytes([0x80 | 126]) + struct.pack(">H", size)
    else:
        header += bytes([0x80 | 127]) + struct.pack(">Q", size)
    masked = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
    sock.sendall(header + mask + masked)


class FrameReader(object):
    def __init__(self, sock, pending=b""):
        self.sock = sock
        self.buf = pending

    def _need(self, count):
        while len(self.buf) < count:
            chunk = self.sock.recv(65536)
            if not chunk:
                raise RuntimeError("连接已关闭（剩余 %r）" % self.buf)
            self.buf += chunk
        out, self.buf = self.buf[:count], self.buf[count:]
        return out

    def read(self):
        b0, b1 = self._need(2)
        masked = bool(b1 & 0x80)
        length = b1 & 0x7F
        if length == 126:
            length = struct.unpack(">H", self._need(2))[0]
        elif length == 127:
            length = struct.unpack(">Q", self._need(8))[0]
        mask = self._need(4) if masked else None
        payload = self._need(length)
        if mask is not None:  # 客户端 -> 服务端方向必须掩码，抓包时要还原
            payload = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
        return b0 & 0x0F, payload


def varint(value):
    out = b""
    while True:
        byte = value & 0x7F
        value >>= 7
        if value:
            out += bytes([byte | 0x80])
        else:
            return out + bytes([byte])


def build_handshake(eagler_protocols, mc_protocols, auth_name=b"",
                    brand=b"EaglercraftX", version=b"26.3"):
    """Eaglercraft 首帧：0x01 0x02 + 版本表 + brand/version + auth 标志 + auth 用户名。"""
    payload = bytes([0x01, 0x02])
    payload += struct.pack(">H", len(eagler_protocols))
    payload += b"".join(struct.pack(">H", item) for item in eagler_protocols)
    payload += struct.pack(">H", len(mc_protocols))
    payload += b"".join(struct.pack(">H", item) for item in mc_protocols)
    payload += bytes([len(brand)]) + brand + bytes([len(version)]) + version
    payload += bytes([1 if auth_name else 0, len(auth_name)]) + auth_name
    return payload


def build_login(username, auth_password=b""):
    """v4/v5 REQUEST_LOGIN：用户名 / 目标服 / 口令 / cookie / 能力位（全 0）。"""
    name = username.encode()
    payload = bytes([0x04, len(name)]) + name
    payload += bytes([0])                       # 目标服（空）
    payload += bytes([len(auth_password)]) + auth_password
    payload += bytes([0])                       # enableCookie = false
    payload += bytes([0])                       # cookie 长度 0
    payload += varint(0)                        # 标准能力位 = 0
    payload += bytes([0])                       # 扩展能力数 0
    return payload


def parse_server_version(data):
    sel_eagler, sel_mc = struct.unpack(">HH", data[1:5])
    index = 5
    blen = data[index]
    index += 1
    brand = data[index:index + blen].decode(errors="replace")
    index += blen
    vlen = data[index]
    index += 1
    version = data[index:index + vlen].decode(errors="replace")
    index += vlen
    return sel_eagler, sel_mc, brand, version, data[index:]


def parse_allow_login(data):
    index = 1
    nlen = data[index]
    index += 1
    name = data[index:index + nlen].decode(errors="replace")
    index += nlen
    high, low = struct.unpack(">qq", data[index:index + 16])
    uid = uuid.UUID(int=((high & (2 ** 64 - 1)) << 64) | (low & (2 ** 64 - 1)))
    return name, uid


def cmd_probe(args):
    eagler_protocols = [int(item) for item in args.eagler_protocols.split(",")]
    mc_protocols = [int(item) for item in args.mc_protocols.split(",")]
    auth_name = args.login.encode() if args.login else b""

    sock, rest = ws_connect(args.host, args.port, use_tls=args.tls, real_ip=args.real_ip)
    reader = FrameReader(sock, rest)
    try:
        send_frame(sock, build_handshake(eagler_protocols, mc_protocols, auth_name))
        _opcode, data = reader.read()
        if not data:
            raise RuntimeError("服务端返回空帧")
        kind = data[0]
        if kind == 0x03:
            count = struct.unpack(">H", data[1:3])[0]
            advertised = [struct.unpack(">H", data[3 + 2 * k:5 + 2 * k])[0] for k in range(count)]
            print("-> VERSION_MISMATCH：服务端只接受 eagler 协议 %s" % advertised)
            return 2
        if kind == 0xFF:
            print("-> SERVER_ERROR code=%d msg=%s" % (data[1], data[3:].decode(errors="replace")))
            return 2
        if kind != 0x02:
            print("-> 未预期的首包 0x%02x（hex=%s）" % (kind, data[:32].hex()))
            return 2

        sel_eagler, sel_mc, brand, version, tail = parse_server_version(data)
        print("-> SERVER_VERSION: eagler_protocol=%d minecraft_protocol=%d brand=%r version=%r tail=%s"
              % (sel_eagler, sel_mc, brand, version, tail.hex()))

        if not args.login:
            return 0

        send_frame(sock, build_login(args.login))
        _opcode, data = reader.read()
        if data and data[0] == 0x05:
            name, uid = parse_allow_login(data)
            print("-> ALLOW_LOGIN name=%r uuid=%s" % (name, uid))
            return 0
        if data and data[0] == 0x06:
            print("-> DENY_LOGIN")
            return 2
        if data and data[0] == 0xFF:
            print("-> SERVER_ERROR code=%d msg=%s" % (data[1], data[3:].decode(errors="replace")))
            return 2
        print("-> 未预期的登录回包 hex=%s" % (data[:48].hex()))
        return 2
    finally:
        try:
            sock.close()
        except OSError:
            pass


def cmd_sniff(args):
    """起假 WS 服务器，打印真实客户端首帧中的协议表。"""
    server = socket.socket()
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server.bind(("0.0.0.0", args.port))
    server.listen(8)
    print("sniffer listening on %d（让客户端连 ws(s)://<host>:%d/）" % (args.port, args.port))
    deadline = time.time() + args.timeout
    while time.time() < deadline:
        server.settimeout(max(1, deadline - time.time()))
        try:
            conn, _addr = server.accept()
        except socket.timeout:
            break
        threading.Thread(target=_sniff_one, args=(conn,), daemon=True).start()
    return 0


def _sniff_one(conn):
    conn.settimeout(25)
    try:
        request = b""
        while b"\r\n\r\n" not in request:
            chunk = conn.recv(4096)
            if not chunk:
                return
            request += chunk
        head = request.split(b"\r\n\r\n")[0].decode(errors="replace")
        key = ""
        for line in head.split("\r\n"):
            if line.lower().startswith("sec-websocket-key:"):
                key = line.split(":", 1)[1].strip()
        accept = base64.b64encode(
            hashlib.sha1((key + WS_GUID).encode()).digest()).decode()
        conn.sendall(("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n"
                      "Connection: Upgrade\r\nSec-WebSocket-Accept: %s\r\n\r\n" % accept).encode())
        opcode, payload = FrameReader(conn).read()
        print("=== 首帧 opcode=%d len=%d ===" % (opcode, len(payload)))
        print("hex:", payload[:64].hex())
        if len(payload) > 4 and payload[0] == 0x01 and payload[1] == 0x02:
            index = 2
            ecount = struct.unpack(">H", payload[index:index + 2])[0]
            index += 2
            eprots = [struct.unpack(">H", payload[index + 2 * k:index + 2 * k + 2])[0]
                      for k in range(ecount)]
            index += 2 * ecount
            mcount = struct.unpack(">H", payload[index:index + 2])[0]
            index += 2
            mprots = [struct.unpack(">H", payload[index + 2 * k:index + 2 * k + 2])[0]
                      for k in range(mcount)]
            index += 2 * mcount
            blen = payload[index]
            index += 1
            brand = payload[index:index + blen].decode(errors="replace")
            index += blen
            vlen = payload[index]
            index += 1
            version = payload[index:index + vlen].decode(errors="replace")
            index += vlen
            print("eagler_protocols=%s" % eprots)
            print("minecraft_protocols=%s" % mprots)
            print("brand=%r version=%r trailing=%s" % (brand, version, payload[index:].hex()))
    except Exception as exc:  # noqa: BLE001 - 探针工具，打印即止
        print("sniff error: %s: %s" % (type(exc).__name__, exc))
    finally:
        try:
            conn.close()
        except OSError:
            pass


def main():
    parser = argparse.ArgumentParser(description="Eaglercraft 握手探针（手工验收用）")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=25565)
    parser.add_argument("--tls", action="store_true", help="用 wss:// 连接（不校验证书）")
    parser.add_argument("--eagler-protocols", default="5", help="声明支持的 eagler 握手协议，默认 5")
    parser.add_argument("--mc-protocols", default="777", help="声明支持的 MC 协议，默认 777（26.3）")
    parser.add_argument("--login", help="完成 LOGIN 请求并打印 ALLOW_LOGIN 的 UUID")
    parser.add_argument("--real-ip", help="带上 X-Real-IP 头（直连代理时必需：forward_ip=true）")
    parser.add_argument("--sniff", action="store_true", help="起假 WS 服务器抓真客户端首帧")
    parser.add_argument("--timeout", type=int, default=120, help="--sniff 的等待秒数")
    args = parser.parse_args()

    if args.sniff:
        return cmd_sniff(args)
    try:
        return cmd_probe(args)
    except Exception as exc:  # noqa: BLE001 - 探针工具，打印即止
        print("probe failed: %s: %s" % (type(exc).__name__, exc))
        return 1


if __name__ == "__main__":
    sys.exit(main())

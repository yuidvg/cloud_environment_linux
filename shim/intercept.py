#!/usr/bin/env python3
"""エージェントプロキシの手前に入る中継プロキシ（gh-shim intercept）。

iptables（shim/ensure.sh が設定）で、エージェントプロキシ（HTTPS_PROXY = 127.0.0.1:<port>）
宛ての接続はすべてここに付け替えられる。ここでは 1 行目だけを見て:

  - CONNECT api.github.com:443 で、接続元のプロセスが nix のとき
      -> ローカルの gh-shim（127.0.0.1:443）につなぐ
  - それ以外（gh / curl / git などすべて）
      -> 元の宛先（SO_ORIGINAL_DST）にそのまま中継する。中身には触れない（TLS も終端しない）

このプロセスが張る上流への接続には SO_MARK を付け、iptables の付け替え対象から外す
（付け替えがループしないように）。
"""
import asyncio
import os
import socket
import struct
import sys

LISTEN = ("127.0.0.1", int(os.environ.get("GH_SHIM_INTERCEPT_PORT", "18443")))
SHIM = ("127.0.0.1", 443)
MARK = int(os.environ.get("GH_SHIM_MARK", "0x6768"), 0)
INTERCEPT_HOSTS = {"api.github.com"}
NIX_EXES = {"nix"}  # nix-build / nix-shell なども実体は nix
SO_ORIGINAL_DST = 80


def log(msg):
    sys.stderr.write(msg + "\n")
    sys.stderr.flush()


def original_dst(sock):
    raw = sock.getsockopt(socket.SOL_IP, SO_ORIGINAL_DST, 16)
    return socket.inet_ntoa(raw[4:8]), struct.unpack("!H", raw[2:4])[0]


def client_exe(peer_port):
    """ループバックの接続元ポートから、そのソケットを持つプロセスの実行ファイルを探す。"""
    local = f"0100007F:{peer_port:04X}"
    inode = None
    with open("/proc/net/tcp") as f:
        next(f)
        for line in f:
            p = line.split()
            if p[1] == local:
                inode = p[9]
                break
    if not inode or inode == "0":
        return None
    target = f"socket:[{inode}]"
    for pid in os.listdir("/proc"):
        if not pid.isdigit():
            continue
        fd_dir = f"/proc/{pid}/fd"
        try:
            fds = os.listdir(fd_dir)
        except OSError:
            continue
        for fd in fds:
            try:
                if os.readlink(f"{fd_dir}/{fd}") == target:
                    return os.readlink(f"/proc/{pid}/exe")
            except OSError:
                pass
    return None


async def copy(reader, writer):
    try:
        while data := await reader.read(65536):
            writer.write(data)
            await writer.drain()
    except (ConnectionError, OSError):
        pass
    finally:
        try:
            writer.write_eof()
        except (OSError, RuntimeError):
            pass


async def pipe(cr, cw, ur, uw):
    try:
        await asyncio.gather(copy(cr, uw), copy(ur, cw))
    finally:
        for w in (cw, uw):
            w.close()


async def handle(reader, writer):
    sock = writer.get_extra_info("socket")
    peer_port = writer.get_extra_info("peername")[1]
    try:
        dst = original_dst(sock)
    except OSError:
        writer.close()  # iptables を通らずに直接来た接続は扱わない
        return
    try:
        head = await asyncio.wait_for(reader.readuntil(b"\r\n\r\n"), 30)
    except (asyncio.TimeoutError, asyncio.IncompleteReadError, asyncio.LimitOverrunError, OSError):
        writer.close()
        return

    parts = head.split(b"\r\n", 1)[0].decode("latin-1").split()
    if len(parts) >= 2 and parts[0].upper() == "CONNECT":
        host = parts[1].rsplit(":", 1)[0].lower()
        if host in INTERCEPT_HOSTS:
            exe = client_exe(peer_port)
            if exe and os.path.basename(exe) in NIX_EXES:
                try:
                    ur, uw = await asyncio.open_connection(*SHIM)
                except OSError as e:
                    log(f"gh-shim not reachable: {e}")
                    writer.write(b"HTTP/1.1 502 Bad Gateway\r\n\r\n")
                    writer.close()
                    return
                writer.write(b"HTTP/1.1 200 Connection established\r\n\r\n")
                return await pipe(reader, writer, ur, uw)

    # 素通し: 元の宛先へ、受け取ったバイト列をそのまま流す
    up = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    try:
        up.setsockopt(socket.SOL_SOCKET, socket.SO_MARK, MARK)
        up.setblocking(False)
        await asyncio.get_running_loop().sock_connect(up, dst)
        ur, uw = await asyncio.open_connection(sock=up)
    except OSError as e:
        up.close()
        log(f"upstream {dst} unreachable: {e}")
        writer.close()
        return
    uw.write(head)
    await pipe(reader, writer, ur, uw)


async def main():
    srv = await asyncio.start_server(handle, *LISTEN, reuse_address=True)
    async with srv:
        await srv.serve_forever()


if __name__ == "__main__":
    asyncio.run(main())

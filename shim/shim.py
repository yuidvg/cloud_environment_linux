#!/usr/bin/env python3
"""Local api.github.com shim for Nix.

Nix の github: フェッチャーが使う 2 つのエンドポイントだけを真似する:
  GET /repos/{o}/{r}/commits/{ref}  -> ref を commit SHA に解決（tree / 日付つき）
  GET /repos/{o}/{r}/tarball/{rev}  -> git archive の tar.gz
中身は匿名 git（公開リポジトリには正規に許可されている経路）で取る。
リクエストの Authorization ヘッダー（ダミートークン）は見ない。
"""
import http.server
import json
import os
import re
import ssl
import subprocess
import sys
import threading

CACHE = "/var/cache/gh-shim"
CERT_DIR = "/opt/gh-shim"
LOCK = threading.Lock()
SHA = re.compile(r"^[0-9a-f]{40}$")
NAME = re.compile(r"^[A-Za-z0-9_.-]+$")


def git(*args, cwd=None):
    return subprocess.run(
        ["git", *args], cwd=cwd, check=True, capture_output=True, text=True
    ).stdout


def resolve(o, r, ref):
    """ref を commit SHA に解決する（refs/heads → タグの ^{} → タグ → そのまま）。"""
    if SHA.match(ref):
        return ref
    url = f"https://github.com/{o}/{r}"
    if ref.startswith("refs/") or ref == "HEAD":
        cands = [ref]
    else:
        cands = [f"refs/heads/{ref}", f"refs/tags/{ref}^{{}}", f"refs/tags/{ref}", ref]
    for cand in cands:
        out = git("ls-remote", url, cand).split()
        if out:
            return out[0]
    raise KeyError(ref)


def ensure(o, r, rev):
    """bare リポジトリに rev を depth 1 で取ってくる（取得済みなら何もしない）。"""
    d = os.path.join(CACHE, o, r + ".git")
    with LOCK:
        if not os.path.isdir(d):
            os.makedirs(d)
            git("init", "--bare", "-q", d)
            git("remote", "add", "origin", f"https://github.com/{o}/{r}", cwd=d)
        missing = subprocess.run(
            ["git", "cat-file", "-e", rev + "^{commit}"], cwd=d, capture_output=True
        ).returncode
        if missing:
            git("fetch", "-q", "--depth", "1", "origin", rev, cwd=d)
    return d


def commit_json(o, r, rev):
    d = ensure(o, r, rev)
    tree, date = git("show", "-s", "--format=%T %cI", rev, cwd=d).split()
    # sha だけだと Nix が "type must be string, but is null" で落ちるので tree / date も返す
    return {
        "sha": rev,
        "commit": {
            "tree": {"sha": tree},
            "committer": {"date": date},
            "author": {"date": date},
        },
    }


def tarball(o, r, rev):
    d = ensure(o, r, rev)
    return subprocess.run(
        ["git", "archive", "--format=tar.gz", f"--prefix={o}-{r}-{rev[:7]}/", rev],
        cwd=d,
        check=True,
        capture_output=True,
    ).stdout


class Handler(http.server.BaseHTTPRequestHandler):
    def send(self, code, body, ctype):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def do_GET(self):
        path = self.path.split("?")[0]
        try:
            if m := re.match(r"^/repos/([^/]+)/([^/]+)/commits/(.+)$", path):
                o, r, ref = m.groups()
                self._check(o, r)
                body = json.dumps(commit_json(o, r, resolve(o, r, ref))).encode()
                return self.send(200, body, "application/json")
            if m := re.match(r"^/repos/([^/]+)/([^/]+)/tarball/(.+)$", path):
                o, r, ref = m.groups()
                self._check(o, r)
                return self.send(200, tarball(o, r, resolve(o, r, ref)), "application/x-gzip")
            self.send(404, b'{"message":"gh-shim: unsupported endpoint"}', "application/json")
        except (KeyError, ValueError, subprocess.CalledProcessError) as e:
            sys.stderr.write(f"gh-shim error {path}: {getattr(e, 'stderr', None) or e}\n")
            self.send(404, b'{"message":"Not Found"}', "application/json")

    do_HEAD = do_GET

    @staticmethod
    def _check(o, r):
        # パス操作（../ など）でキャッシュ外に書かせない
        if not (NAME.match(o) and NAME.match(r)) or o.startswith(".") or r.startswith("."):
            raise ValueError(f"bad repo name {o}/{r}")


def main():
    srv = http.server.ThreadingHTTPServer(("127.0.0.1", 443), Handler)
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.load_cert_chain(f"{CERT_DIR}/server.crt", f"{CERT_DIR}/server.key")
    srv.socket = ctx.wrap_socket(srv.socket, server_side=True)
    srv.serve_forever()


if __name__ == "__main__":
    main()

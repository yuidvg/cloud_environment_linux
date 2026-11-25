#!/bin/bash
# Claude Code クラウド環境用セットアップスクリプト
#   - Nix（single-user）
#   - api.github.com のローカル shim（github: 形式の flake 入力を透過的に使えるようにする）
#   - home-manager で CLI ツール・環境変数・dotfiles を宣言的に管理
set -euo pipefail

export USER=root HOME=/root
SYS_CA=/etc/ssl/certs/ca-certificates.crt
export NIX_SSL_CERT_FILE=$SYS_CA

# ---------------------------------------------------------------------------
# 1. Nix 本体（root / systemd なし前提）
# ---------------------------------------------------------------------------
if [ ! -e /root/.nix-profile/etc/profile.d/nix.sh ]; then
  mkdir -p /etc/nix
  cat > /etc/nix/nix.conf <<'EOF'
build-users-group =
sandbox = false
experimental-features = nix-command flakes
ssl-cert-file = /etc/nix/ca-bundle.pem
# github: 入力を api.github.com の tarball API 経由で取らせるためのダミー（shim は中身を見ない）
access-tokens = github.com=gh-shim-dummy
EOF
  curl -fsSL https://releases.nixos.org/nix/nix-2.24.10/install | sh -s -- --no-daemon --yes
fi
. /root/.nix-profile/etc/profile.d/nix.sh

# ---------------------------------------------------------------------------
# 2. api.github.com shim
#    Nix の github: フェッチャーが使う 2 つの API だけを、匿名 git（公開リポジトリは
#    正規に許可されている経路）で中身を取ってきて返す
# ---------------------------------------------------------------------------
mkdir -p /opt/gh-shim /var/cache/gh-shim
cat > /opt/gh-shim/shim.py <<'EOF'
#!/usr/bin/env python3
"""Local api.github.com shim for Nix: serves commits/tarball endpoints via anonymous git."""
import http.server, json, os, re, ssl, subprocess, sys, threading

CACHE = "/var/cache/gh-shim"
LOCK = threading.Lock()
SHA = re.compile(r"^[0-9a-f]{40}$")

def git(*a, cwd=None):
    return subprocess.run(["git", *a], cwd=cwd, check=True, capture_output=True, text=True).stdout

def resolve(o, r, ref):
    if SHA.match(ref):
        return ref
    url = f"https://github.com/{o}/{r}"
    cands = [ref] if ref.startswith("refs/") or ref == "HEAD" else \
        [f"refs/heads/{ref}", f"refs/tags/{ref}^{{}}", f"refs/tags/{ref}", ref]
    for cand in cands:
        out = git("ls-remote", url, cand).split()
        if out:
            return out[0]
    raise KeyError(ref)

def ensure(o, r, rev):
    d = os.path.join(CACHE, o, r + ".git")
    with LOCK:
        if not os.path.isdir(d):
            os.makedirs(d)
            git("init", "--bare", "-q", d)
            git("remote", "add", "origin", f"https://github.com/{o}/{r}", cwd=d)
        if subprocess.run(["git", "cat-file", "-e", rev + "^{commit}"], cwd=d, capture_output=True).returncode:
            git("fetch", "-q", "--depth", "1", "origin", rev, cwd=d)
    return d

def commit_json(o, r, rev):
    d = ensure(o, r, rev)
    tree, date = git("show", "-s", "--format=%T %cI", rev, cwd=d).split()
    return {"sha": rev, "commit": {"tree": {"sha": tree},
                                   "committer": {"date": date}, "author": {"date": date}}}

def tarball(o, r, rev):
    d = ensure(o, r, rev)
    return subprocess.run(["git", "archive", "--format=tar.gz", f"--prefix={o}-{r}-{rev[:7]}/", rev],
                          cwd=d, check=True, capture_output=True).stdout

class H(http.server.BaseHTTPRequestHandler):
    def send(self, code, body, ctype):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def do_GET(self):
        p = self.path.split("?")[0]
        try:
            if m := re.match(r"^/repos/([^/]+)/([^/]+)/commits/(.+)$", p):
                o, r, ref = m.groups()
                body = json.dumps(commit_json(o, r, resolve(o, r, ref))).encode()
                return self.send(200, body, "application/json")
            if m := re.match(r"^/repos/([^/]+)/([^/]+)/tarball/(.+)$", p):
                o, r, ref = m.groups()
                return self.send(200, tarball(o, r, resolve(o, r, ref)), "application/x-gzip")
            self.send(404, b'{"message":"gh-shim: unsupported endpoint"}', "application/json")
        except (KeyError, subprocess.CalledProcessError) as e:
            sys.stderr.write(f"gh-shim error {p}: {getattr(e, 'stderr', e)}\n")
            self.send(404, b'{"message":"Not Found"}', "application/json")

    do_HEAD = do_GET

srv = http.server.ThreadingHTTPServer(("127.0.0.1", 443), H)
ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
ctx.load_cert_chain("/opt/gh-shim/server.crt", "/opt/gh-shim/server.key")
srv.socket = ctx.wrap_socket(srv.socket, server_side=True)
srv.serve_forever()
EOF

# shim 用の自己署名 CA と api.github.com 証明書（Nix だけが信頼する）
if [ ! -e /opt/gh-shim/server.crt ]; then
  (
    cd /opt/gh-shim
    openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -subj "/CN=gh-shim local CA" \
      -keyout ca.key -out ca.crt 2>/dev/null
    openssl req -newkey rsa:2048 -nodes -subj "/CN=api.github.com" \
      -keyout server.key -out server.csr 2>/dev/null
    printf "subjectAltName=DNS:api.github.com\nbasicConstraints=CA:FALSE\nextendedKeyUsage=serverAuth\n" > ext.cnf
    openssl x509 -req -in server.csr -CA ca.crt -CAkey ca.key -CAcreateserial -days 3650 \
      -extfile ext.cnf -out server.crt 2>/dev/null
  )
fi

# nix ラッパー：毎回 hosts・CA バンドル・shim の起動を確認し、
# nix のプロセスにだけ api.github.com をプロキシに通さず shim に向けさせる
# （gh や curl などほかのツールはこれまでどおりプロキシ経由）
mkdir -p /root/.local/bin
cat > /root/.local/bin/nix <<'EOF'
#!/bin/bash
grep -q '^127.0.0.1 api.github.com$' /etc/hosts 2>/dev/null || echo '127.0.0.1 api.github.com' >> /etc/hosts
cat /etc/ssl/certs/ca-certificates.crt /opt/gh-shim/ca.crt > /etc/nix/ca-bundle.pem.tmp \
  && mv /etc/nix/ca-bundle.pem.tmp /etc/nix/ca-bundle.pem
if ! (exec 3<>/dev/tcp/127.0.0.1/443) 2>/dev/null; then
  nohup python3 /opt/gh-shim/shim.py >>/var/log/gh-shim.log 2>&1 &
  for _ in $(seq 50); do (exec 3<>/dev/tcp/127.0.0.1/443) 2>/dev/null && break; sleep 0.1; done
fi
export no_proxy="${no_proxy:+$no_proxy,}api.github.com" NO_PROXY="${NO_PROXY:+$NO_PROXY,}api.github.com"
export NIX_SSL_CERT_FILE=/etc/nix/ca-bundle.pem
exec /root/.nix-profile/bin/nix "$@"
EOF
chmod +x /root/.local/bin/nix
export PATH=/root/.local/bin:$PATH

# ---------------------------------------------------------------------------
# 3. home-manager の設定（github: 形式のままで OK）
# ---------------------------------------------------------------------------
mkdir -p ~/.config/home-manager
cat > ~/.config/home-manager/flake.nix <<'EOF'
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    home-manager = {
      url = "github:nix-community/home-manager/release-26.05";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { nixpkgs, home-manager, ... }: {
    homeConfigurations.root = home-manager.lib.homeManagerConfiguration {
      pkgs = nixpkgs.legacyPackages.x86_64-linux;
      modules = [
        ({ pkgs, ... }: {
          home.username = "root";
          home.homeDirectory = "/root";
          home.stateVersion = "26.05";

          # 入れたい CLI ツール
          home.packages = with pkgs; [
            fd bat eza just
          ];

          # 環境変数（秘密情報はここに書かない）
          home.sessionVariables = {
            EDITOR = "vim";
          };

          # Claude の Bash からも nix（ラッパー）と環境変数が見えるように .bashrc で読み込む
          programs.bash = {
            enable = true;
            bashrcExtra = ''
              . /root/.nix-profile/etc/profile.d/nix.sh
              . /root/.nix-profile/etc/profile.d/hm-session-vars.sh
              export PATH=/root/.local/bin:$PATH
            '';
          };

          programs.git = {
            enable = true;
            settings.alias.st = "status";
          };
        })
      ];
    };
  };
}
EOF

cd ~/.config/home-manager
nix run --inputs-from . home-manager -- switch --flake .#root -b bak

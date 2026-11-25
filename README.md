# cloud_environment_linux

Claude Code のクラウド環境（claude.ai/code の cloud environment）を、Nix + home-manager で宣言的に管理するリポジトリ。

## 使い方

クラウド環境の設定の **Setup script** 欄に次を貼る。

```bash
#!/bin/bash
# rev: 1
curl -fsSL https://raw.githubusercontent.com/yuidvg/cloud_environment_linux/main/setup.sh | bash
```

`# rev:` は、設定を push したあとにキャッシュを作り直させるためのコメント（後述）。

`setup.sh` は次の 3 段階を順に実行する。各段階の開始・終了・所要時間は stdout と `/var/log/cloud-env-setup.log` に出る。

| 段階 | 内容 | 目安 |
| --- | --- | --- |
| 1. shim setup | `api.github.com` のローカル shim、intercept（nix の通信だけを shim に回す中継プロキシ）、CA バンドル、`~/.claude/settings.json` への SessionStart フックの登録、`/etc/profile.d/zz-gh-shim.sh` | 数秒 |
| 2. nix install | [NixOS/nix-installer](https://github.com/NixOS/nix-installer)（`install linux --init none`）。ベースイメージに nix が入っていればスキップ。どちらの場合も最後に `nix.conf` へ shim の設定を足す | 約 30 秒 |
| 3. home-manager setup | `nix run github:yuidvg/cloud_environment_linux#home-manager -- switch --flake github:yuidvg/cloud_environment_linux#root -b bak` | 約 70 秒 |

shim を先に用意するのは、nix-installer に `--ssl-cert-file /etc/nix/ca-bundle.pem` を渡すため（インストーラーはこのファイルが存在しないと失敗する）。

環境変数 `CLOUD_ENV_OWNER` / `CLOUD_ENV_REPO` / `CLOUD_ENV_REF` で、取得元のリポジトリやブランチを変えられる（fork やブランチでの試験用）。

```bash
curl -fsSL https://raw.githubusercontent.com/yuidvg/cloud_environment_linux/my-branch/setup.sh | CLOUD_ENV_REF=my-branch bash
```

### 失敗したときの扱い

- **shim / nix のインストールの失敗** → 非ゼロで終了する。セッションは起動しないが、壊れた環境に気づかずに作業するよりよい。
- **home-manager の switch の失敗** → `WARN` をログに残し、ゼロで終了する。`home/default.nix` の書き間違い一つでセッションが起動しなくなるのを避けるため。このとき `~/.bashrc` に最低限の設定（nix のプロファイルの読み込み）を追記するので、セッション内で nix を使って直せる。

## パッケージや環境変数を追加する

1. `home/default.nix` の `home.packages` や `home.sessionVariables`、`programs.*` を編集する
2. （入力を更新したいときは）手元の Mac で `nix flake update` して `flake.lock` も更新する
3. `main` に push する
4. **環境のキャッシュが作り直されたあとの新しいセッションから反映される。** 既存のセッションには反映されない

> [!IMPORTANT]
> キャッシュがある間は、新しいセッションでも Setup script は**実行されない**（ドキュメント上「cached environment があるときはスキップ」）。
> Setup script 欄の文字列は curl の行のままなので、push しただけではキャッシュは作り直されず、最大で約 7 日間は古い設定のままになる。
> すぐに反映したいときは、Setup script 欄のコメントを書き換えてキャッシュを作り直させる。
>
> ```bash
> #!/bin/bash
> # rev: 2   ← push したら数字を上げる
> curl -fsSL https://raw.githubusercontent.com/yuidvg/cloud_environment_linux/main/setup.sh | bash
> ```

いまのセッションですぐ試したいときは、次を実行する。

```bash
nix run github:yuidvg/cloud_environment_linux#home-manager -- switch --refresh --flake github:yuidvg/cloud_environment_linux#root -b bak
```

`flake.lock` は Mac でもそのまま作れる。shim 経由で取った `github:` の中身の narHash は、本物の GitHub tarball と一致する（`scripts/check.sh` の 5 番で確認している）。

## shim の仕組み

クラウド環境の GitHub 通信は Anthropic の専用プロキシを通る。このプロキシは、セッションにつないでいないリポジトリへの API（`api.github.com/repos/...`）とアーカイブ（`github.com/.../archive/...`、`codeload.github.com`）を、公開リポジトリであっても 403 にする。一方、公開リポジトリの匿名 `git clone` / `fetch` は通る。そのため Nix の `github:` フェッチャーはそのままでは動かない。

そこで次の仕組みで、**nix からの** `api.github.com` への通信だけを、`git` を使うローカルの shim に回す。

```
nix（どの経路で呼んでも）      gh / curl / git など
  │ CONNECT api.github.com        │ CONNECT <host>
  ▼                                ▼
HTTPS_PROXY = 127.0.0.1:<port>（エージェントプロキシ）
  │ iptables（nat OUTPUT）で付け替え
  ▼
127.0.0.1:18443  intercept（shim/intercept.py）
  │ 接続元が nix で宛先が api.github.com      │ それ以外
  ▼                                            ▼ 元のプロキシへそのまま中継（中身に触れない）
127.0.0.1:443  shim（shim/shim.py）
  │ git ls-remote / git fetch --depth 1（匿名、プロキシ経由）
  ▼
github.com（公開リポジトリ）
```

- `shim/shim.py` は `127.0.0.1:443` で `api.github.com` のふりをする。真似するのは次の 2 つだけ。
  - `GET /repos/{o}/{r}/commits/{ref}` → ref を commit に解決して `sha` / `tree` / 日付を返す
  - `GET /repos/{o}/{r}/tarball/{rev}` → `git archive` の tar.gz を返す
- `shim/intercept.py` は、エージェントプロキシの手前に入る中継プロキシ。iptables で、エージェントプロキシのポート宛ての接続はすべてここに付け替えられる。リクエストの 1 行目だけを見て、
  - `CONNECT api.github.com:443` で、接続元のプロセス（`/proc/net/tcp` のソケットから引く）の実行ファイルが `nix` なら、shim につなぐ。`nix-build` / `nix-shell` なども実体は `nix` なので同じ扱い
  - それ以外は、元の宛先（`SO_ORIGINAL_DST`）へ受け取ったバイト列をそのまま流す。TLS は終端しないので、`gh` や `curl` から見た挙動は変わらない
  - 自分が張る上流への接続には `SO_MARK`（`0x6768`）を付け、iptables の付け替え対象から外す（ループしないように）
- そのため、PATH の順番や呼び方（Claude の Bash ツール、`/nix/var/nix/profiles/default/bin/nix`、`/nix/store/...-nix/bin/nix`）に関係なく、どの nix にも shim が効く。ラッパーや `no_proxy` の書き換えはない。
- エージェントプロキシは Claude Code 本体の中で待ち受けていて、**ポートはセッションごとに変わる**。そのため iptables の規則は Setup script ではなく、`~/.claude/settings.json` に登録した **SessionStart フック**（`/opt/gh-shim/ensure.sh`。セッションの開始・再開のたびに動く）で、そのときの `HTTPS_PROXY` のポートに合わせて入れ直す。規則は専用のチェイン `GH_SHIM` にまとめている。
- intercept が止まるとプロキシ経由の通信がすべて止まるので、shim と intercept は `shim/supervise.sh` の下で動かし、落ちても 1 秒後に起動し直す。`ensure.sh` は intercept が待ち受けていないときは iptables の規則を外す。Claude 本体の API 通信（`api.anthropic.com`）はもともとプロキシを通らないので、影響を受けない。
- shim の設定は**環境変数ではなく `nix.conf` で**渡す。`ensure.sh` が `/etc/nix/gh-shim.conf` を書き、`nix.conf` の**最後の行**に `!include /etc/nix/gh-shim.conf` を置く。後から読んだ設定が勝つので、ほかの場所（ベースイメージの nix-installer が書いた `nix.custom.conf` の `ssl-cert-file = /etc/ssl/certs/ca-certificates.crt` など）より優先される。
  - `ssl-cert-file = /etc/nix/ca-bundle.pem`：Nix は `NIX_SSL_CERT_FILE` より `nix.conf` の `ssl-cert-file` を優先するので、環境変数だけでは効かない。
  - `extra-access-tokens = github.com=gh-shim-dummy`：Nix はトークンがあるときだけ `api.github.com/.../tarball/...` を使う（ないと `github.com/.../archive/...` に行き、プロキシに 403 にされる）。shim はトークンの中身を見ない。
- shim の自己署名 CA は **Nix だけが信頼する**（`/etc/nix/ca-bundle.pem` = エージェントプロキシの CA（`/root/.ccr/ca-bundle.crt`）+ システム CA + shim CA）。システムの信頼ストアには入れない。
- `ensure.sh`（setup.sh と SessionStart フックから呼ばれる。冪等）がそろえるもの:
  1. `/etc/hosts` の `127.0.0.1 api.github.com`（プロキシを使わない nix 用。Setup script の時点ではエージェントプロキシがまだないので、setup.sh 自身の nix はこの経路を使う）
  2. `/etc/nix/ca-bundle.pem` の作り直し（プロキシの CA は入れ替わることがある。中身が変わったときだけ書き換える）
  3. `nix.conf` の `!include` と `/etc/nix/gh-shim.conf`
  4. shim と intercept の起動（環境のキャッシュにはプロセスが残らないので、セッションごとに起動し直す）
  5. iptables の付け替え規則

### 限界

- **取れるのは公開リポジトリ（とセッションにつないだリポジトリ）だけ。** shim は匿名 git で中身を取るため、非公開リポジトリの `github:` 入力は解決できない。このリポジトリ自体が公開なのもそのため。
- **Nix が使う 2 つの API しか真似しない。** ほかのエンドポイントには 404 を返す。nix 以外のプログラムは intercept が素通しするので影響しない。
- **nix の `api.github.com` への通信は、セッションにつないだリポジトリでも shim に回る。** shim は匿名 git で取るので、非公開リポジトリは nix からは取れない（`gh` などは従来どおりプロキシで取れる）。
- **SessionStart フックが動く前の通信は付け替えられない。** Setup script の中では `/etc/hosts` と `no_proxy` で shim に直接つなぐ。
- `/etc/hosts` に `127.0.0.1 api.github.com` があるので、プロキシを使わずに `api.github.com` に直接つなぐプログラムは shim に当たる（shim の CA を信頼していないので TLS エラーになる）。
- タグとブランチの解決は `git ls-remote` で行う。`github:owner/repo` のように ref を省くと `HEAD` を使う。

## キャッシュの挙動

- Setup script が約 5 分以内に終わると、ファイルシステムのスナップショットが環境のキャッシュとして保存され、次のセッションからはそこから始まる（Nix のストア、home-manager の生成物、shim の証明書や git キャッシュもここに含まれる）。**キャッシュから始まるセッションでは Setup script は実行されない。**
- キャッシュは **約 7 日ごと** と、**Setup script 欄（または許可するネットワークホスト）を変えたとき** に作り直される。`setup.sh` や `home/default.nix` を push しただけでは作り直されないので、すぐに反映したい場合は Setup script 欄のコメントを書き換える（上記）。
- アイドル後に VM が復元されたときも Setup script は実行されない。セッションの再開時に SessionStart フック（`ensure.sh`）が、`/etc/hosts`、shim / intercept、iptables（プロキシの新しいポート）を直す。
- キャッシュはファイルだけで、プロセスや iptables の規則は保存されない。どちらも SessionStart フックで用意する。
- Setup script の中で `export` した変数はセッションに引き継がれない。PATH や `home.sessionVariables` は `~/.bashrc`（home-manager の `programs.bash.bashrcExtra`）で読み込んでいる。

## 秘密情報を入れない

このリポジトリは **公開** である（`raw.githubusercontent.com` で `setup.sh` を取るため、また shim が匿名 git で flake を取るため）。API キーやトークンなどの秘密情報は絶対にコミットしない。必要なものはクラウド環境の設定（環境変数、Network secrets）で渡す。

`nix.conf` の `access-tokens = github.com=gh-shim-dummy` はダミーで、秘密ではない。

## 検証（ゼロからの通しテスト）

1. claude.ai/code で新しいクラウド環境を作り、Setup script 欄に上の 2 行を貼る
2. その環境で新しいセッションを始める
3. セッション内で受け入れテストを実行する

```bash
curl -fsSL https://raw.githubusercontent.com/yuidvg/cloud_environment_linux/main/scripts/check.sh | bash
```

`scripts/check.sh` が確認すること:

1. `bash -lc`・`bash -ic`・呼び出し元（Claude の Bash ツール）のどれでも `nix` が PATH にある
2. `home.packages` のツール（fd, bat, eza, just, rg, jq, meguri）に PATH が通っている
3. `home.sessionVariables`（`CLOUD_ENV_LINUX=1`, `EDITOR=vim`, `LANG=C.UTF-8`）が `bash -lc` と `bash -ic` の両方で見える
4. shim を kill し、`/etc/hosts` の行を消しても、`ensure.sh`（SessionStart フックと同じもの）で直り、`--refresh` 付きで `github:` を取れる
5. 同じ rev を `github:` と `git+https://` で `nix flake prefetch` したとき narHash が一致する
6. `curl https://api.github.com/` が shim を通らない（証明書の発行者が gh-shim の CA ではない）、対話シェルの `no_proxy` に `api.github.com` がない
7. 直近の `setup.sh` の所要時間（ログの `TOTAL`）が 5 分未満
8. `nix.conf` 経由で `ssl-cert-file` が `/etc/nix/ca-bundle.pem`、`access-tokens` に `github.com=gh-shim-dummy` がある
9. SessionStart フックが登録され、intercept が動き、iptables が `HTTPS_PROXY` のポート宛てを intercept に付け替えている
10. PATH の `nix`、`/nix/var/nix/profiles/default/bin/nix`、store パスの `nix` のどれで `--refresh` しても、403（とキャッシュへの退避の警告）が出ない

ログ: `/var/log/cloud-env-setup.log`（セットアップ）、`/var/log/gh-shim.log`（ensure.sh）、`/var/log/gh-shim-shim.log` / `/var/log/gh-shim-intercept.log`（各プロセス）

## 構成

```
.
├── setup.sh              # エントリポイント（Setup script から curl | bash される）
├── shim/
│   ├── shim.py           # api.github.com shim → /opt/gh-shim/shim.py
│   ├── intercept.py      # nix の api.github.com だけを shim に回す中継プロキシ → /opt/gh-shim/intercept.py
│   ├── supervise.sh      # shim / intercept が落ちたら起動し直す → /opt/gh-shim/supervise.sh
│   ├── ensure.sh         # hosts / CA / nix.conf / プロセス / iptables → /opt/gh-shim/ensure.sh（SessionStart フック）
│   └── profile.sh        # → /etc/profile.d/zz-gh-shim.sh（ログインシェルで nix のプロファイルを読む）
├── flake.nix             # homeConfigurations.root と packages.home-manager（入力に meguri）
├── flake.lock
├── home/default.nix      # packages / sessionVariables / programs.*
├── scripts/check.sh      # 受け入れテスト
└── reference/claude-cloud-setup.sh   # 移植元（single-user の公式インストーラー版）
```

## やらないこと

- Determinate Systems のインストーラー（`install.determinate.systems`）は使わない（許可リスト外）
- shim の CA をシステムの信頼ストアに入れない。`.bashrc` で `no_proxy` を変えない（nix 以外を shim に回さない）
- TLS 検証を無効にしない。`HTTPS_PROXY` を unset しない

参考: https://code.claude.com/docs/en/cloud-environments.md

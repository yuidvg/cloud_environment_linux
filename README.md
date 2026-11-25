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
| 1. shim setup | `api.github.com` のローカル shim、CA バンドル、`/root/.local/bin/nix` ラッパー | 数秒 |
| 2. nix install | [NixOS/nix-installer](https://github.com/NixOS/nix-installer)（`install linux --init none`） | 約 30 秒 |
| 3. home-manager setup | `nix run github:yuidvg/cloud_environment_linux#home-manager -- switch --flake github:yuidvg/cloud_environment_linux#root -b bak` | 約 70 秒 |

shim を先に用意するのは、nix-installer に `--ssl-cert-file /etc/nix/ca-bundle.pem` を渡すため（インストーラーはこのファイルが存在しないと失敗する）。

環境変数 `CLOUD_ENV_OWNER` / `CLOUD_ENV_REPO` / `CLOUD_ENV_REF` で、取得元のリポジトリやブランチを変えられる（fork やブランチでの試験用）。

```bash
curl -fsSL https://raw.githubusercontent.com/yuidvg/cloud_environment_linux/my-branch/setup.sh | CLOUD_ENV_REF=my-branch bash
```

### 失敗したときの扱い

- **shim / nix のインストールの失敗** → 非ゼロで終了する。セッションは起動しないが、壊れた環境に気づかずに作業するよりよい。
- **home-manager の switch の失敗** → `WARN` をログに残し、ゼロで終了する。`home/default.nix` の書き間違い一つでセッションが起動しなくなるのを避けるため。このとき `~/.bashrc` に最低限の PATH 設定（nix のプロファイルとラッパー）を追記するので、セッション内で nix を使って直せる。

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

そこで次の仕組みで `github:` を `git` に置き換える。

```
nix (ラッパー経由)
  │  no_proxy=api.github.com / NIX_SSL_CERT_FILE=/etc/nix/ca-bundle.pem
  ▼
api.github.com  ──/etc/hosts──▶  127.0.0.1:443  (shim/shim.py)
                                    │ git ls-remote / git fetch --depth 1（匿名、プロキシ経由）
                                    ▼
                               github.com（公開リポジトリ）
```

- `shim/shim.py` は `127.0.0.1:443` で `api.github.com` のふりをする。真似するのは次の 2 つだけ。
  - `GET /repos/{o}/{r}/commits/{ref}` → ref を commit に解決して `sha` / `tree` / 日付を返す
  - `GET /repos/{o}/{r}/tarball/{rev}` → `git archive` の tar.gz を返す
- Nix は `access-tokens` にトークンがあるときだけ `api.github.com/.../tarball/...` を使う（ないと `github.com/.../archive/...` に行ってしまう）。そこで `nix.conf` にダミーのトークン `github.com=gh-shim-dummy` を入れている。shim はトークンの中身を見ない。
- shim の自己署名 CA は **Nix だけが信頼する**（`/etc/nix/ca-bundle.pem` = システム CA + shim CA）。システムの信頼ストアには入れない。
- `/root/.local/bin/nix`（`shim/nix-wrapper.sh`）は実行のたびに `/opt/gh-shim/ensure.sh` を呼び、次を直してから本物の nix（`/nix/var/nix/profiles/default/bin/nix`）を exec する。
  1. `/etc/hosts` の `127.0.0.1 api.github.com`（VM の復元で消える可能性がある）
  2. `/etc/nix/ca-bundle.pem` の作り直し（プロキシの CA は入れ替わることがある）
  3. shim の起動（環境のキャッシュにはプロセスが残らないので、セッションごとに起動し直す）
- `no_proxy=api.github.com` は nix のプロセスにだけ設定する。`.bashrc` には書かないので、`gh` や `curl`、Claude の GitHub ツールはこれまでどおりプロキシを通る。

### 限界

- **取れるのは公開リポジトリ（とセッションにつないだリポジトリ）だけ。** shim は匿名 git で中身を取るため、非公開リポジトリの `github:` 入力は解決できない。このリポジトリ自体が公開なのもそのため。
- **Nix が使う 2 つの API しか真似しない。** ほかのエンドポイントには 404 を返す。ただし、ラッパーの外では `/etc/hosts` に関係なくプロキシ経由になるので（プロキシがホスト名で接続する）、`gh` などには影響しない。
- `/etc/hosts` に `127.0.0.1 api.github.com` があるので、プロキシを使わずに `api.github.com` に直接つなぐプログラムは shim に当たる（shim の CA を信頼していないので TLS エラーになる）。
- タグとブランチの解決は `git ls-remote` で行う。`github:owner/repo` のように ref を省くと `HEAD` を使う。

## キャッシュの挙動

- Setup script が約 5 分以内に終わると、ファイルシステムのスナップショットが環境のキャッシュとして保存され、次のセッションからはそこから始まる（Nix のストア、home-manager の生成物、shim の証明書や git キャッシュもここに含まれる）。**キャッシュから始まるセッションでは Setup script は実行されない。**
- キャッシュは **約 7 日ごと** と、**Setup script 欄（または許可するネットワークホスト）を変えたとき** に作り直される。`setup.sh` や `home/default.nix` を push しただけでは作り直されないので、すぐに反映したい場合は Setup script 欄のコメントを書き換える（上記）。
- アイドル後に VM が復元されたときも Setup script は実行されない。`/etc/hosts` の行が消えていたり shim が止まっていたりしても、nix ラッパーが実行時に直す。
- キャッシュはファイルだけで、プロセスは保存されない。shim はラッパーが必要になったときに起動する。
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

1. `bash -lc` と `bash -ic` の両方で `which nix` が `/root/.local/bin/nix`
2. `home.packages` のツール（fd, bat, eza, just, rg, jq）に PATH が通っている
3. `home.sessionVariables`（`CLOUD_ENV_LINUX=1`, `EDITOR=vim`）が `bash -lc` と `bash -ic` の両方で見える
4. shim を kill し、`/etc/hosts` の行を消しても `nix flake metadata github:nix-community/home-manager/release-26.05` が成功する（ラッパーの自動復旧）
5. 同じ rev を `github:` と `git+https://` で `nix flake prefetch` したとき narHash が一致する
6. `curl https://api.github.com/` が shim を通らない（証明書の発行者が gh-shim の CA ではない）、対話シェルの `no_proxy` に `api.github.com` がない
7. 直近の `setup.sh` の所要時間（ログの `TOTAL`）が 5 分未満

ログ: `/var/log/cloud-env-setup.log`（セットアップ）、`/var/log/gh-shim.log`（shim）

## 構成

```
.
├── setup.sh              # エントリポイント（Setup script から curl | bash される）
├── shim/
│   ├── shim.py           # api.github.com shim → /opt/gh-shim/shim.py
│   ├── ensure.sh         # hosts / CA バンドル / shim 起動の確認 → /opt/gh-shim/ensure.sh
│   └── nix-wrapper.sh    # → /root/.local/bin/nix
├── flake.nix             # homeConfigurations.root と packages.home-manager
├── flake.lock
├── home/default.nix      # packages / sessionVariables / programs.*
├── scripts/check.sh      # 受け入れテスト
└── reference/claude-cloud-setup.sh   # 移植元（single-user の公式インストーラー版）
```

## やらないこと

- Determinate Systems のインストーラー（`install.determinate.systems`）は使わない（許可リスト外）
- shim の CA をシステムの信頼ストアに入れない。`.bashrc` で `no_proxy` を変えない
- TLS 検証を無効にしない。`HTTPS_PROXY` を unset しない

参考: https://code.claude.com/docs/en/cloud-environments.md

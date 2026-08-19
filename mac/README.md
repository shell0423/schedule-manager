# mac/ — 別の友人に渡す macOS 配布物の素材

`windows/` の macOS 版。**Claude Code も Python も入っていない Mac ユーザー**が
ZIP 一式だけで動かせるようにするための素材置き場。`src/` は Mac 版・Windows 版と共有し、
ここには macOS 固有のものだけを置く。

このフォルダ自体は配布しない。`build_mac_zip.py` が `src/` と混ぜて `dist/ai-hisho-mac.zip` を作る。

## ビルド

```bash
cd ~/Claude/スケジュール管理
.venv/bin/python build_mac_zip.py     # → dist/ai-hisho-mac.zip
```

ビルド時に機械的に保証していること:

- `.sh` / `.command` は **LF**（CR が混ざると shebang が壊れて起動しない）
- `.command` / `.sh` に **実行権(755)を立て、ZIP の external_attr に保存する**。
  書き出した ZIP を読み直して実行権ビットが載っているか検証し、落ちていたらビルドを中止する
  （これが無いと展開後にダブルクリックできず、友人が最初の1歩で詰まる）
- `.env` / `credentials.json` / `token.json` / `schedule.db` は名前でも中身でも混入不可
- shebang の無い `.sh` / `.command` があれば中止

## Windows 版との違い

| | Windows | macOS |
|---|---|---|
| 入口 | `.bat`（ASCII・CRLF 必須） | `.command`（LF・**実行権が必須**） |
| 実処理 | PowerShell 5.1 互換の `.ps1` | **bash 3.2 互換**の `.sh`（連想配列・`${var^^}` は使えない） |
| 常駐 | スタートアップ + 再起動ループ | **LaunchAgent（KeepAlive）**。launchd が面倒を見るので再起動ループの自作が要らない |
| 定時実行 | タスクスケジューラ | LaunchAgent `StartCalendarInterval` |
| 設置場所 | `C:\ai-hisho` 固定 | **どこでもよい**。スクリプトが自分の位置から `$ROOT` を求める |
| 常駐の登録 | 固定パス前提で同梱 | **`make_plists.py` が設置場所に合わせて毎回生成**（ユーザー名も置き場所も人によって違うため） |
| 初回の関門 | 「WindowsによってPCが保護されました」 | **Gatekeeper**（右クリック→開く）。`1_setup` が残り全部の隔離を解除する |
| 停止 | プロセスを名前で探して kill | `launchctl unload` だけ |

## macOS 固有で気をつけた点

- **Gatekeeper / 隔離属性**: ネット経由の ZIP は `com.apple.quarantine` が付き、ダブルクリックが
  ブロックされる。`1_setup.command` の冒頭で `xattr -dr` + `chmod +x` を全体にかけ、
  **最初の1本さえ右クリックで開ければ残りは普通に動く**ようにしてある。ガイド STEP 6 に手順を明記。
- **Python の選び方**: 「新しい順」にしてはいけない。Homebrew の 3.14 系は `ensurepip` を持たず
  `venv` を作れないことがある（**実機で踏んだ**）。3.11〜3.13 を最優先、次に 3.10、その後 3.14 系、
  最後に macOS 標準の 3.9 という順で試し、**実際に venv を作って pip が動くまで次の候補に落ちる**。
- **macOS 標準の Python 3.9.6 で動く**ことを確認済み（テスト53件パス＋Flask 疎通）。
  つまり多くの Mac では Python を別途入れなくてよい。ただし Google 製ライブラリが
  「3.9 はサポート対象外」の警告を出す（無視してよい）。
- **plist は plistlib で生成**する。文字列連結の XML だと、置き場所に空白・日本語・`&` が
  入ったときに壊れる（`/Users/太郎/Desktop/AI秘書 & 予定/` のようなパスは普通にありうる）。
- **ポート衝突**: 「ポートが応答する ≠ 自分のが動いている」。別プログラムが 5555 を使っていると
  `status` が誤って OK を出すため、LaunchAgent の稼働状況と併せて判定している。
  `3_start` は起動前に衝突を検出して止まる。
- **フォルダの移動**: plist には絶対パスが焼かれるので、移動すると launchd が黙って失敗する。
  `status` が plist の `WorkingDirectory` と現在地を比較して検出し、`3_start` で直せる。

## 配布先の前提（Windows 版と違う点）

この配布先は **Claude Code を使っており、AI にも技術にも詳しい**。Windows 版の友人
（Claude Code も Python も持たない前提）とは想定が違うので、資料の作り方を変えてある。

| ファイル | 役割 |
|---|---|
| `CLAUDE.md` | Claude Code がプロジェクト直下から**毎セッション自動で読む**運用メモ |
| `.claude/settings.json` | `.env` / `token.json` / `credentials.json` の Read を deny |
| `0_START_HERE.html` | 前提知識ゼロ向けの導入。冒頭に**慣れている人向けの近道**を置いてある |
| `使えないケース.md` | 届かない/入らない条件と仕様上の制約。`CLAUDE.md` と HTML の両方から参照している |

`CLAUDE.md` は噛み砕きではなく密度を優先して書く。噛み砕くと、直接手を動かせる相手に
`.command` への迂回を勧めることになり、かえって遅くなる。載せているのは次の4種類:

1. **アーキテクチャと運用コマンド** — `3_start` が何を一括でやるか（unload → plist 再生成 →
   load → 疎通 → LINE 側 URL 登録）まで書く。手で `launchctl` を叩くより速いと分かるように
2. **セットアップの分担** — AI が代行できる範囲と、人間にしかできないこと
   （OAuth のブラウザ同意・鍵の取得・LINE 側の応答設定）を明示。詳しい相手ほど
   **セットアップごと AI に投げる**ので、ここが効く
3. **「一見おかしいが意図的」な箇所を理由つきで** — 対話認証にフォールバックしない件、
   週次/日次の分離とリトライ、終日 end の exclusive 変換、dict 検証、ポート判定。
   詳しい相手＝コードを実際に触る相手なので、**善意の"修正"で壊れる場所**を先に潰しておく
4. **環境固有の罠** — plist の絶対パス、ngrok のユーザー共通設定と同時1セッション、
   Gatekeeper、Homebrew 3.14 の ensurepip 欠落

`.claude/settings.json` の deny は **file ツールを守るだけで `cat` 等のシェル経由は塞げない**。
補助であって歯止めは `CLAUDE.md` 側にある、と両方に明記した（消してよいが利用者に伝えること、
とも書いてある）。

`CLAUDE.md` に載せたコマンド（`python -m pytest` / `-m ruff` / `-m mypy` /
`pip install -r requirements-dev.txt`）は、**実際に動くことを確認してから記載**している。

## 実機確認の状況

Windows 版と違い、**開発機が macOS なので実際に動かして確認できている**。確認済み:

- ZIP 展開後に実行権と LF が保たれること（`unzip` 実測）
- `1_setup.command` の通し実行（Python 選択のフォールバック・venv・pip・ngrok 自動DL・`.env` 生成）
- ngrok の macOS 版ダウンロードと起動（`ngrok version` が通る）
- `make_plists.py` が空白・日本語・`&` 入りパスで妥当な plist を吐くこと（`plutil -lint`）
- **LaunchAgent の load → 稼働 → `/healthz` 応答 → unload** の一巡
- `status.command` が全項目を完走すること、ポート衝突の検出
- `3_start.command` が未認証状態で安全に停止すること

未確認（作者の環境では安全に試せない）:

- **ngrok を実際に起動しての外部疎通**。ngrok 無料枠は同時1セッションで、
  作者の本番トンネルを奪ってしまうため意図的に試していない
- LINE の Webhook URL 自動登録（相手のチャネルが要る）
- 他人の Mac での Gatekeeper の出方（macOS のバージョンで文言が変わる）

## 保守メモ

- `.sh` は **bash 3.2 互換**で書く（macOS の `/bin/bash` は 3.2）。`declare -A` は使えない
- 秘密の受け渡しは環境変数で。引数に書くと `ps` で他ユーザーに見える
- `ngrok config add-authtoken` は**ユーザー共通の設定を書き換える**。テストで偽トークンを
  入れると自分の本番 ngrok 認証を壊すので注意
- `check_gemini.py` は Windows 版と共有（`shared/`）。どちらのビルドも `scripts/` 直下に置く
- `CLAUDE.md` を直したら、書いた手順が本当に動くか確かめてから配ること。
  AI はそこに書いてあることを事実として扱うので、間違いがそのまま実行される

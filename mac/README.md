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

## 相手が Claude Code を使う前提での同梱物

この配布先は Claude Code を持っている（Windows 版の友人とはここが違う）ので、
**AI に読ませる前提の資料を同梱している**。

| ファイル | 役割 |
|---|---|
| `CLAUDE.md` | Claude Code がプロジェクト直下から**毎セッション自動で読み込む**運用メモ。人間向けの `0_START_HERE.html` とは別物 |
| `.claude/settings.json` | `.env` / `token.json` / `credentials.json` の Read を拒否する権限設定 |

`CLAUDE.md` に書いたのは、**AI が知らずに壊す可能性が高いこと**に絞ってある:

- 持ち主はプログラマーではない → 平易な日本語で、操作は `.command` を案内する
- `_service()` が対話認証に落ちないのは**仕様**（直そうとすると常駐がハングする）
- `notifier` の週次/日次の独立実行とリトライを「簡潔に」まとめない（事故の再発）
- 終日予定の `end` は Google が exclusive・内部は含む最終日（境界でだけ変換）
- ポートが応答する ≠ 自分のが動いている／plist には絶対パスが焼かれている
- `python -m src.main` を手で起動しない（LaunchAgent と衝突）
- `schedule.db` を安易に消さない（通知済みフラグ）
- 仕様として正しい挙動（0件の日は送らない・1日1回まで・Google の未確認警告）

`.claude/settings.json` の deny は **file ツールを守るだけで、`cat` 等のシェル経由は塞げない**。
あくまで補助で、実効的な歯止めは `CLAUDE.md` の指示側にある。そのことも `CLAUDE.md` に明記した。

`CLAUDE.md` に書いたコマンド（`python -m pytest` / `-m ruff` / `-m mypy` /
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

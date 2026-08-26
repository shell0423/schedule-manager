# AI秘書（スケジュール管理）— Claude Code 向け運用メモ

このフォルダで動く AI が毎セッション読む前提の文書。**利用者は AI に詳しい**ので、
噛み砕きより密度を優先してよい。回りくどい確認や `.command` への誘導は不要で、
必要なら直接コマンドを叩いて構わない（`.command` は中身が `scripts/*.sh` の薄い入口）。

人間向けの丁寧な導入は `0_START_HERE.html`。アカウント作成（LINE / Google Cloud /
Gemini / ngrok）の画面手順だけはあちらが正本。

**「動かない」と言われたら `使えないケース.md` を先に読む。** 障害の切り分け（届かない /
入らない / 通知だけ来ない）と、そもそも仕様上できないこと（過去の予定の変更、60日より先の
日付なし指定、テキスト以外の無視など）が一覧してある。**バグ扱いで調査を始める前に確認する。**

---

## アーキテクチャ

```
LINE Messaging API
  └ webhook → ngrok(固定ドメイン) → 127.0.0.1:5555 Flask   src/main.py
                                      ├ 自由文解析 (Gemini)  src/parser.py
                                      ├ Calendar CRUD        src/calendar_client.py
                                      ├ 署名検証/reply/push  src/line_client.py
                                      └ 通知の重複防止(SQLite) src/db.py
LaunchAgent 毎朝08:00 → src/notifier.py → LINE Push
```

- 常駐は LaunchAgent 3点: `com.ai-hisho.{webhook,ngrok,notifier}`（`~/Library/LaunchAgents/`）
- plist は同梱せず `scripts/make_plists.py` が**設置場所に合わせて生成**する。
  `3_start.command` が毎回作り直すので、フォルダを移動したらそれを実行すればよい
- Python は 3.9〜3.13 で動く（macOS 標準の 3.9.6 で全テストが通ることを確認済み）。
  `1_setup` は 3.11〜3.13 を優先し、venv 作成と pip 起動に成功するまで候補を降りる

---

## セットアップを AI が代行する場合

利用者から「セットアップして」と言われたときの分担。

**AI がやれること**
- `./1_setup.command`（対話。値を持っていれば AI が流し込んでもよい）
- `.env` の各値の書き込み。キーは `LINE_CHANNEL_ACCESS_TOKEN` / `LINE_CHANNEL_SECRET` /
  `GEMINI_API_KEY` / `NGROK_DOMAIN` / `NGROK_AUTHTOKEN`（`env.example.txt` に全量）
- `./3_start.command` 以降（LINE 側の Webhook URL 登録まで自動）
- `./status.command` で 8 項目の診断

**人間にしかできないこと（先に依頼する）**
- LINE Developers でのチャネル作成と鍵の取得、**「応答メッセージ」をオフにする設定**
- Google Cloud の OAuth 同意画面設定と `credentials.json` のダウンロード配置
- **`2_google_auth.command` のブラウザ同意**（OAuth の画面クリックは代行不可）
- ngrok アカウント作成と固定ドメイン取得
- LINE 公式アカウントを友だち追加して1通送る（`4_set_user_id` がログから userId を拾う）

順序は `1_setup` → `credentials.json` 配置 → `2_google_auth` → `3_start` →
LINE で1通 → `4_set_user_id`。

---

## 運用

```bash
./status.command                  # まずこれ。設定/鍵/常駐/疎通/LINE側/定時実行を上から診断
./3_start.command                 # 起動・再起動（コードや .env を変えたら必ずこれ）
./stop.command                    # 一時停止（登録は残る）
./test_notify.command             # 朝の通知を即実行

tail -f logs/webhook.err.log      # 本体のログはこちら（webhook.log はほぼ空）
tail -f logs/notifier.err.log     # 朝の通知
tail -f logs/ngrok.log            # 外部疎通
launchctl list | grep ai-hisho
```

`3_start.command` は unload → plist 再生成 → load → localhost 疎通 → 外部疎通 →
LINE の webhook endpoint 登録/検証まで一通りやる。**手で `launchctl` を叩くより速い。**

---

## 意図的にそうなっている箇所（「直す」と壊れる）

コードを読むと不自然に見えるが、いずれも事故を踏んで入れたもの。変更するなら理由ごと。

**`calendar_client._service()` が対話認証にフォールバックしない**
`AuthRequiredError` を投げて即死する。ブラウザの無い LaunchAgent 配下で
`InstalledAppFlow.run_local_server()` に入ると**無言で永久にハングする**ため。
対話認証の入口は `python -m src.calendar_client`（= `2_google_auth.command`）だけ。
`allow_interactive=True` はそこからしか渡らない。

**`notifier._run_with_retry()` が週次と日次を別々に呼ぶ**
以前は `main()` が両方を素直に呼んでおり、起床直後の DNS 断で週次が例外を上げると
日次まで巻き添えで実行されず、その日の通知が全部消えた（2026-08-17 に実際に発生）。
一時的な通信断（`OSError` 系 / `httplib2.ServerNotFoundError` / `TransportError`）は
30秒×5回リトライし、`RefreshError` のような恒久的失敗は即諦める。
`httplib2.ServerNotFoundError` は `OSError` 系ではないので個別に列挙が要る。

**終日予定の end**
Google API の終日 `end` は **exclusive**（最終日の翌日）。このコードは内部で常に
「**含む最終日**」を持ち、`calendar_client._apply_period` と `main._handle_update` の
2箇所でだけ変換する。ここを触ったら `tests/test_calendar_client.py` を必ず回すこと。

**`parser.parse_message()` が dict を確認してから返す**
`response.text` は `str | None`。また `response_mime_type=application/json` でも
配列が返ることがあり、そのままだと呼び出し側の `.get()` が `AttributeError` になって
利用者には原因不明の「エラーが発生しました」だけが届く。

### 送信者チェック（第三者による書き込みの防止）

LINE 公式アカウントの ID を知られると誰でも友だち追加できる。`_is_authorized()`
（`src/main.py`）で `LINE_USER_ID` と一致しない送信者を無視しており、これが無いと
**第三者があなたのカレンダーを作成・変更・削除できる**。返信もしない（存在を知らせない・
返信トークンを消費しない）が、設定ミスで自分が弾かれたときに気づけるよう userId はログに残す。

`LINE_USER_ID` が**未設定のうちは通す**。初回セットアップは「1通送る→ログの userId を
`4_set_user_id` が拾う」流れなので、ここで弾くと1通目が処理されず手順が回らない。
その代わり `status` が未設定を「誰でも操作できる状態」として警告する。

**`status` がポート応答だけで OK を出さない**
別プロセスが 5555 を掴んでいても `/healthz` は返る。LaunchAgent の稼働と併せて判定する。
`3_start` は起動前に衝突を検出して止まる。

---

## 環境固有の罠

- **plist に絶対パスが焼かれる。** フォルダを移動/リネームすると launchd は古い場所を見に行き
  **黙って失敗する**。`status` が `WorkingDirectory` と現在地を比較して検出する。直すのは `3_start`。
  plist を手で編集しない（生成物なので次回上書きされる）。
- **`ngrok config add-authtoken` はユーザー共通設定**（`~/Library/Application Support/ngrok/`）を
  書き換える。この Mac で別の ngrok を使っているなら影響する。
- **ngrok 無料枠は同時1セッション。** `ERR_NGROK_108` は多重起動。
- **Gatekeeper**: 配布 ZIP は隔離属性付き。`1_setup` が `xattr -dr` と `chmod +x` を
  フォルダ全体にかけるので、最初の1本さえ通れば以降は素通り。
- **Homebrew の Python 3.14 系は `ensurepip` を欠き venv を作れないことがある**（実機で遭遇）。
  バージョン選択を「新しい順」に単純化しないこと。
- **スリープ中の webhook は取りこぼす。** LINE は再送しないので、その間のメッセージは消える。
  朝8時の通知は復帰時に launchd がまとめて実行するので比較的残る。

---

## コードを変更するとき

```bash
.venv/bin/python -m pip install -r requirements-dev.txt   # 初回のみ
.venv/bin/python -m pytest -q        # 53件
.venv/bin/python -m ruff check src tests
.venv/bin/python -m mypy src         # strict。エラー0が現状
./3_start.command                    # 反映
```

- `src/` と `tests/` は**配布元の Mac 版・Windows 版と共有**しているコード。ここを変えると
  配布元から更新が来たとき衝突する。恒久的な修正なら配布元に還元するのが筋。
- mypy strict でエラー0を維持している。google 系ライブラリは型が無いので、
  戻り値は中間変数に注釈を付けて `no-any-return` を抑えている（既存の書き方に倣う）。
- 日付・終日・繰り返し・月指定の分岐は `tests/test_calendar_client.py` と
  `tests/test_notifier.py` が守っている。ここを削らない。

---

## 秘密の扱い

- `.env` / `token.json` / `credentials.json` に生の鍵が入っている。**内容を出力しない**
  （チャット・ログ・コミットいずれも）。値の確認が要るなら `status.command` の出力を使う
  （先頭6文字に伏せてある）。
- `.claude/settings.json` でこの3ファイルの `Read` を deny してある。ただしこれは
  **file ツールだけを塞ぐもので、`cat` 等のシェル経由は素通りする**。実効的な歯止めは
  この文書側にある。邪魔なら消してよいが、消した事実を利用者に伝えること。
- `.env` は 600。`token.json` も `2_google_auth` が 600 にする。

---

## 仕様（バグではない）

- その日の予定が0件なら朝の通知を**送らない**
- 朝の通知は**1日1回**まで（`schedule.db` の `notification_log` で抑止）。
  再テストしたいなら該当行を消す。DB ごと消すと過去の抑止記録も飛ぶ
- Google 認証が切れると LINE に「⚠️ カレンダーに接続できません」を**1日1回**送る
  （黙って止まらないため）。復旧は `2_google_auth.command`
- OAuth 同意画面の「確認されていません」警告は自作アプリなので正常
- `token.json` の期限は1時間だが `refresh_token` で自動更新される。
  期限切れ表示だけを見て消さない。壊れているのは `invalid_grant` のとき

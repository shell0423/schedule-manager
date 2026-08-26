# status.bat の本体。今どこまで動いているかを上から順に確認する。
# 調子が悪いときは、この出力をそのまま渡してもらえば原因が絞れる。

. (Join-Path $PSScriptRoot "common.ps1")

Write-Host ""
Write-Host "==================================================" -ForegroundColor Cyan
Write-Host "  AI秘書 状態チェック" -ForegroundColor Cyan
Write-Host "==================================================" -ForegroundColor Cyan

$envMap = Read-EnvFile
$domain = ""
if ($envMap.Contains("NGROK_DOMAIN")) { $domain = $envMap["NGROK_DOMAIN"] }
$port = 5555
if ($envMap.Contains("WEBHOOK_PORT") -and $envMap["WEBHOOK_PORT"] -ne "") { $port = [int]$envMap["WEBHOOK_PORT"] }

Write-Step "1. 設定ファイル"
foreach ($k in @("LINE_CHANNEL_ACCESS_TOKEN", "LINE_CHANNEL_SECRET", "GEMINI_API_KEY", "NGROK_DOMAIN")) {
    if ($envMap.Contains($k) -and $envMap[$k] -ne "") { Write-Ok "$k 設定済み" } else { Write-Err2 "$k が空 → 1_setup.bat" }
}
if ($envMap.Contains("LINE_USER_ID") -and $envMap["LINE_USER_ID"] -ne "") {
    Write-Ok "LINE_USER_ID 設定済み（朝の通知が届く／本人以外からの操作を拒否）"
} else {
    Write-Err2 "LINE_USER_ID が空です。4_set_user_id.bat で設定してください"
    Write-Host "      ・朝の通知が届きません" -ForegroundColor Yellow
    Write-Host "      ・さらに、この状態では【誰でも】あなたのカレンダーを操作できます。" -ForegroundColor Yellow
    Write-Host "        LINE公式アカウントのIDを知って友だち追加した人が、予定を" -ForegroundColor Yellow
    Write-Host "        追加・変更・削除できてしまいます。設定すると本人以外は無視されます。" -ForegroundColor Yellow
}
if (Test-Path (Join-Path $Root "token.json")) { Write-Ok "Google 許可済み（token.json）" } else { Write-Err2 "token.json なし → 2_google_auth.bat" }

Write-Step "2. Gemini API キー（実際に問い合わせて確認）"
$gem = Test-GeminiKey
if ($gem.ok) {
    Write-Ok "使えます"
} else {
    Write-Err2 "使えません: $($gem.detail)"
    Show-GeminiKeyHelp
}

Write-Step "3. 動いているプロセス"
$procs = @(Get-OurProcesses)
$hasPy = @($procs | Where-Object { $_.Name -eq 'python.exe' }).Count
$hasNg = @($procs | Where-Object { $_.Name -eq 'ngrok.exe' }).Count
if ($hasPy -gt 0) { Write-Ok "Webhook サーバー（python）: 動作中" } else { Write-Err2 "Webhook サーバーが止まっています → 3_start.bat" }
if ($hasNg -gt 0) { Write-Ok "ngrok: 動作中" } else { Write-Err2 "ngrok が止まっています → 3_start.bat" }

Write-Step "4. このPCの中から繋がるか"
if (Test-WebhookAlive -Port $port) {
    Write-Ok "http://127.0.0.1:$port/healthz → ok"
} else {
    Write-Err2 "繋がりません。logs\webhook.log を確認"
}

Write-Step "5. インターネットから繋がるか"
if ($domain -eq "") {
    Write-Err2 "NGROK_DOMAIN が未設定"
} else {
    try {
        $r = Invoke-WebRequest -Uri "https://$domain/healthz" -TimeoutSec 10 -UseBasicParsing
        if ($r.StatusCode -eq 200) { Write-Ok "https://$domain/healthz → ok" } else { Write-Err2 "応答 $($r.StatusCode)" }
    } catch {
        Write-Err2 "繋がりません: $($_.Exception.Message)"
        Write-Info "logs\ngrok.log を確認"
    }
}

Write-Step "6. LINE 側の設定"
if ($envMap.Contains("LINE_CHANNEL_ACCESS_TOKEN") -and $envMap["LINE_CHANNEL_ACCESS_TOKEN"] -ne "") {
    try {
        $headers = @{ "Authorization" = "Bearer " + $envMap["LINE_CHANNEL_ACCESS_TOKEN"] }
        $cur = Invoke-RestMethod -Method Get -Uri "https://api.line.me/v2/bot/channel/webhook/endpoint" -Headers $headers -TimeoutSec 15
        Write-Info "登録先: $($cur.endpoint)"
        if ($cur.endpoint -eq "https://$domain/webhook/line") { Write-Ok "URL は合っています" } else { Write-Err2 "URL がずれています → 3_start.bat で登録し直す" }
        if ($cur.active) { Write-Ok "Webhook の利用: オン" } else { Write-Err2 "Webhook の利用: オフ → LINE Developers の Messaging API タブでオンにする" }
    } catch {
        Write-Err2 "LINE に問い合わせできません: $($_.Exception.Message)"
    }
}

Write-Step "7. 毎朝8時の通知（タスクスケジューラ）"
try {
    $t = Get-ScheduledTask -TaskName "AI-Hisho-DailyNotify" -ErrorAction Stop
    $info = Get-ScheduledTaskInfo -TaskName "AI-Hisho-DailyNotify"
    Write-Ok "登録済み（状態: $($t.State)）"
    Write-Info "前回: $($info.LastRunTime)  結果コード: $($info.LastTaskResult)  次回: $($info.NextRunTime)"
} catch {
    Write-Err2 "未登録 → 3_start.bat"
}

Write-Step "8. 最近のログ（webhook.log の末尾10行）"
$log = Join-Path $Root "logs\webhook.log"
if (Test-Path $log) {
    Get-Content $log -Tail 10 -Encoding UTF8 -ErrorAction SilentlyContinue | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
} else {
    Write-Info "まだログがありません"
}

Write-Host ""
Write-Host "==================================================" -ForegroundColor Cyan
Write-Host "  【失敗】が出た項目の指示に従ってください。" -ForegroundColor Cyan
Write-Host "==================================================" -ForegroundColor Cyan
Write-Host ""

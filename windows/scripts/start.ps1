# 3_start.bat の本体。常駐を開始し、Windows 起動時の自動起動と毎朝8時の通知も登録する。
# 何度実行してもよい（いったん止めてから起動し直す）。

. (Join-Path $PSScriptRoot "common.ps1")

$Hidden      = Join-Path $PSScriptRoot "hidden.vbs"
$WebhookBat  = Join-Path $PSScriptRoot "run_webhook.bat"
$NgrokBat    = Join-Path $PSScriptRoot "run_ngrok.bat"
$NotifierBat = Join-Path $PSScriptRoot "run_notifier.bat"
$TaskName    = "AI-Hisho-DailyNotify"

Write-Host ""
Write-Host "==================================================" -ForegroundColor Cyan
Write-Host "  AI秘書 起動と自動起動の登録 (3/3)" -ForegroundColor Cyan
Write-Host "==================================================" -ForegroundColor Cyan

# ---------------------------------------------------------------- 事前チェック
Write-Step "準備ができているか確認しています"
$ng = $false
if (-not (Get-VenvPython)) { Write-Err2 "実行環境がありません → 先に 1_setup.bat"; $ng = $true }
if (-not (Test-Path (Join-Path $Root "token.json"))) { Write-Err2 "Google の許可がまだです → 先に 2_google_auth.bat"; $ng = $true }
$envMap = Read-EnvFile
foreach ($k in @("LINE_CHANNEL_ACCESS_TOKEN", "LINE_CHANNEL_SECRET", "GEMINI_API_KEY", "NGROK_DOMAIN")) {
    if (-not $envMap.Contains($k) -or $envMap[$k] -eq "") { Write-Err2 "$k が未設定です → 1_setup.bat をもう一度"; $ng = $true }
}
if ($ng) { Write-Host ""; exit 1 }
Write-Ok "OK"

$domain = $envMap["NGROK_DOMAIN"]
$port = 5555
if ($envMap.Contains("WEBHOOK_PORT") -and $envMap["WEBHOOK_PORT"] -ne "") { $port = [int]$envMap["WEBHOOK_PORT"] }

# ---------------------------------------------------------------- 既存を停止
Write-Step "動いているものをいったん止めます"
$procs = @(Get-OurProcesses)
foreach ($p in $procs) { try { Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue } catch {} }
if ($procs.Count -gt 0) { Write-Info "$($procs.Count) 個のプロセスを停止しました" }
Start-Sleep -Seconds 2

# ---------------------------------------------------------------- 自動起動の登録
Write-Step "Windows 起動時に自動で立ち上がるよう登録しています"
$startup = [Environment]::GetFolderPath('Startup')
$ws = New-Object -ComObject WScript.Shell
foreach ($item in @(
    @{ name = "AI-Hisho Webhook.lnk"; bat = $WebhookBat },
    @{ name = "AI-Hisho Ngrok.lnk";   bat = $NgrokBat }
)) {
    $lnk = $ws.CreateShortcut((Join-Path $startup $item.name))
    $lnk.TargetPath = "wscript.exe"
    $lnk.Arguments = '"' + $Hidden + '" "' + $item.bat + '"'
    $lnk.WorkingDirectory = $Root
    $lnk.Description = "AI秘書（スケジュール管理ボット）"
    $lnk.Save()
}
Write-Ok "スタートアップに登録しました"
Write-Info "解除したいときは uninstall.bat"

Write-Step "毎朝 8:00 の通知を登録しています"
try {
    $action = New-ScheduledTaskAction -Execute "wscript.exe" `
        -Argument ('"' + $Hidden + '" "' + $NotifierBat + '"') -WorkingDirectory $Root
    $trigger = New-ScheduledTaskTrigger -Daily -At "08:00"
    # StartWhenAvailable: PCがスリープ/電源オフで8時を過ぎても、起きたときにまとめて実行する
    $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 10)
    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger `
        -Settings $settings -Description "AI秘書 朝の予定通知" -Force | Out-Null
    Write-Ok "タスクスケジューラに登録しました（$TaskName）"
} catch {
    Write-Warn2 "自動登録に失敗しました: $($_.Exception.Message)"
    Write-Info "朝の通知だけ動きません。登録・変更・削除・一覧は問題なく使えます。"
}

# ---------------------------------------------------------------- 起動
Write-Step "起動しています"
Start-Process -FilePath "wscript.exe" -ArgumentList ('"' + $Hidden + '"'), ('"' + $WebhookBat + '"') -WindowStyle Hidden
Start-Process -FilePath "wscript.exe" -ArgumentList ('"' + $Hidden + '"'), ('"' + $NgrokBat + '"')   -WindowStyle Hidden

Write-Info "立ち上がるまで待っています..."
$alive = $false
for ($i = 0; $i -lt 20; $i++) {
    Start-Sleep -Seconds 2
    if (Test-WebhookAlive -Port $port) { $alive = $true; break }
}
if ($alive) {
    Write-Ok "このPCの中では動いています (http://127.0.0.1:$port/healthz)"
} else {
    Write-Err2 "起動できませんでした。logs\webhook.log の最後のほうを見てください。"
    Write-Host ""
    Write-Host "  --- logs\webhook.log の末尾 ---" -ForegroundColor DarkGray
    Get-Content (Join-Path $Root "logs\webhook.log") -Tail 20 -ErrorAction SilentlyContinue
    exit 1
}

Write-Info "外（インターネット）から届くか確認しています..."
$outside = $false
for ($i = 0; $i -lt 15; $i++) {
    Start-Sleep -Seconds 2
    try {
        $r = Invoke-WebRequest -Uri "https://$domain/healthz" -TimeoutSec 8 -UseBasicParsing
        if ($r.StatusCode -eq 200) { $outside = $true; break }
    } catch {}
}
if ($outside) {
    Write-Ok "外からも届きます (https://$domain/healthz)"
} else {
    Write-Err2 "外から届きません。logs\ngrok.log を見てください。"
    Write-Host ""
    Write-Host "  --- logs\ngrok.log の末尾 ---" -ForegroundColor DarkGray
    Get-Content (Join-Path $Root "logs\ngrok.log") -Tail 20 -ErrorAction SilentlyContinue
    Write-Host ""
    Write-Warn2 "よくある原因: NGROK_DOMAIN の綴り違い / ngrok Authtoken 未設定 → 1_setup.bat をやり直す"
    exit 1
}

# ---------------------------------------------------------------- LINE 側の設定
Write-Step "LINE に「ここに送って」と伝えています"
$endpoint = "https://$domain/webhook/line"
$headers = @{ "Authorization" = "Bearer " + $envMap["LINE_CHANNEL_ACCESS_TOKEN"]; "Content-Type" = "application/json" }
try {
    $body = (@{ endpoint = $endpoint } | ConvertTo-Json -Compress)
    Invoke-RestMethod -Method Put -Uri "https://api.line.me/v2/bot/channel/webhook/endpoint" `
        -Headers $headers -Body $body -TimeoutSec 15 | Out-Null
    Write-Ok "Webhook URL を登録しました: $endpoint"

    $cur = Invoke-RestMethod -Method Get -Uri "https://api.line.me/v2/bot/channel/webhook/endpoint" `
        -Headers $headers -TimeoutSec 15
    if ($cur.active) {
        Write-Ok "LINE 側の Webhook はオンです"
    } else {
        Write-Warn2 "LINE 側の『Webhookの利用』がオフです。ここだけ手作業が要ります:"
        Write-Host "      LINE Developers > チャネル > Messaging API タブ" -ForegroundColor Yellow
        Write-Host "      > Webhook settings > 【Use webhook】をオンにする" -ForegroundColor Yellow
    }
    $test = Invoke-RestMethod -Method Post -Uri "https://api.line.me/v2/bot/channel/webhook/test" `
        -Headers $headers -Body $body -TimeoutSec 20
    if ($test.success) { Write-Ok "LINE からの疎通テスト成功" } else { Write-Warn2 "疎通テスト: $($test.reason)" }
} catch {
    Write-Warn2 "自動登録できませんでした: $($_.Exception.Message)"
    Write-Host "      LINE Developers の Messaging API タブで、Webhook URL に" -ForegroundColor Yellow
    Write-Host "      $endpoint" -ForegroundColor Yellow
    Write-Host "      を手で貼り付け、【Use webhook】をオンにしてください。" -ForegroundColor Yellow
}

# ---------------------------------------------------------------- 仕上げ
Write-Host ""
Write-Host "==================================================" -ForegroundColor Green
Write-Host "  起動しました" -ForegroundColor Green
Write-Host "==================================================" -ForegroundColor Green
Write-Host ""
Write-Host "  LINE で AI秘書 に「明日10時にテスト」と送ってみてください。" -ForegroundColor White
Write-Host ""
if ($envMap["LINE_USER_ID"] -eq "") {
    Write-Host "  1通送ったあと 4_set_user_id.bat を実行すると、" -ForegroundColor White
    Write-Host "  毎朝8時の通知も届くようになります。" -ForegroundColor White
    Write-Host ""
}
Write-Host "  状態を見る : status.bat" -ForegroundColor Gray
Write-Host "  止める     : stop.bat" -ForegroundColor Gray
Write-Host ""

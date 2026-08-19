# 4_set_user_id.bat の本体。
# 朝の通知の宛先（LINE_USER_ID）は、自分がボットに1通送ったログからしか分からない。
# その1通分のログを拾って .env に書き込み、Webhook を読み込み直させる。

. (Join-Path $PSScriptRoot "common.ps1")

Write-Host ""
Write-Host "==================================================" -ForegroundColor Cyan
Write-Host "  朝の通知の宛先を設定します" -ForegroundColor Cyan
Write-Host "==================================================" -ForegroundColor Cyan

$log = Join-Path $Root "logs\webhook.log"
if (-not (Test-Path $log)) {
    Write-Err2 "ログがまだありません。先に 3_start.bat で起動してください。"
    exit 1
}

$found = $null
foreach ($line in [System.IO.File]::ReadAllLines($log)) {
    $m = [regex]::Match($line, 'userId=(U[0-9a-f]{32})')
    if ($m.Success) { $found = $m.Groups[1].Value }   # 最後に見つかったものを採用
}

if (-not $found) {
    Write-Err2 "まだ誰からもメッセージが届いていません。"
    Write-Host ""
    Write-Host "  スマホの LINE で AI秘書 に何か1通（例:「テスト」）送ってから、" -ForegroundColor Yellow
    Write-Host "  10秒ほど待って、この 4_set_user_id.bat をもう一度実行してください。" -ForegroundColor Yellow
    Write-Host ""
    exit 1
}

$envMap = Read-EnvFile
$before = ""
if ($envMap.Contains("LINE_USER_ID")) { $before = $envMap["LINE_USER_ID"] }
$envMap["LINE_USER_ID"] = $found
Write-EnvFile $envMap
Write-Ok "宛先を設定しました: $($found.Substring(0,8))...（.env の LINE_USER_ID）"

if ($before -ne "" -and $before -ne $found) {
    Write-Info "前の設定 $($before.Substring(0,8))... から変更しました"
}

# python だけ落とせば run_webhook.bat のループが新しい .env で立ち上げ直す
Write-Step "設定を反映させています"
$killed = 0
foreach ($p in @(Get-OurProcesses)) {
    if ($p.Name -eq 'python.exe') {
        try { Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue; $killed++ } catch {}
    }
}
if ($killed -eq 0) {
    Write-Warn2 "常駐が動いていないようです。3_start.bat を実行してください。"
    exit 0
}

Write-Info "再起動を待っています（15秒ほど）..."
$port = 5555
if ($envMap.Contains("WEBHOOK_PORT") -and $envMap["WEBHOOK_PORT"] -ne "") { $port = [int]$envMap["WEBHOOK_PORT"] }
$alive = $false
for ($i = 0; $i -lt 15; $i++) {
    Start-Sleep -Seconds 2
    if (Test-WebhookAlive -Port $port) { $alive = $true; break }
}
Write-Host ""
if ($alive) {
    Write-Ok "反映しました"
    Write-Host ""
    Write-Host "  今すぐ通知を試すなら test_notify.bat をダブルクリック。" -ForegroundColor White
    Write-Host "  以後は毎朝 8:00 に自動で届きます。" -ForegroundColor White
} else {
    Write-Warn2 "再起動を確認できませんでした。status.bat で様子を見てください。"
}
Write-Host ""

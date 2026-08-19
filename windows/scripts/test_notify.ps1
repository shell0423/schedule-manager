# test_notify.bat の本体。毎朝8時に流れるのと同じ通知を、今すぐ1回だけ送る。
# 「明日の朝まで待たずに確かめたい」ときに使う。

. (Join-Path $PSScriptRoot "common.ps1")

Write-Host ""
Write-Host "==================================================" -ForegroundColor Cyan
Write-Host "  朝の通知を今すぐ試す" -ForegroundColor Cyan
Write-Host "==================================================" -ForegroundColor Cyan

$venvPy = Get-VenvPython
if (-not $venvPy) { Write-Err2 "先に 1_setup.bat を実行してください。"; exit 1 }

$envMap = Read-EnvFile
if (-not $envMap.Contains("LINE_USER_ID") -or $envMap["LINE_USER_ID"] -eq "") {
    Write-Err2 "宛先（LINE_USER_ID）が未設定です。"
    Write-Host "    LINE で AI秘書 に1通送ってから 4_set_user_id.bat を実行してください。" -ForegroundColor Yellow
    exit 1
}

Write-Info "送信しています..."
Push-Location $Root
$env:PYTHONUTF8 = "1"
$env:PYTHONIOENCODING = "utf-8"
& $venvPy -m src.notifier
$code = $LASTEXITCODE
Pop-Location

Write-Host ""
if ($code -eq 0) {
    Write-Ok "実行しました。LINE を確認してください。"
    Write-Host ""
    Write-Host "  ※ 今日の予定が1件も無い日は、あえて何も送りません（仕様）。" -ForegroundColor DarkGray
    Write-Host "  ※ 1日1回までしか送りません。もう一度試したいときは、" -ForegroundColor DarkGray
    Write-Host "     カレンダーに予定を入れてから明日試すか、schedule.db を消してください。" -ForegroundColor DarkGray
} else {
    Write-Err2 "失敗しました（コード $code）。上のメッセージを確認してください。"
}
Write-Host ""

# uninstall.bat の本体。常駐を止め、自動起動とタスクの登録を消す。
# フォルダの中身（.env・token.json・ログ）は消さない。3_start.bat でいつでも戻せる。

. (Join-Path $PSScriptRoot "common.ps1")

Write-Host ""
Write-Host "==================================================" -ForegroundColor Cyan
Write-Host "  AI秘書 自動起動の解除" -ForegroundColor Cyan
Write-Host "==================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "  次のことをします:" -ForegroundColor White
Write-Host "    ・動いている AI秘書 を止める"
Write-Host "    ・Windows 起動時の自動起動を解除する"
Write-Host "    ・毎朝8時の通知タスクを削除する"
Write-Host ""
Write-Host "  設定ファイル(.env)・Google の許可(token.json)・ログは残します。" -ForegroundColor DarkGray
Write-Host "  3_start.bat を実行すればいつでも元に戻せます。" -ForegroundColor DarkGray
Write-Host ""
$ans = Read-Host "  進めますか？ (y/n)"
if ($ans -ne "y" -and $ans -ne "Y") { Write-Host "  中止しました。"; exit 0 }

Write-Step "止めています"
$procs = @(Get-OurProcesses)
foreach ($name in @('wscript.exe', 'cmd.exe', 'python.exe', 'ngrok.exe')) {
    foreach ($p in ($procs | Where-Object { $_.Name -eq $name })) {
        try { Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue } catch {}
    }
    Start-Sleep -Milliseconds 300
}
Write-Ok "停止しました"

Write-Step "スタートアップの登録を消しています"
$startup = [Environment]::GetFolderPath('Startup')
foreach ($n in @("AI-Hisho Webhook.lnk", "AI-Hisho Ngrok.lnk")) {
    $p = Join-Path $startup $n
    if (Test-Path $p) { Remove-Item $p -Force; Write-Ok "削除: $n" }
}

Write-Step "毎朝8時のタスクを消しています"
try {
    Unregister-ScheduledTask -TaskName "AI-Hisho-DailyNotify" -Confirm:$false -ErrorAction Stop
    Write-Ok "削除しました"
} catch {
    Write-Info "登録されていませんでした"
}

Write-Host ""
Write-Host "==================================================" -ForegroundColor Green
Write-Host "  解除しました。" -ForegroundColor Green
Write-Host "==================================================" -ForegroundColor Green
Write-Host ""
Write-Host "  完全に消したい場合は、この後さらに:" -ForegroundColor Gray
Write-Host "    ・このフォルダごとゴミ箱へ" -ForegroundColor Gray
Write-Host "    ・LINE Developers でチャネルを削除" -ForegroundColor Gray
Write-Host "    ・Google AI Studio で Gemini API キーを削除" -ForegroundColor Gray
Write-Host "    ・ngrok ダッシュボードでドメインを削除" -ForegroundColor Gray
Write-Host ""

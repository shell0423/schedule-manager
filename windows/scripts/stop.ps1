# stop.bat の本体。常駐を止める。自動起動の登録はそのまま残るので、
# 次に Windows を起動したらまた立ち上がる（完全にやめるなら uninstall.bat）。

. (Join-Path $PSScriptRoot "common.ps1")

Write-Host ""
Write-Host "==================================================" -ForegroundColor Cyan
Write-Host "  AI秘書 停止" -ForegroundColor Cyan
Write-Host "==================================================" -ForegroundColor Cyan

# 再起動ループ（cmd.exe / wscript.exe）を先に止めないと、
# python や ngrok を落としてもすぐ生き返ってしまう。
$procs = @(Get-OurProcesses)
$order = @('wscript.exe', 'cmd.exe', 'python.exe', 'ngrok.exe')
$count = 0
foreach ($name in $order) {
    foreach ($p in ($procs | Where-Object { $_.Name -eq $name })) {
        try { Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue; $count++ } catch {}
    }
    Start-Sleep -Milliseconds 300
}

Start-Sleep -Seconds 2
$left = @(Get-OurProcesses)
Write-Host ""
if ($left.Count -eq 0) {
    Write-Ok "止めました（$count 個）"
} else {
    Write-Warn2 "$($left.Count) 個が残っています。もう一度 stop.bat を実行してください。"
    foreach ($p in $left) { Write-Info "$($p.Name) (PID $($p.ProcessId))" }
}
Write-Host ""
Write-Host "  もう一度動かす : 3_start.bat" -ForegroundColor Gray
Write-Host "  完全にやめる   : uninstall.bat" -ForegroundColor Gray
Write-Host ""

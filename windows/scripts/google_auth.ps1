# 2_google_auth.bat の本体。ブラウザで Google の許可を取り token.json を作る。
# token.json ができれば、以後この操作は不要（失効したときだけやり直す）。

. (Join-Path $PSScriptRoot "common.ps1")

Write-Host ""
Write-Host "==================================================" -ForegroundColor Cyan
Write-Host "  Google カレンダーの利用許可 (2/3)" -ForegroundColor Cyan
Write-Host "==================================================" -ForegroundColor Cyan

$venvPy = Get-VenvPython
if (-not $venvPy) { Write-Err2 "先に 1_setup.bat を実行してください。"; exit 1 }

$cred = Join-Path $Root "credentials.json"
if (-not (Test-Path $cred)) {
    Write-Err2 "credentials.json がありません。"
    Write-Host "    ガイド STEP 2 でダウンロードした JSON を credentials.json という名前で" -ForegroundColor Yellow
    Write-Host "    次の場所に置いてから、もう一度実行してください:" -ForegroundColor Yellow
    Write-Host "      $Root\credentials.json" -ForegroundColor Yellow
    exit 1
}

$token = Join-Path $Root "token.json"
if (Test-Path $token) {
    Write-Info "すでに許可済みです（token.json あり）。"
    $ans = Read-Host "  取り直しますか？ 普通は n でOK (y/n)"
    if ($ans -ne "y" -and $ans -ne "Y") {
        Write-Ok "そのまま使います。次は 3_start.bat"
        exit 0
    }
    Remove-Item $token -Force
}

Write-Host ""
Write-Host "  これからブラウザが開きます。次の順に進めてください:" -ForegroundColor White
Write-Host "    1. 自分の Google アカウントを選ぶ"
Write-Host "    2.『このアプリは Google で確認されていません』と出たら"
Write-Host "       → 左下【詳細】→【（アプリ名）に移動】をクリック"
Write-Host "    3.『カレンダーの予定の表示と編集』にチェック →【続行】"
Write-Host ""
Write-Host "  ※ 自分で作ったアプリなので、この警告が出るのが正常です。" -ForegroundColor DarkGray
Write-Host ""
Read-Host "  準備ができたら Enter"

Push-Location $Root
$env:PYTHONUTF8 = "1"
& $venvPy -m src.calendar_client
$code = $LASTEXITCODE
Pop-Location

Write-Host ""
if ($code -eq 0 -and (Test-Path $token)) {
    Write-Ok "許可が取れました（token.json を作成）"
    Write-Host ""
    Write-Host "  2/3 完了。次は 3_start.bat をダブルクリック" -ForegroundColor Green
} else {
    Write-Err2 "許可に失敗しました。"
    Write-Host "    よくある原因:" -ForegroundColor Yellow
    Write-Host "      ・Google Cloud で Calendar API を有効にしていない（ガイド STEP 2-2）"
    Write-Host "      ・OAuth の公開ステータスが【テスト】のまま（ガイド STEP 2-3）"
    Write-Host "      ・ダウンロードした JSON が『デスクトップアプリ』用でない"
}

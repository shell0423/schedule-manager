# 共通ヘルパー。各 *.ps1 から . (ドットソース) で読み込む。
# Windows PowerShell 5.1 互換で書くこと（?? 演算子・三項演算子は使わない）。

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}
# 古い既定のままだと LINE / ngrok / Google への HTTPS が TLS1.0 で弾かれることがある
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}

# scripts\ の親 = プロジェクトルート
$Root = Split-Path -Parent $PSScriptRoot

function Write-Step($msg)  { Write-Host ""; Write-Host "== $msg" -ForegroundColor Cyan }
function Write-Ok($msg)    { Write-Host "  OK   $msg" -ForegroundColor Green }
function Write-Info($msg)  { Write-Host "       $msg" -ForegroundColor Gray }
function Write-Warn2($msg) { Write-Host "  注意 $msg" -ForegroundColor Yellow }
function Write-Err2($msg)  { Write-Host "  失敗 $msg" -ForegroundColor Red }

function Get-EnvPath { return (Join-Path $Root ".env") }

function Read-EnvFile {
    <#
      .env を読んで順序つき辞書で返す。無ければ空の辞書。
      値に = が含まれても壊れないよう最初の = だけで分割する。
    #>
    $map = [ordered]@{}
    $path = Get-EnvPath
    if (-not (Test-Path $path)) { return $map }
    foreach ($line in [System.IO.File]::ReadAllLines($path)) {
        $t = $line.Trim()
        if ($t -eq "" -or $t.StartsWith("#")) { continue }
        $i = $t.IndexOf("=")
        if ($i -lt 1) { continue }
        $map[$t.Substring(0, $i).Trim()] = $t.Substring($i + 1).Trim()
    }
    return $map
}

function Write-EnvFile($map) {
    <#
      辞書を .env に書き出す。
      BOM を付けると python-dotenv が最初のキー名を読み違えるので UTF8Encoding($false) 固定。
    #>
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine("# AI秘書 設定ファイル。他人に見せないこと。")
    foreach ($k in $map.Keys) { [void]$sb.AppendLine("$k=$($map[$k])") }
    $enc = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText((Get-EnvPath), $sb.ToString(), $enc)
}

function Get-EnvValue($key) {
    $map = Read-EnvFile
    if ($map.Contains($key)) { return $map[$key] }
    return ""
}

function Get-VenvPython {
    $p = Join-Path $Root ".venv\Scripts\python.exe"
    if (Test-Path $p) { return $p }
    return $null
}

function Get-NgrokExe {
    # 同梱 bin\ を優先し、無ければ PATH を探す
    $local = Join-Path $Root "bin\ngrok.exe"
    if (Test-Path $local) { return $local }
    $cmd = Get-Command ngrok.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return $null
}

function Get-OurProcesses {
    <#
      このフォルダから起動された python / ngrok / それを回している cmd を列挙する。

      注意: *.bat をダブルクリックすると cmd.exe が起動し、そのコマンドラインには
      "C:\ai-hisho\stop.bat" のように $Root が含まれる。素朴に絞り込むと
      「今このスクリプトを動かしている cmd.exe」まで対象に入り、自分で自分を
      殺してウィンドウごと消える。なので $PID から親をたどった一連を除外する。
    #>
    $all = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue)

    $parentOf = @{}
    foreach ($p in $all) { $parentOf[[int]$p.ProcessId] = [int]$p.ParentProcessId }
    $skip = New-Object 'System.Collections.Generic.HashSet[int]'
    $cur = $PID
    for ($i = 0; $i -lt 20; $i++) {
        if (-not $skip.Add($cur)) { break }          # 循環していたら打ち切り
        if (-not $parentOf.ContainsKey($cur)) { break }
        $cur = $parentOf[$cur]
        if ($cur -le 0) { break }
    }

    # -like は [ ] をワイルドカード扱いするので、素直に部分一致で見る
    return $all | Where-Object {
        -not $skip.Contains([int]$_.ProcessId) -and
        $null -ne $_.CommandLine -and
        $_.CommandLine.Contains($Root) -and
        ($_.Name -eq 'python.exe' -or $_.Name -eq 'ngrok.exe' -or $_.Name -eq 'cmd.exe' -or $_.Name -eq 'wscript.exe')
    }
}

function Test-GeminiKey {
    <#
      Gemini API キーで実際に1回だけ問い合わせて、使えるかを確かめる。
      戻り値: @{ ok = $true/$false; detail = "理由" }
      鍵は環境変数で渡す（コマンドライン引数だとプロセス一覧に出てしまう）。
    #>
    $venvPy = Get-VenvPython
    if (-not $venvPy) { return @{ ok = $false; detail = "実行環境がありません（先に 1_setup.bat）" } }
    $map = Read-EnvFile
    $key = ""
    if ($map.Contains("GEMINI_API_KEY")) { $key = $map["GEMINI_API_KEY"] }
    if ($key -eq "") { return @{ ok = $false; detail = "鍵が未設定です" } }

    $model = "gemini-2.5-flash"
    if ($map.Contains("GEMINI_MODEL") -and $map["GEMINI_MODEL"] -ne "") { $model = $map["GEMINI_MODEL"] }

    $script = Join-Path $PSScriptRoot "check_gemini.py"
    $env:GEMINI_API_KEY = $key
    $env:GEMINI_MODEL = $model
    $env:PYTHONUTF8 = "1"
    try {
        $out = (& $venvPy $script 2>&1 | Out-String)
    } catch {
        $out = "GEMINI_NG $($_.Exception.Message)"
    } finally {
        $env:GEMINI_API_KEY = ""
    }
    if ($out -match "GEMINI_OK") { return @{ ok = $true; detail = "" } }
    return @{ ok = $false; detail = ($out -replace "GEMINI_NG\s*", "").Trim() }
}

function Show-GeminiKeyHelp {
    <# Gemini キーが通らないときの案内。AQ. 形式のキー問題への対処を含む。 #>
    Write-Host "    考えられる原因と対処:" -ForegroundColor Yellow
    Write-Host "      ・キーの貼り付けミス（途中で切れている）→ 1_setup.bat で入れ直す"
    Write-Host "      ・キーが AQ. で始まる新形式で、まだ対応していない環境がある"
    Write-Host "        → 従来形式(AIza...)の鍵を作り直すと通ることが多い:"
    Write-Host "           1. https://console.cloud.google.com/ を開く"
    Write-Host "           2. APIとサービス > ライブラリ > 'Generative Language API' を有効にする"
    Write-Host "           3. APIとサービス > 認証情報 > + 認証情報を作成 > APIキー"
    Write-Host "           4. 出てきた AIza... を 1_setup.bat で入れ直す"
    Write-Host "      ・無料枠を使い切っている（429 / RESOURCE_EXHAUSTED）→ 時間をおく"
}

function Test-WebhookAlive {
    param([int]$Port = 5555)
    try {
        $r = Invoke-WebRequest -Uri "http://127.0.0.1:$Port/healthz" -TimeoutSec 5 -UseBasicParsing
        return ($r.StatusCode -eq 200)
    } catch { return $false }
}

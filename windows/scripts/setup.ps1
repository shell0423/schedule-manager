# 1_setup.bat の本体。Python・依存パッケージ・ngrok・.env をまとめて用意する。
# 何度実行しても壊れない（冪等）。途中で失敗したら直してもう一度実行すればよい。

. (Join-Path $PSScriptRoot "common.ps1")

Write-Host ""
Write-Host "==================================================" -ForegroundColor Cyan
Write-Host "  AI秘書 セットアップ (1/3)" -ForegroundColor Cyan
Write-Host "==================================================" -ForegroundColor Cyan
Write-Host "  作業フォルダ: $Root"

# ---------------------------------------------------------------- Python
Write-Step "Python を探しています"

function Get-PythonCandidates {
    <#
      Python の候補を集める。PATH だけに頼らないのが要点。

      winget でインストールした直後は、PATH の更新が「いま開いているウィンドウ」に
      反映されないことがある（レジストリを読み直しても Get-Command が拾えない環境がある）。
      そのため既定のインストール先も直接ファイルとして探す。
    #>
    $list = @()

    # 1) PATH 上の py.exe / python.exe
    $py = Get-Command py.exe -ErrorAction SilentlyContinue
    if ($py) {
        foreach ($v in @('-3.12', '-3.11', '-3.13', '-3')) {
            $list += @{ exe = $py.Source; args = @($v) }
        }
    }
    $python = Get-Command python.exe -ErrorAction SilentlyContinue
    if ($python) { $list += @{ exe = $python.Source; args = @() } }

    # 2) 既定のインストール先を直接探す（新しいバージョンを優先）
    $roots = @(
        (Join-Path $env:LOCALAPPDATA 'Programs\Python'),
        'C:\Program Files',
        'C:\Program Files (x86)'
    )
    foreach ($root in $roots) {
        if (-not $root -or -not (Test-Path $root)) { continue }
        $dirs = @(Get-ChildItem -Path $root -Directory -Filter 'Python3*' -ErrorAction SilentlyContinue |
                  Sort-Object Name -Descending)
        foreach ($dir in $dirs) {
            $exe = Join-Path $dir.FullName 'python.exe'
            if (Test-Path $exe) { $list += @{ exe = $exe; args = @() } }
        }
    }

    # 3) py ランチャーの実体
    foreach ($p in @(
        (Join-Path $env:LOCALAPPDATA 'Programs\Python\Launcher\py.exe'),
        (Join-Path $env:WINDIR 'py.exe')
    )) {
        if ($p -and (Test-Path $p)) { $list += @{ exe = $p; args = @('-3') } }
    }

    return $list
}

function Find-Python {
    $probe = 'import sys;print("%d.%d" % sys.version_info[:2])'
    # 未インストールの py -3.x は標準エラーに書く。ErrorActionPreference=Stop のままだと
    # 2>$null との組み合わせで例外になり、後続の候補まで巻き添えで落ちるため緩める。
    $saved = $ErrorActionPreference
    $ErrorActionPreference = 'SilentlyContinue'
    try {
        foreach ($c in (Get-PythonCandidates)) {
            if (-not (Test-Path $c.exe)) { continue }
            $ver = $null
            $probeArgs = @($c.args) + @('-c', $probe)
            try { $ver = (& $c.exe $probeArgs 2>$null | Select-Object -First 1) } catch { continue }
            if (-not $ver) { continue }           # Microsoft Store のダミー python.exe は何も返さない
            $parts = "$ver".Trim().Split(".")
            if ($parts.Count -lt 2) { continue }
            $maj = 0; $min = 0
            if (-not [int]::TryParse($parts[0], [ref]$maj)) { continue }
            if (-not [int]::TryParse($parts[1], [ref]$min)) { continue }
            if ($maj -eq 3 -and $min -ge 10) {
                return @{ exe = $c.exe; args = $c.args; version = "$maj.$min" }
            }
        }
        return $null
    } finally { $ErrorActionPreference = $saved }
}

$py = Find-Python
$installed = $false
if (-not $py) {
    Write-Warn2 "Python 3.10 以上が見つかりませんでした。"
    if (Get-Command winget.exe -ErrorAction SilentlyContinue) {
        Write-Host ""
        $ans = Read-Host "  今すぐ自動でインストールしますか？ (y/n)"
        if ($ans -eq "y" -or $ans -eq "Y") {
            Write-Info "winget で Python 3.12 を入れています（数分かかります）..."
            # --scope user: 管理者権限なしで入る（既定のインストール先が決まるので後で探しやすい）
            & winget.exe install -e --id Python.Python.3.12 --scope user `
                --accept-package-agreements --accept-source-agreements
            $installed = $true
            # 入れた直後は今のウィンドウの PATH に反映されないので、レジストリから読み直す。
            # これでも拾えない環境があるため、Find-Python 側で既定の場所も直接探している。
            $machinePath = [Environment]::GetEnvironmentVariable("Path", "Machine")
            $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
            $env:Path = "$machinePath;$userPath"
            Write-Info "インストール後の再検出中..."
            $py = Find-Python
        }
    }
}
if (-not $py) {
    Write-Err2 "Python を用意できませんでした。"
    Write-Host ""
    if ($installed) {
        # winget は成功したのに見つからない = PATH がこのウィンドウに未反映
        Write-Host "  インストール自体は成功しています。" -ForegroundColor Yellow
        Write-Host "  【この黒い画面を閉じて、1_setup.bat をもう一度ダブルクリック】" -ForegroundColor Yellow
        Write-Host "  してください。新しいウィンドウなら見つかります。" -ForegroundColor Yellow
        Write-Host ""
        Write-Host "  それでも駄目なら、一度サインアウト→サインインしてから再実行してください。" -ForegroundColor Gray
    } else {
        Write-Host "  手動で入れてください:" -ForegroundColor Yellow
        Write-Host "    1. https://www.python.org/downloads/windows/ を開く"
        Write-Host "    2. 'Windows installer (64-bit)' をダウンロード"
        Write-Host "    3. インストーラ最初の画面で【Add python.exe to PATH】に必ずチェック"
        Write-Host "    4. 入れ終わったら 1_setup.bat をもう一度実行"
    }
    Write-Host ""
    exit 1
}
Write-Ok "Python $($py.version) を使います"

# ---------------------------------------------------------------- 仮想環境
Write-Step "専用の実行環境（.venv）を作っています"
$venvPy = Get-VenvPython
if (-not $venvPy) {
    $venvArgs = @($py.args) + @('-m', 'venv', (Join-Path $Root ".venv"))
    & $py.exe $venvArgs
    $venvPy = Get-VenvPython
}
if (-not $venvPy) { Write-Err2 ".venv の作成に失敗しました"; exit 1 }
Write-Ok ".venv を用意しました"

Write-Step "必要なパッケージを入れています（初回は数分かかります）"
& $venvPy -m pip install --upgrade pip --quiet --disable-pip-version-check
& $venvPy -m pip install -r (Join-Path $Root "requirements.txt") --disable-pip-version-check
if ($LASTEXITCODE -ne 0) { Write-Err2 "パッケージのインストールに失敗しました。ネット接続を確認してもう一度実行してください。"; exit 1 }
Write-Ok "パッケージのインストール完了"

# 日本時間の計算に必要（Windows には IANA タイムゾーンDBが無い）
& $venvPy -c "from zoneinfo import ZoneInfo; ZoneInfo('Asia/Tokyo')"
if ($LASTEXITCODE -ne 0) {
    Write-Err2 "タイムゾーンデータを読めません。'.venv\Scripts\python.exe -m pip install tzdata' を実行してください。"
    exit 1
}
Write-Ok "タイムゾーン（Asia/Tokyo）を確認"

New-Item -ItemType Directory -Force -Path (Join-Path $Root "logs") | Out-Null

# ---------------------------------------------------------------- ngrok
Write-Step "ngrok（外からこのPCに繋ぐ道具）を用意しています"
$ngrok = Get-NgrokExe
if (-not $ngrok) {
    $arch = $env:PROCESSOR_ARCHITECTURE
    if ($arch -eq "ARM64") {
        $url = "https://bin.equinox.io/c/bNyj1mQVY4c/ngrok-v3-stable-windows-arm64.zip"
    } else {
        $url = "https://bin.equinox.io/c/bNyj1mQVY4c/ngrok-v3-stable-windows-amd64.zip"
    }
    Write-Info "ダウンロード中: $url"
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $zip = Join-Path $env:TEMP "ngrok-ai-hisho.zip"
        Invoke-WebRequest -Uri $url -OutFile $zip -UseBasicParsing
        $bin = Join-Path $Root "bin"
        New-Item -ItemType Directory -Force -Path $bin | Out-Null
        Expand-Archive -Path $zip -DestinationPath $bin -Force
        Remove-Item $zip -Force -ErrorAction SilentlyContinue
        $ngrok = Get-NgrokExe
    } catch {
        Write-Warn2 "自動ダウンロードに失敗しました: $($_.Exception.Message)"
    }
}
if (-not $ngrok) {
    Write-Err2 "ngrok を用意できませんでした。"
    Write-Host "    https://ngrok.com/download から Windows 版 zip を落とし、" -ForegroundColor Yellow
    Write-Host "    中の ngrok.exe を次の場所に置いてから、もう一度実行してください:" -ForegroundColor Yellow
    Write-Host "      $Root\bin\ngrok.exe" -ForegroundColor Yellow
    exit 1
}
Write-Ok "ngrok: $ngrok"

# ---------------------------------------------------------------- 設定値
Write-Step "鍵と設定を入力します"
Write-Host "  ガイド（0_START_HERE.html）の STEP 1〜4 で控えた値を貼り付けてください。" -ForegroundColor Gray
Write-Host "  貼り付けは 右クリック または Ctrl+V。何も入れずに Enter で今の値のまま。" -ForegroundColor Gray

$envMap = Read-EnvFile
if ($envMap.Count -eq 0) {
    # 初回はひな形から起こす
    $tpl = Join-Path $Root "env.example.txt"
    if (Test-Path $tpl) { Copy-Item $tpl (Get-EnvPath) -Force }
    $envMap = Read-EnvFile
}

function Set-Default($map, $key, $value) {
    if (-not $map.Contains($key) -or $map[$key] -eq "") { $map[$key] = $value }
}
Set-Default $envMap "GEMINI_MODEL" "gemini-2.5-flash"
Set-Default $envMap "GOOGLE_CALENDAR_ID" "primary"
Set-Default $envMap "GOOGLE_CREDENTIALS_PATH" "credentials.json"
Set-Default $envMap "GOOGLE_TOKEN_PATH" "token.json"
Set-Default $envMap "WEBHOOK_HOST" "127.0.0.1"
Set-Default $envMap "WEBHOOK_PORT" "5555"
Set-Default $envMap "VERIFY_SIGNATURE" "true"
Set-Default $envMap "LINE_USER_ID" ""
# 必須キーは「空文字で存在する」状態にしておく。キー自体が無いと $envMap[$k] が
# $null になり、後段の「未入力チェック」($envMap[$k] -eq "") をすり抜けてしまう。
Set-Default $envMap "LINE_CHANNEL_ACCESS_TOKEN" ""
Set-Default $envMap "LINE_CHANNEL_SECRET" ""
Set-Default $envMap "GEMINI_API_KEY" ""
Set-Default $envMap "NGROK_DOMAIN" ""

function Read-Setting($map, $key, $label, $hint) {
    $cur = ""
    if ($map.Contains($key)) { $cur = $map[$key] }
    Write-Host ""
    Write-Host "  [$label]" -ForegroundColor White
    Write-Host "   $hint" -ForegroundColor DarkGray
    if ($cur -ne "") {
        $shown = $cur
        if ($shown.Length -gt 12) { $shown = $shown.Substring(0, 6) + "..." + $shown.Substring($shown.Length - 4) }
        Write-Host "   現在: $shown" -ForegroundColor DarkGray
    }
    $inp = Read-Host "   入力"
    if ($inp.Trim() -ne "") { $map[$key] = $inp.Trim() }
}

Read-Setting $envMap "LINE_CHANNEL_ACCESS_TOKEN" "メモの ①アクセストークン" `
    "LINE Developers > Messaging API設定タブ > チャネルアクセストークン（長期）"
Read-Setting $envMap "LINE_CHANNEL_SECRET" "メモの ②シークレット" `
    "LINE Developers > チャネル基本設定タブ > チャネルシークレット"
Read-Setting $envMap "GEMINI_API_KEY" "メモの ③Geminiキー" `
    "Google AI Studio で作った AIza... で始まる文字列"
Read-Setting $envMap "NGROK_DOMAIN" "メモの ④ドメイン" `
    "ngrok > Domains の xxxx-xxxx.ngrok-free.dev（https:// や / は付いたままでOK）"

# https:// や末尾の / を付けて貼られても直す
if ($envMap["NGROK_DOMAIN"] -ne "") {
    $d = $envMap["NGROK_DOMAIN"]
    $d = $d -replace '^https?://', ''
    $d = $d.TrimEnd('/')
    $envMap["NGROK_DOMAIN"] = $d
}

Write-EnvFile $envMap
Write-Ok ".env に保存しました"

# ---------------------------------------------------------------- Gemini 疎通
# ここで確かめておかないと、鍵の不備が「LINEに送っても『解析に失敗しました』としか
# 返らない」という分かりにくい形で最後に出てくる。
$geminiOk = $true
if ($envMap["GEMINI_API_KEY"] -eq "") {
    Write-Step "Gemini API キーの確認はとばします（未入力）"
    $geminiOk = $false
} else {
    Write-Step "Gemini API キーが本当に使えるか試しています"
    $res = Test-GeminiKey
    if ($res.ok) {
        Write-Ok "Gemini API キーは有効です"
    } else {
        $geminiOk = $false
        Write-Err2 "Gemini API キーで問い合わせできませんでした"
        Write-Host "    $($res.detail)" -ForegroundColor DarkGray
        Show-GeminiKeyHelp
    }
}

# ---------------------------------------------------------------- ngrok 認証
Write-Step "ngrok にログインします"
$needToken = $true
$ngrokCfg = Join-Path $env:LOCALAPPDATA "ngrok\ngrok.yml"
if (Test-Path $ngrokCfg) {
    if ((Get-Content $ngrokCfg -Raw) -match "authtoken") {
        Write-Ok "ngrok は設定済みです"
        Write-Host "   （入れ直したいときだけ入力。そのままでよければ Enter）" -ForegroundColor DarkGray
        $needToken = $false
    }
}
Write-Host ""
Write-Host "  [メモの ④Authtoken]" -ForegroundColor White
Write-Host "   ngrok ダッシュボード > Your Authtoken の文字列" -ForegroundColor DarkGray
$tok = Read-Host "   入力"
if ($tok.Trim() -ne "") {
    & $ngrok config add-authtoken $tok.Trim()
    if ($LASTEXITCODE -eq 0) { Write-Ok "ngrok にログインしました" } else { Write-Err2 "ngrok の認証に失敗しました" }
} elseif ($needToken) {
    Write-Warn2 "Authtoken 未設定のままです。ngrok が起動しない場合はもう一度 1_setup.bat を実行してください。"
}

# ---------------------------------------------------------------- 仕上げ確認
Write-Step "残りの確認"
$missing = @()
foreach ($k in @("LINE_CHANNEL_ACCESS_TOKEN", "LINE_CHANNEL_SECRET", "GEMINI_API_KEY", "NGROK_DOMAIN")) {
    if ($envMap[$k] -eq "") { $missing += $k }
}
if ($missing.Count -gt 0) {
    Write-Warn2 "まだ空の項目: $($missing -join ', ')  → 揃ったら 1_setup.bat をもう一度実行"
} else {
    Write-Ok "鍵はすべて入力済み"
}

$cred = Join-Path $Root "credentials.json"
if (Test-Path $cred) {
    Write-Ok "credentials.json あり"
} else {
    Write-Warn2 "credentials.json がありません"
    Write-Host "    ガイドの STEP 2 でダウンロードした Google の JSON ファイルを、" -ForegroundColor Yellow
    Write-Host "    名前を credentials.json に変えて次の場所に置いてください:" -ForegroundColor Yellow
    Write-Host "      $Root\credentials.json" -ForegroundColor Yellow
}

if (-not $geminiOk) {
    Write-Warn2 "Gemini API キーが未確認です（上の対処を見て 1_setup.bat をやり直してください）"
}

Write-Host ""
Write-Host "==================================================" -ForegroundColor Cyan
if ($missing.Count -eq 0 -and $geminiOk -and (Test-Path $cred)) {
    Write-Host "  1/3 完了。次は 2_google_auth.bat をダブルクリック" -ForegroundColor Green
} else {
    Write-Host "  上の【注意】【失敗】を解消してから、1_setup.bat をもう一度実行" -ForegroundColor Yellow
}
Write-Host "==================================================" -ForegroundColor Cyan

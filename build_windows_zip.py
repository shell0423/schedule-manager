"""Windows 配布用 ZIP（友人に渡す一式）を組み立てる。

使い方:
    .venv/bin/python build_windows_zip.py

出力: dist/ai-hisho.zip

やっていること:
  - src/ など共有コードと windows/ 配下のスクリプトを1つのフォルダにまとめる
  - .bat / .vbs は CRLF・ASCII（cmd.exe は非ASCIIの .bat を読み違える）
  - .ps1 は CRLF・UTF-8 **BOM付き**（Windows PowerShell 5.1 は BOM が無いと
    日本語を ANSI として読んで文字化けする）
  - .env や token.json など秘密が1つでも混入したら中止する
  - ZIP のルート直下にファイルを置く（「C:\\ai-hisho に展開」で正しい形になる）
"""
from __future__ import annotations

import shutil
import sys
import zipfile
from pathlib import Path

BASE_DIR = Path(__file__).resolve().parent
STAGE_DIR = BASE_DIR / "dist" / "ai-hisho"
ZIP_PATH = BASE_DIR / "dist" / "ai-hisho.zip"

# 共有コード: プロジェクト直下からそのまま入れるもの
SHARED_FILES = ["requirements.txt", "requirements-dev.txt", "pyproject.toml"]
SHARED_DIRS = ["src", "tests"]

# 絶対に入れてはいけないもの（存在チェックで二重に守る）
FORBIDDEN = {".env", "credentials.json", "token.json", "schedule.db"}

# .env のキーのうち、値が秘密でないもの（ひな形にも同じ値が載るので照合対象外）
NON_SECRET_KEYS = {
    "GEMINI_MODEL",
    "GOOGLE_CALENDAR_ID",
    "GOOGLE_CREDENTIALS_PATH",
    "GOOGLE_TOKEN_PATH",
    "WEBHOOK_HOST",
    "WEBHOOK_PORT",
    "VERIFY_SIGNATURE",
    "TZ",
}

CRLF_ASCII = {".bat", ".vbs"}
CRLF_BOM = {".ps1"}


def fail(msg: str) -> None:
    print(f"\n[中止] {msg}\n", file=sys.stderr)
    sys.exit(1)


def copy_tree(src: Path, dst: Path) -> None:
    """__pycache__ やキャッシュを除いてディレクトリをコピーする。"""
    shutil.copytree(
        src,
        dst,
        ignore=shutil.ignore_patterns(
            "__pycache__", "*.pyc", ".pytest_cache", ".mypy_cache", ".ruff_cache"
        ),
    )


def normalize_line_endings(root: Path) -> None:
    """Windows で確実に読める形に .bat / .vbs / .ps1 を書き直す。"""
    for path in sorted(root.rglob("*")):
        if not path.is_file():
            continue
        suffix = path.suffix.lower()
        if suffix not in CRLF_ASCII and suffix not in CRLF_BOM:
            continue
        text = path.read_text(encoding="utf-8")
        text = text.replace("\r\n", "\n").replace("\r", "\n").replace("\n", "\r\n")
        if suffix in CRLF_ASCII:
            if not text.isascii():
                offenders = sorted({c for c in text if not c.isascii()})
                fail(f"{path.name} に非ASCII文字があります: {''.join(offenders)}")
            path.write_bytes(text.encode("ascii"))
        else:
            path.write_bytes(b"\xef\xbb\xbf" + text.encode("utf-8"))


def assert_no_secrets(root: Path) -> None:
    """ファイル名と中身の両面から、秘密の混入をチェックする。"""
    for path in root.rglob("*"):
        if path.is_file() and path.name in FORBIDDEN:
            fail(f"秘密ファイルが混入しています: {path.relative_to(root)}")

    env_path = BASE_DIR / ".env"
    if not env_path.exists():
        return
    secrets: list[tuple[str, str]] = []
    for line in env_path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        key, value = key.strip(), value.strip()
        # 設定値（モデル名・パス等）は秘密でないので照合対象から外す
        if key in NON_SECRET_KEYS or len(value) < 12:
            continue
        secrets.append((key, value))

    for path in root.rglob("*"):
        if not path.is_file():
            continue
        try:
            content = path.read_text(encoding="utf-8", errors="ignore")
        except OSError:
            continue
        for key, value in secrets:
            if value in content:
                fail(f"{path.relative_to(root)} に {key} の値が含まれています")


def build() -> None:
    if STAGE_DIR.exists():
        shutil.rmtree(STAGE_DIR)
    STAGE_DIR.mkdir(parents=True)

    windows_dir = BASE_DIR / "windows"
    if not windows_dir.is_dir():
        fail("windows/ が見つかりません")

    # windows/ の中身をパッケージのルート直下へ（README.md は保守用なので除く）
    for item in sorted(windows_dir.iterdir()):
        if item.name == "README.md":
            continue
        if item.is_dir():
            copy_tree(item, STAGE_DIR / item.name)
        else:
            shutil.copy2(item, STAGE_DIR / item.name)

    for name in SHARED_DIRS:
        copy_tree(BASE_DIR / name, STAGE_DIR / name)
    for name in SHARED_FILES:
        shutil.copy2(BASE_DIR / name, STAGE_DIR / name)

    (STAGE_DIR / "logs").mkdir(exist_ok=True)
    (STAGE_DIR / "logs" / ".keep").write_text("", encoding="utf-8")

    normalize_line_endings(STAGE_DIR)
    assert_no_secrets(STAGE_DIR)

    ZIP_PATH.parent.mkdir(parents=True, exist_ok=True)
    if ZIP_PATH.exists():
        ZIP_PATH.unlink()
    with zipfile.ZipFile(ZIP_PATH, "w", zipfile.ZIP_DEFLATED) as zf:
        for path in sorted(STAGE_DIR.rglob("*")):
            if path.is_file():
                zf.write(path, path.relative_to(STAGE_DIR).as_posix())

    size_kb = ZIP_PATH.stat().st_size / 1024
    with zipfile.ZipFile(ZIP_PATH) as zf:
        count = len(zf.namelist())
    print(f"作成しました: {ZIP_PATH}")
    print(f"  {count} ファイル / {size_kb:.0f} KB")
    print(f"  展開用の中間フォルダ: {STAGE_DIR}")


if __name__ == "__main__":
    build()

"""macOS 配布用 ZIP（友人に渡す一式）を組み立てる。

使い方:
    .venv/bin/python build_mac_zip.py

出力: dist/ai-hisho-mac.zip

やっていること:
  - src/ など共有コードと mac/ 配下のスクリプトを1つのフォルダにまとめる
  - .sh / .command は **LF**（CR が混ざると shebang が壊れて起動しない）
  - .command / .sh に実行権(755)を立て、**ZIP に実行権ビットを保存する**
    （macOS の展開では権限が復元される。これが無いとダブルクリックできない）
  - .env や token.json など秘密が1つでも混入したら中止する
  - ZIP のルート直下にファイルを置く（展開してそのまま正しい形になる）

Windows 版（build_windows_zip.py）との違いは、改行コードと実行権の扱いだけ。
"""

from __future__ import annotations

import shutil
import stat
import sys
import zipfile
from pathlib import Path

BASE_DIR = Path(__file__).resolve().parent
STAGE_DIR = BASE_DIR / "dist" / "ai-hisho-mac"
ZIP_PATH = BASE_DIR / "dist" / "ai-hisho-mac.zip"

SHARED_FILES = ["requirements.txt", "requirements-dev.txt", "pyproject.toml"]
SHARED_DIRS = ["src", "tests"]
# OS 非依存の補助スクリプト。Windows 版と同じ shared/ から取る（二重管理しない）
SHARED_SCRIPTS = ["check_gemini.py"]

FORBIDDEN = {".env", "credentials.json", "token.json", "schedule.db"}

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

# 実行権を立てる拡張子（.command はダブルクリックの入口）
EXECUTABLE = {".sh", ".command"}


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


def normalize(root: Path) -> None:
    """.sh / .command を LF に揃え、実行権を立てる。"""
    for path in sorted(root.rglob("*")):
        if not path.is_file() or path.suffix.lower() not in EXECUTABLE:
            continue
        text = path.read_text(encoding="utf-8")
        if "\r" in text:
            text = text.replace("\r\n", "\n").replace("\r", "\n")
            path.write_text(text, encoding="utf-8")
        if not text.startswith("#!"):
            fail(f"{path.name} に shebang がありません（ダブルクリックで動きません）")
        path.chmod(0o755)


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

    mac_dir = BASE_DIR / "mac"
    if not mac_dir.is_dir():
        fail("mac/ が見つかりません")

    # mac/ の中身をパッケージのルート直下へ（README.md は保守用なので除く）
    for item in sorted(mac_dir.iterdir()):
        if item.name == "README.md":
            continue
        if item.is_dir():
            copy_tree(item, STAGE_DIR / item.name)
        else:
            shutil.copy2(item, STAGE_DIR / item.name)

    for name in SHARED_SCRIPTS:
        shutil.copy2(BASE_DIR / "shared" / name, STAGE_DIR / "scripts" / name)
    for name in SHARED_DIRS:
        copy_tree(BASE_DIR / name, STAGE_DIR / name)
    for name in SHARED_FILES:
        shutil.copy2(BASE_DIR / name, STAGE_DIR / name)

    (STAGE_DIR / "logs").mkdir(exist_ok=True)
    (STAGE_DIR / "logs" / ".keep").write_text("", encoding="utf-8")

    normalize(STAGE_DIR)
    assert_no_secrets(STAGE_DIR)

    ZIP_PATH.parent.mkdir(parents=True, exist_ok=True)
    if ZIP_PATH.exists():
        ZIP_PATH.unlink()
    with zipfile.ZipFile(ZIP_PATH, "w", zipfile.ZIP_DEFLATED) as zf:
        for path in sorted(STAGE_DIR.rglob("*")):
            if not path.is_file():
                continue
            arcname = path.relative_to(STAGE_DIR).as_posix()
            # ZipInfo を自分で作り、実行権を external_attr に載せる。
            # zf.write() 任せでも mode は入るが、明示して意図を残す。
            info = zipfile.ZipInfo.from_file(path, arcname)
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = (path.stat().st_mode & 0xFFFF) << 16
            zf.writestr(info, path.read_bytes())

    # 実行権が本当に載ったか、書いた ZIP を読み直して確かめる
    missing = []
    with zipfile.ZipFile(ZIP_PATH) as zf:
        for info in zf.infolist():
            if Path(info.filename).suffix.lower() in EXECUTABLE:
                mode = info.external_attr >> 16
                if not mode & stat.S_IXUSR:
                    missing.append(info.filename)
    if missing:
        fail(f"実行権が保存されていません: {missing}")

    size_kb = ZIP_PATH.stat().st_size / 1024
    with zipfile.ZipFile(ZIP_PATH) as zf:
        count = len(zf.namelist())
    print(f"作成しました: {ZIP_PATH}")
    print(f"  {count} ファイル / {size_kb:.0f} KB（実行権の保存を確認済み）")
    print(f"  展開用の中間フォルダ: {STAGE_DIR}")


if __name__ == "__main__":
    build()

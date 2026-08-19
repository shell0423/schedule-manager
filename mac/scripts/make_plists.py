"""LaunchAgent の plist 3点を、実際の設置場所に合わせて生成する。

3_start.command から呼ばれる。Windows 版と違い Mac では展開先が人によって違う
（ユーザー名も違う）ので、plist を同梱せずここで組み立てる。

XML の手組みは避けて plistlib を使う。展開先に空白や日本語、& が入っていても
正しくエスケープされるため（例: /Users/太郎/Desktop/AI秘書 & 予定/）。

環境変数で受け取る: AIH_ROOT / AIH_NGROK / AIH_PORT / AIH_DOMAIN
"""

from __future__ import annotations

import os
import plistlib
import sys
from pathlib import Path

LABEL_WEBHOOK = "com.ai-hisho.webhook"
LABEL_NGROK = "com.ai-hisho.ngrok"
LABEL_NOTIFIER = "com.ai-hisho.notifier"


def build(root: Path, ngrok: str, port: str, domain: str) -> dict[str, dict]:
    """ラベル → plist の内容 を返す。"""
    venv_py = str(root / ".venv" / "bin" / "python")
    logs = root / "logs"
    common_env = {
        # launchd は PATH をほとんど持たないので明示する
        "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin",
        "TZ": "Asia/Tokyo",
    }

    def base(label: str, args: list[str], log_name: str) -> dict:
        return {
            "Label": label,
            "ProgramArguments": args,
            "WorkingDirectory": str(root),
            "StandardOutPath": str(logs / f"{log_name}.log"),
            "StandardErrorPath": str(logs / f"{log_name}.err.log"),
            "EnvironmentVariables": dict(common_env),
        }

    webhook = base(LABEL_WEBHOOK, [venv_py, "-m", "src.main"], "webhook")
    webhook["RunAtLoad"] = True
    webhook["KeepAlive"] = True

    ngrok_args = [ngrok, "http", port, "--log=stdout"]
    if domain:
        ngrok_args.insert(3, f"--url={domain}")
    ng = base(LABEL_NGROK, ngrok_args, "ngrok")
    ng["RunAtLoad"] = True
    ng["KeepAlive"] = True

    notifier = base(LABEL_NOTIFIER, [venv_py, "-m", "src.notifier"], "notifier")
    # 毎朝 8:00。スリープで時刻を過ぎても、復帰時に launchd がまとめて実行する。
    notifier["StartCalendarInterval"] = {"Hour": 8, "Minute": 0}

    return {LABEL_WEBHOOK: webhook, LABEL_NGROK: ng, LABEL_NOTIFIER: notifier}


def main() -> int:
    root = Path(os.environ["AIH_ROOT"]).resolve()
    ngrok = os.environ.get("AIH_NGROK", "")
    port = os.environ.get("AIH_PORT", "5555") or "5555"
    domain = os.environ.get("AIH_DOMAIN", "")
    if not ngrok:
        print("AIH_NGROK が渡されていません", file=sys.stderr)
        return 1

    agent_dir = Path.home() / "Library" / "LaunchAgents"
    agent_dir.mkdir(parents=True, exist_ok=True)
    (root / "logs").mkdir(exist_ok=True)

    for label, data in build(root, ngrok, port, domain).items():
        path = agent_dir / f"{label}.plist"
        with path.open("wb") as f:
            plistlib.dump(data, f)
        print(str(path))
    return 0


if __name__ == "__main__":
    sys.exit(main())

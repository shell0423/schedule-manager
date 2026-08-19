"""Gemini API キーが実際に使えるかを1回だけ呼んで確かめる。

1_setup.bat / status.bat から呼ばれる。

ここで弾いておかないと、鍵の不備が「LINEに送っても『解析に失敗しました』としか
返ってこない」という原因の分かりにくい形で最後に出てくる。2026年に Google が
配り始めた `AQ.` 形式のキーが環境によって通らない件の検出も兼ねる。

鍵はコマンドライン引数ではなく環境変数で受け取る（プロセス一覧に出さないため）。
"""

from __future__ import annotations

import os
import sys


def main() -> int:
    """疎通できたら GEMINI_OK、駄目なら GEMINI_NG <理由> を1行で出す。"""
    key = os.environ.get("GEMINI_API_KEY", "")
    model = os.environ.get("GEMINI_MODEL", "gemini-2.5-flash")
    if not key:
        print("GEMINI_NG 鍵が設定されていません")
        return 1
    try:
        from google import genai
    except ImportError as exc:
        print(f"GEMINI_NG ライブラリを読み込めません: {exc}")
        return 1
    try:
        client = genai.Client(api_key=key)
        response = client.models.generate_content(model=model, contents="ping")
    except Exception as exc:  # SDK は多様な例外を投げるのでまとめて拾う
        print(f"GEMINI_NG {type(exc).__name__}: {str(exc)[:400]}")
        return 1
    if not (response.text or "").strip():
        print("GEMINI_NG 応答が空でした")
        return 1
    print("GEMINI_OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())

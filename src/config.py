"""環境変数・設定の読み込み。"""
from __future__ import annotations

import os
from pathlib import Path

from dotenv import load_dotenv

BASE_DIR = Path(__file__).resolve().parent.parent
load_dotenv(BASE_DIR / ".env")

LINE_CHANNEL_ACCESS_TOKEN: str = os.getenv("LINE_CHANNEL_ACCESS_TOKEN", "")
LINE_CHANNEL_SECRET: str = os.getenv("LINE_CHANNEL_SECRET", "")
LINE_USER_ID: str = os.getenv("LINE_USER_ID", "")

GEMINI_API_KEY: str = os.getenv("GEMINI_API_KEY", "")
GEMINI_MODEL: str = os.getenv("GEMINI_MODEL", "gemini-2.5-flash")

GOOGLE_CALENDAR_ID: str = os.getenv("GOOGLE_CALENDAR_ID", "primary")
GOOGLE_CREDENTIALS_PATH: Path = BASE_DIR / os.getenv(
    "GOOGLE_CREDENTIALS_PATH", "credentials.json"
)
GOOGLE_TOKEN_PATH: Path = BASE_DIR / os.getenv("GOOGLE_TOKEN_PATH", "token.json")

WEBHOOK_HOST: str = os.getenv("WEBHOOK_HOST", "0.0.0.0")
WEBHOOK_PORT: int = int(os.getenv("WEBHOOK_PORT", "5555"))
VERIFY_SIGNATURE: bool = os.getenv("VERIFY_SIGNATURE", "true").lower() == "true"

DB_PATH: Path = BASE_DIR / "schedule.db"
TZ: str = "Asia/Tokyo"

"""LINE Messaging API クライアント。"""

from __future__ import annotations

import base64
import hashlib
import hmac

import requests

from src.config import LINE_CHANNEL_ACCESS_TOKEN, LINE_CHANNEL_SECRET

PUSH_URL = "https://api.line.me/v2/bot/message/push"
REPLY_URL = "https://api.line.me/v2/bot/message/reply"


def verify_signature(body: bytes, signature: str) -> bool:
    """X-Line-Signature を検証する。"""
    if not signature or not LINE_CHANNEL_SECRET:
        return False
    mac = hmac.new(LINE_CHANNEL_SECRET.encode(), body, hashlib.sha256).digest()
    expected = base64.b64encode(mac).decode()
    return hmac.compare_digest(expected, signature)


def _headers() -> dict[str, str]:
    return {
        "Authorization": f"Bearer {LINE_CHANNEL_ACCESS_TOKEN}",
        "Content-Type": "application/json",
    }


def reply(reply_token: str, text: str) -> None:
    """リプライメッセージを送信する。"""
    payload = {
        "replyToken": reply_token,
        "messages": [{"type": "text", "text": text[:5000]}],
    }
    r = requests.post(REPLY_URL, headers=_headers(), json=payload, timeout=10)
    r.raise_for_status()


def push(user_id: str, text: str) -> None:
    """Push メッセージを送信する。"""
    payload = {"to": user_id, "messages": [{"type": "text", "text": text[:5000]}]}
    r = requests.post(PUSH_URL, headers=_headers(), json=payload, timeout=10)
    r.raise_for_status()

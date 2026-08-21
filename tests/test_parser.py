"""parser モジュールの単体テスト（Gemini API 呼び出しはスタブ）。"""

from __future__ import annotations

from typing import Any

import pytest

from src import parser


class _StubResponse:
    def __init__(self, text: str | None) -> None:
        self.text = text


class _StubModels:
    def __init__(self, text: str | None) -> None:
        self._text = text

    def generate_content(self, **_kwargs: Any) -> _StubResponse:
        return _StubResponse(self._text)


class _StubClient:
    def __init__(self, text: str | None) -> None:
        self.models = _StubModels(text)


def _with_response(monkeypatch: pytest.MonkeyPatch, text: str | None) -> None:
    monkeypatch.setattr(parser, "_get_client", lambda: _StubClient(text))


def test_valid_json_object_is_returned(monkeypatch: pytest.MonkeyPatch) -> None:
    _with_response(monkeypatch, '{"action": "create", "title": "歯医者"}')
    assert parser.parse_message("明日10時に歯医者") == {
        "action": "create",
        "title": "歯医者",
    }


def test_none_text_does_not_raise(monkeypatch: pytest.MonkeyPatch) -> None:
    """安全フィルタ等で text=None のとき、TypeError にせず unknown を返す。"""
    _with_response(monkeypatch, None)
    assert parser.parse_message("なにか") == {
        "action": "unknown",
        "message": "解析に失敗しました",
    }


def test_empty_text_does_not_raise(monkeypatch: pytest.MonkeyPatch) -> None:
    _with_response(monkeypatch, "")
    assert parser.parse_message("なにか")["action"] == "unknown"


def test_non_object_json_is_rejected(monkeypatch: pytest.MonkeyPatch) -> None:
    """配列が返っても呼び出し側の .get() が AttributeError にならない。"""
    _with_response(monkeypatch, '[{"action": "create"}]')
    result = parser.parse_message("なにか")
    assert result["action"] == "unknown"
    assert result.get("title") is None  # .get() が使えること


def test_broken_json_is_rejected(monkeypatch: pytest.MonkeyPatch) -> None:
    _with_response(monkeypatch, "{壊れた")
    assert parser.parse_message("なにか")["action"] == "unknown"


# --- 429 の案内文（2026-08-21 に実際に出た支出上限超過の再現）---


def _api_error(code: int, message: str) -> Exception:
    from google.genai import errors as genai_errors

    return genai_errors.ClientError(
        code,
        {"error": {"code": code, "message": message, "status": "RESOURCE_EXHAUSTED"}},
    )


class _RaisingModels:
    def __init__(self, exc: Exception) -> None:
        self._exc = exc

    def generate_content(self, **_kwargs: Any) -> Any:
        raise self._exc


class _RaisingClient:
    def __init__(self, exc: Exception) -> None:
        self.models = _RaisingModels(exc)


def test_spending_cap_gives_actionable_message(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """支出上限は待っても直らないので、上限ページへ誘導する。"""
    exc = _api_error(
        429,
        "Your project has exceeded its monthly spending cap. Please go to AI Studio "
        "at https://ai.studio/spend to manage your project spend cap.",
    )
    monkeypatch.setattr(parser, "_get_client", lambda: _RaisingClient(exc))
    msg = parser.parse_message("9/1 高額不動在庫処理")["message"]
    assert "支出上限" in msg
    assert "ai.studio/spend" in msg


def test_rate_limit_says_wait(monkeypatch: pytest.MonkeyPatch) -> None:
    """レート制限は時間をおけば回復するので、待つよう伝える。"""
    exc = _api_error(429, "Resource has been exhausted (e.g. check quota).")
    monkeypatch.setattr(parser, "_get_client", lambda: _RaisingClient(exc))
    msg = parser.parse_message("明日10時に歯医者")["message"]
    assert "時間をおいて" in msg
    assert "ai.studio/spend" not in msg


def test_other_errors_keep_generic_message(monkeypatch: pytest.MonkeyPatch) -> None:
    """429 以外は従来どおりの文言（誤誘導しない）。"""
    monkeypatch.setattr(
        parser, "_get_client", lambda: _RaisingClient(RuntimeError("boom"))
    )
    assert parser.parse_message("なにか")["message"] == "解析に失敗しました"

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

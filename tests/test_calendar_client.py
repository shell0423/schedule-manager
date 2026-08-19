"""calendar_client の start/end 組み立てロジックの単体テスト（API 呼び出しなし）。"""
from __future__ import annotations

from typing import Any

import pytest
from google.auth.exceptions import RefreshError

from src import calendar_client
from src.calendar_client import AuthRequiredError, _apply_period


def _timed_event() -> dict[str, Any]:
    return {
        "start": {"dateTime": "2026-12-04T13:30:00", "timeZone": "Asia/Tokyo"},
        "end": {"dateTime": "2026-12-04T14:30:00", "timeZone": "Asia/Tokyo"},
    }


def _all_day_event() -> dict[str, Any]:
    return {"start": {"date": "2026-08-11"}, "end": {"date": "2026-08-12"}}


def test_timed_to_all_day_multi_day() -> None:
    """時刻付き → 終日の期間予定（400 Bad Request の原因だったケース）。"""
    event = _timed_event()
    _apply_period(event, "2026-12-04", "2026-12-05", True)
    # end は exclusive なので最終日 +1 日
    assert event["start"] == {"date": "2026-12-04"}
    assert event["end"] == {"date": "2026-12-06"}
    # dateTime が残ると Google が 400 を返す
    assert "dateTime" not in event["start"]
    assert "dateTime" not in event["end"]


def test_all_day_inferred_from_date_only_value() -> None:
    """all_day フラグが false でも日付のみの値なら終日として扱う。"""
    event = _timed_event()
    _apply_period(event, "2026-12-04", "2026-12-05", False)
    assert event["start"] == {"date": "2026-12-04"}
    assert event["end"] == {"date": "2026-12-06"}


def test_timed_to_single_all_day() -> None:
    event = _timed_event()
    _apply_period(event, "2026-12-04", None, True)
    assert event["start"] == {"date": "2026-12-04"}
    assert event["end"] == {"date": "2026-12-05"}


def test_all_day_to_timed() -> None:
    """終日 → 時刻付き（逆方向）。date が残らないこと。"""
    event = _all_day_event()
    _apply_period(event, "2026-08-11T09:00:00", None, False)
    assert event["start"] == {"dateTime": "2026-08-11T09:00:00", "timeZone": "Asia/Tokyo"}
    assert event["end"] == {"dateTime": "2026-08-11T10:00:00", "timeZone": "Asia/Tokyo"}
    assert "date" not in event["start"]
    assert "date" not in event["end"]


def test_timed_start_only_fills_one_hour_end() -> None:
    event = _timed_event()
    _apply_period(event, "2026-12-04T19:00:00", None, False)
    assert event["start"]["dateTime"] == "2026-12-04T19:00:00"
    assert event["end"]["dateTime"] == "2026-12-04T20:00:00"


def test_all_day_end_only_extends_period() -> None:
    """終了日だけ指定（「8/13まで延長」）。開始日は既存イベントから引き継ぐ。"""
    event = _all_day_event()
    _apply_period(event, None, "2026-08-13", None)
    assert event["start"] == {"date": "2026-08-11"}
    assert event["end"] == {"date": "2026-08-14"}


def test_end_before_start_is_clamped() -> None:
    event = _timed_event()
    _apply_period(event, "2026-12-04", "2026-12-01", True)
    assert event["end"] == {"date": "2026-12-05"}


def test_no_period_fields_leaves_event_untouched() -> None:
    """タイトルだけ変更するケースで start/end を壊さない。"""
    event = _timed_event()
    _apply_period(event, None, None, False)
    assert event == _timed_event()


# --- 認証: 常駐プロセスがブラウザ待ちでハングしないこと ---


class _StubCreds:
    """期限切れで refresh を試みる認証情報のスタブ。"""

    def __init__(self, refresh_exc: Exception | None = None) -> None:
        self.valid = False
        self.expired = True
        self.refresh_token = "dummy-refresh-token"
        self._refresh_exc = refresh_exc

    def refresh(self, _request: Any) -> None:
        if self._refresh_exc:
            raise self._refresh_exc
        self.valid = True

    def to_json(self) -> str:
        return "{}"


@pytest.fixture(autouse=True)
def _forbid_interactive(monkeypatch: pytest.MonkeyPatch) -> None:
    """対話フローに入ったら即座にテストを失敗させる番人。

    ここが呼ばれること自体が「LaunchAgent 配下で無言ハングする」バグの再現。
    """

    def _boom(*_args: Any, **_kwargs: Any) -> None:
        raise AssertionError("対話認証フローに入った（常駐プロセスならハングする）")

    monkeypatch.setattr(
        calendar_client.InstalledAppFlow, "from_client_secrets_file", _boom
    )


def test_no_token_raises_instead_of_prompting(monkeypatch: pytest.MonkeyPatch) -> None:
    """token.json が無いとき、ブラウザを開かずに AuthRequiredError で落ちる。"""
    monkeypatch.setattr(calendar_client, "_load_creds", lambda: None)
    with pytest.raises(AuthRequiredError) as e:
        calendar_client._service()
    assert "再認証" in str(e.value)


def test_revoked_token_raises_instead_of_prompting(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """invalid_grant（失効・取り消し）でもブラウザを開かない。"""
    monkeypatch.setattr(
        calendar_client,
        "_load_creds",
        lambda: _StubCreds(RefreshError("invalid_grant: Token has been revoked")),
    )
    with pytest.raises(AuthRequiredError) as e:
        calendar_client._service()
    assert "invalid_grant" in str(e.value)


def test_network_error_on_refresh_is_not_auth_error(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """通信断は認証切れではないので AuthRequiredError にせず、そのまま上げる（notifier がリトライする）。"""
    from google.auth.exceptions import TransportError

    monkeypatch.setattr(
        calendar_client, "_load_creds", lambda: _StubCreds(TransportError("DNS down"))
    )
    with pytest.raises(TransportError):
        calendar_client._service()


def test_valid_token_builds_service(monkeypatch: pytest.MonkeyPatch) -> None:
    """有効なトークンならそのままサービスを組む（対話にもリフレッシュにも行かない）。"""
    creds = _StubCreds()
    creds.valid = True
    monkeypatch.setattr(calendar_client, "_load_creds", lambda: creds)
    monkeypatch.setattr(
        calendar_client, "build", lambda *a, **kw: "service"  # type: ignore[arg-type]
    )
    assert calendar_client._service() == "service"


def test_refresh_success_saves_token(monkeypatch: pytest.MonkeyPatch) -> None:
    """リフレッシュできたら token.json を保存する。"""
    saved = []
    monkeypatch.setattr(calendar_client, "_load_creds", lambda: _StubCreds())
    monkeypatch.setattr(calendar_client, "_save_creds", lambda c: saved.append(c))
    monkeypatch.setattr(
        calendar_client, "build", lambda *a, **kw: "service"  # type: ignore[arg-type]
    )
    assert calendar_client._service() == "service"
    assert len(saved) == 1


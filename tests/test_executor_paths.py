"""Coverage-completion tests for CodexAppServerExecutor.

The existing ``test_executor.py`` exercises ``_run_turn`` against a
fake AppServerProcess. This file completes the public surface:

  - ``execute()`` happy + every error-path branch
  - ``cancel()`` with no-active-turn / active-turn / interrupt-failure
  - ``shutdown()`` + ``_reset_app_server`` idempotency + close-failure
  - ``on_notification`` dispatch for the dotted ``turn.completed``
    form, ignored unknown methods
  - Bootstrap error paths: thread/start without id, turn/start without id
"""

from __future__ import annotations

import asyncio
import sys
from pathlib import Path
from typing import Any, List
from unittest.mock import MagicMock

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

pytest.importorskip("a2a.helpers")
pytest.importorskip("molecule_runtime.adapters.base")

from executor import CodexAppServerExecutor  # noqa: E402
from app_server import AppServerError  # noqa: E402
from molecule_runtime.adapters.base import AdapterConfig  # noqa: E402

# Reuse the FakeAppServer from the existing test file.
from tests.test_executor import FakeAppServer  # noqa: E402


class _CapturingQueue:
    def __init__(self) -> None:
        self.events: List[Any] = []

    async def enqueue_event(self, event: Any) -> None:
        self.events.append(event)


def _ctx(text: str, *, task_id: str = "task-A"):
    ctx = MagicMock()
    ctx.task_id = task_id
    text_part = MagicMock()
    text_part.text = text
    text_part.kind = "text"
    msg = MagicMock()
    msg.task_id = task_id
    msg.parts = [text_part]
    ctx.message = msg
    return ctx


def _make(fake: FakeAppServer) -> CodexAppServerExecutor:
    cfg = AdapterConfig(model="gpt-5", system_prompt="be terse")
    ex = CodexAppServerExecutor(cfg)
    ex._app_server = fake  # type: ignore[assignment]
    return ex


# ---- execute() ------------------------------------------------------


@pytest.mark.asyncio
async def test_execute_short_circuits_empty_prompt():
    fake = FakeAppServer()
    ex = _make(fake)
    queue = _CapturingQueue()
    await ex.execute(_ctx("   "), queue)
    assert len(queue.events) == 1
    assert "empty prompt" in repr(queue.events[0])
    # No turn/start should have been issued.
    assert not any(m == "turn/start" for m, _ in fake.requests)


@pytest.mark.asyncio
async def test_execute_happy_path_emits_assembled_text():
    fake = FakeAppServer()
    ex = _make(fake)
    queue = _CapturingQueue()

    async def driver():
        for _ in range(50):
            if any(m == "turn/start" for m, _ in fake.requests):
                break
            await asyncio.sleep(0.01)
        fake.push("agent_message_delta", {"delta": "answer"})
        fake.push("turn/completed", {"turnId": "tu_1"})

    await asyncio.gather(ex.execute(_ctx("question"), queue), driver())
    assert len(queue.events) == 1
    assert "answer" in repr(queue.events[0])


@pytest.mark.asyncio
async def test_execute_handles_app_server_error():
    fake = FakeAppServer()
    fake.turn_start_raises = AppServerError("upstream 503")
    ex = _make(fake)
    queue = _CapturingQueue()
    await ex.execute(_ctx("trigger error"), queue)
    assert len(queue.events) == 1
    assert "codex error" in repr(queue.events[0])
    assert "upstream 503" in repr(queue.events[0])


@pytest.mark.asyncio
async def test_execute_handles_turn_timeout(monkeypatch):
    """Squeeze the turn timeout to <1s so the test runs fast."""
    import executor as ex_mod
    monkeypatch.setattr(ex_mod, "_TURN_TIMEOUT", 0.3)

    fake = FakeAppServer()
    ex = _make(fake)
    queue = _CapturingQueue()

    # Drive thread/start + turn/start but never push completion.
    await ex.execute(_ctx("waits forever"), queue)

    assert len(queue.events) == 1
    assert "timed out" in repr(queue.events[0])


@pytest.mark.asyncio
async def test_execute_handles_connection_error_and_resets():
    """ConnectionError mid-turn should drop cached state so the next
    turn re-bootstraps."""
    fake = FakeAppServer()
    fake.turn_start_raises = ConnectionError("pipe closed")
    ex = _make(fake)
    queue = _CapturingQueue()
    await ex.execute(_ctx("hi"), queue)
    assert "codex unreachable" in repr(queue.events[0])
    # _reset_app_server zeroed the cached child + thread.
    assert ex._app_server is None
    assert ex._thread_id is None
    assert ex._current_turn_id is None


# ---- cancel() -------------------------------------------------------


@pytest.mark.asyncio
async def test_cancel_no_active_turn_is_noop():
    fake = FakeAppServer()
    ex = _make(fake)
    # No prior execute() — no turn id tracked.
    await ex.cancel(MagicMock(), _CapturingQueue())
    # Nothing posted, in particular no turn/interrupt.
    assert not any(m == "turn/interrupt" for m, _ in fake.requests)


@pytest.mark.asyncio
async def test_cancel_with_active_turn_fires_interrupt():
    fake = FakeAppServer()
    ex = _make(fake)
    ex._thread_id = "th_1"
    ex._current_turn_id = "tu_1"
    await ex.cancel(MagicMock(), _CapturingQueue())
    assert ("turn/interrupt", {"threadId": "th_1", "turnId": "tu_1"}) in fake.requests


@pytest.mark.asyncio
async def test_cancel_swallows_interrupt_errors():
    """If turn/interrupt raises (turn already done, server gone, etc.)
    cancel() must NOT propagate — A2A treats cancel as best-effort."""

    class FlakyFake(FakeAppServer):
        async def request(self, method, params=None, *, timeout=None):
            if method == "turn/interrupt":
                raise AppServerError("turn already complete")
            return await super().request(method, params, timeout=timeout)

    fake = FlakyFake()
    ex = _make(fake)
    ex._thread_id = "th_1"
    ex._current_turn_id = "tu_1"
    # Should not raise.
    await ex.cancel(MagicMock(), _CapturingQueue())


# ---- shutdown / reset ----------------------------------------------


@pytest.mark.asyncio
async def test_shutdown_closes_app_server():
    fake = FakeAppServer()
    ex = _make(fake)
    await ex.shutdown()
    assert fake.closed is True
    assert ex._app_server is None


@pytest.mark.asyncio
async def test_shutdown_idempotent():
    fake = FakeAppServer()
    ex = _make(fake)
    await ex.shutdown()
    await ex.shutdown()  # second call should be a no-op


@pytest.mark.asyncio
async def test_reset_swallows_close_errors():
    class ExplodingFake(FakeAppServer):
        async def close(self):
            raise RuntimeError("kaboom")

    ex = _make(ExplodingFake())
    # _reset_app_server logs but doesn't raise.
    await ex._reset_app_server()
    assert ex._app_server is None


# ---- on_notification edge cases ------------------------------------


@pytest.mark.asyncio
async def test_completed_dotted_form_also_completes_turn():
    """The schema spells it ``turn/completed`` but the running binary
    has been observed using ``turn.completed``. Both should work."""
    fake = FakeAppServer()
    ex = _make(fake)

    async def driver():
        for _ in range(50):
            if any(m == "turn/start" for m, _ in fake.requests):
                break
            await asyncio.sleep(0.01)
        fake.push("agent_message_delta", {"delta": "via dotted"})
        fake.push("turn.completed", {"id": "tu_1"})  # dotted, not slashed

    driver_task = asyncio.create_task(driver())
    text = await ex._run_turn("dotted")
    await driver_task
    assert text == "via dotted"


@pytest.mark.asyncio
async def test_codex072_snake_case_event_schema():
    """codex 0.72 emits snake_case event names: `agent_message`
    (whole reply, no streaming) + `task_complete` (instead of
    `turn/completed`). Both must produce a populated text result —
    pre-fix codex returned empty text because the executor only
    knew the older slash/dot schema. Caught live during 2026-05-03
    4-runtime A2A E2E."""
    fake = FakeAppServer()
    ex = _make(fake)

    async def driver():
        for _ in range(50):
            if any(m == "turn/start" for m, _ in fake.requests):
                break
            await asyncio.sleep(0.01)
        # Whole-message form (codex 0.72 when model didn't stream chunks)
        fake.push("agent_message", {"message": "snake_case ok"})
        fake.push("task_complete", {"task_id": "tu_1"})

    driver_task = asyncio.create_task(driver())
    text = await ex._run_turn("snake-case")
    await driver_task
    assert text == "snake_case ok"


@pytest.mark.asyncio
async def test_codex072_turn_aborted_surfaces_as_error():
    """`turn_aborted` (codex 0.72) and `stream_error` map to the
    same error path as the older `error_notification`."""
    fake = FakeAppServer()
    ex = _make(fake)

    async def driver():
        for _ in range(50):
            if any(m == "turn/start" for m, _ in fake.requests):
                break
            await asyncio.sleep(0.01)
        fake.push("turn_aborted", {"message": "user pressed Ctrl-C"})

    driver_task = asyncio.create_task(driver())
    with pytest.raises(RuntimeError, match="user pressed Ctrl-C"):
        await ex._run_turn("aborted")
    await driver_task


@pytest.mark.asyncio
async def test_unknown_notification_methods_are_logged_and_ignored(caplog):
    fake = FakeAppServer()
    ex = _make(fake)

    async def driver():
        for _ in range(50):
            if any(m == "turn/start" for m, _ in fake.requests):
                break
            await asyncio.sleep(0.01)
        fake.push("reasoning_delta", {"delta": "thinking..."})  # ignored
        fake.push("tool_exec_start", {"name": "shell"})  # ignored
        fake.push("agent_message_delta", {"delta": "ok"})
        fake.push("turn/completed", {"turnId": "tu_1"})

    driver_task = asyncio.create_task(driver())
    text = await ex._run_turn("test")
    await driver_task
    assert text == "ok"


# ---- bootstrap error paths -----------------------------------------


@pytest.mark.asyncio
async def test_thread_start_without_id_raises():
    fake = FakeAppServer()
    fake.thread_start_response = {"thread": {"unexpected": "shape"}}
    ex = _make(fake)
    with pytest.raises(RuntimeError, match="thread/start did not return an id"):
        await ex._ensure_thread()


@pytest.mark.asyncio
async def test_turn_start_without_id_raises():
    fake = FakeAppServer()
    # Standard thread/start, but turn/start returns junk.
    fake.turn_start_responses = [{"turn": {"unexpected": "shape"}}]
    ex = _make(fake)
    with pytest.raises(RuntimeError, match="turn/start did not return an id"):
        await ex._run_turn("hi")


@pytest.mark.asyncio
async def test_thread_start_accepts_legacy_threadId_field():
    """If codex starts emitting ``threadId`` instead of ``id``, we still
    pick it up. Documented in the executor source as a known shape drift."""
    fake = FakeAppServer()
    fake.thread_start_response = {"thread": {"threadId": "th_legacy"}}
    ex = _make(fake)
    tid = await ex._ensure_thread()
    assert tid == "th_legacy"


@pytest.mark.asyncio
async def test_turn_start_accepts_legacy_turnId_field():
    fake = FakeAppServer()
    fake.turn_start_responses = [{"turn": {"turnId": "tu_legacy"}}]
    ex = _make(fake)

    async def driver():
        for _ in range(50):
            if any(m == "turn/start" for m, _ in fake.requests):
                break
            await asyncio.sleep(0.01)
        fake.push("turn/completed", {"turnId": "tu_legacy"})

    driver_task = asyncio.create_task(driver())
    text = await ex._run_turn("legacy")
    await driver_task
    assert text == ""  # no deltas pushed

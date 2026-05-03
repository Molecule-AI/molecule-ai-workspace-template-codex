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
        fake.push_event("agent_message_delta", delta="answer")
        fake.push_event("task_complete", task_id="tu_1", last_agent_message="")

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
async def test_execute_wraps_runtimeerror_from_notification_path():
    """When codex emits an `error` notification mid-turn, `_run_turn`
    raises a RuntimeError. execute() should wrap it with the same
    `[codex error]` prefix the AppServerError path uses — without
    this wrap, a2a-sdk's top-level handler returns a bare JSON-RPC
    -32603, which surfaces in the canvas as a confusing protocol
    error rather than the actual upstream message.

    Captured live on staging 2026-05-03 against codex 0.72: a fake
    OPENAI_API_KEY produced `unexpected status 401 Unauthorized` from
    the codex HTTP client; pre-fix the canvas saw the raw JSON-RPC
    wrapper with the message buried in `error.message`."""
    fake = FakeAppServer()
    ex = _make(fake)
    queue = _CapturingQueue()

    async def driver():
        for _ in range(50):
            if any(m == "turn/start" for m, _ in fake.requests):
                break
            await asyncio.sleep(0.01)
        fake.push_event("error", message="unexpected status 401 Unauthorized")

    await asyncio.gather(ex.execute(_ctx("test 401"), queue), driver())
    assert len(queue.events) == 1
    text = repr(queue.events[0])
    assert "codex error" in text
    assert "401" in text


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
        fake.push_event("agent_message_delta", delta="via dotted")
        fake.push_event("task_complete", task_id="tu_1", last_agent_message="")  # dotted, not slashed

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
        fake.push_event("agent_message", message="snake_case ok")
        fake.push_event("task_complete", task_id="tu_1", last_agent_message="")

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
        fake.push("error", {"error": {"message": "user pressed Ctrl-C"}, "willRetry": False})

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
        fake.push_event("agent_reasoning_delta", delta="thinking...")  # ignored
        fake.push_event("exec_command_begin", command="shell")  # ignored
        fake.push_event("agent_message_delta", delta="ok")
        fake.push_event("task_complete", task_id="tu_1", last_agent_message="")

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
        fake.push_event("task_complete", task_id="tu_legacy", last_agent_message="")

    driver_task = asyncio.create_task(driver())
    text = await ex._run_turn("legacy")
    await driver_task
    assert text == ""  # no deltas pushed


# ---- turn/steer push parity (mid-turn steering) ----------------------


@pytest.mark.asyncio
async def test_execute_steers_when_turn_in_flight():
    """When a NEW message arrives while a turn is already in flight,
    execute() should fire `turn/steer` to inject the new prompt into
    the active turn instead of blocking on _turn_lock for the full
    prior-turn duration. Push parity with claude-code's
    `notifications/claude/channel` mid-session interrupt.
    """
    fake = FakeAppServer()
    ex = _make(fake)
    queue = _CapturingQueue()

    # Simulate "turn in flight": lock held + thread/turn ids set, as
    # they would be from a real concurrent _run_turn() invocation.
    ex._thread_id = "th_active"
    ex._current_turn_id = "tu_active"
    await ex._turn_lock.acquire()
    try:
        await ex.execute(_ctx("steered prompt"), queue)

        # turn/steer should be the only routed call (no turn/start).
        steer_calls = [
            (m, p) for m, p in fake.requests if m == "turn/steer"
        ]
        start_calls = [m for m, _ in fake.requests if m == "turn/start"]
        assert len(steer_calls) == 1, (
            f"expected exactly one turn/steer, got {fake.requests}"
        )
        assert not start_calls, (
            f"steer path must NOT also start a new turn, got {start_calls}"
        )

        method, params = steer_calls[0]
        assert params["threadId"] == "th_active"
        assert params["expectedTurnId"] == "tu_active"
        assert params["input"] == [
            {"type": "text", "text": "steered prompt"}
        ]

        # Placeholder delivered for the A2A response.
        assert len(queue.events) == 1
        assert "steered into in-flight turn" in repr(queue.events[0])
    finally:
        ex._turn_lock.release()


@pytest.mark.asyncio
async def test_execute_falls_through_when_no_active_turn():
    """Lock not held / no turn id → original path (turn/start). The
    steer branch is gated on (lock held AND turn id set) — partial
    state should fall through to the new-turn path so we don't fire
    a turn/steer against a non-existent turn id."""
    fake = FakeAppServer()
    ex = _make(fake)
    queue = _CapturingQueue()

    async def driver():
        for _ in range(50):
            if any(m == "turn/start" for m, _ in fake.requests):
                break
            await asyncio.sleep(0.01)
        fake.push_event("agent_message_delta", delta="ok")
        fake.push_event("task_complete", task_id="tu_1", last_agent_message="")

    await asyncio.gather(ex.execute(_ctx("hi"), queue), driver())

    # Confirms the steer branch did NOT fire when no turn was in flight.
    assert not any(m == "turn/steer" for m, _ in fake.requests)
    assert any(m == "turn/start" for m, _ in fake.requests)


@pytest.mark.asyncio
async def test_execute_falls_through_when_steer_raises_not_steerable():
    """`turn/steer` returns ActiveTurnNotSteerable for review/manual-
    compact turns OR if expectedTurnId mismatches (turn ended between
    our lock-check and the steer call). On either, fall through to
    the lock-and-wait path so the message still gets processed.
    """
    fake = FakeAppServer()
    fake.turn_steer_raises = AppServerError("ActiveTurnNotSteerable")
    ex = _make(fake)
    queue = _CapturingQueue()

    # Simulate active-turn state, but steer will raise.
    ex._thread_id = "th_active"
    ex._current_turn_id = "tu_active"
    await ex._turn_lock.acquire()
    # Release shortly so the fall-through path can acquire and proceed.
    async def releaser():
        await asyncio.sleep(0.05)
        ex._turn_lock.release()
    asyncio.create_task(releaser())

    async def driver():
        for _ in range(100):
            if any(m == "turn/start" for m, _ in fake.requests):
                break
            await asyncio.sleep(0.01)
        fake.push_event("agent_message_delta", delta="real reply")
        fake.push_event("task_complete", task_id="tu_2", last_agent_message="")

    await asyncio.gather(ex.execute(_ctx("retry"), queue), driver())

    # Steer was attempted and failed; turn/start fired as fall-through.
    assert any(m == "turn/steer" for m, _ in fake.requests)
    assert any(m == "turn/start" for m, _ in fake.requests)
    # The fall-through path delivered the real reply, not the placeholder.
    text = repr(queue.events[-1])
    assert "real reply" in text
    assert "steered into in-flight" not in text

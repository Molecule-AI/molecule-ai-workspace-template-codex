"""Coverage-completion tests for AppServerProcess.

The existing ``test_app_server.py`` covers happy paths against a mock
binary. This file fills the remaining branches:

  - ``unsubscribe`` happy + idempotent (double-call → silent no-op)
  - ``close()`` early-return for already-closed instance
  - ``request()`` rejects calls when ``_reader_exc`` is set
  - ``_dispatch`` ignores responses for unknown ids (late / dup)
  - ``_dispatch`` ignores unrecognized message shapes
  - Reader loop survives a non-JSON line + a notification subscriber
    that raises (must not crash the loop)
"""

from __future__ import annotations

import asyncio
import json
import sys
import textwrap
from pathlib import Path
from unittest.mock import MagicMock

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from app_server import AppServerError, AppServerProcess  # noqa: E402

_MOCK = str(Path(__file__).resolve().parent / "mock_app_server.py")


# ---- subscribe / unsubscribe ----------------------------------------


@pytest.mark.asyncio
async def test_unsubscribe_removes_callback():
    proc = await AppServerProcess.start(executable=sys.executable, args=(_MOCK,))
    try:
        await proc.initialize(client_info={"name": "test", "version": "0"})
        received = []
        unsub = proc.subscribe(lambda m, p: received.append(m))
        # First emit — callback fires.
        await proc.request("emit", {"count": 1, "method": "tick"})
        await asyncio.sleep(0.05)
        unsub()
        # After unsubscribe, the next emit should not reach our callback.
        await proc.request("emit", {"count": 1, "method": "tick"})
        await asyncio.sleep(0.05)
        assert received == ["tick"]
    finally:
        await proc.close()


@pytest.mark.asyncio
async def test_unsubscribe_is_idempotent():
    """Second call to the same unsubscribe must NOT raise — the
    closure swallows ValueError so callers can safely double-unsubscribe."""
    proc = await AppServerProcess.start(executable=sys.executable, args=(_MOCK,))
    try:
        unsub = proc.subscribe(lambda m, p: None)
        unsub()
        unsub()  # idempotent — no exception
    finally:
        await proc.close()


# ---- close() idempotency + already-closed return -------------------


@pytest.mark.asyncio
async def test_close_returns_returncode_when_already_closed():
    """close() called a second time must return the cached returncode
    rather than re-running the shutdown sequence."""
    proc = await AppServerProcess.start(executable=sys.executable, args=(_MOCK,))
    rc1 = await proc.close()
    rc2 = await proc.close()
    assert rc1 == rc2  # mock exits cleanly so both should be 0


# ---- request() rejects when reader has died -------------------------


@pytest.mark.asyncio
async def test_request_raises_when_reader_exc_set():
    """If the reader loop set ``_reader_exc`` (catastrophic stream
    failure), every subsequent request() must raise ConnectionError
    with the underlying cause chained."""
    proc = await AppServerProcess.start(executable=sys.executable, args=(_MOCK,))
    try:
        await proc.initialize(client_info={"name": "test", "version": "0"})
        proc._reader_exc = RuntimeError("simulated stream death")
        with pytest.raises(ConnectionError, match="reader failed"):
            await proc.request("echo", {"text": "x"})
    finally:
        proc._reader_exc = None  # let close() proceed normally
        await proc.close()


# ---- _dispatch edge cases -------------------------------------------


@pytest.mark.asyncio
async def test_dispatch_ignores_response_for_unknown_id():
    """A response for an id that's not in _pending must be silently
    dropped (logged at DEBUG, not an exception)."""
    proc = await AppServerProcess.start(executable=sys.executable, args=(_MOCK,))
    try:
        await proc.initialize(client_info={"name": "test", "version": "0"})
        # Direct dispatch with a stale response — should not raise.
        proc._dispatch({"jsonrpc": "2.0", "id": 99999, "result": {"x": 1}})
    finally:
        await proc.close()


@pytest.mark.asyncio
async def test_dispatch_ignores_response_for_already_done_future():
    """Same as above but for a completed future — set_result on a done
    future would raise InvalidStateError, so dispatch must check first."""
    proc = await AppServerProcess.start(executable=sys.executable, args=(_MOCK,))
    try:
        await proc.initialize(client_info={"name": "test", "version": "0"})
        loop = asyncio.get_running_loop()
        fut: asyncio.Future = loop.create_future()
        fut.set_result({"already": "resolved"})
        proc._pending[42] = fut
        # Dispatch a duplicate response — must not raise.
        proc._dispatch({"jsonrpc": "2.0", "id": 42, "result": {"new": "value"}})
        # And the future still has the original result.
        assert fut.result() == {"already": "resolved"}
    finally:
        proc._pending.clear()
        await proc.close()


@pytest.mark.asyncio
async def test_dispatch_ignores_unrecognized_shape():
    """A message with neither 'id'+result/error nor 'method' must be
    logged and dropped — never crash the dispatcher."""
    proc = await AppServerProcess.start(executable=sys.executable, args=(_MOCK,))
    try:
        await proc.initialize(client_info={"name": "test", "version": "0"})
        proc._dispatch({"jsonrpc": "2.0", "weird": "shape"})
    finally:
        await proc.close()


@pytest.mark.asyncio
async def test_dispatch_routes_error_response_to_pending():
    """A response with an error payload must resolve the matching
    future via set_exception(AppServerError)."""
    proc = await AppServerProcess.start(executable=sys.executable, args=(_MOCK,))
    try:
        await proc.initialize(client_info={"name": "test", "version": "0"})
        loop = asyncio.get_running_loop()
        fut: asyncio.Future = loop.create_future()
        proc._pending[7] = fut
        proc._dispatch({
            "jsonrpc": "2.0",
            "id": 7,
            "error": {"code": -32000, "message": "explicit failure"},
        })
        with pytest.raises(AppServerError, match="explicit failure"):
            await fut
    finally:
        proc._pending.clear()
        await proc.close()


# ---- subscriber that raises must not break dispatch -----------------


@pytest.mark.asyncio
async def test_subscriber_exception_does_not_crash_dispatch():
    """If a notification subscriber raises, _dispatch must log and
    continue calling the other subscribers (best-effort delivery)."""
    proc = await AppServerProcess.start(executable=sys.executable, args=(_MOCK,))
    try:
        await proc.initialize(client_info={"name": "test", "version": "0"})

        good_received = []

        def boom(method, params):
            raise RuntimeError("subscriber kaboom")

        def good(method, params):
            good_received.append(method)

        proc.subscribe(boom)
        proc.subscribe(good)

        await proc.request("emit", {"count": 1, "method": "ping"})
        await asyncio.sleep(0.05)

        # The good subscriber still fired despite boom raising.
        assert good_received == ["ping"]
    finally:
        await proc.close()


# ---- non-JSON lines on stdout are skipped ----------------------------


@pytest.mark.asyncio
async def test_reader_skips_non_json_lines(tmp_path):
    """Some codex versions print banner text on stdout before the JSON
    starts. The reader logs and skips those lines without dying."""

    # Stand up a tiny script that prints one banner line, one JSON
    # response to initialize, one more banner, then exits on stdin EOF.
    mock = tmp_path / "noisy_mock.py"
    mock.write_text(textwrap.dedent("""\
        import json, sys, asyncio

        async def main():
            loop = asyncio.get_running_loop()
            reader = asyncio.StreamReader()
            await loop.connect_read_pipe(
                lambda: asyncio.StreamReaderProtocol(reader), sys.stdin
            )
            # Banner line — not JSON.
            sys.stdout.write("=== codex banner ===\\n")
            sys.stdout.flush()
            line = await reader.readline()
            if line:
                msg = json.loads(line.decode())
                sys.stdout.write(json.dumps({
                    "jsonrpc": "2.0", "id": msg["id"],
                    "result": {"userAgent": "noisy/0"}
                }) + "\\n")
                sys.stdout.flush()
            # Trailing non-JSON garbage.
            sys.stdout.write("=== goodbye ===\\n")
            sys.stdout.flush()
            await asyncio.sleep(0.05)

        asyncio.run(main())
    """))

    proc = await AppServerProcess.start(executable=sys.executable, args=(str(mock),))
    try:
        # initialize succeeds despite the banner before/after the JSON.
        result = await proc.initialize(client_info={"name": "t", "version": "0"})
        assert result["userAgent"] == "noisy/0"
    finally:
        await proc.close()

"""Tests for the codex CodexAdapter shell.

The adapter does almost no work — its job is to expose the
BaseAdapter contract (name, schema, capabilities, factory) and gate
boot on ``codex`` binary + ``OPENAI_API_KEY``. The interesting logic
lives in ``executor.py``; this file just validates the shell.
"""

from __future__ import annotations

import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

pytest.importorskip("a2a.helpers")
pytest.importorskip("molecule_runtime.adapters.base")

from adapter import Adapter, CodexAdapter  # noqa: E402
from molecule_runtime.adapters.base import AdapterConfig  # noqa: E402


def test_adapter_alias():
    assert Adapter is CodexAdapter


def test_static_introspection():
    assert CodexAdapter.name() == "codex"
    assert CodexAdapter.display_name() == "OpenAI Codex CLI"
    desc = CodexAdapter.description()
    assert "OpenAI Codex" in desc
    assert "session continuity" in desc
    schema = CodexAdapter.get_config_schema()
    assert "model" in schema
    assert schema["model"]["type"] == "string"


@pytest.mark.asyncio
async def test_setup_raises_without_codex_binary(monkeypatch):
    monkeypatch.setattr("adapter.shutil.which", lambda _: None)
    monkeypatch.setenv("OPENAI_API_KEY", "sk-stub")
    cfg = AdapterConfig(model="gpt-5")
    with pytest.raises(RuntimeError, match="codex binary not on PATH"):
        await CodexAdapter().setup(cfg)


@pytest.mark.asyncio
async def test_setup_raises_without_any_provider_key(monkeypatch):
    """Neither OPENAI_API_KEY nor MINIMAX_API_KEY → fail fast."""
    monkeypatch.setattr("adapter.shutil.which", lambda _: "/usr/local/bin/codex")
    monkeypatch.delenv("OPENAI_API_KEY", raising=False)
    monkeypatch.delenv("MINIMAX_API_KEY", raising=False)
    cfg = AdapterConfig(model="gpt-5")
    with pytest.raises(RuntimeError, match="Neither OPENAI_API_KEY nor MINIMAX_API_KEY"):
        await CodexAdapter().setup(cfg)


@pytest.mark.asyncio
async def test_setup_passes_with_openai_only(monkeypatch):
    """OPENAI_API_KEY alone is enough (default OpenAI-direct path)."""
    monkeypatch.setattr("adapter.shutil.which", lambda _: "/usr/local/bin/codex")
    monkeypatch.setenv("OPENAI_API_KEY", "sk-stub")
    monkeypatch.delenv("MINIMAX_API_KEY", raising=False)
    cfg = AdapterConfig(model="gpt-5")
    await CodexAdapter().setup(cfg)  # no raise


@pytest.mark.asyncio
async def test_setup_passes_with_minimax_only(monkeypatch):
    """MINIMAX_API_KEY alone is enough — codex_bridge.sh routes via
    LiteLLM and writes a sentinel OPENAI_API_KEY at runtime."""
    monkeypatch.setattr("adapter.shutil.which", lambda _: "/usr/local/bin/codex")
    monkeypatch.delenv("OPENAI_API_KEY", raising=False)
    monkeypatch.setenv("MINIMAX_API_KEY", "mm-stub")
    cfg = AdapterConfig(model="MiniMax-M2")
    await CodexAdapter().setup(cfg)  # no raise


@pytest.mark.asyncio
async def test_setup_passes_when_both_present(monkeypatch):
    monkeypatch.setattr("adapter.shutil.which", lambda _: "/usr/local/bin/codex")
    monkeypatch.setenv("OPENAI_API_KEY", "sk-stub")
    cfg = AdapterConfig(model="gpt-5")
    # Should not raise.
    await CodexAdapter().setup(cfg)


@pytest.mark.asyncio
async def test_create_executor_returns_codex_executor():
    from executor import CodexAppServerExecutor
    cfg = AdapterConfig(model="gpt-5")
    executor = await CodexAdapter().create_executor(cfg)
    assert isinstance(executor, CodexAppServerExecutor)

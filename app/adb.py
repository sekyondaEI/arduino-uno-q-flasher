"""Async wrappers around the `adb` CLI.

All functions stream stdout/stderr line-by-line via an async callback so the
caller can forward log lines to a WebSocket without buffering.
"""
from __future__ import annotations

import asyncio
import shutil
from dataclasses import dataclass
from pathlib import Path
from typing import Awaitable, Callable

LineCallback = Callable[[str, str], Awaitable[None]]  # (line, stream)


class AdbNotFoundError(RuntimeError):
    pass


def adb_path() -> str:
    path = shutil.which("adb")
    if not path:
        raise AdbNotFoundError(
            "adb was not found on PATH. Install Android platform-tools and "
            "ensure `adb` is available."
        )
    return path


@dataclass(frozen=True)
class AdbDevice:
    serial: str
    state: str  # "device", "offline", "unauthorized", ...


async def list_devices() -> list[AdbDevice]:
    """Return only devices in the 'device' (online & authorized) state."""
    proc = await asyncio.create_subprocess_exec(
        adb_path(),
        "devices",
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE,
    )
    stdout_b, _ = await proc.communicate()
    if proc.returncode != 0:
        return []
    devices: list[AdbDevice] = []
    for raw in stdout_b.decode(errors="replace").splitlines()[1:]:
        parts = raw.strip().split()
        if len(parts) >= 2 and parts[1] == "device":
            devices.append(AdbDevice(serial=parts[0], state=parts[1]))
    return devices


async def _run_streaming(
    args: list[str],
    on_line: LineCallback | None,
    timeout: float | None = 120.0,
) -> tuple[int, str]:
    """Run `adb` with the given args. Stream stdout/stderr to `on_line`.

    Returns (returncode, combined_output).

    If `timeout` seconds elapse the adb process is killed and we return a
    non-zero rc with an explanatory line, rather than hanging forever. Pass
    timeout=None for genuinely long-running commands (the setup script).
    """
    proc = await asyncio.create_subprocess_exec(
        adb_path(),
        *args,
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE,
    )

    collected: list[str] = []

    async def pump(stream: asyncio.StreamReader, label: str) -> None:
        while True:
            chunk = await stream.readline()
            if not chunk:
                return
            line = chunk.decode(errors="replace").rstrip("\r\n")
            if not line:
                continue
            collected.append(line)
            if on_line is not None:
                await on_line(line, label)

    assert proc.stdout is not None and proc.stderr is not None

    async def _drain_and_wait() -> int:
        await asyncio.gather(
            pump(proc.stdout, "stdout"),
            pump(proc.stderr, "stderr"),
        )
        return await proc.wait()

    try:
        rc = await asyncio.wait_for(_drain_and_wait(), timeout=timeout)
    except asyncio.TimeoutError:
        msg = (
            f"adb {' '.join(args[2:])[:60]} did not return after {timeout:.0f}s; "
            f"killing it. The board is likely offline or the adb server is "
            f"wedged — try `adb devices`, then `adb kill-server`."
        )
        collected.append(msg)
        if on_line is not None:
            await on_line(msg, "stderr")
        try:
            proc.kill()
        except ProcessLookupError:
            pass
        # Do NOT plain `await proc.wait()` here. asyncio only wakes the exit
        # waiter once every pipe is disconnected, and adb forks a server
        # daemon that inherits stdout/stderr -- so the pipes can stay open
        # after the client dies and wait() would block forever.
        try:
            await asyncio.wait_for(proc.wait(), timeout=5.0)
        except (asyncio.TimeoutError, ProcessLookupError):
            pass
        return 124, "\n".join(collected)
    return rc, "\n".join(collected)


async def push(
    serial: str,
    local: Path,
    remote: str,
    on_line: LineCallback | None = None,
    timeout: float | None = 300.0,
) -> tuple[int, str]:
    return await _run_streaming(
        ["-s", serial, "push", str(local), remote], on_line, timeout
    )


async def shell(
    serial: str,
    command: str,
    on_line: LineCallback | None = None,
    timeout: float | None = 120.0,
) -> tuple[int, str]:
    return await _run_streaming(
        ["-s", serial, "shell", command], on_line, timeout
    )

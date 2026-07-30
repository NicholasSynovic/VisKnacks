"""
ParaView MCP server engine (v3, single-tool execute_code).

Unlike v1/v2 (which share the tool set defined in ``pvpython_renderer.tools``),
v3 defines its **own** ``FastMCP`` instance and exposes a **single** tool:
``execute_code``. Like v2 it serves over MCP streamable-http and binds to a
configurable host/port (the MCP transport address).

v3 is **self-contained and stateless**: each ``execute_code`` call spawns its
own short-lived ``pv_runner.py`` (under ``pvpython``) which **listens** for a
reverse connection, then spawns a single-client ``pvserver`` in
**reverse-connection mode** which dials back to the runner on ``localhost``.
The supplied code runs in the runner, all output is captured, and both
processes are torn down again. The caller does **not** need to start
``pvserver`` manually for v3, and there is **no** persistent pipeline state
between calls (each call starts from a blank ParaView session).

Reverse-connection mode is used (server dials client) rather than forward mode
(client dials server) because ``pvserver`` advertises/binds on the machine's
system hostname rather than ``localhost``; a forward ``Connect`` to
``localhost`` is refused for ParaView's entire connect-retry window, which
deadlocks every call. In reverse mode the runner listens on ``localhost`` and
the server is told to dial back there via ``--client-host=localhost``.

Usage:
1. Point an MCP streamable-http client at the bound host:port (default
   http://localhost:8080/mcp).
"""

import shutil
import socket
import subprocess  # nosec B404 - intentional; pvpython/pvserver resolved via shutil.which
import threading
import time
from datetime import datetime
from pathlib import Path

from mcp.server.fastmcp import FastMCP

# Import the prompt and logger from ParaView-free modules (NOT from
# pvpython_renderer.tools, which transitively imports manager.py -> paraview.simple).
# This keeps the v3 engine process import-clean of ParaView; only the
# pv_runner.py subprocess (run via pvpython) needs paraview.simple.
from pvpython_renderer.logger import setup_logging
from pvpython_renderer.prompts import default_prompt

logger = setup_logging()

# The single FastMCP instance for the v3 engine. Distinct from the shared
# instance in ``pvpython_renderer.tools`` used by v1/v2.
mcp = FastMCP("ParaView", instructions=default_prompt)

# Standalone runner script invoked as a subprocess by ``execute_code``. Resolved
# relative to this file so it works regardless of the current working directory.
PV_RUNNER = Path(__file__).parent / "pv_runner.py"

# Directory for per-call log files (runner + pvserver output).
LOG_DIR = Path.home() / "paraview_logs"

# Maximum time (seconds) to wait for the runner subprocess (code execution)
# before giving up. This bounds the *user code*, not the handshake; it is set
# comfortably above ParaView's internal connect-retry window so render-heavy
# code is not killed mid-run.
SUBPROCESS_TIMEOUT = 120

# Runner readiness: the banner the runner (reverse-connection listener) prints
# on stdout once its listening socket is open and it is ready for the server to
# dial back, plus the maximum time we wait to see it before launching pvserver
# anyway (the server's dial-back will surface any failure).
RUNNER_READY_BANNER = "Accepting connection(s)"
RUNNER_READY_TIMEOUT = 30

# Max characters of the user ``code`` echoed into the pv_runner *launch* log
# line. The full code is still executed and its output is logged separately;
# this only keeps the single launch line readable.
CODE_PREVIEW_CHARS = 200


def _code_preview(code: str) -> str:
    """Return a single-line, length-capped preview of ``code`` for logging."""
    flat = " ".join(code.split())
    if len(flat) > CODE_PREVIEW_CHARS:
        return flat[:CODE_PREVIEW_CHARS] + "... [truncated]"
    return flat


# ============================================================================
# Per-call lifecycle helpers (reverse-connection, stateless)
# ============================================================================


def _find_free_port() -> int:
    """Return an unused TCP port on localhost (best-effort, race-tolerant)."""
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.bind(("localhost", 0))
        return s.getsockname()[1]


def _start_reader_threads(
    proc: subprocess.Popen,
    stdout_buffer: list[str],
    stderr_buffer: list[str],
    ready_event: threading.Event | None,
) -> list[threading.Thread]:
    """
    Start daemon threads that drain ``proc``'s stdout and stderr into buffers.

    Draining both pipes from dedicated threads avoids pipe-buffer deadlock and
    avoids the ``communicate()``/manual-read conflict. If ``ready_event`` is
    given, it is set when ``RUNNER_READY_BANNER`` appears on stdout.

    Returns the started threads so callers can ``join`` them at teardown.
    """

    def _read(stream, buffer: list[str], watch: bool) -> None:
        for line in stream:
            buffer.append(line)
            if (
                watch
                and ready_event is not None
                and RUNNER_READY_BANNER in line
            ):
                ready_event.set()

    threads: list[threading.Thread] = []
    if proc.stdout is not None:
        t = threading.Thread(
            target=_read, args=(proc.stdout, stdout_buffer, True), daemon=True
        )
        t.start()
        threads.append(t)
    if proc.stderr is not None:
        t = threading.Thread(
            target=_read, args=(proc.stderr, stderr_buffer, False), daemon=True
        )
        t.start()
        threads.append(t)
    return threads


def _spawn_runner(
    pvpython: str,
    port: int,
    code: str,
    timestamp: str,
) -> tuple[
    subprocess.Popen | None,
    threading.Event,
    list[str],
    list[str],
    list[threading.Thread],
    str,
]:
    """
    Spawn the ``pv_runner.py`` listener (reverse-connection client).

    The runner opens a listening socket on ``port`` (via ``ReverseConnect``),
    waits for the server to dial back, then ``exec``s ``code``. It must be
    started **before** ``pvserver`` (it is the listener in reverse mode).

    Returns ``(proc, ready_event, stdout_buffer, stderr_buffer, threads,
    error)``. ``proc`` is ``None`` and ``error`` is set if the runner could not
    be launched. Reader threads stream the runner's stdout/stderr into the
    buffers and set ``ready_event`` once the readiness banner appears.

    Args:
        pvpython: Resolved path to the ``pvpython`` binary.
        port: Ephemeral local port the runner listens on.
        code: User code to execute once the server connects.
        timestamp: Per-call id used to prefix/correlate log lines.
    """
    ready_event = threading.Event()
    stdout_buffer: list[str] = []
    stderr_buffer: list[str] = []

    cmd = [
        pvpython,
        str(PV_RUNNER),
        "--pv-host",
        "localhost",
        "--pv-port",
        str(port),
        "--code",
        code,
    ]
    try:
        proc = subprocess.Popen(  # nosec B603 - cmd built from shutil.which + fixed args
            cmd,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            bufsize=1,
        )
    except Exception as e:  # pragma: no cover - launch failure
        return (
            None,
            ready_event,
            stdout_buffer,
            stderr_buffer,
            [],
            f"Error launching pv_runner: {str(e)}",
        )

    logger.info(
        f"[call {timestamp}] Launched pv_runner (pid={proc.pid}) listening on "
        f"port {port}: {pvpython} {PV_RUNNER} --pv-host localhost --pv-port "
        f"{port} --code {_code_preview(code)}"
    )

    threads = _start_reader_threads(
        proc, stdout_buffer, stderr_buffer, ready_event
    )
    return proc, ready_event, stdout_buffer, stderr_buffer, threads, ""


def _spawn_pvserver_reverse(
    pvserver: str,
    port: int,
    timestamp: str,
) -> tuple[
    subprocess.Popen | None,
    list[str],
    list[str],
    list[threading.Thread],
    str,
]:
    """
    Spawn a ``pvserver`` in reverse-connection mode that dials the runner back.

    The server connects back to the runner listening on ``localhost:port``
    rather than listening itself. This sidesteps the forward-connection
    hostname-advertisement mismatch.

    Returns ``(proc, stdout_buffer, stderr_buffer, threads, error)``. ``proc``
    is ``None`` and ``error`` is set if ``pvserver`` could not be launched.
    Reader threads stream pvserver stdout/stderr into the buffers.

    Args:
        pvserver: Resolved path to the ``pvserver`` binary.
        port: The port the runner is listening on (server dials this back).
        timestamp: Per-call id used to prefix/correlate log lines.
    """
    stdout_buffer: list[str] = []
    stderr_buffer: list[str] = []

    cmd = [
        pvserver,
        "--reverse-connection",
        "--client-host=localhost",
        f"--server-port={port}",
    ]
    try:
        proc = subprocess.Popen(  # nosec B603 - cmd built from shutil.which + fixed args
            cmd,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            bufsize=1,
        )
    except Exception as e:  # pragma: no cover - launch failure
        return (
            None,
            stdout_buffer,
            stderr_buffer,
            [],
            f"Error launching pvserver: {str(e)}",
        )

    logger.info(
        f"[call {timestamp}] Launched pvserver (pid={proc.pid}) reverse-"
        f"connecting to localhost:{port}: {' '.join(cmd)}"
    )

    threads = _start_reader_threads(proc, stdout_buffer, stderr_buffer, None)
    return proc, stdout_buffer, stderr_buffer, threads, ""


def _terminate_proc(
    proc: subprocess.Popen,
    stdout_buffer: list[str],
    stderr_buffer: list[str],
    threads: list[threading.Thread],
    timestamp: str,
    name: str,
) -> tuple[str, str]:
    """
    Gracefully stop a child process and collect its buffered output.

    The process's output is drained by reader threads started at spawn time;
    this terminates the process (if still running), joins those threads, and
    returns the accumulated buffers.

    Args:
        proc: The running process.
        stdout_buffer: stdout lines accumulated by the reader thread.
        stderr_buffer: stderr lines accumulated by the reader thread.
        threads: The reader threads to join after the process exits.
        timestamp: Per-call id used to prefix/correlate log lines.
        name: Human-readable process name for log messages.

    Returns ``(stdout, stderr)``.
    """
    logger.info(f"[call {timestamp}] Terminating {name} (pid={proc.pid})")
    try:
        if proc.poll() is None:
            proc.terminate()
            try:
                proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                logger.warning(
                    f"[call {timestamp}] {name} did not exit gracefully; killed"
                )
                proc.kill()
                proc.wait()
    except Exception as e:  # pragma: no cover - teardown failure
        logger.error(f"[call {timestamp}] Error terminating {name}: {str(e)}")

    # Reader threads exit once the pipes hit EOF (after the process dies).
    for t in threads:
        t.join(timeout=5)

    logger.info(f"[call {timestamp}] {name} stopped (exit={proc.returncode})")
    return "".join(stdout_buffer), "".join(stderr_buffer)


def _log_call_output(
    timestamp: str,
    runner_stdout: str,
    runner_stderr: str,
    pvserver_stdout: str,
    pvserver_stderr: str,
) -> None:
    """Echo the captured subprocess output into the main log (labeled blocks).

    The same content is also persisted to per-call files by
    ``_write_call_logs``; this surfaces it in the main log/console stream too.
    """
    prefix = f"[call {timestamp}]"
    logger.info(f"{prefix} ===== pv_runner stdout =====\n{runner_stdout}")
    logger.info(f"{prefix} ===== pv_runner stderr =====\n{runner_stderr}")
    logger.info(f"{prefix} ===== pvserver stdout =====\n{pvserver_stdout}")
    logger.info(f"{prefix} ===== pvserver stderr =====\n{pvserver_stderr}")


def _write_call_logs(
    timestamp: str,
    runner_stdout: str,
    runner_stderr: str,
    pvserver_stdout: str,
    pvserver_stderr: str,
) -> None:
    """Write per-call runner and pvserver output to dedicated log files."""
    try:
        LOG_DIR.mkdir(parents=True, exist_ok=True)
        runner_log = LOG_DIR / f"call_{timestamp}_runner.log"
        pvserver_log = LOG_DIR / f"call_{timestamp}_pvserver.log"
        runner_log.write_text(
            f"=== stdout ===\n{runner_stdout}\n"
            f"=== stderr ===\n{runner_stderr}\n"
        )
        pvserver_log.write_text(
            f"=== stdout ===\n{pvserver_stdout}\n"
            f"=== stderr ===\n{pvserver_stderr}\n"
        )
    except Exception as e:  # pragma: no cover - logging is best-effort
        logger.error(f"Error writing per-call logs: {str(e)}")


# ============================================================================
# MCP Tool for ParaView (v3)
# ============================================================================


@mcp.tool()
def execute_code(code: str) -> dict:
    """
    Execute a Python code string against a fresh ParaView session.

    Each call is **self-contained and stateless**: a ``pv_runner.py`` listener
    (under ``pvpython``) is started on an ephemeral local port, a single-client
    ``pvserver`` is then launched in reverse-connection mode to dial back to it,
    the supplied code is run in the runner, and both processes are then shut
    down. There is **no** pipeline state shared between calls, so any
    multi-step workflow must be expressed within a single ``code`` string.

    Args:
        code: Python source to run in a ``paraview.simple`` session.

    Returns:
        A dict with keys ``returncode`` (int), ``runner_stdout`` (str),
        ``runner_stderr`` (str), ``pvserver_stdout`` (str) and
        ``pvserver_stderr`` (str). ``returncode`` is ``-1`` on
        launch/timeout/internal errors.
    """
    timestamp = datetime.now().strftime("%Y%m%d_%H%M%S_%f")

    pvpython = shutil.which("pvpython")
    if pvpython is None:
        message = "pvpython not found on PATH"
        logger.error(f"[call {timestamp}] {message}")
        return {
            "returncode": -1,
            "runner_stdout": "",
            "runner_stderr": message,
            "pvserver_stdout": "",
            "pvserver_stderr": "",
        }

    pvserver = shutil.which("pvserver")
    if pvserver is None:
        message = "pvserver not found on PATH"
        logger.error(f"[call {timestamp}] {message}")
        return {
            "returncode": -1,
            "runner_stdout": "",
            "runner_stderr": message,
            "pvserver_stdout": "",
            "pvserver_stderr": "",
        }

    logger.info(
        f"[call {timestamp}] Resolved binaries: pvpython={pvpython}, "
        f"pvserver={pvserver}"
    )

    port = _find_free_port()

    # 1. Start the runner FIRST: in reverse-connection mode the runner is the
    #    listener and must be up before pvserver dials back.
    (
        runner_proc,
        ready_event,
        runner_out_buf,
        runner_err_buf,
        runner_threads,
        spawn_error,
    ) = _spawn_runner(pvpython, port, code, timestamp)
    if runner_proc is None:
        logger.error(f"[call {timestamp}] {spawn_error}")
        return {
            "returncode": -1,
            "runner_stdout": "",
            "runner_stderr": spawn_error,
            "pvserver_stdout": "",
            "pvserver_stderr": "",
        }

    runner_stdout = ""
    runner_stderr = ""
    runner_stderr_tail = ""
    returncode = -1
    pvserver_proc: subprocess.Popen | None = None
    pvserver_out_buf: list[str] = []
    pvserver_err_buf: list[str] = []
    pvserver_threads: list[threading.Thread] = []

    try:
        # Wait for the runner's listening socket to be open. If the banner does
        # not appear in time, launch pvserver anyway and let the dial-back
        # surface any failure.
        if ready_event.wait(timeout=RUNNER_READY_TIMEOUT):
            logger.info(
                f"[call {timestamp}] pv_runner listening (banner seen) on port "
                f"{port}"
            )
        else:
            logger.warning(
                f"[call {timestamp}] pv_runner readiness banner not seen within "
                f"{RUNNER_READY_TIMEOUT}s on port {port}; proceeding anyway"
            )

        # 2. Launch pvserver in reverse-connection mode to dial the runner back.
        (
            pvserver_proc,
            pvserver_out_buf,
            pvserver_err_buf,
            pvserver_threads,
            pv_error,
        ) = _spawn_pvserver_reverse(pvserver, port, timestamp)
        if pvserver_proc is None:
            logger.error(f"[call {timestamp}] {pv_error}")
            runner_stderr_tail = pv_error
        else:
            # 3. Wait for the runner to finish executing the code.
            start = time.monotonic()
            try:
                returncode = runner_proc.wait(timeout=SUBPROCESS_TIMEOUT)
                duration = time.monotonic() - start
                logger.info(
                    f"[call {timestamp}] pv_runner finished: "
                    f"returncode={returncode}, duration={duration:.2f}s"
                )
            except subprocess.TimeoutExpired:
                duration = time.monotonic() - start
                timeout_note = (
                    f"Subprocess timed out after {SUBPROCESS_TIMEOUT} seconds."
                )
                logger.error(
                    f"[call {timestamp}] {timeout_note} "
                    f"(duration={duration:.2f}s)"
                )
                runner_stderr_tail = timeout_note
            except Exception as e:
                message = f"Error running pv_runner.py: {str(e)}"
                logger.error(f"[call {timestamp}] {message}")
                runner_stderr_tail = message
    finally:
        # Terminate runner first, then pvserver; collect buffered output.
        runner_stdout, runner_stderr = _terminate_proc(
            runner_proc,
            runner_out_buf,
            runner_err_buf,
            runner_threads,
            timestamp,
            "pv_runner",
        )
        if runner_stderr_tail:
            runner_stderr = (
                f"{runner_stderr}\n{runner_stderr_tail}"
                if runner_stderr
                else runner_stderr_tail
            )

        if pvserver_proc is not None:
            pvserver_stdout, pvserver_stderr = _terminate_proc(
                pvserver_proc,
                pvserver_out_buf,
                pvserver_err_buf,
                pvserver_threads,
                timestamp,
                "pvserver",
            )
        else:
            pvserver_stdout, pvserver_stderr = (
                "".join(pvserver_out_buf),
                "".join(pvserver_err_buf),
            )

    _log_call_output(
        timestamp,
        runner_stdout,
        runner_stderr,
        pvserver_stdout,
        pvserver_stderr,
    )

    _write_call_logs(
        timestamp,
        runner_stdout,
        runner_stderr,
        pvserver_stdout,
        pvserver_stderr,
    )

    return {
        "returncode": returncode,
        "runner_stdout": runner_stdout,
        "runner_stderr": runner_stderr,
        "pvserver_stdout": pvserver_stdout,
        "pvserver_stderr": pvserver_stderr,
    }


def run(
    mcp_server: str = "localhost",
    mcp_port: int = 8080,
) -> None:
    """
    Run the v3 MCP server over streamable-http.

    CLI parsing and logging setup are performed by ``pvpython_renderer.cli`` and
    ``pvpython_renderer.main`` before this function is called. v3 manages its own
    ``pvserver`` per ``execute_code`` call, so no ParaView server address is
    configured here.

    Args:
        mcp_server: Hostname the MCP server binds to (transport).
        mcp_port: Port the MCP server binds to (transport).
    """
    # Configure the MCP transport bind address before serving.
    mcp.settings.host = mcp_server
    mcp.settings.port = mcp_port

    # Run the MCP server over streamable-http using the configured bind address.
    try:
        logger.info("Starting ParaView External MCP Server")
        logger.info(f"MCP server (streamable-http): {mcp_server}:{mcp_port}")
        mcp.run(transport="streamable-http")
    except KeyboardInterrupt:
        logger.info("Server stopped by user")
    except Exception as e:
        logger.error(f"Error running MCP server: {str(e)}")

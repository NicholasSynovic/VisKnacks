"""
Logging configuration for the ParaView MCP server.

Provides a single ``setup_logging`` entry point that configures the root
logging handlers (file + stream) and returns the named logger used across
the package. Importing this module does not require ParaView.
"""

import logging
import os
from pathlib import Path

LOGGER_NAME = "pv_external_mcp"
LOG_FORMAT = "%(asctime)s - %(name)s - %(levelname)s - %(message)s"


def setup_logging(level: int = logging.INFO) -> logging.Logger:
    """
    Configure logging for the ParaView MCP server.

    Creates ``~/paraview_logs/`` (if needed) and attaches a file handler
    writing to ``paraview_mcp_external.log`` plus a stream handler. This
    function is idempotent: calling it more than once will not attach
    duplicate handlers.

    Args:
        level: Logging level for the configured handlers (default: INFO).

    Returns:
        The package logger (named ``pv_external_mcp``).
    """
    log_dir = Path.home() / "paraview_logs"
    os.makedirs(log_dir, exist_ok=True)
    log_file = log_dir / "paraview_mcp_external.log"

    root_logger = logging.getLogger()

    # Only configure handlers once to avoid duplicate log lines.
    if not getattr(setup_logging, "_configured", False):
        logging.basicConfig(
            level=level,
            format=LOG_FORMAT,
            handlers=[
                logging.FileHandler(log_file),
                logging.StreamHandler(),
            ],
        )
        setup_logging._configured = True
    else:
        root_logger.setLevel(level)

    return logging.getLogger(LOGGER_NAME)

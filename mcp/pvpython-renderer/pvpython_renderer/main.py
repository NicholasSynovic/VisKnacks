"""
ParaView MCP server entrypoint.

This is the controller invoked by the ``paraview-mcp`` console script
(``pvpython_renderer.main:main``). It parses the CLI arguments, configures
logging, then hands off to the MCP server defined in
``pvpython_renderer.pv_mcp``.

The server module is imported lazily (inside ``main``) because importing it
constructs the FastMCP instance and logger, which should happen after the
CLI and logging are configured.
"""

from pvpython_renderer.cli import parse_args
from pvpython_renderer.logger import setup_logging


def main() -> None:
    """Parse arguments, configure logging, and run the ParaView MCP server."""
    args = parse_args()
    logger = setup_logging()

    try:
        from pvpython_renderer import pv_mcp

        pv_mcp.run(
            mcp_server=args.server,
            mcp_port=args.port,
        )
    except Exception as e:  # pragma: no cover - top-level safety net
        logger.error(f"Fatal error starting ParaView MCP server: {str(e)}")
        raise


if __name__ == "__main__":
    main()

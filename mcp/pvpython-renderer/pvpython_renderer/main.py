"""
ParaView MCP server entrypoint.

This is the controller invoked by the ``paraview-mcp`` console script
(``pvpython_renderer.main:main``). It parses the CLI arguments, configures
logging, optionally extends ``sys.path`` for an external ParaView install,
then hands off to the MCP server defined in ``pvpython_renderer.v1.pv_mcp``.

The server module is imported lazily (inside ``main``) because importing it
pulls in ``paraview.simple`` and constructs the ParaView manager, neither of
which is available without a ParaView build.
"""

import sys

from pvpython_renderer.cli import parse_args
from pvpython_renderer.logger import setup_logging


def main() -> None:
    """Parse arguments, configure logging, and run the ParaView MCP server."""
    args = parse_args()
    logger = setup_logging()

    # Make an external ParaView install importable before importing the
    # engine module (which imports paraview.simple at import time).
    # v3 does not define --paraview-package-path (it is import-clean of
    # paraview.simple), so access it defensively.
    if getattr(args, "paraview_package_path", None):
        sys.path.append(args.paraview_package_path)

    try:
        if args.engine == "v1":
            # Imported lazily, after sys.path is extended, because importing
            # this module pulls in paraview.simple.
            from pvpython_renderer.v1 import pv_mcp

            pv_mcp.run(
                server=args.paraview_server,
                port=args.paraview_port,
                compress_screenshots=args.compress_screenshots,
                max_screenshot_width=args.max_screenshot_width,
                screenshot_quality=args.screenshot_quality,
            )
        elif args.engine == "v2":
            # Imported lazily, after sys.path is extended, because importing
            # this module pulls in paraview.simple.
            from pvpython_renderer.v2 import pv_mcp

            pv_mcp.run(
                paraview_server=args.paraview_server,
                paraview_port=args.paraview_port,
                mcp_server=args.server,
                mcp_port=args.port,
                compress_screenshots=args.compress_screenshots,
                max_screenshot_width=args.max_screenshot_width,
                screenshot_quality=args.screenshot_quality,
            )
        elif args.engine == "v3":
            # v3 is import-clean of paraview.simple (only its pv_runner.py
            # subprocess imports ParaView), but keep the import lazy for
            # symmetry with v1/v2.
            from pvpython_renderer.v3 import pv_mcp

            pv_mcp.run(
                mcp_server=args.server,
                mcp_port=args.port,
            )
        else:
            raise NotImplementedError(
                f"The '{args.engine}' engine is not implemented yet."
            )
    except Exception as e:  # pragma: no cover - top-level safety net
        logger.error(f"Fatal error starting ParaView MCP server: {str(e)}")
        raise


if __name__ == "__main__":
    main()

"""
ParaView MCP server engine (v1, stdio transport).

This is a thin shim around the shared tool definitions in
``paraview_mcp.tools``. The 43 MCP tools and the FastMCP instance live there
and are shared with the v2 engine; v1 differs only in that it serves over
stdio.

Usage:
1. Start pvserver with --multi-clients (e.g. pvserver --multi-clients
   --server-port=11111).
2. Start the ParaView app and connect to the server.
3. Configure the MCP client (e.g. Claude Desktop) to use this engine.
"""

from paraview_mcp.manager import ParaViewManager
from paraview_mcp.tools import logger, mcp, set_pv_manager


def run(
    server: str = "localhost",
    port: int = 11111,
    compress_screenshots: bool = True,
    max_screenshot_width: int = 1280,
    screenshot_quality: int = 85,
) -> None:
    """
    Connect to ParaView and run the MCP server over stdio.

    CLI parsing, logging setup and ``sys.path`` handling for an external
    ParaView install are performed by ``paraview_mcp.cli`` and
    ``paraview_mcp.main`` before this function is called.

    Args:
        server: ParaView server hostname.
        port: ParaView server port.
        compress_screenshots: Whether to compress screenshots to reduce token
            usage.
        max_screenshot_width: Maximum screenshot width in pixels when
            compression is enabled (height scales proportionally).
        screenshot_quality: JPEG quality (1-100) when compression is enabled.
    """
    # Construct the ParaView manager with the CLI-provided screenshot settings
    # and install it for the shared tool functions to use.
    set_pv_manager(
        ParaViewManager(
            compress_screenshots=compress_screenshots,
            max_screenshot_width=max_screenshot_width,
            screenshot_quality=screenshot_quality,
        )
    )

    from paraview_mcp.tools import pv_manager

    # Connect to ParaView
    pv_manager.connect(server, port)

    # Run the MCP server
    try:
        logger.info("Starting ParaView External MCP Server")
        logger.info(f"ParaView server: {server}:{port}")
        mcp.run()
    except KeyboardInterrupt:
        logger.info("Server stopped by user")
    except Exception as e:
        logger.error(f"Error running MCP server: {str(e)}")

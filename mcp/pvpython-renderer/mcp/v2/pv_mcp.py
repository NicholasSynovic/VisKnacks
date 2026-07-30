"""
ParaView MCP server engine (v2, streamable-http transport).

This is a thin shim around the shared tool definitions in
``paraview_mcp.tools``. The 43 MCP tools and the FastMCP instance live there
and are shared with the v1 engine; v2 differs only in that it serves over MCP
streamable-http and binds to a configurable host/port (the MCP transport
address, distinct from the ParaView server address).

Usage:
1. Start pvserver with --multi-clients (e.g. pvserver --multi-clients
   --server-port=11111).
2. Start the ParaView app and connect to the server.
3. Point an MCP streamable-http client at the bound host:port (default
   http://localhost:8080/mcp).
"""

from paraview_mcp.manager import ParaViewManager
from paraview_mcp.tools import logger, mcp, set_pv_manager


def run(
    paraview_server: str = "localhost",
    paraview_port: int = 11111,
    mcp_server: str = "localhost",
    mcp_port: int = 8080,
    compress_screenshots: bool = True,
    max_screenshot_width: int = 1280,
    screenshot_quality: int = 85,
) -> None:
    """
    Connect to ParaView and run the MCP server over streamable-http.

    CLI parsing, logging setup and ``sys.path`` handling for an external
    ParaView install are performed by ``paraview_mcp.cli`` and
    ``paraview_mcp.main`` before this function is called.

    Args:
        paraview_server: ParaView server hostname to connect to.
        paraview_port: ParaView server port to connect to.
        mcp_server: Hostname the MCP server binds to (transport), distinct
            from the ParaView server.
        mcp_port: Port the MCP server binds to (transport), distinct from the
            ParaView port.
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
    pv_manager.connect(paraview_server, paraview_port)

    # Configure the MCP transport bind address before serving.
    mcp.settings.host = mcp_server
    mcp.settings.port = mcp_port

    # Run the MCP server over streamable-http using the configured bind address.
    try:
        logger.info("Starting ParaView External MCP Server")
        logger.info(f"ParaView server: {paraview_server}:{paraview_port}")
        logger.info(f"MCP server (streamable-http): {mcp_server}:{mcp_port}")
        mcp.run(transport="streamable-http")
    except KeyboardInterrupt:
        logger.info("Server stopped by user")
    except Exception as e:
        logger.error(f"Error running MCP server: {str(e)}")

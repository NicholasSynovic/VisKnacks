"""
Command-line interface for the ParaView MCP server.

Thin argparse wrapper that defines the CLI surface and returns the parsed
arguments. Importing this module does not require ParaView; the actual
server is imported and run by ``pvpython_renderer.main``.
"""

import argparse

from pvpython_renderer import __doi__, __prog__, __version__


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    """
    Parse command-line arguments for the ParaView MCP server.

    Args:
        argv: Optional list of arguments to parse. Defaults to ``sys.argv``.

    Returns:
        The parsed argument namespace, containing ``server`` and ``port``
        for the MCP transport bind address.
    """
    parser = argparse.ArgumentParser(
        prog=__prog__,
        description="ParaView External MCP Server",
        epilog=f"DOI: {__doi__}",
    )
    parser.add_argument(
        "--version",
        action="version",
        version=f"%(prog)s {__version__}",
        help="Show the paraview-mcp version and exit",
    )

    mcp_group = parser.add_argument_group("MCP Server Options")
    mcp_group.add_argument(
        "--server",
        type=str,
        default="localhost",
        help="MCP server bind hostname (default: %(default)s)",
    )
    mcp_group.add_argument(
        "--port",
        type=int,
        default=8080,
        help="MCP server bind port (default: %(default)s)",
    )

    return parser.parse_args(argv)

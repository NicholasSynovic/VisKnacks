"""
Command-line interface for the ParaView MCP server.

Thin argparse wrapper that defines the CLI surface and returns the parsed
arguments. Importing this module does not require ParaView; the actual
server is imported and run by ``paraview_mcp.main``.
"""

import argparse

from paraview_mcp import __doi__, __prog__, __version__


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    """
    Parse command-line arguments for the ParaView MCP server.

    Args:
        argv: Optional list of arguments to parse. Defaults to ``sys.argv``.

    Returns:
        The parsed argument namespace. Depending on the chosen sub-command,
        it will contain 'engine' ("v1", "v2" or "v3") along with the
        engine-specific arguments.
    """
    # 1. Define the shared parent parser for ParaView options
    # We set add_help=False so it doesn't conflict with the subparser help flags
    pv_parent = argparse.ArgumentParser(add_help=False)
    pv_group = pv_parent.add_argument_group("ParaView Server Options")
    pv_group.add_argument(
        "--paraview-server",
        type=str,
        default="localhost",
        help="ParaView server hostname (default: %(default)s)",
    )
    pv_group.add_argument(
        "--paraview-port",
        type=int,
        default=11111,
        help="ParaView server port (default: %(default)s)",
    )
    # --paraview-package-path lives on its own parent parser so only engines
    # that import paraview.simple in-process (v1/v2) inherit it. v3 is
    # import-clean of ParaView (only its pv_runner.py subprocess imports it),
    # so it does NOT need this flag.
    pkg_parent = argparse.ArgumentParser(add_help=False)
    pkg_group = pkg_parent.add_argument_group("External ParaView Options")
    pkg_group.add_argument(
        "--paraview-package-path",
        type=str,
        default=None,
        help=(
            "Path to an external ParaView install's site-packages directory. "
            "When set, it is appended to sys.path before importing "
            "paraview.simple (default: %(default)s)"
        ),
    )

    # Screenshot options live on a separate parent parser so engines can opt
    # in independently. v1/v2 inherit it; v3 (no screenshot functionality) does
    # not.
    ss_parent = argparse.ArgumentParser(add_help=False)
    ss_group = ss_parent.add_argument_group("Screenshot Compression Options")
    ss_group.add_argument(
        "--compress-screenshots",
        action=argparse.BooleanOptionalAction,
        default=True,
        help="Compress screenshots to reduce token usage (default: %(default)s)",
    )
    ss_group.add_argument(
        "--max-screenshot-width",
        type=int,
        default=1280,
        help=(
            "Maximum screenshot width in pixels when compression is enabled "
            "(default: %(default)s)"
        ),
    )
    ss_group.add_argument(
        "--screenshot-quality",
        type=int,
        default=85,
        help=(
            "JPEG quality 1-100 when compression is enabled (default: %(default)s)"
        ),
    )

    # 2. Define the main root parser
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

    subparsers = parser.add_subparsers(
        dest="engine", required=True, help="ParaView MCP engine to run"
    )

    # =========================================================================
    # --- V1 Subparser Configuration -----------------------------------------
    # =========================================================================
    # Inherits the ParaView options automatically via the parents parameter
    subparsers.add_parser(
        "v1",
        parents=[pv_parent, ss_parent, pkg_parent],
        help="Run using V1 engine protocols",
    )

    # =========================================================================
    # --- V2 Subparser Configuration -----------------------------------------
    # =========================================================================
    # Inherits the ParaView options via parents, and adds its own MCP options
    v2_parser = subparsers.add_parser(
        "v2",
        parents=[pv_parent, ss_parent, pkg_parent],
        help="Run using V2 engine protocols",
    )

    v2_mcp_group = v2_parser.add_argument_group("V2 MCP Server Options")
    v2_mcp_group.add_argument(
        "--server",
        type=str,
        default="localhost",
        help=(
            "MCP server bind hostname (transport), distinct from "
            "--paraview-server (default: %(default)s)"
        ),
    )
    v2_mcp_group.add_argument(
        "--port",
        type=int,
        default=8080,
        help=(
            "MCP server bind port (transport), distinct from "
            "--paraview-port (default: %(default)s)"
        ),
    )

    # =========================================================================
    # --- V3 Subparser Configuration -----------------------------------------
    # =========================================================================
    # Single-tool (execute_code) engine. Like v2 it serves over streamable-http
    # and adds its own MCP bind options. v3 manages its own pvserver per call,
    # so it does NOT inherit pv_parent (--paraview-server/--paraview-port).
    v3_parser = subparsers.add_parser(
        "v3", help="Run using V3 engine protocols"
    )

    v3_mcp_group = v3_parser.add_argument_group("V3 MCP Server Options")
    v3_mcp_group.add_argument(
        "--server",
        type=str,
        default="localhost",
        help=(
            "MCP server bind hostname (transport), distinct from "
            "--paraview-server (default: %(default)s)"
        ),
    )
    v3_mcp_group.add_argument(
        "--port",
        type=int,
        default=8080,
        help=(
            "MCP server bind port (transport), distinct from "
            "--paraview-port (default: %(default)s)"
        ),
    )

    return parser.parse_args(argv)

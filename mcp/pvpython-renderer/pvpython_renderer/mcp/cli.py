from argparse import ArgumentParser, Namespace

from importlib_metadata import version

from pvpython_renderer.mcp import __prog__


def cli_parser() -> Namespace:
    parser: ArgumentParser = ArgumentParser(
        prog=__prog__,
        description="MCP service frontend to execute `pvpython` code",
    )
    parser.add_argument(
        "--server",
        type=str,
        default="localhost",
        help="MCP server bind hostname (default: %(default)s)",
    )
    parser.add_argument(
        "--port",
        type=int,
        default=8080,
        help="MCP server bind port (default: %(default)s)",
    )
    parser.add_argument(
        "--version",
        action="version",
        version=f"%(prog)s {version(distribution_name=__prog__)}",
        help="Show the version and exit",
    )
    parser.parse_args()

    return parser.parse_args()
